defmodule CareJobsTest do
  use ExUnit.Case

  doctest CareJobs
  doctest CareJobs.Error

  @version Mix.Project.config()[:version]

  # The recorded answer that belongs to the tool in the request.
  @recordings %{
    "search_healthcare_jobs" => "search",
    "get_healthcare_pay" => "pay_overview",
    "get_healthcare_job_market" => "market",
    "get_healthcare_jobs_by_state" => "states_overview",
    "list_healthcare_employers" => "employers",
    "get_healthcare_employer" => "employer"
  }

  setup do
    server =
      FakeServer.start(fn request ->
        body = JSON.decode!(request.body)

        if body["method"] == "tools/list" do
          Fixtures.raw("tools_list")
        else
          Fixtures.raw(Map.fetch!(@recordings, body["params"]["name"]))
        end
      end)

    on_exit(fn -> FakeServer.stop(server) end)
    %{server: server, opts: [base_url: server.url, timeout: 5_000]}
  end

  defp serving(answer) do
    server = FakeServer.start(fn _request -> answer end)
    on_exit(fn -> FakeServer.stop(server) end)
    [base_url: server.url, timeout: 5_000]
  end

  defp calls(server) do
    for request <- FakeServer.requests(server) do
      body = JSON.decode!(request.body)
      {body["params"]["name"], body["params"]["arguments"]}
    end
  end

  describe "the request" do
    test "is a JSON-RPC tools/call POST to /api/mcp", %{server: server, opts: opts} do
      assert {:ok, _result} = CareJobs.search_jobs([query: "icu", state: "TX"] ++ opts)

      request = FakeServer.last_request(server)
      assert request.method == "POST"
      assert request.path == "/api/mcp"
      assert request.headers["content-type"] == "application/json"
      assert request.headers["accept"] == "application/json, text/event-stream"
      assert request.headers["user-agent"] == "carejobs-elixir/#{@version}"

      body = JSON.decode!(request.body)
      assert is_integer(body["id"])

      assert Map.delete(body, "id") == %{
               "jsonrpc" => "2.0",
               "method" => "tools/call",
               "params" => %{
                 "name" => "search_healthcare_jobs",
                 "arguments" => %{"query" => "icu", "state" => "TX"}
               }
             }
    end

    test "carries a different id each time", %{server: server, opts: opts} do
      for _ <- 1..3, do: CareJobs.job_market(opts)

      ids = for request <- FakeServer.requests(server), do: JSON.decode!(request.body)["id"]
      assert length(Enum.uniq(ids)) == 3
    end

    test "sends the user agent and ignores trailing slashes of the base URL", %{server: server} do
      CareJobs.job_market(base_url: server.url <> "//", user_agent: "my-app/1.0")

      request = FakeServer.last_request(server)
      assert request.path == "/api/mcp"
      assert request.headers["user-agent"] == "my-app/1.0"
    end

    test "leaves nil out, turns atoms into strings, and sends remote only when true", %{
      server: server,
      opts: opts
    } do
      CareJobs.search_jobs(
        [
          kind: :nurses,
          employer: nil,
          remote: false,
          min_hourly_usd: 50,
          sort: "newest",
          limit: 3
        ] ++
          opts
      )

      assert [{_tool, arguments}] = calls(server)

      assert arguments == %{
               "kind" => "nurses",
               "min_hourly_usd" => 50,
               "sort" => "newest",
               "limit" => 3
             }

      CareJobs.search_jobs([remote: true] ++ opts)
      assert {_tool, %{"remote" => true}} = server |> calls() |> List.last()
    end

    test "reads an underscore in a kind, type or care atom as the API's hyphen", %{
      server: server,
      opts: opts
    } do
      CareJobs.search_jobs([kind: :nursing_assistants, sort: :highest_pay] ++ opts)

      CareJobs.employers(
        [type: :ai_program, care: :home_care, kind: :nurse_practitioners] ++ opts
      )

      CareJobs.employers([kind: "nursing_assistants"] ++ opts)

      assert [
               {_, %{"kind" => "nursing-assistants", "sort" => "highest_pay"}},
               {_,
                %{"type" => "ai-program", "care" => "home-care", "kind" => "nurse-practitioners"}},
               {_, %{"kind" => "nursing_assistants"}}
             ] = calls(server)
    end

    test "every function calls its tool with the API's names", %{server: server, opts: opts} do
      CareJobs.search_jobs(
        [
          query: "night",
          kind: "nurses",
          employer: "kaiser-permanente",
          state: "Texas",
          remote: true,
          min_hourly_usd: 40,
          sort: "highest_pay",
          limit: 5
        ] ++ opts
      )

      CareJobs.pay([kind: "nurses", employer: "cvs-health"] ++ opts)
      CareJobs.job_market(opts)
      CareJobs.jobs_by_state([state: "OH", kind: "nursing-assistants", limit: 2] ++ opts)

      CareJobs.employers(
        [
          query: "kaiser",
          type: "employer",
          care: "home-care",
          state: "CA",
          kind: "physicians",
          limit: 9
        ] ++
          opts
      )

      CareJobs.employer("cvs-health", opts)

      assert calls(server) == [
               {"search_healthcare_jobs",
                %{
                  "query" => "night",
                  "kind" => "nurses",
                  "employer" => "kaiser-permanente",
                  "state" => "Texas",
                  "remote" => true,
                  "min_hourly_usd" => 40,
                  "sort" => "highest_pay",
                  "limit" => 5
                }},
               {"get_healthcare_pay", %{"kind" => "nurses", "employer" => "cvs-health"}},
               {"get_healthcare_job_market", %{}},
               {"get_healthcare_jobs_by_state",
                %{"state" => "OH", "kind" => "nursing-assistants", "limit" => 2}},
               {"list_healthcare_employers",
                %{
                  "query" => "kaiser",
                  "type" => "employer",
                  "care" => "home-care",
                  "state" => "CA",
                  "kind" => "physicians",
                  "limit" => 9
                }},
               {"get_healthcare_employer", %{"employer" => "cvs-health"}}
             ]
    end

    test "every function works with no options at all", %{server: server} do
      Application.put_env(:carejobs, :base_url, server.url)
      on_exit(fn -> Application.delete_env(:carejobs, :base_url) end)

      assert {:ok, _} = CareJobs.search_jobs()
      assert {:ok, _} = CareJobs.pay()
      assert {:ok, _} = CareJobs.job_market()
      assert {:ok, _} = CareJobs.jobs_by_state()
      assert {:ok, _} = CareJobs.employers()
      assert {:ok, _} = CareJobs.employer("kaiser-permanente")

      assert Enum.map(calls(server), &elem(&1, 1)) == [
               %{},
               %{},
               %{},
               %{},
               %{},
               %{"employer" => "kaiser-permanente"}
             ]
    end
  end

  describe "the answer" do
    test "is the data (string keys, null as nil) and the readable summary", %{opts: opts} do
      assert {:ok, %{data: data, text: text}} = CareJobs.search_jobs(opts)

      recorded = Fixtures.json("search")["result"]
      assert data == recorded["structuredContent"]
      assert text == hd(recorded["content"])["text"]

      assert data["total"] > 0

      assert [%{"title" => title, "via" => nil, "url" => "https://carejobs.now/jobs/" <> _} | _] =
               data["jobs"]

      assert is_binary(title)
      assert text =~ "open healthcare jobs match"
    end

    test "of a search with no match has no jobs", %{} do
      opts = serving(Fixtures.raw("search_empty"))

      assert {:ok, %{data: %{"total" => 0, "jobs" => [], "pay" => nil}, text: text}} =
               CareJobs.search_jobs([query: "zzzqqqxx"] ++ opts)

      assert text =~ "No open healthcare jobs match"
    end

    test "of every other function is the recorded structured content", %{opts: opts} do
      for {result, recording} <- [
            {CareJobs.pay(opts), "pay_overview"},
            {CareJobs.job_market(opts), "market"},
            {CareJobs.jobs_by_state(opts), "states_overview"},
            {CareJobs.employers(opts), "employers"},
            {CareJobs.employer("kaiser-permanente", opts), "employer"}
          ] do
        assert {:ok, %{data: data, text: text}} = result
        assert data == Fixtures.json(recording)["result"]["structuredContent"]
        assert text != ""
      end
    end
  end

  describe "tools/1 and call_tool/3" do
    test "tools/1 lists the six tools with their input schemas", %{server: server, opts: opts} do
      assert {:ok, tools} = CareJobs.tools(opts)

      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == [
               "get_healthcare_employer",
               "get_healthcare_job_market",
               "get_healthcare_jobs_by_state",
               "get_healthcare_pay",
               "list_healthcare_employers",
               "search_healthcare_jobs"
             ]

      assert %{"properties" => %{"kind" => _}} =
               Enum.find(tools, &(&1["name"] == "get_healthcare_pay"))["inputSchema"]

      assert JSON.decode!(FakeServer.last_request(server).body)["method"] == "tools/list"
    end

    test "call_tool/3 takes a map or a keyword list, atom or string keys, and drops nil", %{
      server: server,
      opts: opts
    } do
      assert {:ok, %{data: %{"pay_by_kind" => _}}} =
               CareJobs.call_tool("get_healthcare_pay", %{kind: "nurses"}, opts)

      CareJobs.call_tool("get_healthcare_pay", [kind: "nurses", employer: nil], opts)
      CareJobs.call_tool("get_healthcare_pay", %{"employer" => "cvs-health"}, opts)
      CareJobs.call_tool("get_healthcare_job_market", %{}, opts)

      assert calls(server) == [
               {"get_healthcare_pay", %{"kind" => "nurses"}},
               {"get_healthcare_pay", %{"kind" => "nurses"}},
               {"get_healthcare_pay", %{"employer" => "cvs-health"}},
               {"get_healthcare_job_market", %{}}
             ]
    end

    test "call_tool/3 reports arguments that JSON cannot carry and sends nothing", %{
      server: server,
      opts: opts
    } do
      assert {:error,
              %CareJobs.Error{code: :protocol, tool: "get_healthcare_pay", message: message}} =
               CareJobs.call_tool("get_healthcare_pay", %{kind: {:not, :json}}, opts)

      assert message =~ "cannot be encoded as JSON"
      assert FakeServer.requests(server) == []
    end
  end

  describe "errors" do
    test "a tool error is :tool with the server's explanation" do
      opts = serving(Fixtures.raw("error_tool"))

      assert {:error,
              %CareJobs.Error{code: :tool, tool: "get_healthcare_employer", message: message}} =
               CareJobs.employer("no-such-employer-xyz", opts)

      assert message =~ "Unknown employer"
    end

    test "an unknown kind is :tool and lists the kinds" do
      opts = serving(Fixtures.raw("error_kind"))

      assert {:error, %CareJobs.Error{code: :tool, message: message}} =
               CareJobs.pay([kind: "bogus"] ++ opts)

      assert message =~ "Unknown kind 'bogus'. Use one of: nurses,"
    end

    test "a JSON-RPC error is :rpc with its code" do
      opts = serving(Fixtures.raw("error_rpc"))

      assert {:error,
              %CareJobs.Error{code: :rpc, rpc_code: -32_601, message: "Method not found: nope"}} =
               CareJobs.job_market(opts)
    end

    test "a JSON-RPC error that is not an object is :protocol" do
      opts = serving(~s({"jsonrpc":"2.0","id":1,"error":"boom"}))

      assert {:error, %CareJobs.Error{code: :protocol, message: "Malformed JSON-RPC error"}} =
               CareJobs.job_market(opts)
    end

    test "a non-2xx status is :http with the status and the body's text" do
      opts = serving({500, [{"content-type", "text/plain"}], "upstream exploded"})

      assert {:error,
              %CareJobs.Error{code: :http, status: 500, message: "HTTP 500: upstream exploded"}} =
               CareJobs.job_market(opts)
    end

    test "a non-2xx status with a JSON-RPC body uses its message" do
      opts = serving({400, [], Fixtures.raw("error_rpc")})

      assert {:error,
              %CareJobs.Error{
                code: :http,
                status: 400,
                message: "HTTP 400: Method not found: nope"
              }} =
               CareJobs.job_market(opts)
    end

    test "a non-2xx status with an empty body is just the status" do
      opts = serving({404, [], ""})

      assert {:error, %CareJobs.Error{code: :http, status: 404, message: "HTTP 404"}} =
               CareJobs.job_market(opts)
    end

    test "a body that is not JSON is :protocol" do
      opts = serving({200, [{"content-type", "text/html"}], "<html>maintenance</html>"})

      assert {:error,
              %CareJobs.Error{code: :protocol, message: "The server did not answer with JSON"}} =
               CareJobs.job_market(opts)
    end

    test "JSON that is not a JSON-RPC object is :protocol" do
      opts = serving("[1,2,3]")

      assert {:error,
              %CareJobs.Error{
                code: :protocol,
                message: "The server did not answer with a JSON-RPC object"
              }} =
               CareJobs.job_market(opts)
    end

    test "an answer with no result is :protocol" do
      opts = serving(~s({"jsonrpc":"2.0","id":1}))

      assert {:error, %CareJobs.Error{code: :protocol, message: "The answer held no result"}} =
               CareJobs.job_market(opts)
    end

    test "a tool result without structured content is :protocol" do
      opts =
        serving(~s({"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hi"}]}}))

      assert {:error,
              %CareJobs.Error{
                code: :protocol,
                tool: "get_healthcare_job_market",
                message: message
              }} =
               CareJobs.job_market(opts)

      assert message =~ "without structured content"
    end

    test "a body with invalid UTF-8 does not crash" do
      opts = serving({502, [{"content-type", "text/plain"}], <<"bad gateway ", 0xFF, 0xFE>>})

      assert {:error,
              %CareJobs.Error{code: :http, status: 502, message: "HTTP 502: bad gateway " <> _}} =
               CareJobs.job_market(opts)
    end

    test "a refused connection is :network" do
      server = FakeServer.start(fn _request -> "" end)
      FakeServer.stop(server)
      Process.sleep(50)

      assert {:error,
              %CareJobs.Error{code: :network, tool: "get_healthcare_job_market", message: message}} =
               CareJobs.job_market(base_url: server.url, timeout: 2_000)

      assert message =~ "Could not reach #{server.url}/api/mcp"
      assert message =~ "econnrefused"
    end

    test "an unknown host is :network" do
      assert {:error, %CareJobs.Error{code: :network, message: message}} =
               CareJobs.job_market(
                 base_url: "http://carejobs-elixir-test.invalid",
                 timeout: 5_000
               )

      assert message =~ "nxdomain"
    end

    test "no answer in time is :timeout" do
      server =
        FakeServer.start(fn _request ->
          Process.sleep(600)
          Fixtures.raw("market")
        end)

      on_exit(fn -> FakeServer.stop(server) end)

      assert {:error, %CareJobs.Error{code: :timeout, message: message}} =
               CareJobs.job_market(base_url: server.url, timeout: 100)

      assert message == "No answer from #{server.url}/api/mcp within 100 ms"
    end
  end

  describe "event streams" do
    test "an answer sent as text/event-stream is read" do
      server =
        FakeServer.start(fn request ->
          id = JSON.decode!(request.body)["id"]
          market = JSON.decode!(Fixtures.raw("market"))
          message = JSON.encode!(%{market | "id" => id})

          {200, [{"content-type", "text/event-stream"}],
           "event: ping\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n" <>
             "event: message\ndata: #{message}\n\n"}
        end)

      on_exit(fn -> FakeServer.stop(server) end)

      assert {:ok, %{data: data}} = CareJobs.job_market(base_url: server.url, timeout: 5_000)
      assert data == Fixtures.json("market")["result"]["structuredContent"]
    end
  end

  describe "options" do
    test "an unknown option raises and sends nothing", %{server: server, opts: opts} do
      assert_raise ArgumentError,
                   ~r/unknown option\(s\) \[:stat\] for CareJobs.search_jobs\/1/,
                   fn ->
                     CareJobs.search_jobs([stat: "TX"] ++ opts)
                   end

      assert_raise ArgumentError,
                   ~r/unknown option\(s\) \[:kind\] for CareJobs.job_market\/1/,
                   fn ->
                     CareJobs.job_market([kind: "nurses"] ++ opts)
                   end

      assert_raise ArgumentError,
                   ~r/unknown option\(s\) \[:limit\] for CareJobs.employer\/2/,
                   fn ->
                     CareJobs.employer("cvs-health", [limit: 3] ++ opts)
                   end

      assert FakeServer.requests(server) == []
    end

    test "options that are not a keyword list raise" do
      # Through apply/3, so that the compiler's own type check does not stop these calls.
      for options <- [%{kind: "nurses"}, ["nurses"], "nurses"] do
        assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
          apply(CareJobs, :pay, [options])
        end
      end
    end

    test "an invalid :timeout raises" do
      for timeout <- [0, -1, 1.5, "5", :infinity, nil] do
        assert_raise ArgumentError,
                     ~r/:timeout option must be a number of milliseconds above 0/,
                     fn ->
                       CareJobs.job_market(timeout: timeout)
                     end
      end
    end

    test "an invalid :base_url raises" do
      for base_url <- ["carejobs.now", "ftp://carejobs.now", "http://", "", 5, nil] do
        assert_raise ArgumentError,
                     ~r/:base_url option must be an http:\/\/ or https:\/\/ address/,
                     fn ->
                       CareJobs.job_market(base_url: base_url)
                     end
      end
    end

    test "an invalid :user_agent, :cacerts or :request_fun raises" do
      assert_raise ArgumentError, ~r/:user_agent/, fn -> CareJobs.job_market(user_agent: "") end
      assert_raise ArgumentError, ~r/:cacerts/, fn -> CareJobs.job_market(cacerts: "pem") end

      assert_raise ArgumentError, ~r/:request_fun/, fn ->
        CareJobs.job_market(request_fun: fn -> :ok end)
      end
    end

    test "employer/2 needs a string slug" do
      for slug <- [:"kaiser-permanente", nil, 5] do
        assert_raise FunctionClauseError, fn -> apply(CareJobs, :employer, [slug]) end
      end
    end

    test "the application environment sets the defaults and the options of a call win", %{
      server: server
    } do
      other = FakeServer.start(fn _request -> Fixtures.raw("market") end)
      on_exit(fn -> FakeServer.stop(other) end)

      Application.put_env(:carejobs, :base_url, other.url)
      Application.put_env(:carejobs, :user_agent, "from-config/1")

      on_exit(fn ->
        Application.delete_env(:carejobs, :base_url)
        Application.delete_env(:carejobs, :user_agent)
      end)

      assert {:ok, _} = CareJobs.job_market()
      assert FakeServer.last_request(other).headers["user-agent"] == "from-config/1"
      assert FakeServer.requests(server) == []

      assert {:ok, _} = CareJobs.job_market(base_url: server.url, user_agent: "from-call/1")
      assert FakeServer.last_request(server).headers["user-agent"] == "from-call/1"
    end
  end

  describe ":request_fun" do
    test "answers instead of the network and receives the whole request" do
      test = self()

      request_fun = fn request ->
        send(test, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [{"Content-Type", "application/json"}],
           body: Fixtures.raw("market")
         }}
      end

      assert {:ok, %{data: %{"open_jobs" => open_jobs}}} =
               CareJobs.job_market(request_fun: request_fun)

      assert is_integer(open_jobs)

      assert_received {:request,
                       %{
                         method: :post,
                         url: "https://carejobs.now/api/mcp",
                         timeout: 60_000,
                         headers: headers,
                         body: body
                       }}

      assert {"content-type", "application/json"} in headers
      assert {"accept", "application/json, text/event-stream"} in headers
      assert JSON.decode!(body)["params"]["name"] == "get_healthcare_job_market"
    end

    test "may leave the headers out of its answer" do
      request_fun = fn _request -> {:ok, %{status: 200, body: Fixtures.raw("market")}} end
      assert {:ok, _} = CareJobs.job_market(request_fun: request_fun)
    end

    test "an {:error, reason} becomes :timeout or :network" do
      assert {:error, %CareJobs.Error{code: :timeout}} =
               CareJobs.job_market(request_fun: fn _ -> {:error, :timeout} end)

      assert {:error, %CareJobs.Error{code: :timeout}} =
               CareJobs.job_market(
                 request_fun: fn _ ->
                   {:error,
                    {:failed_connect, [{:to_address, {~c"h", 443}}, {:inet, [:inet], :timeout}]}}
                 end
               )

      assert {:error, %CareJobs.Error{code: :network, message: message}} =
               CareJobs.job_market(request_fun: fn _ -> {:error, :econnrefused} end)

      assert message ==
               "Could not reach https://carejobs.now/api/mcp: econnrefused (connection refused)"

      assert {:error, %CareJobs.Error{code: :network, message: message}} =
               CareJobs.job_market(request_fun: fn _ -> {:error, {:weird, 1}} end)

      assert message =~ "{:weird, 1}"
    end

    test "any other return value is :protocol" do
      assert {:error, %CareJobs.Error{code: :protocol, message: message}} =
               CareJobs.job_market(request_fun: fn _ -> :ok end)

      assert message =~ "The request function returned :ok"
    end

    test "can be set for the whole application" do
      Application.put_env(:carejobs, :request_fun, fn _ ->
        {:ok, %{status: 200, body: Fixtures.raw("pay_overview")}}
      end)

      on_exit(fn -> Application.delete_env(:carejobs, :request_fun) end)

      assert {:ok, %{data: %{"pay_by_kind" => _}}} = CareJobs.pay()
    end
  end

  describe "the enumerations" do
    test "list the kinds, care types, employer types and sorts of the API" do
      assert length(CareJobs.kinds()) == 17
      assert length(CareJobs.care_types()) == 17
      assert CareJobs.employer_types() == ["employer", "ai-program", "job-board"]
      assert CareJobs.sorts() == ["mixed", "newest", "highest_pay"]
    end

    test "match the recorded tools/list schemas" do
      properties =
        Fixtures.json("tools_list")["result"]["tools"]
        |> Map.new(&{&1["name"], &1["inputSchema"]["properties"]})

      assert properties["search_healthcare_jobs"]["kind"]["enum"] == CareJobs.kinds()
      assert properties["search_healthcare_jobs"]["sort"]["enum"] == CareJobs.sorts()
      assert properties["list_healthcare_employers"]["type"]["enum"] == CareJobs.employer_types()
      assert properties["list_healthcare_employers"]["care"]["enum"] == CareJobs.care_types()
    end
  end
end
