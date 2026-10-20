defmodule Fixtures do
  @moduledoc false

  @dir Path.expand("fixtures", __DIR__)

  # The recorded JSON-RPC answer of the live API, as the server sent it.
  def raw(name), do: File.read!(Path.join(@dir, "#{name}.json"))

  # The recorded answer decoded.
  def json(name), do: name |> raw() |> JSON.decode!()
end

# The live tests call the real API: run them with `mix test --only live`.
ExUnit.start(exclude: [:live])
