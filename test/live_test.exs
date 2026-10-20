defmodule CareJobs.LiveTest do
  use ExUnit.Case

  # Runs against the real API, and only on request:
  #
  #     mix test --only live
  #
  # An uncached query can take about 25 seconds on the server, so each test gets two minutes
  # and each call a minute.
  @moduletag :live
  @moduletag timeout: 120_000

  test "search_jobs/1" do
    assert {:ok, %{data: data, text: text}} =
             CareJobs.search_jobs(kind: :nurses, state: "TX", limit: 3)

    assert data["total"] > 0
    assert length(data["jobs"]) in 1..3
    assert hd(data["jobs"])["url"] =~ ~r{\Ahttps://carejobs\.now/jobs/}
    assert text != ""
  end

  test "pay/1" do
    assert {:ok, %{data: all}} = CareJobs.pay()

    assert length(all["pay_by_kind"]) + length(all["no_market_rate"] || []) ==
             length(CareJobs.kinds())

    assert {:ok, %{data: nurses}} = CareJobs.pay(kind: :nurses)
    assert nurses["kind"] == "nurses"
    assert nurses["pay"]["median"] > 0
  end

  test "job_market/0" do
    assert {:ok, %{data: market}} = CareJobs.job_market()

    assert market["open_jobs"] > 0

    assert market["open_by_kind"] |> Enum.map(& &1["slug"]) |> Enum.sort() ==
             Enum.sort(CareJobs.kinds())
  end

  test "jobs_by_state/1" do
    assert {:ok, %{data: %{"states" => states}}} = CareJobs.jobs_by_state()
    assert length(states) >= 50

    assert {:ok, %{data: texas}} = CareJobs.jobs_by_state(state: "TX", limit: 2)
    assert texas["state"] == "TX"
    assert length(texas["newest"]) <= 2
  end

  test "employers/1 and employer/1" do
    assert {:ok, %{data: list}} = CareJobs.employers(query: "kaiser", limit: 3)
    assert list["total"] > 0

    slug = hd(list["entries"])["slug"]
    assert {:ok, %{data: employer}} = CareJobs.employer(slug)
    assert employer["slug"] == slug
    assert employer["open_jobs"] > 0

    assert {:ok, %{data: %{"slug" => "cvs-health"}}} = CareJobs.employer("cvs-health")
  end

  test "an unknown employer is a :tool error" do
    assert {:error, %CareJobs.Error{code: :tool, message: message}} =
             CareJobs.employer("no-such-employer-xyz")

    assert message =~ "Unknown employer"
  end

  test "the enumerations match the live schemas" do
    assert {:ok, tools} = CareJobs.tools()
    properties = Map.new(tools, &{&1["name"], &1["inputSchema"]["properties"]})

    assert properties["search_healthcare_jobs"]["kind"]["enum"] == CareJobs.kinds()
    assert properties["search_healthcare_jobs"]["sort"]["enum"] == CareJobs.sorts()
    assert properties["list_healthcare_employers"]["type"]["enum"] == CareJobs.employer_types()
    assert properties["list_healthcare_employers"]["care"]["enum"] == CareJobs.care_types()
  end

  test "a live HTTPS connection verifies the certificate: a host with a bad one is refused" do
    assert {:error, %CareJobs.Error{code: :network, message: message}} =
             CareJobs.job_market(base_url: "https://expired.badssl.com", timeout: 20_000)

    assert message =~ "TLS handshake failed"
  end
end
