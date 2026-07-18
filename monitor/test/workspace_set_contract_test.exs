unless Code.ensure_loaded?(PixirMonitor.InventoryFixture) do
  Code.require_file("support/inventory_fixture.ex", __DIR__)
end

defmodule PixirMonitor.WorkspaceSetContractSource do
  @moduledoc false

  def list_runs(%{key: key}) do
    {:ok,
     %{
       "schema" => "pixir.monitor.runs",
       "schema_version" => 1,
       "runs" => [
         %{
           "run" => %{"id" => "same-session", "title" => "Run from #{key}"},
           "attention" => %{"required" => false}
         }
       ],
       "inventory" => %{
         "total" => 1,
         "selected" => 1,
         "truncated" => false,
         "limitations" => []
       }
     }}
  end

  def fetch_run("same-session", %{key: key}) do
    {:ok,
     %{
       "schema" => "pixir.presenter.run",
       "schema_version" => 1,
       "run" => %{"id" => "same-session", "title" => "Run from #{key}"}
     }}
  end

  def fetch_run(id, _source) do
    {:error, %{kind: "run_not_found", message: "Run was not found", details: %{run_id: id}}}
  end
end

defmodule PixirMonitor.WorkspaceSetContractFailingSource do
  @moduledoc false

  def list_runs(%{key: "left"}),
    do: {:error, %{kind: "run_source_failed", message: "Source failed", details: %{reason: "/private/sentinel/root"}}}

  def list_runs(source), do: PixirMonitor.WorkspaceSetContractSource.list_runs(source)
  def fetch_run(id, source), do: PixirMonitor.WorkspaceSetContractSource.fetch_run(id, source)
end

defmodule PixirMonitor.WorkspaceSetContractTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  @host "127.0.0.1:41091"
  @origin "http://127.0.0.1:41091"
  @schema_path "priv/presenter/schema/pixir.presenter.workspace_set.v1.schema.json"

  setup do
    previous = %{
      workspace_set: Application.get_env(:pixir_monitor, :workspace_set),
      run_source: Application.get_env(:pixir_monitor, :run_source),
      projection_source: Application.get_env(:pixir_monitor, :projection_source),
      active_port: Application.get_env(:pixir_monitor, :active_port)
    }

    root = Path.join(System.tmp_dir!(), "pixir-workspace-set-#{System.unique_integer([:positive])}")
    left = Path.join(root, "private-left-root")
    right = Path.join(root, "private-right-root")
    File.mkdir_p!(left)
    File.mkdir_p!(right)

    Application.put_env(:pixir_monitor, :workspace_set, [
      %{key: "left", path: left},
      %{key: "right", path: right}
    ])

    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.WorkspaceSetContractSource)
    Application.put_env(:pixir_monitor, :active_port, 41_091)

    on_exit(fn ->
      File.rm_rf!(root)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    {:ok, root: root, left: left, right: right}
  end

  test "fixture declares the complete frozen negative case set" do
    fixture = Jason.decode!(File.read!("test/fixtures/workspace_set_contract_cases.json"))

    expected =
      MapSet.new([
        "set-frame-missing-workspace",
        "single-frame-carrying-workspace",
        "frame-extra-key",
        "frame-unknown-workspace",
        "envelope-missing-provenance",
        "envelope-invalid-provenance",
        "envelope-extra-key",
        "shell-wrong-cardinality",
        "shell-duplicate-key",
        "shell-unknown-mode",
        "unscoped-route-in-set-mode",
        "scoped-route-in-single-mode",
        "absolute-path-disclosure",
        "stale-deep-view",
        "unavailability-is-never-zero",
        "no-set-sums",
        "collision-honesty"
      ])

    assert MapSet.new(fixture["negative"]) == expected
  end

  test "generated shell, list, detail, error, and set frame conform to frozen schema definitions", %{left: left} do
    schema = Jason.decode!(File.read!(@schema_path))
    create_real_run(left, "real-run")
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)
    {:ok, list} = PixirMonitor.WorkspaceSet.list_runs("left")
    {:ok, detail} = PixirMonitor.WorkspaceSet.fetch_run("left", "real-run")
    {:error, run_not_found} = PixirMonitor.WorkspaceSet.fetch_run("left", "missing-run")
    {:error, invalid_key} = PixirMonitor.WorkspaceSet.source("$invalid")
    {:ok, shell} = PixirMonitor.Bootstrap.shell()
    assert shell =~ "<main aria-label=\"Pixir Monitor\""
    assert shell =~ ~S|<p id="status" role="status">|
    [encoded] = Regex.run(~r/data-workspace-set="([^"]+)"/, shell, capture: :all_but_first)

    shell_config =
      encoded
      |> String.replace("&quot;", "\"")
      |> String.replace("&amp;", "&")
      |> Jason.decode!()

    assert_schema_valid(schema, "shell_config", shell_config)
    assert_schema_valid(schema, "scoped_list_snapshot", list)
    assert_schema_valid(schema, "scoped_run_snapshot", detail)
    assert_schema_valid(schema, "scoped_error", json_round_trip(%{error: run_not_found}))
    assert_schema_valid(schema, "scoped_error", json_round_trip(%{error: invalid_key}))

    frame = frame_data(PixirMonitor.InvalidationHub.frame(7, "left", "same-session"))
    assert_schema_valid(schema, "invalidation_frame", frame)
  end

  test "configured workspace set rejects malformed sources and duplicate keys", %{left: left, right: right} do
    invalid_sets = [
      [%{key: "left", path: left}, :not_a_source],
      [%{key: "left", path: left}, %{key: "right"}],
      [%{key: "left", path: left}, %{key: 42, path: right}],
      [%{key: "left", path: left}, %{key: "right", path: 42}],
      [%{key: "$invalid", path: left}, %{key: "right", path: right}],
      [%{key: "same", path: left}, %{key: "same", path: right}]
    ]

    Enum.each(invalid_sets, fn sources ->
      Application.put_env(:pixir_monitor, :workspace_set, sources)
      assert {:error, %{kind: "workspace_set_not_configured"}} = PixirMonitor.WorkspaceSet.configured()
      assert {:ok, :single} = PixirMonitor.WorkspaceSet.mode()
    end)
  end

  test "schema rejects crossed frames, shell drift, envelope drift, and forbidden error details" do
    valid_frame = %{"type" => "projection_changed", "workspace" => "left", "projection_id" => "run"}
    refute schema_valid?("invalidation_frame", Map.delete(valid_frame, "workspace"))
    refute schema_valid?("invalidation_frame", Map.put(valid_frame, "extra", true))
    refute schema_valid?("invalidation_frame", %{valid_frame | "workspace" => "undeclared key"})

    for shell <- [
          %{"mode" => "workspace_set", "workspaces" => ["left"]},
          %{"mode" => "workspace_set", "workspaces" => ["left", "right", "third"]},
          %{"mode" => "workspace_set", "workspaces" => ["left", "left"]},
          %{"mode" => "fleet", "workspaces" => ["left", "right"]}
        ] do
      refute schema_valid?("shell_config", shell)
    end

    valid_list = %{
      "workspace" => "left",
      "source" => %{"sessions_directory" => "observed"},
      "snapshot" => %{
        "schema" => "pixir.monitor.runs",
        "schema_version" => 1,
        "runs" => [],
        "inventory" => %{"total" => 0, "selected" => 0, "truncated" => false, "limitations" => []}
      }
    }

    refute schema_valid?("scoped_list_snapshot", Map.delete(valid_list, "source"))
    refute schema_valid?("scoped_list_snapshot", put_in(valid_list, ["source", "sessions_directory"], "unknown"))
    refute schema_valid?("scoped_list_snapshot", Map.put(valid_list, "extra", true))
    refute schema_valid?("scoped_list_snapshot", put_in(valid_list, ["snapshot", "schema"], "wrong"))

    refute schema_valid?("scoped_error", %{
             "error" => %{
               "kind" => "invalid_workspace_key",
               "message" => "invalid",
               "details" => %{"workspace" => "left"}
             }
           })
  end

  test "projection source rejects non-list list options without raising" do
    assert {:error,
            %{
              kind: "invalid_projection_options",
              message: "Projection options must be a keyword list",
              details: %{}
            }} = PixirMonitor.Projection.Source.list_runs(%{})
  end

  test "real projector distinguishes an observed empty directory from an absent directory", %{left: left} do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)
    File.mkdir_p!(Path.join([left, ".pixir", "sessions"]))

    assert {:ok,
            %{
              "source" => %{"sessions_directory" => "observed"},
              "snapshot" => %{
                "inventory" => %{
                  "total" => 0,
                  "selected" => 0,
                  "truncated" => false,
                  "limitations" => []
                }
              }
            }} = PixirMonitor.WorkspaceSet.list_runs("left")

    assert {:ok,
            %{
              "source" => %{"sessions_directory" => "absent"},
              "snapshot" => %{"inventory" => %{"total" => 0}}
            }} = PixirMonitor.WorkspaceSet.list_runs("right")
  end

  test "real projector keeps truncation and projection limitations inside one source", %{left: left} do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)
    Application.put_env(:pixir_monitor, :projection_source, max_logs: 1, max_log_bytes: 8_388_608, max_events: 20_000)
    sessions = Path.join([left, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    File.write!(Path.join(sessions, "first.ndjson"), "{malformed\n")
    File.write!(Path.join(sessions, "second.ndjson"), "")

    assert {:ok, %{"snapshot" => %{"inventory" => inventory}}} =
             PixirMonitor.WorkspaceSet.list_runs("left")

    assert inventory["total"] == 2
    assert inventory["selected"] == 1
    assert inventory["truncated"] == true

    assert Enum.map(inventory["limitations"], & &1["kind"]) == [
             "run_inventory_truncated",
             "run_projection_incomplete"
           ]

    assert {:ok, %{"snapshot" => %{"inventory" => sibling}}} =
             PixirMonitor.WorkspaceSet.list_runs("right")

    assert sibling["total"] == 0
    assert sibling["limitations"] == []
  end

  test "scoped snapshots pass through the real projector modulo volatile clock fields", %{left: left} do
    create_real_run(left, "real-parity")
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)
    opts = [workspace: left, max_logs: 512, max_log_bytes: 8_388_608, max_events: 20_000]

    {:ok, expected_list} = PixirMonitor.Projection.Source.list_runs(opts)
    {:ok, expected_detail} = PixirMonitor.Projection.Source.fetch_run("real-parity", opts)

    assert {:ok, %{"snapshot" => actual_list} = list_envelope} =
             PixirMonitor.WorkspaceSet.list_runs("left")

    assert {:ok, %{"snapshot" => actual_detail} = detail_envelope} =
             PixirMonitor.WorkspaceSet.fetch_run("left", "real-parity")

    assert normalize_clocks(actual_list) == normalize_clocks(expected_list)
    assert normalize_clocks(actual_detail) == normalize_clocks(expected_detail)

    assert Map.keys(list_envelope) |> Enum.sort() == ["snapshot", "source", "workspace"]
    assert Map.keys(detail_envelope) |> Enum.sort() == ["snapshot", "source", "workspace"]
    refute Map.has_key?(list_envelope, "observed_at")
    refute Map.has_key?(list_envelope, "projected_at")
    refute Map.has_key?(list_envelope, "authority")
  end

  test "equal run ids remain unambiguous workspace-scoped identities with no collision inference" do
    assert {:ok, left} = PixirMonitor.WorkspaceSet.fetch_run("left", "same-session")
    assert {:ok, right} = PixirMonitor.WorkspaceSet.fetch_run("right", "same-session")
    assert left["workspace"] == "left"
    assert right["workspace"] == "right"
    assert left["snapshot"]["run"]["title"] != right["snapshot"]["run"]["title"]
    refute inspect([left, right]) =~ "collision"
    refute inspect([left, right]) =~ "cross_reference"
  end

  test "both workspace sources confess their independent 512 of 513 inventory bounds", %{
    left: left,
    right: right
  } do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)

    Application.put_env(:pixir_monitor, :projection_source,
      max_logs: 512,
      max_log_bytes: 8_388_608,
      max_events: 20_000
    )

    left_ids = PixirMonitor.InventoryFixture.materialize_many!(left, 0..512) |> MapSet.new()
    right_ids = PixirMonitor.InventoryFixture.materialize_many!(right, 4096..4608) |> MapSet.new()

    assert MapSet.disjoint?(left_ids, right_ids)

    assert {:ok, %{"workspace" => "left", "snapshot" => left_snapshot}} =
             PixirMonitor.WorkspaceSet.list_runs("left")

    assert {:ok, %{"workspace" => "right", "snapshot" => right_snapshot}} =
             PixirMonitor.WorkspaceSet.list_runs("right")

    assert_magnitude_inventory(left_snapshot["inventory"])
    assert_magnitude_inventory(right_snapshot["inventory"])

    selected_left_ids = left_snapshot["runs"] |> MapSet.new(& &1["id"])
    selected_right_ids = right_snapshot["runs"] |> MapSet.new(& &1["id"])

    assert MapSet.size(selected_left_ids) == 512
    assert MapSet.size(selected_right_ids) == 512
    assert MapSet.subset?(selected_left_ids, left_ids)
    assert MapSet.subset?(selected_right_ids, right_ids)
    assert MapSet.disjoint?(selected_left_ids, selected_right_ids)
    assert MapSet.disjoint?(selected_left_ids, right_ids)
    assert MapSet.disjoint?(selected_right_ids, left_ids)
  end

  test "source-scoped routes isolate failures and unscoped routes confess set mode", %{left: left_root, right: right_root} do
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    left_response = request(:get, "/api/workspaces/left/runs", headers)
    right_response = request(:get, "/api/workspaces/right/runs/same-session", headers)
    assert left_response.status == 200
    assert right_response.status == 200
    assert Jason.decode!(right_response.resp_body)["workspace"] == "right"

    unscoped = request(:get, "/api/runs", headers)
    assert unscoped.status == 404

    assert Jason.decode!(unscoped.resp_body) == %{
             "error" => %{
               "kind" => "unscoped_route_unavailable",
               "message" => "Use a workspace-scoped Runs route"
             }
           }

    invalid = request(:get, "/api/workspaces/%24bad/runs", headers)
    assert invalid.status == 400
    refute Jason.decode!(invalid.resp_body)["error"] |> Map.has_key?("details")
    assert {:error, invalid_module_error} = PixirMonitor.WorkspaceSet.list_runs("$bad")
    assert invalid_module_error.kind == "invalid_workspace_key"
    refute Map.has_key?(invalid_module_error, :details)

    unknown = request(:get, "/api/workspaces/unknown/runs", headers)
    assert unknown.status == 404
    assert get_in(Jason.decode!(unknown.resp_body), ["error", "details", "workspace"]) == "unknown"

    for response <- [left_response, right_response, unscoped, invalid, unknown] do
      for private_path <- [
            left_root,
            right_root,
            Path.join([left_root, ".pixir", "sessions"]),
            Path.join([right_root, ".pixir", "sessions"])
          ] do
        refute response.resp_body =~ private_path
      end

      refute response.resp_body =~ "workspace_basename"
    end
  end

  test "one failed source is a label-only 503 while its sibling remains authoritative" do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.WorkspaceSetContractFailingSource)
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    failed = request(:get, "/api/workspaces/left/runs", headers)
    sibling = request(:get, "/api/workspaces/right/runs", headers)

    assert failed.status == 503
    assert sibling.status == 200

    assert Jason.decode!(failed.resp_body) == %{
             "error" => %{
               "kind" => "workspace_unavailable",
               "message" => "Workspace projection is unavailable",
               "details" => %{"workspace" => "left", "reason" => "workspace_error"}
             }
           }

    refute failed.resp_body =~ "/private/sentinel/root"
    refute failed.resp_body =~ "workspace_basename"
  end

  test "single and workspace-set SSE frames are separate exact contract cases" do
    raw_single = PixirMonitor.InvalidationHub.frame(1, "same-session")

    # Frozen single-workspace wire bytes, captured from the REAL frame/2 output
    # (key order included): changing event name, ids, key order, or delimiters
    # is a contract break.
    assert raw_single ==
             "id: 1\nevent: projection_changed\ndata: {\"type\":\"projection_changed\",\"projection_id\":\"same-session\"}\n\n"

    single = frame_data(raw_single)
    set = frame_data(PixirMonitor.InvalidationHub.frame(2, "left", "same-session"))

    assert Map.keys(single) |> Enum.sort() == ["projection_id", "type"]
    assert Map.keys(set) |> Enum.sort() == ["projection_id", "type", "workspace"]
    refute Map.has_key?(single, "workspace")
    refute schema_valid?("invalidation_frame", single)
    assert schema_valid?("invalidation_frame", set)
    refute schema_valid?("invalidation_frame", Map.put(set, "extra", true))
  end

  test "single-workspace shell and routes retain their pre-set shapes" do
    Application.delete_env(:pixir_monitor, :workspace_set)
    {:ok, shell} = PixirMonitor.Bootstrap.shell()
    refute shell =~ "data-workspace-set"

    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]
    scoped = request(:get, "/api/workspaces/left/runs", headers)
    assert scoped.status == 405

    single_frame = frame_data(PixirMonitor.InvalidationHub.frame(3, "same-session"))
    refute Map.has_key?(single_frame, "workspace")
  end

  test "bundle pins workspace-bound navigation, collision-safe client state, anomaly deep refetch, and unavailable rendering" do
    js = File.read!("priv/static/app.js")

    assert js =~ "const routedList = workspaceSetMode() && workspaceSnapshots[route.workspace] && workspaceSnapshots[route.workspace].list;"
    assert js =~ "if (workspaceSetMode()) state.list = routedList ? routedList.snapshot : null;"
    assert js =~ "return current.workspace + \":\""
    assert js =~ "node.dataset.focusKey = clientStateKey(value)"
    assert js =~ "node.dataset.disclosureKey = scopedDisclosureValue(value)"
    assert js =~ "activityOrder: scopedStore()"
    assert js =~ "pages: scopedStore()"
    assert js =~ "savedRestore.workspace || null"
    assert js =~ "state.detailWorkspace === route.workspace"
    assert js =~ "envelope.workspace === workspace"
    assert js =~ "held.listObservedAt"
    assert js =~ "held.detailObservedAt"
    assert js =~ "held.listError"
    assert js =~ "held.detailError"
    assert js =~ "const heldPayload = held && (route.view === \"runs\" ? held.list : held.detailId === route.runId ? held.detail : null);"
    assert js =~ "if (heldPayload && heldError && route.view !== \"workspaces\")"
    assert js =~ "listObservedAt: new Date().toISOString()"
    assert js =~ "listError: null});\n      state.lastAuthoritativeRefetchAt = new Date();"
    assert js =~ "detailObservedAt: receivedAt"
    assert js =~ "const listRefresh = refetchWorkspaceList(parsed.workspace, reason)"
    assert js =~ "sourceRequestGeneration: Object.create(null)"
    assert js =~ "const requestGeneration = (state.sourceRequestGeneration[workspace] || 0) + 1"
    assert js =~ "state.sourceRequestGeneration[workspace] !== requestGeneration"
    assert js =~ "Object.assign({}, workspaceSnapshots[workspace] || {}, {list: envelope, listObservedAt: new Date().toISOString(), listError: null})"
    assert js =~ "Object.assign({}, workspaceSnapshots[workspace] || {}, {listError: {kind: failure.kind}})"
    assert js =~ "Object.assign({}, workspaceSnapshots[workspace] || {}, {detail: snapshot, detailId: route.runId, detailObservedAt: receivedAt, detailError: null})"
    assert js =~ "const failureState = {detailError: {kind: failure.kind}}"
    assert js =~ "Object.assign({}, workspaceSnapshots[workspace] || {}, failureState)"
    assert length(String.split(js, "const currentSnapshot = workspaceSnapshots[workspace] || {};")) == 3
    assert js =~ "if (currentSnapshot.detail && currentSnapshot.detailId === route.runId)"
    refute js =~ "if (route.view === \"runs\" && held.list)"
    refute js =~ "held.detail && held.detailId === route.runId"
    assert length(String.split(js, "Object.assign({}, workspaceSnapshots[workspace] || {},")) == 5
    assert length(String.split(js, "workspaceSnapshots[workspace] =")) == 5
    refute js =~ "Object.assign({}, held,"
    assert js =~ "fetchJSON(\"/api/workspaces/\" + encodeURIComponent(workspace) + \"/runs\", null)"
    assert js =~ "expectedGeneration !== null && expectedGeneration !== state.generation"
    assert js =~ "return refetchWorkspaceList(workspace, null)"
    assert js =~ "await refetchWorkspaceList(workspace, null)"
    assert js =~ "Per-source latest-result-wins arbitration: stale completions are discarded silently."
    assert js =~ "let latestFailure = null"
    assert js =~ "latestFailure = failure"
    assert js =~ "else if (currentSnapshot.listError && latestFailure) renderProjectionFailureSafely(latestFailure);"
    assert js =~ "refreshSingleFlight(reason + \" detail revalidation\")"
    assert js =~ "refreshSingleFlight(reason + \" deep-view revalidation\")"
    assert js =~ "if (runChanged) refreshSingleFlight(\"navigation\");"
    assert js =~ "Attention and remaining runs are unavailable because no source snapshot is held."
    assert js =~ "Unavailable. No observed count is held; retry the authoritative source."
    assert js =~ "Retry this source"
    assert js =~ "refetchWorkspaceList(workspace, \"source retry\")"
    assert js =~ "\"source-retry:\" + workspace"
    refute js =~ "Unavailable. Observed Session Logs: 0"
  end

  test "bundle pins strict boot, source routes, traveling stale disclosure, and text-only hostile rendering" do
    js = File.read!("priv/static/app.js")

    assert js =~ "Object.keys(value).sort().join(\",\") === \"mode,workspaces\""
    assert js =~ "#/workspaces/"
    assert js =~ "if (workspaceSetMode()) {\n      if (route.view === \"invalid\") {\n        renderCurrent();\n        return;"
    assert js =~ "Stale source snapshot · received "
    assert js =~ "Authoritative scoped snapshot · "
    assert js =~ "const receiptLabel = held.listError ? \"last-observed \" : \"observed-at \""
    assert js =~ "Sessions directory provenance: "
    assert js =~ "Inventory bases: projected_runs "
    assert js =~ "non_parent_logs "
    assert js =~ "dropped_logs "
    assert js =~ "Limitation details: "
    assert js =~ "Error kinds: "
    assert js =~ ~s|const stats = el("p", "source-stats");|

    assert js =~
             ~s|const evidence = setDisclosureKey(el("details", "source-evidence"), "source-evidence:" + workspace);|

    assert js =~ ~s|text("summary", "Evidence details")|

    assert js =~
             ~s|const remaining = setDisclosureKey(el("details", "remaining-runs-disclosure"), "remaining-runs:" + workspace);|

    assert js =~ ~s|text("summary", "View all remaining runs")|
    assert js =~ ~s|"remaining-runs:" + workspace|
    assert js =~ "No parent-observed attention in the held snapshot."
    assert js =~ "No remaining observed runs in the held snapshot."
    assert js =~ "node.textContent = scalar(value, \"—\")"
    assert js =~ "Object.keys(body).sort().join(\",\") !== expectedKeys"
    assert js =~ "function exactObjectKeys(value, required, allowed)"
    assert js =~ "function validateScopedEnvelope(envelope, workspace, scope)"
    assert js =~ "envelope.workspace !== workspace"
    assert js =~ "![\"observed\", \"absent\"].includes(envelope.source.sessions_directory)"
    assert js =~ "snapshot.schema !== \"pixir.monitor.runs\" || snapshot.schema_version !== 1"
    assert js =~ "typeof row.id === \"string\" && row.id.length > 0"
    assert js =~ "snapshot.schema !== \"pixir.presenter.run\" || snapshot.schema_version !== 1"
    assert js =~ "inventoryAllowed = inventoryRequired.concat([\"dropped_logs\", \"non_parent_logs\", \"projected_runs\"])"
    assert js =~ "throw projectionFailure(\"decode\", \"scoped_envelope_invalid\", 200)"
    assert js =~ "validateScopedEnvelope(fetchedEnvelope, workspace, \"list\")"
    refute js =~ "Healthy"
    refute js =~ "healthy\""
    refute js =~ ".innerHTML"
  end

  test "serve grammar rejects every frozen declaration error kind", %{left: left, right: right} do
    invalid_key = "bad key=#{left}"

    cases = [
      {["left=#{left}"], "workspace_declaration_single_keyed"},
      {["left=#{left}", "right=#{right}", "third=#{left}"], "workspace_declaration_too_many"},
      {["left=#{left}", right], "workspace_declaration_mixed"},
      {[left, right], "workspace_declaration_unkeyed_pair"},
      {["left=#{left}", "left=#{right}"], "workspace_declaration_duplicate_key"},
      {[invalid_key, "right=#{right}"], "workspace_declaration_invalid_key"},
      {["left=", "right=#{right}"], "workspace_declaration_empty_path"},
      {["path=that-was-plain"], "workspace_declaration_single_keyed"}
    ]

    Enum.each(cases, fn {values, kind} ->
      assert {:error, %{kind: ^kind}} = PixirMonitor.CLI.resolve_workspace_config(values)
    end)
  end

  defp assert_magnitude_inventory(inventory) do
    assert inventory["total"] == 513
    assert inventory["selected"] == 512
    assert inventory["projected_runs"] == 512
    assert inventory["non_parent_logs"] == 0
    assert inventory["dropped_logs"] == 0
    assert inventory["truncated"] == true

    assert inventory["limitations"] == [
             %{
               "kind" => "run_inventory_truncated",
               "message" => "Only the newest bounded Session Logs were selected",
               "details" => %{"max_logs" => 512, "total" => 513, "selected" => 512}
             }
           ]
  end

  defp assert_schema_valid(schema, definition, value) do
    required_definitions =
      case definition do
        "shell_config" -> ["shell_config", "workspace_key"]
        "scoped_list_snapshot" -> ["scoped_list_snapshot", "workspace_key", "source_facts", "runs_list_document"]
        "scoped_run_snapshot" -> ["scoped_run_snapshot", "workspace_key", "source_facts"]
        "scoped_error" -> ["scoped_error", "workspace_key"]
        "invalidation_frame" -> ["invalidation_frame", "workspace_key"]
      end

    definitions = Map.take(schema["$defs"], required_definitions)

    definitions =
      if definition == "scoped_run_snapshot" do
        run_schema = Jason.decode!(File.read!("priv/presenter/schema/pixir.presenter.run.v1.schema.json"))
        put_in(definitions, ["scoped_run_snapshot", "properties", "snapshot"], run_schema)
      else
        definitions
      end

    document = %{
      "$schema" => schema["$schema"],
      "$ref" => "#/$defs/#{definition}",
      "$defs" => definitions
    }

    built = JSV.build!(document)
    assert {:ok, ^value} = JSV.validate(value, built)
  end

  defp schema_valid?(definition, value) do
    schema = Jason.decode!(File.read!(@schema_path))

    try do
      assert_schema_valid(schema, definition, value)
      true
    rescue
      ExUnit.AssertionError -> false
    end
  end

  defp create_real_run(workspace, id) do
    event =
      Pixir.Event.new(
        id,
        :subagent_event,
        %{
          "event" => "queued",
          "status" => "queued",
          "subagent_id" => "subagent-1",
          "child_session_id" => "child-1",
          "agent" => "default"
        },
        seq: 0,
        ts: "2026-01-01T00:00:00Z"
      )

    assert {:ok, [_]} = Pixir.Log.create_session(id, [event], workspace: workspace)
  end

  defp normalize_clocks(value) when is_map(value) do
    value
    |> Map.drop(["projected_at", "observed_at"])
    |> Map.new(fn {key, nested} -> {key, normalize_clocks(nested)} end)
  end

  defp normalize_clocks(value) when is_list(value), do: Enum.map(value, &normalize_clocks/1)
  defp normalize_clocks(value), do: value

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp frame_data(frame) do
    frame
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "data: "))
    |> String.replace_prefix("data: ", "")
    |> Jason.decode!()
  end

  defp session_cookie do
    {:ok, launch} = PixirMonitor.Vault.issue_launch()

    accepted =
      request(
        :post,
        "/bootstrap",
        [
          {"origin", @origin},
          {"sec-fetch-site", "same-origin"},
          {"content-type", "application/json"}
        ],
        Jason.encode!(%{launch: launch})
      )

    accepted
    |> get_resp_header("set-cookie")
    |> List.first()
    |> String.split(";", parts: 2)
    |> hd()
  end

  defp request(method, path, headers, body \\ "") do
    uri = URI.parse("http://#{@host}")

    Enum.reduce(headers, %{conn(method, path, body) | host: uri.host, port: uri.port}, fn {key, value}, acc ->
      put_req_header(acc, key, value)
    end)
    |> PixirMonitor.Router.call([])
  end

  defp restore_env(key, nil), do: Application.delete_env(:pixir_monitor, key)
  defp restore_env(key, value), do: Application.put_env(:pixir_monitor, key, value)
end
