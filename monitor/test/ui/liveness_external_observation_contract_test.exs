defmodule PixirMonitor.UILivenessExternalObservationContractTest do
  @moduledoc """
  Presenter contract for the `externally_owned` liveness state (#440).

  The truth card must read as an epistemic statement, not a fault; the follow
  banner must stay silent for a healthily progressing externally observed run;
  and the marker tone must be informational rather than attention-weight.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)
  @package Path.expand("../../priv/presenter", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  test "the marker vocabulary admits externally_owned", %{js: js} do
    assert js =~ ~s|"live", "externally_owned", "stale_handle"|
  end

  test "the liveness truth card copy is state-specific and never asserts a fault", %{js: js} do
    assert js =~ "function livenessCardNote("
    assert js =~ "Owner is another process; activity confirmed from durable Log evidence."
    assert js =~ ~s|truthCard(route, "Liveness", "liveness", livenessState(run), livenessBasis(run), livenessCardNote(run))|
    # "Not currently reachable" must no longer be the blanket else-branch for
    # every non-reachable state: externally_owned is not a reachability fault.
    refute js =~ ~s|run.liveness.reachable === true ? "Reachable now" : "Not currently reachable"|
  end

  test "the follow banner stays silent for a healthy externally observed run", %{js: js} do
    assert js =~
             ~S<if (liveness === "owner_unavailable" || liveness === "stale_handle") wrap.append(labeledMarker("Followed run is ">

    refute js =~ ~S<liveness === "externally_owned") wrap.append(labeledMarker("Followed run is ">
  end

  test "the externally_owned marker carries the muted tone, not the attention tone", %{css: css} do
    attention_rule =
      css
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, ".marker-stale_handle::before"))

    refute String.contains?(attention_rule, "marker-externally_owned")

    muted_rule =
      css
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, ".marker-unobserved::before"))

    assert String.contains?(muted_rule, ".marker-externally_owned::before")
  end

  test "the projection v1 spec documents the state and its basis" do
    spec = File.read!(Path.join(@package, "projection-v1.md"))

    assert spec =~ "externally_owned"
    assert spec =~ "durable_log_activity"
    assert spec =~ "activity_evidence"
    assert spec =~ ~r/live \| externally_owned \| stale_handle/
  end

  test "the run schema admits the state, its basis, and nothing else new" do
    schema =
      @package
      |> Path.join("schema/pixir.presenter.run.v1.schema.json")
      |> File.read!()
      |> Jason.decode!()

    liveness = schema["$defs"]["liveness"]["properties"]

    assert liveness["state"]["enum"] ==
             ~w(live externally_owned stale_handle owner_unavailable not_applicable unknown)

    assert "durable_log_activity" in liveness["basis"]["enum"]
  end

  test "the fixture schema admits the caller-supplied activity assertion" do
    schema =
      @package
      |> Path.join("schema/pixir.presenter.fixture.v1.schema.json")
      |> File.read!()
      |> Jason.decode!()

    activity = schema["$defs"]["activityEvidence"]

    assert activity["properties"]["durable_evidence"]["enum"] == ~w(advanced unchanged unknown)
    assert activity["additionalProperties"] == false
    assert Map.has_key?(schema["$defs"]["inputs"]["properties"], "activity_evidence")
    # The assertion is optional: absence is "not asserted", never a build error.
    refute "activity_evidence" in schema["$defs"]["inputs"]["required"]
  end

  test "the healthy external-observation fixture is frozen and proves the non-alarming projection" do
    manifest =
      @package |> Path.join("fixtures/manifest.json") |> File.read!() |> Jason.decode!()

    scenario =
      Enum.find(manifest["scenarios"], &(&1["id"] == "externally-owned-running-advancing"))

    assert is_map(scenario)
    assert Enum.any?(scenario["proves"], &(&1 =~ "externally_owned"))

    golden =
      @package
      |> Path.join("fixtures/golden/externally-owned-running-advancing.json")
      |> File.read!()
      |> Jason.decode!()

    assert golden["liveness"]["state"] == "externally_owned"
    assert golden["liveness"]["reachable"] == false
    assert golden["liveness"]["basis"] == "durable_log_activity"
    assert golden["execution"]["state"] == "running"
    assert golden["source"]["freshness"] == "current"
    refute "source_stale" in golden["source"]["limitations"]
    assert golden["counts"]["attention_units"] == 0
  end

  test "the stale-running-no-owner fixture still proves the conservative fallback" do
    manifest =
      @package |> Path.join("fixtures/manifest.json") |> File.read!() |> Jason.decode!()

    scenario = Enum.find(manifest["scenarios"], &(&1["id"] == "stale-running-no-owner"))

    assert Enum.any?(scenario["proves"], &(&1 =~ "without asserted"))

    golden =
      @package
      |> Path.join("fixtures/golden/stale-running-no-owner.json")
      |> File.read!()
      |> Jason.decode!()

    assert golden["liveness"]["state"] == "stale_handle"
    assert golden["source"]["freshness"] == "stale"
    assert golden["counts"]["attention_units"] == 1
  end
end
