# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-20

### Added

- `CareJobs.search_jobs/1`, `pay/1`, `job_market/0`, `jobs_by_state/1`, `employers/1` and
  `employer/1` (each also takes request options), returning
  `{:ok, %{data: map, text: string}}` or `{:error, %CareJobs.Error{}}`. `:data` is the CareJobs.Now
  MCP tool's structured answer (string keys), `:text` the server's readable summary.
- Low-level `CareJobs.tools/1` and `CareJobs.call_tool/3` for any tool the server adds later.
- `CareJobs.Error` with a `:code` of `:tool`, `:rpc`, `:http`, `:network`, `:timeout` or
  `:protocol`.
- `CareJobs.kinds/0`, `care_types/0`, `employer_types/0` and `sorts/0`, taken from the live
  `tools/list` schemas.
- Request options `:base_url`, `:timeout` (milliseconds, default 60 000), `:user_agent`,
  `:cacerts` and `:request_fun` (replaces the HTTP transport, for tests), per call or through
  `config :carejobs`.
- No runtime dependencies: Erlang's `:httpc` with TLS verified against the operating system's CA
  certificates and the host name, and the built-in `JSON` module. Elixir 1.18 or newer.

[1.0.0]: https://github.com/yumaheymans/carejobs-elixir/releases/tag/v1.0.0
