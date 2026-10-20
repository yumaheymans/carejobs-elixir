defmodule FakeServer do
  @moduledoc false

  # A real HTTP server on 127.0.0.1, plain or TLS, that answers with whatever its handler
  # returns, so the tests exercise the real :httpc code with no network. One request per
  # connection.
  #
  # The handler gets a request map (%{method, path, headers, body}, header names lowercased)
  # and returns {status, headers, body}, or just a body string for a 200 JSON answer.

  def start(handler, options \\ []) do
    {:ok, requests} = Agent.start(fn -> [] end)
    {listen_module, listen_options} = listener(Keyword.get(options, :tls))

    {:ok, listen} =
      listen_module.listen(
        0,
        [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ listen_options
      )

    {:ok, {_address, port}} = sockname(listen_module, listen)
    owner = spawn(fn -> own(listen_module, listen, handler, requests) end)

    scheme = if Keyword.get(options, :tls), do: "https", else: "http"

    %{
      owner: owner,
      port: port,
      requests: requests,
      url: "#{scheme}://localhost:#{port}"
    }
  end

  def stop(%{owner: owner, requests: requests}) do
    send(owner, :stop)
    if Process.alive?(requests), do: Agent.stop(requests)
  end

  def requests(%{requests: requests}), do: requests |> Agent.get(& &1) |> Enum.reverse()

  def last_request(server), do: server |> requests() |> List.last()

  # A TLS server config with a certificate for "localhost", and the CA certificates a client
  # has to trust to accept it.
  def tls_config do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    key = {:namedCurve, :secp256r1}

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: key, digest: :sha256],
          peer: [key: key, digest: :sha256, extensions: [san]]
        },
        client_chain: %{root: [], peer: []}
      })

    %{server: [cert: server[:cert], key: server[:key]], cacerts: server[:cacerts]}
  end

  # -- internals --------------------------------------------------------------------------

  defp listener(nil), do: {:gen_tcp, []}
  defp listener(tls), do: {:ssl, [log_level: :error] ++ tls}

  defp sockname(:gen_tcp, listen), do: :inet.sockname(listen)
  defp sockname(:ssl, listen), do: :ssl.sockname(listen)

  defp own(module, listen, handler, requests) do
    acceptor = spawn_link(fn -> accept_loop(module, listen, handler, requests) end)

    receive do
      :stop ->
        Process.unlink(acceptor)
        Process.exit(acceptor, :kill)
        module.close(listen)
    end
  end

  defp accept_loop(module, listen, handler, requests) do
    case accept(module, listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(module, socket, handler, requests) end)
        controlling_process(module, socket, pid)
        send(pid, :go)
        accept_loop(module, listen, handler, requests)

      {:error, _reason} ->
        accept_loop(module, listen, handler, requests)
    end
  end

  defp accept(:gen_tcp, listen), do: :gen_tcp.accept(listen)

  defp accept(:ssl, listen) do
    with {:ok, socket} <- :ssl.transport_accept(listen) do
      # The handshake runs in the accepting process, so a client that rejects the
      # certificate costs only a failed handshake.
      case :ssl.handshake(socket, 5_000) do
        {:ok, tls_socket} -> {:ok, tls_socket}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp controlling_process(module, socket, pid), do: module.controlling_process(socket, pid)

  defp serve(module, socket, handler, requests) do
    receive do
      :go -> :ok
    end

    with {:ok, request} <- read_request(module, socket) do
      Agent.update(requests, &[request | &1])

      {status, headers, body} =
        case handler.(request) do
          body when is_binary(body) -> {200, %{}, body}
          {status, headers, body} -> {status, Map.new(headers), body}
        end

      headers = Map.merge(%{"content-type" => "application/json"}, headers)

      response =
        ["HTTP/1.1 #{status} Status\r\n"] ++
          for({name, value} <- headers, do: "#{name}: #{value}\r\n") ++
          ["content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n", body]

      module.send(socket, response)
    end

    module.close(socket)
  end

  defp read_request(module, socket, buffer \\ "") do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, path | _] = String.split(request_line, " ")

        headers =
          Map.new(header_lines, fn line ->
            [name, value] = String.split(line, ": ", parts: 2)
            {String.downcase(name), value}
          end)

        length = headers |> Map.get("content-length", "0") |> String.to_integer()

        with {:ok, body} <- read_body(module, socket, rest, length) do
          {:ok, %{method: method, path: path, headers: headers, body: body}}
        end

      [_incomplete] ->
        with {:ok, data} <- module.recv(socket, 0, 5_000) do
          read_request(module, socket, buffer <> data)
        end
    end
  end

  defp read_body(_module, _socket, buffer, length) when byte_size(buffer) >= length do
    {:ok, binary_part(buffer, 0, length)}
  end

  defp read_body(module, socket, buffer, length) do
    with {:ok, data} <- module.recv(socket, 0, 5_000) do
      read_body(module, socket, buffer <> data, length)
    end
  end
end
