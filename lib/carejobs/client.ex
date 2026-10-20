defmodule CareJobs.Client do
  @moduledoc false

  # Settings and the request pipeline behind the public CareJobs functions:
  # settings (defaults < application environment < options of the call), one JSON-RPC
  # request through the transport, and the mapping of everything that can go wrong to a
  # CareJobs.Error.

  alias CareJobs.{Error, HTTP, Protocol}

  @version Mix.Project.config()[:version]

  @default_base_url "https://carejobs.now"

  # Milliseconds. The server answers a query it has not seen before in up to about 25
  # seconds (its database may be waking up), then repeats of it in a fraction of one.
  @default_timeout 60_000

  @transport_keys [:base_url, :timeout, :user_agent, :request_fun, :cacerts]

  @type config :: %{
          url: String.t(),
          timeout: pos_integer(),
          user_agent: String.t(),
          request_fun: (HTTP.request() -> {:ok, HTTP.response()} | {:error, term()})
        }

  @doc "The options that configure the transport rather than the tool call."
  @spec transport_keys() :: [atom()]
  def transport_keys, do: @transport_keys

  @doc """
  Builds the settings of a call from the defaults, the `:carejobs` application environment
  and the options of the call. Raises `ArgumentError` for an invalid setting.
  """
  @spec config!(keyword()) :: config()
  def config!(options) do
    settings =
      [
        base_url: @default_base_url,
        timeout: @default_timeout,
        user_agent: "carejobs-elixir/#{@version}"
      ]
      |> Keyword.merge(Keyword.take(Application.get_all_env(:carejobs), @transport_keys))
      |> Keyword.merge(options)

    base_url = settings[:base_url]
    timeout = settings[:timeout]
    user_agent = settings[:user_agent]
    cacerts = settings[:cacerts]
    request_fun = settings[:request_fun]

    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError,
            "the :timeout option must be a number of milliseconds above 0, got: #{inspect(timeout)}"
    end

    unless is_binary(user_agent) and user_agent != "" do
      raise ArgumentError,
            "the :user_agent option must be a non-empty string, got: #{inspect(user_agent)}"
    end

    unless is_nil(cacerts) or is_list(cacerts) do
      raise ArgumentError,
            "the :cacerts option must be a list of CA certificates, got: #{inspect(cacerts)}"
    end

    unless is_nil(request_fun) or is_function(request_fun, 1) do
      raise ArgumentError,
            "the :request_fun option must be a function of one argument, got: #{inspect(request_fun)}"
    end

    %{
      url: endpoint!(base_url),
      timeout: timeout,
      user_agent: user_agent,
      request_fun: request_fun || (&HTTP.request(&1, cacerts))
    }
  end

  @doc "Calls one tool. `arguments` is a map with string keys and no nil values."
  @spec call_tool(String.t(), map(), config()) ::
          {:ok, %{data: map(), text: String.t()}} | {:error, Error.t()}
  def call_tool(name, arguments, config) do
    with {:ok, raw} <-
           rpc("tools/call", %{"name" => name, "arguments" => arguments}, name, config) do
      Protocol.tool_result(raw, name)
    end
  end

  @doc "The tools the server offers, with their input schemas."
  @spec list_tools(config()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_tools(config) do
    with {:ok, raw} <- rpc("tools/list", %{}, nil, config) do
      Protocol.tools_list(raw)
    end
  end

  # -- internals --------------------------------------------------------------------------

  defp endpoint!(base_url) do
    uri = if is_binary(base_url), do: URI.parse(base_url)

    if match?(
         %URI{scheme: scheme, host: host}
         when scheme in ["http", "https"] and host not in [nil, ""],
         uri
       ) do
      String.trim_trailing(base_url, "/") <> "/api/mcp"
    else
      raise ArgumentError,
            "the :base_url option must be an http:// or https:// address, got: #{inspect(base_url)}"
    end
  end

  defp rpc(method, params, tool, config) do
    id = System.unique_integer([:positive])

    with {:ok, body} <- Protocol.encode_request(id, method, params, tool),
         {:ok, response} <- send_request(body, tool, config) do
      Protocol.decode_result(response, id, tool)
    end
  end

  defp send_request(body, tool, config) do
    request = %{
      method: :post,
      url: config.url,
      headers: [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"user-agent", config.user_agent}
      ],
      body: body,
      timeout: config.timeout
    }

    case config.request_fun.(request) do
      {:ok, %{status: status, body: body} = response}
      when is_integer(status) and is_binary(body) ->
        {:ok, Map.put_new(response, :headers, [])}

      {:error, reason} ->
        {:error, transport_error(reason, config, tool)}

      other ->
        {:error,
         Error.new(
           :protocol,
           "The request function returned #{inspect(other)}, not {:ok, response} or {:error, reason}",
           tool: tool
         )}
    end
  end

  defp transport_error(reason, config, tool) do
    if timeout?(reason) do
      Error.new(:timeout, "No answer from #{config.url} within #{config.timeout} ms", tool: tool)
    else
      Error.new(:network, "Could not reach #{config.url}: #{format_reason(reason)}", tool: tool)
    end
  end

  # :httpc reports a request that ran out of time as :timeout, and a connection attempt that
  # ran out of time as a failed_connect with a :timeout inside.
  defp timeout?(reason) when reason in [:timeout, :etimedout], do: true

  defp timeout?({:failed_connect, details}) when is_list(details) do
    Enum.any?(details, fn
      {:inet, _families, reason} -> timeout?(reason)
      _detail -> false
    end)
  end

  defp timeout?(_reason), do: false

  defp format_reason({:failed_connect, details}) when is_list(details) do
    details
    |> Enum.flat_map(fn
      {:inet, _families, reason} -> [format_reason(reason)]
      {:tls_alert, _alert} = alert -> [format_reason(alert)]
      _detail -> []
    end)
    |> case do
      [] -> inspect({:failed_connect, details})
      reasons -> Enum.join(reasons, ", ")
    end
  end

  defp format_reason({:tls_alert, {alert, text}}) do
    "TLS handshake failed (#{alert}): #{tls_detail(text)}"
  end

  defp format_reason(reason) when is_atom(reason) do
    text = reason |> :inet.format_error() |> to_string()

    if String.starts_with?(text, "unknown POSIX error"),
      do: inspect(reason),
      else: "#{reason} (#{text})"
  end

  defp format_reason(reason), do: inspect(reason)

  # The OTP alert text reads "TLS client: In state certify at ssl_handshake.erl:2316
  # generated CLIENT ALERT: Fatal - Bad Certificate\n {bad_cert, ...}". Keep what follows
  # "CLIENT ALERT: " on one line.
  defp tls_detail(text) do
    text
    |> to_string()
    |> String.replace(~r/^.*?ALERT: /s, "")
    |> String.split()
    |> Enum.join(" ")
  end
end
