defmodule CareJobs.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/yumaheymans/carejobs-elixir"

  def project do
    [
      app: :carejobs,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "CareJobs",
      description:
        "Client for the CareJobs.Now healthcare jobs API: search open US healthcare jobs, " <>
          "see the pay employers post, and look up employers and states. " <>
          "Free, no API key, no runtime dependencies.",
      source_url: @source_url,
      homepage_url: "https://carejobs.now",
      package: package(),
      docs: docs()
    ]
  end

  # :inets (the :httpc client), :ssl and :public_key (certificate verification) ship with
  # Erlang/OTP. They are the only things this library needs at runtime.
  def application do
    [extra_applications: [:inets, :ssl, :public_key]]
  end

  # The fake HTTP server of the tests is compiled with the project in the test environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Website" => "https://carejobs.now/data",
        "Source" => @source_url
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
