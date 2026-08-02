defmodule PixirMonitor.WorkspaceSetCardinalitySource do
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
       "inventory" => %{"total" => 1, "selected" => 1, "truncated" => false, "limitations" => []}
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

  def fetch_run(id, _source),
    do: {:error, %{kind: "run_not_found", message: "Run was not found", details: %{run_id: id}}}
end

defmodule PixirMonitor.WorkspaceSetCardinalityFailingSource do
  @moduledoc false

  def list_runs(%{key: "lane3"}),
    do: {:error, %{kind: "run_source_failed", message: "Source failed", details: %{}}}

  def list_runs(source), do: PixirMonitor.WorkspaceSetCardinalitySource.list_runs(source)
  def fetch_run(id, source), do: PixirMonitor.WorkspaceSetCardinalitySource.fetch_run(id, source)
end

defmodule PixirMonitor.WorkspaceSetCardinalityTest do
  @moduledoc """
  Pins the bounded-N (2..8) widening of keyed workspace-set mode: declaration
  grammar at cardinality greater than two, the configured-source gate, the
  shell embed and its schema bound, per-source isolation across N sections,
  and the operator-facing copy that must no longer promise "exactly two".
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  @host "127.0.0.1:41093"
  @origin "http://127.0.0.1:41093"
  @schema_path "priv/presenter/schema/pixir.presenter.workspace_set.v1.schema.json"
  @max_sources 8

  setup do
    previous = %{
      workspace_set: Application.get_env(:pixir_monitor, :workspace_set),
      run_source: Application.get_env(:pixir_monitor, :run_source),
      projection_source: Application.get_env(:pixir_monitor, :projection_source),
      active_port: Application.get_env(:pixir_monitor, :active_port)
    }

    root = Path.join(System.tmp_dir!(), "pixir-workspace-cardinality-#{System.unique_integer([:positive])}")

    roots =
      Map.new(1..(@max_sources + 1), fn index ->
        path = Path.join(root, "private-lane-#{index}-root")
        File.mkdir_p!(path)
        {index, path}
      end)

    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.WorkspaceSetCardinalitySource)
    Application.put_env(:pixir_monitor, :active_port, 41_093)

    on_exit(fn ->
      File.rm_rf!(root)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    {:ok, root: root, roots: roots}
  end

  defp lane_key(index), do: "lane#{index}"

  defp declarations(roots, count),
    do: Enum.map(1..count, fn index -> "#{lane_key(index)}=#{roots[index]}" end)

  defp install_set(roots, count) do
    sources = Enum.map(1..count, fn index -> %{key: lane_key(index), path: roots[index]} end)
    Application.put_env(:pixir_monitor, :workspace_set, sources)
    sources
  end

  test "three keyed declarations resolve into workspace-set mode in declaration order", %{roots: roots} do
    assert {:ok, {:workspace_set, sources}} =
             PixirMonitor.CLI.resolve_workspace_config(declarations(roots, 3))

    assert Enum.map(sources, & &1.key) == ["lane1", "lane2", "lane3"]
    assert Enum.map(sources, & &1.origin) == ["cli", "cli", "cli"]
    assert Enum.map(sources, & &1.path) == Enum.map(1..3, &Path.expand(roots[&1]))
  end

  test "the maximum supported keyed declarations resolve on the same terms", %{roots: roots} do
    assert {:ok, {:workspace_set, sources}} =
             PixirMonitor.CLI.resolve_workspace_config(declarations(roots, @max_sources))

    assert Enum.map(sources, & &1.key) == Enum.map(1..@max_sources, &lane_key/1)
  end

  test "one declaration beyond the bound fails with the stable kind and discloses the bound", %{roots: roots} do
    assert {:error, error} = PixirMonitor.CLI.resolve_workspace_config(declarations(roots, @max_sources + 1))
    assert error.kind == "workspace_declaration_too_many"
    assert error.details[:max_workspaces] == @max_sources
    assert Enum.any?(error.next_actions, &(&1 =~ to_string(@max_sources)))
    refute Enum.any?(error.next_actions, &(&1 =~ "exactly two"))
  end

  test "an empty declaration list is a declaration error, never an empty workspace set" do
    assert {:error, error} = PixirMonitor.CLI.resolve_workspace_config([])
    assert error.kind == "workspace_declaration_empty"
    assert Enum.any?(error.next_actions, &(&1 =~ to_string(@max_sources)))
  end

  test "serve-time over-bound declarations print kind and message and drop nothing", %{roots: roots} do
    args = ["serve", "--dry-run", "--json"] ++ Enum.flat_map(declarations(roots, @max_sources + 1), &["--workspace", &1])

    output = capture_io(:stderr, fn -> assert {:error, 1} = PixirMonitor.CLI.run(args) end)
    error = Jason.decode!(output)["error"]

    assert error["kind"] == "workspace_declaration_too_many"
    assert is_binary(error["message"]) and error["message"] != ""
    assert error["details"]["max_workspaces"] == @max_sources
    refute Map.has_key?(error, "workspaces")
  end

  test "declaration violations keep their kinds above cardinality two", %{roots: roots} do
    base = declarations(roots, 3)

    cases = [
      {base ++ ["lane1=#{roots[4]}"], "workspace_declaration_duplicate_key"},
      {base ++ ["bad key=#{roots[4]}"], "workspace_declaration_invalid_key"},
      {base ++ ["lane4="], "workspace_declaration_empty_path"},
      {base ++ [roots[4]], "workspace_declaration_mixed"},
      {[roots[1], roots[2], roots[3]], "workspace_declaration_unkeyed_pair"},
      {["lane1=#{roots[1]}"], "workspace_declaration_single_keyed"}
    ]

    Enum.each(cases, fn {values, kind} ->
      assert {:error, %{kind: ^kind}} = PixirMonitor.CLI.resolve_workspace_config(values),
             "expected #{kind} for #{inspect(values)}"
    end)
  end

  test "the dry-run plan lists every declared source in declaration order", %{roots: roots} do
    args = ["serve", "--dry-run", "--json"] ++ Enum.flat_map(declarations(roots, 5), &["--workspace", &1])

    {output, result} = run_io(fn -> PixirMonitor.CLI.run(args) end)
    assert {:ok, 0} = result
    plan = Jason.decode!(output)

    assert plan["mode"] == "workspace_set"
    assert Enum.map(plan["workspaces"], & &1["key"]) == Enum.map(1..5, &lane_key/1)
    assert Enum.map(plan["workspaces"], & &1["origin"]) == List.duplicate("cli", 5)
    assert Enum.map(plan["workspaces"], & &1["path"]) == Enum.map(1..5, &Path.expand(roots[&1]))
  end

  test "configured/0 accepts bounded-N source lists and refuses to degrade past the bound", %{roots: roots} do
    for count <- 2..@max_sources do
      sources = install_set(roots, count)
      assert {:ok, ^sources} = PixirMonitor.WorkspaceSet.configured()
      assert {:ok, :workspace_set} = PixirMonitor.WorkspaceSet.mode()
    end

    install_set(roots, @max_sources + 1)
    assert {:error, %{kind: "workspace_set_not_configured"}} = PixirMonitor.WorkspaceSet.configured()

    Application.put_env(:pixir_monitor, :workspace_set, [
      %{key: "lane1", path: roots[1]},
      %{key: "lane2", path: roots[2]},
      %{key: "lane1", path: roots[3]}
    ])

    assert {:error, %{kind: "workspace_set_not_configured"}} = PixirMonitor.WorkspaceSet.configured()

    Application.put_env(:pixir_monitor, :workspace_set, [
      %{key: "lane1", path: roots[1]},
      %{key: "lane2", path: roots[2]},
      %{key: "$bad", path: roots[3]}
    ])

    assert {:error, %{kind: "workspace_set_not_configured"}} = PixirMonitor.WorkspaceSet.configured()
  end

  test "the shell embeds every declared key in declaration order and validates against the schema", %{roots: roots} do
    install_set(roots, 5)
    {:ok, shell} = PixirMonitor.Bootstrap.shell()
    [encoded] = Regex.run(~r/data-workspace-set="([^"]+)"/, shell, capture: :all_but_first)

    config =
      encoded
      |> String.replace("&quot;", "\"")
      |> String.replace("&amp;", "&")
      |> Jason.decode!()

    assert config["workspaces"] == Enum.map(1..5, &lane_key/1)
    assert schema_valid?("shell_config", config)

    for path <- Enum.map(1..5, &roots[&1]), do: refute(shell =~ path)
  end

  test "the shell_config schema accepts 2..N and rejects 1, N+1, and duplicates" do
    keys = Enum.map(1..(@max_sources + 1), &lane_key/1)

    for count <- 2..@max_sources do
      assert schema_valid?("shell_config", %{
               "mode" => "workspace_set",
               "workspaces" => Enum.take(keys, count)
             })
    end

    refute schema_valid?("shell_config", %{"mode" => "workspace_set", "workspaces" => ["lane1"]})
    refute schema_valid?("shell_config", %{"mode" => "workspace_set", "workspaces" => keys})

    refute schema_valid?("shell_config", %{
             "mode" => "workspace_set",
             "workspaces" => ["lane1", "lane2", "lane1"]
           })
  end

  test "the SPA boot validator agrees with the schema at every cardinality" do
    js = File.read!("priv/static/app.js")

    assert js =~ "keys.length >= 2 && keys.length <= #{@max_sources}"
    refute js =~ "keys.length === 2"
    assert js =~ "new Set(keys).size === keys.length"
  end

  test "the Workspace Overview announcement derives its count from the declared set" do
    js = File.read!("priv/static/app.js")

    assert js =~
             ~S|"Workspace Overview updated. " + shellConfig.workspaces.length + " source sections remain in declaration order."|

    refute js =~ "Two source sections"
  end

  test "N sources serve their own scoped routes and isolate a single failure", %{roots: roots} do
    install_set(roots, 4)
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.WorkspaceSetCardinalityFailingSource)
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    responses =
      Map.new(1..4, fn index ->
        {index, request(:get, "/api/workspaces/#{lane_key(index)}/runs", headers)}
      end)

    assert responses[3].status == 503
    assert get_in(Jason.decode!(responses[3].resp_body), ["error", "details", "workspace"]) == "lane3"

    for index <- [1, 2, 4] do
      response = responses[index]
      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["workspace"] == lane_key(index)
      assert body["source"] == %{"sessions_directory" => "absent"}

      detail = request(:get, "/api/workspaces/#{lane_key(index)}/runs/same-session", headers)
      assert detail.status == 200
      assert Jason.decode!(detail.resp_body)["workspace"] == lane_key(index)
    end

    for {_index, response} <- responses,
        path <- Enum.map(1..4, &roots[&1]) do
      refute response.resp_body =~ path
      refute response.resp_body =~ "workspace_basename"
    end
  end

  test "one shared monotonic sequence names each declared source across N sources", %{roots: roots} do
    install_set(roots, 3)
    {:ok, _sequence} = PixirMonitor.InvalidationHub.subscribe()
    on_exit(fn -> PixirMonitor.InvalidationHub.unsubscribe() end)

    frames =
      Enum.map(1..3, fn index ->
        key = lane_key(index)
        :ok = PixirMonitor.InvalidationHub.projection_changed(key, "run-#{index}")
        assert_receive {:projection_changed, sequence, ^key, projection_id}
        PixirMonitor.InvalidationHub.ack()
        {:ok, _} = PixirMonitor.InvalidationHub.subscribe()
        {sequence, key, projection_id}
      end)

    sequences = Enum.map(frames, &elem(&1, 0))
    assert sequences == Enum.sort(sequences)
    assert length(Enum.uniq(sequences)) == 3
    assert Enum.map(frames, &elem(&1, 1)) == ["lane1", "lane2", "lane3"]

    for {sequence, key, projection_id} <- frames do
      data = frame_data(PixirMonitor.InvalidationHub.frame(sequence, key, projection_id))
      assert Map.keys(data) |> Enum.sort() == ["projection_id", "type", "workspace"]
      assert schema_valid?("invalidation_frame", data)
    end
  end

  test "operator-facing copy describes the bounded-N set instead of exactly two" do
    {output, {:ok, 0}} = run_io(fn -> PixirMonitor.CLI.run(["--help"]) end)

    refute output =~ "Exactly two"
    refute output =~ "exactly two"
    assert output =~ "#{@max_sources}"
    assert output =~ "--workspace KEY=PATH"

    js = File.read!("priv/static/app.js")
    refute js =~ "Two explicitly configured local sources."
    assert js =~ "Explicitly configured local sources, in declaration order."

    contract = File.read!("priv/presenter/workspace-set-v1.md")
    refute contract =~ "frozen at 2"
    refute contract =~ "a set size other than exactly 2"
    refute contract =~ "both addends are already in view"
    assert contract =~ "2..8"
  end

  defp run_io(fun) do
    parent = self()

    output =
      capture_io(fn ->
        send(parent, {:cli_result, fun.()})
      end)

    result =
      receive do
        {:cli_result, result} -> result
      after
        0 -> flunk("CLI did not return")
      end

    {output, result}
  end

  defp schema_valid?(definition, value) do
    schema = Jason.decode!(File.read!(@schema_path))

    required =
      case definition do
        "shell_config" -> ["shell_config", "workspace_key"]
        "invalidation_frame" -> ["invalidation_frame", "workspace_key"]
      end

    document = %{
      "$schema" => schema["$schema"],
      "$ref" => "#/$defs/#{definition}",
      "$defs" => Map.take(schema["$defs"], required)
    }

    match?({:ok, _}, JSV.validate(value, JSV.build!(document)))
  end

  defp frame_data(frame) do
    frame
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "data: "))
    |> String.replace_prefix("data: ", "")
    |> Jason.decode!()
  end

  defp session_cookie do
    {:ok, launch} = PixirMonitor.Vault.issue_launch()

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
