defmodule CareJobs.ProtocolTest do
  use ExUnit.Case, async: true

  alias CareJobs.{Error, Protocol}

  defp response(body, content_type \\ "application/json", status \\ 200) do
    %{status: status, headers: [{"Content-Type", content_type}], body: body}
  end

  describe "decode_result/3 with an event stream" do
    @answer ~s({"jsonrpc":"2.0","id":7,"result":{"ok":true}})

    test "picks the message whose id matches" do
      body = ~s(data: {"jsonrpc":"2.0","id":8,"result":{"ok":false}}\n\ndata: #{@answer}\n\n)

      assert {:ok, %{"ok" => true}} =
               Protocol.decode_result(response(body, "text/event-stream"), 7, nil)
    end

    test "falls back to the first message that carries a result or an error" do
      body =
        ~s(data: {"jsonrpc":"2.0","method":"ping"}\n\ndata: {"jsonrpc":"2.0","id":99,"result":{"ok":1}}\n\n)

      assert {:ok, %{"ok" => 1}} =
               Protocol.decode_result(response(body, "text/event-stream"), 7, nil)
    end

    test "reads CRLF line endings, a data line with no space and data split over lines" do
      body =
        "event: message\r\ndata:{\"jsonrpc\":\"2.0\",\r\ndata: \"id\":7,\"result\":{\"ok\":true}}\r\n\r\n"

      assert {:ok, %{"ok" => true}} =
               Protocol.decode_result(response(body, "text/event-stream; charset=utf-8"), 7, nil)
    end

    test "skips events that are not JSON objects, and comments" do
      body = ": keep-alive\n\ndata: not json\n\ndata: [1]\n\ndata: #{@answer}\n\n"

      assert {:ok, %{"ok" => true}} =
               Protocol.decode_result(response(body, "text/event-stream"), 7, nil)
    end

    test "a stream with no answer is :protocol" do
      assert {:error,
              %Error{code: :protocol, message: "The event stream held no JSON-RPC answer"}} =
               Protocol.decode_result(response("data: nope\n\n", "text/event-stream"), 7, nil)

      assert {:error, %Error{code: :protocol}} =
               Protocol.decode_result(response("", "text/event-stream"), 7, "t")
    end

    test "an error in the stream is the error" do
      body =
        ~s(data: {"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"Unknown tool: nope"}}\n\n)

      assert {:error, %Error{code: :rpc, rpc_code: -32_602, message: "Unknown tool: nope"}} =
               Protocol.decode_result(response(body, "text/event-stream"), 7, "nope")
    end
  end

  describe "decode_result/3" do
    test "a JSON-RPC error without a message still says what it is" do
      body = ~s({"jsonrpc":"2.0","id":1,"error":{"code":"x"}})

      assert {:error, %Error{code: :rpc, rpc_code: nil, message: "JSON-RPC error"}} =
               Protocol.decode_result(response(body), 1, nil)
    end

    test "a null error with a result is the result" do
      body = ~s({"jsonrpc":"2.0","id":1,"error":null,"result":{"a":1}})
      assert {:ok, %{"a" => 1}} = Protocol.decode_result(response(body), 1, nil)
    end

    test "an HTTP error body is cut to 200 characters" do
      assert {:error, %Error{code: :http, message: message}} =
               Protocol.decode_result(
                 response(String.duplicate("x", 500), "text/plain", 503),
                 1,
                 nil
               )

      assert message == "HTTP 503: " <> String.duplicate("x", 200)
    end

    test "header names are matched in any case" do
      body = ~s(data: {"jsonrpc":"2.0","id":1,"result":{"a":1}}\n\n)
      response = %{status: 200, headers: [{"CONTENT-TYPE", "text/event-stream"}], body: body}
      assert {:ok, %{"a" => 1}} = Protocol.decode_result(response, 1, nil)
    end
  end

  describe "tool_result/2" do
    test "joins the text parts with newlines and ignores the others" do
      raw = %{
        "content" => [
          %{"type" => "text", "text" => "one"},
          %{"type" => "image", "data" => "..."},
          %{"type" => "text", "text" => "two"}
        ],
        "structuredContent" => %{"a" => 1}
      }

      assert {:ok, %{data: %{"a" => 1}, text: "one\ntwo"}} = Protocol.tool_result(raw, "t")
    end

    test "an error without text still names the tool" do
      assert {:error, %Error{code: :tool, message: "t failed", tool: "t"}} =
               Protocol.tool_result(%{"isError" => true}, "t")
    end

    test "a result that is not an object is :protocol" do
      assert {:error, %Error{code: :protocol, message: "t answered without a result"}} =
               Protocol.tool_result("x", "t")
    end

    test "a structured content that is not an object is :protocol" do
      assert {:error, %Error{code: :protocol}} =
               Protocol.tool_result(%{"structuredContent" => [1]}, "t")
    end
  end

  describe "tools_list/1" do
    test "needs a list of tools" do
      assert {:ok, [%{"name" => "a"}]} = Protocol.tools_list(%{"tools" => [%{"name" => "a"}]})

      assert {:error,
              %Error{code: :protocol, message: "tools/list answered without a tools list"}} =
               Protocol.tools_list(%{"tools" => "no"})
    end
  end
end
