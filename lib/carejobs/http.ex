defmodule CareJobs.HTTP do
  @moduledoc false

  # The default transport: one POST through Erlang's built-in :httpc. TLS is verified
  # against the operating system's trusted CA certificates (:public_key.cacerts_get/0),
  # and the certificate must match the host name.

  @type request :: %{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          timeout: pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @spec request(request(), [term()] | nil) :: {:ok, response()} | {:error, term()}
  def request(%{url: url, headers: headers, body: body, timeout: timeout}, cacerts) do
    {content_type, headers} = pop_header(headers, "content-type")

    with {:ok, http_options} <- http_options(url, timeout, cacerts) do
      request = {
        String.to_charlist(url),
        for({name, value} <- headers, do: {String.to_charlist(name), String.to_charlist(value)}),
        String.to_charlist(content_type || "application/json"),
        body
      }

      case :httpc.request(:post, request, http_options, body_format: :binary) do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          {:ok,
           %{
             status: status,
             headers:
               for({name, value} <- response_headers, do: {to_string(name), to_string(value)}),
             body: response_body
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp http_options(url, timeout, cacerts) do
    base = [timeout: timeout, connect_timeout: timeout, autoredirect: false]

    if String.starts_with?(url, "https://") do
      with {:ok, cacerts} <- trusted_cacerts(cacerts) do
        {:ok, [{:ssl, ssl_options(cacerts)} | base]}
      end
    else
      {:ok, base}
    end
  end

  defp ssl_options(cacerts) do
    [
      verify: :verify_peer,
      cacerts: cacerts,
      depth: 10,
      # The error returned to the caller carries the alert, so OTP's own notice would only
      # repeat it in the application's log.
      log_level: :error,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp trusted_cacerts(nil) do
    {:ok, :public_key.cacerts_get()}
  rescue
    _error -> {:error, :no_cacerts_found}
  end

  defp trusted_cacerts(cacerts), do: {:ok, cacerts}

  defp pop_header(headers, name) do
    {matching, rest} =
      Enum.split_with(headers, fn {key, _value} -> String.downcase(key) == name end)

    case matching do
      [{_key, value} | _] -> {value, rest}
      [] -> {nil, rest}
    end
  end
end
