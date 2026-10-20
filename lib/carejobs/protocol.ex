defmodule CareJobs.Protocol do
  @moduledoc false

  # JSON-RPC 2.0 over MCP's streamable HTTP transport, pure functions only: encoding the
  # request, and turning the HTTP answer into a tool result or a CareJobs.Error.

  alias CareJobs.Error

  @doc "Encodes one JSON-RPC request."
  @spec encode_request(integer(), String.t(), map(), String.t() | nil) ::
          {:ok, binary()} | {:error, Error.t()}
  def encode_request(id, method, params, tool) do
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    {:ok, JSON.encode!(body)}
  rescue
    exception ->
      {:error,
       Error.new(
         :protocol,
         "The arguments cannot be encoded as JSON: " <> Exception.message(exception),
         tool: tool
       )}
  end

  @doc """
  Reads the `result` of the JSON-RPC answer inside an HTTP response, or the error that the
  status, the body or the JSON-RPC error stands for.
  """
  @spec decode_result(
          %{status: integer(), headers: [{String.t(), String.t()}], body: binary()},
          integer(),
          String.t() | nil
        ) :: {:ok, term()} | {:error, Error.t()}
  def decode_result(%{status: status, headers: headers, body: body}, id, tool) do
    body = String.replace_invalid(body)
    content_type = header(headers, "content-type")

    if status in 200..299 do
      with {:ok, message} <- parse_message(body, content_type, id, tool) do
        unwrap(message, tool)
      end
    else
      {:error,
       Error.new(:http, http_detail(status, body, content_type, id), status: status, tool: tool)}
    end
  end

  @doc """
  Turns the `result` of a `tools/call` into `{:ok, %{data: map, text: string}}`, or the
  `:tool` error the server answered with.
  """
  @spec tool_result(term(), String.t()) ::
          {:ok, %{data: map(), text: String.t()}} | {:error, Error.t()}
  def tool_result(%{} = raw, name) do
    text = text_of(raw["content"])

    cond do
      raw["isError"] not in [nil, false] ->
        {:error, Error.new(:tool, if(text == "", do: "#{name} failed", else: text), tool: name)}

      is_map(raw["structuredContent"]) ->
        {:ok, %{data: raw["structuredContent"], text: text}}

      true ->
        {:error, Error.new(:protocol, "#{name} answered without structured content", tool: name)}
    end
  end

  def tool_result(_raw, name) do
    {:error, Error.new(:protocol, "#{name} answered without a result", tool: name)}
  end

  @doc "The tools of a `tools/list` result."
  @spec tools_list(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def tools_list(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}

  def tools_list(_raw) do
    {:error, Error.new(:protocol, "tools/list answered without a tools list")}
  end

  # -- internals --------------------------------------------------------------------------

  defp text_of(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp text_of(_content), do: ""

  defp unwrap(%{"error" => error}, tool) when not is_nil(error) do
    case error do
      %{} = error ->
        message = error["message"]
        code = error["code"]

        {:error,
         Error.new(
           :rpc,
           if(is_binary(message) and message != "", do: message, else: "JSON-RPC error"),
           rpc_code: if(is_integer(code), do: code),
           tool: tool
         )}

      _other ->
        {:error, Error.new(:protocol, "Malformed JSON-RPC error", tool: tool)}
    end
  end

  defp unwrap(%{"result" => result}, _tool) when not is_nil(result), do: {:ok, result}

  defp unwrap(_message, tool) do
    {:error, Error.new(:protocol, "The answer held no result", tool: tool)}
  end

  # A plain JSON body, or the JSON-RPC message inside a text/event-stream body.
  defp parse_message(body, content_type, id, tool) do
    if String.contains?(content_type, "text/event-stream") do
      parse_event_stream(body, id, tool)
    else
      case JSON.decode(body) do
        {:ok, %{} = message} ->
          {:ok, message}

        {:ok, _other} ->
          {:error,
           Error.new(:protocol, "The server did not answer with a JSON-RPC object", tool: tool)}

        {:error, _reason} ->
          {:error, Error.new(:protocol, "The server did not answer with JSON", tool: tool)}
      end
    end
  end

  # The message whose id matches the request, else the first message that carries a result
  # or an error.
  defp parse_event_stream(body, id, tool) do
    messages =
      body
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")
      |> Enum.flat_map(&event_message/1)

    case Enum.find(messages, &(&1["id"] == id)) ||
           Enum.find(messages, &(Map.has_key?(&1, "result") or Map.has_key?(&1, "error"))) do
      nil ->
        {:error, Error.new(:protocol, "The event stream held no JSON-RPC answer", tool: tool)}

      message ->
        {:ok, message}
    end
  end

  defp event_message(event) do
    data =
      for "data:" <> rest <- String.split(event, "\n") do
        String.replace_prefix(rest, " ", "")
      end

    with [_ | _] <- data,
         {:ok, %{} = message} <- data |> Enum.join("\n") |> JSON.decode() do
      [message]
    else
      _other -> []
    end
  end

  defp http_detail(status, body, content_type, id) do
    detail = "HTTP #{status}"

    with {:ok, message} <- parse_message(body, content_type, id, nil),
         %{"error" => %{"message" => text}} when is_binary(text) and text != "" <- message do
      "#{detail}: #{text}"
    else
      _other ->
        case body |> String.trim() |> String.slice(0, 200) do
          "" -> detail
          text -> "#{detail}: #{text}"
        end
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, "", fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end
end
