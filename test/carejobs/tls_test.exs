defmodule CareJobs.TLSTest do
  use ExUnit.Case

  # The default transport verifies the server's certificate: it must chain to a trusted CA
  # and match the host name. These tests run a TLS server on the loopback interface with a
  # certificate for "localhost" that a throwaway CA signed.

  setup do
    tls = FakeServer.tls_config()
    server = FakeServer.start(fn _request -> Fixtures.raw("market") end, tls: tls.server)
    on_exit(fn -> FakeServer.stop(server) end)
    %{server: server, cacerts: tls.cacerts}
  end

  test "accepts a certificate that chains to a trusted CA and matches the host", %{
    server: server,
    cacerts: cacerts
  } do
    assert {:ok, %{data: %{"open_jobs" => _}}} =
             CareJobs.job_market(base_url: server.url, cacerts: cacerts, timeout: 5_000)

    assert FakeServer.last_request(server).path == "/api/mcp"
  end

  test "rejects a certificate no trusted CA signed", %{server: server} do
    assert {:error, %CareJobs.Error{code: :network, message: message}} =
             CareJobs.job_market(base_url: server.url, timeout: 5_000)

    assert message =~ "TLS handshake failed"
    assert FakeServer.requests(server) == []
  end

  test "rejects a trusted certificate that is for another host", %{
    server: server,
    cacerts: cacerts
  } do
    # The certificate names "localhost", not the address 127.0.0.1.
    assert {:error, %CareJobs.Error{code: :network, message: message}} =
             CareJobs.job_market(
               base_url: "https://127.0.0.1:#{server.port}",
               cacerts: cacerts,
               timeout: 5_000
             )

    assert message =~ "hostname_check_failed"
    assert FakeServer.requests(server) == []
  end
end
