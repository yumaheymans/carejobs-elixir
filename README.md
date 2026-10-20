# carejobs

Client for the [CareJobs.Now](https://carejobs.now) healthcare jobs API. Search open US healthcare jobs, see the pay employers post, and look up employers and states, from Elixir.

- Free, no API key.
- No runtime dependencies: Erlang's built-in `:httpc` and `:ssl` (certificates verified against the operating system's CA store) and the `JSON` module that ships with Elixir 1.18 and newer.
- One result shape (`{:ok, %{data: map, text: string}}`), one error struct.
- The same API is a remote MCP server at <https://carejobs.now/api/mcp>, so any MCP client can use it too.

## Install

Add `carejobs` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:carejobs, "~> 1.0"}
  ]
end
```

## Quick start

```elixir
{:ok, %{data: jobs}} = CareJobs.search_jobs(query: "icu", state: "TX", kind: :nurses, limit: 5)

IO.puts("#{jobs["total"]} jobs match")

for job <- jobs["jobs"] do
  IO.puts(Enum.join([job["title"], job["employer"], job["location"], job["url"]], " | "))
end

{:ok, %{data: pay, text: summary}} = CareJobs.pay(kind: :nurses)
IO.puts("Median posted pay for nurses: $#{pay["pay"]["median"]}/hr")

# Every answer also carries the server's readable summary:
IO.puts(summary)
```

Each function returns `{:ok, %{data: data, text: text}}` or `{:error, %CareJobs.Error{}}`. `data` is the tool's structured answer, decoded from JSON with **string keys** exactly as the API sends them (`"typical_low"`, `"open_jobs"`), so no atoms are created from server data. Where the API sends `null`, the value is `nil`. `text` is a readable plain-text summary written by the server.

## Functions

Every function takes a keyword list of options. Unknown options raise `ArgumentError`, so a typo does not silently drop a filter. `nil` values are left out of the request. Enumerated filters accept strings as the API spells them (`"nursing-assistants"`) or atoms (`:nursing_assistants`, where an underscore in a `:kind`, `:type` or `:care` atom stands for the API's hyphen).

### `search_jobs(options)`

Open healthcare jobs at US hospitals, health systems, clinics and care companies, plus the job boards the site reads. Every option is optional.

| Option | Meaning |
| --- | --- |
| `:query` | Words every job must carry in its title, place, department or schedule ("ICU", "night") |
| `:kind` | Kind of job, see below |
| `:employer` | Employer slug or name ("kaiser-permanente") |
| `:state` | Two-letter code or name ("TX", "Texas") |
| `:remote` | `true` for only remote jobs (`false` and `nil` leave the filter off) |
| `:min_hourly_usd` | Only jobs whose posted hourly ceiling reaches this (1 to 1000) |
| `:sort` | `"mixed"` (default), `"newest"` or `"highest_pay"` |
| `:limit` | 1 to 25, default 10 |

`data` has `"total"`, `"pay"`, `"jobs"` and `"more"`. `"total"` counts every match, `"jobs"` holds the ones returned. Each job has `"title"`, `"employer"`, `"via"`, `"kind"`, `"pay"`, `"schedule"`, `"facility"`, `"location"`, `"listed"`, `"url"` (its page on CareJobs.Now, where the user applies) and `"employer_page"`.

### `pay(options)`

What jobs post as hourly pay, measured from open jobs (before shift differentials and bonuses). The answer depends on the options:

```elixir
CareJobs.pay()                                              # every kind of job
CareJobs.pay(kind: :nurses)                                 # one kind, plus the employers posting the most
CareJobs.pay(employer: "kaiser-permanente")                 # one employer, overall and by kind
CareJobs.pay(kind: :nurses, employer: "kaiser-permanente")
```

"Typical" pay runs from the 25th percentile of what jobs pay to the 90th-percentile advertised ceiling. A market rate is reported only where at least three employers post a rate (`"market_rate"`).

### `job_market()`

How many healthcare jobs are open, how many were first listed in the last 7 days, and the open jobs by kind, by state and by employer.

### `jobs_by_state(options)`

```elixir
CareJobs.jobs_by_state()                                    # every state
CareJobs.jobs_by_state(state: "TX", limit: 5)               # one state: kinds, pay, towns, employers, newest jobs
CareJobs.jobs_by_state(state: "OH", kind: :nursing_assistants)
```

`:kind` needs a `:state`. `:limit` (1 to 25) is how many of the newest jobs to return.

### `employers(options)`

Employers, AI-training programs and job boards the site reads, most open jobs first. Options: `:query` (part of the name), `:type` (`"employer"`, `"ai-program"` or `"job-board"`), `:care` (one of `CareJobs.care_types/0`), `:state`, `:kind` and `:limit` (1 to 100, default 20). Each entry in `data["entries"]` has a `"slug"` for `employer/1`.

### `employer(slug)`

One employer by slug or name: what it is, where it hires, open jobs by kind, posted pay, newest and best-paid jobs, and links to its page, every open job and its own careers site.

```elixir
{:ok, %{data: employer}} = CareJobs.employer("kaiser-permanente")
employer["open_jobs"]
```

### Kinds

`CareJobs.kinds/0` lists the kinds of job (strings, as the API spells them):

```
nurses, nurse-practitioners, physicians, nursing-assistants, caregivers,
therapy-rehab, mental-health, pharmacy, imaging, lab, surgical-techs,
emts-paramedics, medical-assistants, dental, admin, allied-health, ai-training
```

`CareJobs.care_types/0`, `employer_types/0` and `sorts/0` work the same way. They are copied from the live `tools/list` schemas, and a live test checks them against the server.

## Request options

Every function, including `job_market/1` and `employer/2`, also accepts these options for the request itself:

| Option | Meaning |
| --- | --- |
| `:base_url` | The host, default `"https://carejobs.now"` (the endpoint is `<base_url>/api/mcp`) |
| `:timeout` | Milliseconds a request may take to connect and to be answered, default `60_000` |
| `:user_agent` | The `User-Agent` header, default `"carejobs-elixir/<version>"` |
| `:cacerts` | CA certificates to trust for `https`, default the operating system's. Only needed behind a TLS-inspecting proxy |
| `:request_fun` | Replaces the HTTP transport (see "Testing your code") |

The server answers a query it has not seen before in up to about 25 seconds (its database may be waking up), then repeats of it in a fraction of one, which is why the default timeout is a minute.

Set them once for the whole application if you like. Options of a call win:

```elixir
# config/config.exs
config :carejobs, timeout: 30_000, user_agent: "my-app/1.0"
```

An invalid setting (a `:timeout` that is not a positive integer, a `:base_url` that is not an http or https address) raises `ArgumentError`.

## Errors

Every failure is a `%CareJobs.Error{}` with a `:code`:

| `:code` | Meaning |
| --- | --- |
| `:tool` | The server ran the tool and answered with an error (unknown kind, unknown employer). `:message` is the server's explanation. |
| `:rpc` | JSON-RPC error (`:rpc_code` is set) |
| `:http` | Non-2xx HTTP status (`:status` is set) |
| `:network` | The request never completed (DNS, refused connection, failed TLS verification) |
| `:timeout` | No answer within `:timeout` |
| `:protocol` | The answer was not the MCP shape, or the arguments could not be encoded as JSON |

```elixir
case CareJobs.employer("no-such-employer") do
  {:ok, %{data: employer}} -> employer
  {:error, %CareJobs.Error{code: :tool, message: message}} -> message
end
```

The struct is an exception too, so `raise error` works. The client does not retry: wrap calls yourself if you need that.

## Low level

`CareJobs.tools/1` returns the server's tools with their input schemas, and `CareJobs.call_tool(name, arguments)` calls any tool by name (arguments in the API's names, `nil` values left out), for tools added after this version.

## Testing your code

`:request_fun` receives the request as a map (`:method`, `:url`, `:headers`, `:body`, `:timeout`) and returns `{:ok, %{status: integer, headers: list, body: binary}}` or `{:error, reason}`. Set it in `config/test.exs` to answer without a network:

```elixir
config :carejobs, request_fun: &MyApp.FakeCareJobs.request/1
```

## About the data

Jobs are read daily from the career sites of US hospitals, health systems and care employers. Pay is the hourly rate the employer posts, not a survey of what everyone in a field earns, and only jobs that post a rate count toward it. The board covers the employers it reads, not the whole labor market. Method: <https://carejobs.now/methodology>.

The CareJobs.Now data files (`/roles.json` and `/pay.json`) are published under CC BY 4.0, so credit CareJobs.Now when you use the numbers. See <https://carejobs.now/data> for the files, the OpenAPI description and the current terms.

## Development

```sh
mix test                # offline: a local HTTP and TLS server replays recorded answers
mix test --only live    # the same questions against the real API (about a minute)
```

## Links

- Site: <https://carejobs.now>
- Data and API docs: <https://carejobs.now/data>
- MCP server: <https://carejobs.now/api/mcp>
- OpenAPI spec: <https://github.com/yumaheymans/carejobs-mcp>
- JavaScript and TypeScript: <https://github.com/yumaheymans/carejobs-js>
- Python: <https://github.com/yumaheymans/carejobs-python>
- Ruby gem: `gem install carejobs`
- Go module: `go get github.com/yumaheymans/carejobs-go`
- Swift: <https://github.com/yumaheymans/carejobs-swift> (CocoaPods: `pod 'CareJobs'`)
- Every app and integration: <https://carejobs.now/apps>

## License

MIT, Copyright 2026 CareJobs.Now. The license covers this package's code, not the data it fetches.
