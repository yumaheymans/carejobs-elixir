defmodule CareJobs do
  @moduledoc """
  Client for the [CareJobs.Now](https://carejobs.now) healthcare jobs API.

  CareJobs.Now is a free US healthcare job board. Its API is a remote MCP server at
  `https://carejobs.now/api/mcp`: free, no API key. This library speaks to it with what
  ships with Erlang/OTP (`:httpc`, `:ssl`, and the built-in `JSON` module), so it has no
  runtime dependencies.

  ## Quick start

      {:ok, %{data: jobs, text: summary}} =
        CareJobs.search_jobs(query: "icu", state: "TX", kind: :nurses, limit: 5)

      IO.puts("\#{jobs["total"]} jobs match")

      for job <- jobs["jobs"] do
        IO.puts(Enum.join([job["title"], job["employer"], job["location"], job["url"]], " | "))
      end

      {:ok, %{data: pay}} = CareJobs.pay(kind: :nurses)
      IO.puts("Median posted pay for nurses: $\#{pay["pay"]["median"]}/hr")

      # Every answer also carries the server's readable summary:
      IO.puts(summary)

  ## The six functions

    * `search_jobs/1` - open jobs, filtered by words, kind, employer, state and pay
    * `pay/1` - what jobs post as hourly pay
    * `job_market/1` - how many jobs are open, by kind, state and employer
    * `jobs_by_state/1` - open jobs by state
    * `employers/1` - the employers, AI-training programs and job boards the site reads
    * `employer/2` - one employer in full

  Each returns `{:ok, %{data: map, text: string}}` or `{:error, %CareJobs.Error{}}`.
  `:data` is the tool's structured answer, decoded from JSON with **string keys** exactly as
  the API sends them (`"typical_low"`, `"open_jobs"`). Where the API sends `null`, the value
  is `nil`. `:text` is a readable plain-text summary written by the server.

  ## Options

  Every function takes a keyword list. Its filters are described on each function. Unknown
  options raise `ArgumentError`, so a typo does not silently drop a filter. Values that are
  `nil` are left out of the request. Atoms are accepted for the enumerated filters
  (`kind: :nurses`), and for `:kind`, `:type` and `:care` an underscore stands for the
  hyphen the API uses (`kind: :nursing_assistants` is sent as `"nursing-assistants"`).
  Strings are sent as they are.

  Every function also accepts these options for the request itself:

    * `:base_url` - the host, default `"https://carejobs.now"` (the endpoint is
      `<base_url>/api/mcp`)
    * `:timeout` - milliseconds a request may take to connect and to be answered, default
      `60_000`. The server answers a query it has not seen before in up to about 25
      seconds (its database may be waking up) and repeats of it in a fraction of one,
      which is why the default is a minute.
    * `:user_agent` - the `User-Agent` header, default `"carejobs-elixir/<version>"`
    * `:cacerts` - the CA certificates to trust for `https`, default the operating
      system's (`:public_key.cacerts_get/0`). Set it only behind a TLS-inspecting proxy.
    * `:request_fun` - replaces the HTTP transport, see "Testing your code" below

  These can also be set for the whole application, and options of a call win:

      # config/config.exs
      config :carejobs, timeout: 30_000, user_agent: "my-app/1.0"

  ## Kinds

  `kinds/0` lists the kinds of job, as the API spells them:

  ```
  nurses, nurse-practitioners, physicians, nursing-assistants, caregivers,
  therapy-rehab, mental-health, pharmacy, imaging, lab, surgical-techs,
  emts-paramedics, medical-assistants, dental, admin, allied-health, ai-training
  ```

  `care_types/0`, `employer_types/0` and `sorts/0` work the same way. They are copied from the
  live `tools/list` schemas, and a live test checks them against the server.

  ## Errors

  Every failure is a `t:CareJobs.Error.t/0` with a `:code`: `:tool` (the server ran the
  tool and answered with an error, `:message` is its explanation), `:rpc`, `:http`,
  `:network`, `:timeout` or `:protocol`.

      case CareJobs.employer("no-such-employer") do
        {:ok, %{data: employer}} -> employer
        {:error, %CareJobs.Error{code: :tool, message: message}} -> message
      end

  The client does not retry. Wrap calls yourself if you need that. An invalid option
  (an unknown key, a `:timeout` that is not a positive integer, a `:base_url` that is not
  an http or https address) raises `ArgumentError`.

  ## Testing your code

  `:request_fun` is a function that receives the request as a map (`:method`, `:url`,
  `:headers`, `:body`, `:timeout`) and returns `{:ok, %{status: integer, headers: list,
  body: binary}}` or `{:error, reason}`. Set it in `config/test.exs` to answer without a
  network:

      config :carejobs, request_fun: &MyApp.FakeCareJobs.request/1

  ## About the data

  Jobs are read daily from the career sites of US hospitals, health systems and care
  employers. Pay is the hourly rate the employer posts, not a survey of what everyone in a
  field earns, and only jobs that post a rate count toward it. The board covers the
  employers it reads, not the whole labor market. Method:
  <https://carejobs.now/methodology>.

  The CareJobs.Now data files (`/roles.json` and `/pay.json`) are published under CC BY 4.0,
  so credit CareJobs.Now when you use the numbers. See <https://carejobs.now/data> for the
  files, the OpenAPI description and the current terms.
  """

  alias CareJobs.{Client, Error}

  @kinds ~w(
    nurses nurse-practitioners physicians nursing-assistants caregivers therapy-rehab
    mental-health pharmacy imaging lab surgical-techs emts-paramedics medical-assistants
    dental admin allied-health ai-training
  )

  @care_types ~w(
    health-system childrens-hospital outpatient specialty-care behavioral-health autism-care
    home-care senior-care rehab dental pharmacy-retail kidney-care labs-imaging telehealth
    staffing ai-training job-boards
  )

  @employer_types ~w(employer ai-program job-board)

  @sorts ~w(mixed newest highest_pay)

  @typedoc "What every function returns: the tool's data (string keys) and the server's readable summary."
  @type result :: %{data: map(), text: String.t()}

  @type response :: {:ok, result()} | {:error, Error.t()}

  @typedoc """
  An enumerated value: a string as the API spells it (`"nursing-assistants"`), or an atom
  (`:nursing_assistants`).
  """
  @type enum :: String.t() | atom()

  @typedoc "The options that configure the request rather than the question."
  @type request_option ::
          {:base_url, String.t()}
          | {:timeout, pos_integer()}
          | {:user_agent, String.t()}
          | {:cacerts, [binary() | :public_key.combined_cert()]}
          | {:request_fun, (map() -> {:ok, map()} | {:error, term()})}

  @type search_option ::
          {:query, String.t() | nil}
          | {:kind, enum() | nil}
          | {:employer, String.t() | nil}
          | {:state, String.t() | nil}
          | {:remote, boolean() | nil}
          | {:min_hourly_usd, pos_integer() | nil}
          | {:sort, enum() | nil}
          | {:limit, pos_integer() | nil}
          | request_option()

  @type pay_option :: {:kind, enum() | nil} | {:employer, String.t() | nil} | request_option()

  @type state_option ::
          {:state, String.t() | nil}
          | {:kind, enum() | nil}
          | {:limit, pos_integer() | nil}
          | request_option()

  @type employers_option ::
          {:query, String.t() | nil}
          | {:type, enum() | nil}
          | {:care, enum() | nil}
          | {:state, String.t() | nil}
          | {:kind, enum() | nil}
          | {:limit, pos_integer() | nil}
          | request_option()

  # -- the six tools ----------------------------------------------------------------------

  @doc """
  Searches the open healthcare jobs at US hospitals, health systems, clinics and care
  companies, plus the job boards the site reads. Every filter is optional.

  ## Options

    * `:query` - words every job must carry in its title, place, department or schedule
      (`"ICU"`, `"night"`, `"Houston"`)
    * `:kind` - the kind of job, one of `kinds/0`
    * `:employer` - an employer slug (`"kaiser-permanente"`) or name. `employers/1` finds
      the slugs.
    * `:state` - a US state, as `"TX"` or `"Texas"`
    * `:remote` - `true` for only remote (work-from-home) jobs. `false` and `nil` leave the
      filter off.
    * `:min_hourly_usd` - only jobs whose posted hourly ceiling reaches this many dollars
      (1 to 1000)
    * `:sort` - one of `sorts/0`, default `"mixed"` (the board's order, employers
      interleaved)
    * `:limit` - how many jobs to return, 1 to 25, default 10

  and the request options described in the `CareJobs` module documentation.

  The answer's `:data` has `"total"` (every match), `"pay"`, `"jobs"` (the ones returned)
  and `"more"`. Each job has `"title"`, `"employer"`, `"via"`, `"kind"`, `"pay"`,
  `"schedule"`, `"facility"`, `"location"`, `"listed"`, `"url"` (its page on CareJobs.Now,
  where the user applies) and `"employer_page"`.

  ## Examples

      {:ok, %{data: %{"total" => total, "jobs" => jobs}}} =
        CareJobs.search_jobs(query: "icu", kind: :nurses, state: "TX", limit: 3)

      {:ok, %{data: data}} = CareJobs.search_jobs(remote: true, sort: :highest_pay)
  """
  @spec search_jobs([search_option()]) :: response()
  def search_jobs(options \\ []) do
    run(
      "search_healthcare_jobs",
      options,
      [:query, :kind, :employer, :state, :remote, :min_hourly_usd, :sort, :limit],
      "search_jobs/1"
    )
  end

  @doc """
  What healthcare jobs post as hourly pay today, measured from open jobs (before shift
  differentials and bonuses). The answer depends on the options:

    * none: the median and typical range for every kind of job
    * `:kind`: that job's pay and the employers posting the most for it
    * `:employer`: that employer's pay overall and by kind of job
    * both: that employer's pay for that kind of job

  `:kind` is one of `kinds/0`, `:employer` an employer slug or name. The request options
  described in the `CareJobs` module documentation work too.

  "Typical" pay runs from the 25th percentile of what jobs pay to the 90th-percentile
  advertised ceiling. A market rate is reported only where at least three employers post a
  rate (`"market_rate"`).

  ## Examples

      CareJobs.pay()
      CareJobs.pay(kind: :nurses)
      CareJobs.pay(employer: "kaiser-permanente")

      {:ok, %{data: %{"pay" => %{"median" => median}}}} =
        CareJobs.pay(kind: :nurses, employer: "kaiser-permanente")
  """
  @spec pay([pay_option()]) :: response()
  def pay(options \\ []) do
    run("get_healthcare_pay", options, [:kind, :employer], "pay/1")
  end

  @doc """
  How many healthcare jobs are open right now, how many were first listed in the last 7
  days, and the open jobs by kind of job, by US state and by employer (with each
  employer's slug).

  Takes only the request options described in the `CareJobs` module documentation.

  ## Examples

      {:ok, %{data: %{"open_jobs" => open_jobs}}} = CareJobs.job_market()
  """
  @spec job_market([request_option()]) :: response()
  def job_market(options \\ []) do
    run("get_healthcare_job_market", options, [], "job_market/1")
  end

  @doc """
  Open healthcare jobs by US state.

    * with no `:state`: every state's open jobs and employers
    * with a `:state`: its open jobs by kind of job, the hourly pay they post, the towns and
      employers with the most jobs, and its newest jobs
    * with a `:state` and a `:kind`: the same for that kind of job (CNA jobs in Ohio)

  `:state` is `"TX"` or `"Texas"`, `:kind` is one of `kinds/0` and needs a `:state`,
  `:limit` (1 to 25, default 10) is how many of the newest jobs to return. The request
  options described in the `CareJobs` module documentation work too.

  ## Examples

      CareJobs.jobs_by_state()
      CareJobs.jobs_by_state(state: "TX", limit: 5)
      CareJobs.jobs_by_state(state: "OH", kind: :nursing_assistants)
  """
  @spec jobs_by_state([state_option()]) :: response()
  def jobs_by_state(options \\ []) do
    run("get_healthcare_jobs_by_state", options, [:state, :kind, :limit], "jobs_by_state/1")
  end

  @doc """
  The hospitals, health systems, clinic groups and care companies whose jobs CareJobs.Now
  reads, most open jobs first, with where each hires, its open jobs and its posted pay. Also
  lists the AI-training programs and the job boards the site reads.

  ## Options

    * `:query` - part of the name (`"Kaiser"`, `"children"`, `"dialysis"`)
    * `:type` - one of `employer_types/0`: `"employer"` (hospitals, clinics and care
      companies, the default without a query), `"ai-program"` or `"job-board"`
    * `:care` - the kind of care, one of `care_types/0`
    * `:state` - only employers with open jobs in this state
    * `:kind` - only employers with open jobs of this kind, one of `kinds/0`
    * `:limit` - how many to return, 1 to 100, default 20

  and the request options described in the `CareJobs` module documentation.

  The answer's `:data` has `"total"` and `"entries"`. Each entry has `"slug"` (the
  argument for `employer/2` and the `:employer` filters), `"name"`, `"type"`, `"model"`,
  `"care"`, `"hq"`, `"states"`, `"open_jobs"`, `"posted_median_hourly"` and `"url"`.

  ## Examples

      {:ok, %{data: %{"entries" => entries}}} = CareJobs.employers(query: "kaiser", limit: 3)

      CareJobs.employers(care: :home_care, state: "CA")
      CareJobs.employers(type: :job_board)
  """
  @spec employers([employers_option()]) :: response()
  def employers(options \\ []) do
    run(
      "list_healthcare_employers",
      options,
      [:query, :type, :care, :state, :kind, :limit],
      "employers/1"
    )
  end

  @doc """
  One employer, AI-training program or job board, by slug (`"kaiser-permanente"`) or name:
  what it is, where it hires, its open jobs right now by kind of job, the pay its jobs post,
  its newest and best-paid open jobs, and links to its page and every open job.

  Takes the request options described in the `CareJobs` module documentation as its second
  argument. An unknown employer is an `{:error, %CareJobs.Error{code: :tool}}` whose message
  says so.

  ## Examples

      {:ok, %{data: %{"name" => name, "open_jobs" => open_jobs}}} =
        CareJobs.employer("kaiser-permanente")

      {:error, %CareJobs.Error{code: :tool}} = CareJobs.employer("no-such-employer")
  """
  @spec employer(String.t(), [request_option()]) :: response()
  def employer(slug, options \\ []) when is_binary(slug) do
    run("get_healthcare_employer", options, [], "employer/2", %{"employer" => slug})
  end

  # -- low level --------------------------------------------------------------------------

  @doc """
  The tools the server offers, as a list of maps with their input schemas (string keys).

  ## Options

  The request options described in the `CareJobs` module documentation.

  ## Examples

      {:ok, tools} = CareJobs.tools()
      Enum.map(tools, & &1["name"])
  """
  @spec tools([request_option()]) :: {:ok, [map()]} | {:error, Error.t()}
  def tools(options \\ []) do
    {_arguments, transport} = split_options!(options, [], "tools/1")
    Client.list_tools(Client.config!(transport))
  end

  @doc """
  Calls any tool by name, for a tool the server adds after this version of the library.
  The six functions above use this.

  `arguments` is a map or keyword list in the API's names. Keys may be atoms or strings,
  and `nil` values are left out. The request options are described in the `CareJobs` module
  documentation.

  ## Examples

      {:ok, %{data: data, text: text}} =
        CareJobs.call_tool("get_healthcare_pay", %{kind: "nurses"})
  """
  @spec call_tool(String.t(), map() | keyword(), [request_option()]) :: response()
  def call_tool(name, arguments \\ %{}, options \\ [])
      when is_binary(name) and (is_map(arguments) or is_list(arguments)) do
    {_arguments, transport} = split_options!(options, [], "call_tool/3")

    arguments =
      for {key, value} <- arguments, value != nil, into: %{} do
        {to_string(key), value}
      end

    Client.call_tool(name, arguments, Client.config!(transport))
  end

  # -- the enumerations -------------------------------------------------------------------

  @doc """
  The kinds of healthcare job, as the API spells them: the values of the `:kind` option.

  ## Examples

      iex> "nurses" in CareJobs.kinds()
      true

      iex> length(CareJobs.kinds())
      17
  """
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The kinds of care, the values of the `:care` option of `employers/1`.

  ## Examples

      iex> "home-care" in CareJobs.care_types()
      true
  """
  @spec care_types() :: [String.t()]
  def care_types, do: @care_types

  @doc """
  What an entry of the employer list is, the values of the `:type` option of `employers/1`.

  ## Examples

      iex> CareJobs.employer_types()
      ["employer", "ai-program", "job-board"]
  """
  @spec employer_types() :: [String.t()]
  def employer_types, do: @employer_types

  @doc """
  The orders of `search_jobs/1` results, the values of its `:sort` option.

  ## Examples

      iex> CareJobs.sorts()
      ["mixed", "newest", "highest_pay"]
  """
  @spec sorts() :: [String.t()]
  def sorts, do: @sorts

  # -- internals --------------------------------------------------------------------------

  defp run(tool, options, keys, function, extra \\ %{}) do
    {arguments, transport} = split_options!(options, keys, function)
    config = Client.config!(transport)
    Client.call_tool(tool, arguments |> normalize() |> Map.merge(extra), config)
  end

  # Splits the options of a call into the tool's arguments and the request options, and
  # raises for anything that is neither.
  defp split_options!(options, keys, function) do
    unless Keyword.keyword?(options) do
      raise ArgumentError,
            "CareJobs.#{function} expects a keyword list of options, got: #{inspect(options)}"
    end

    transport_keys = Client.transport_keys()
    {known, unknown} = Keyword.split(options, keys ++ transport_keys)

    if unknown != [] do
      raise ArgumentError,
            "unknown option(s) #{inspect(Keyword.keys(unknown))} for CareJobs.#{function}. " <>
              "Valid options: #{inspect(keys ++ transport_keys)}"
    end

    Keyword.split(known, keys)
  end

  defp normalize(arguments) do
    for {key, value} <- arguments,
        value != nil,
        not (key == :remote and value == false),
        into: %{} do
      {Atom.to_string(key), normalize_value(key, value)}
    end
  end

  # The API spells its slugs with hyphens, so an atom's underscores stand for them.
  defp normalize_value(key, value)
       when key in [:kind, :type, :care] and is_atom(value) and not is_boolean(value) do
    value |> Atom.to_string() |> String.replace("_", "-")
  end

  defp normalize_value(_key, value), do: value
end
