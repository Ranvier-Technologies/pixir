defmodule PixirMonitor.SelfCheckTest.ObservedRouter do
  def init(owner), do: owner

  def call(conn, owner) do
    conn = PixirMonitor.Router.call(conn, [])
    send(owner, {:self_check_request, conn.method, conn.request_path, conn.status})
    conn
  end
end

defmodule PixirMonitor.SelfCheckTest.BadSchemaSource do
  def list_runs, do: {:ok, %{"schema" => "wrong.schema", "schema_version" => 1, "runs" => [], "inventory" => %{}}}
end

defmodule PixirMonitor.SelfCheckTest do
  @moduledoc """
  Monitor loopback integration test, matching the existing built-escript
  self-check tier. No external endpoint or Provider is contacted; the ephemeral
  listener is owned and terminated by the test supervisor.
  """
  use ExUnit.Case, async: false
  @moduletag :loopback

  setup do
    keys = [:active_port, :workspace_set, :run_source, :projection_input_provider, :projection_source]
    previous = Map.new(keys, &{&1, Application.fetch_env(:pixir_monitor, &1)})
    workspace = PixirMonitor.TestRun.tmp("pixir-self-check")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:pixir_monitor, key, value)
        {key, :error} -> Application.delete_env(:pixir_monitor, key)
      end)

      File.rm_rf!(workspace)
    end)

    Application.delete_env(:pixir_monitor, :workspace_set)
    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)
    Application.put_env(:pixir_monitor, :projection_input_provider, PixirMonitor.Projection.Source.Filesystem)
    Application.put_env(:pixir_monitor, :projection_source, workspace: workspace)
    listener = start_supervised!({Bandit, plug: {__MODULE__.ObservedRouter, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    assert {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    Application.put_env(:pixir_monitor, :active_port, port)
    :ok
  end

  test "SelfCheck reports the schemas it verified through a real loopback listener" do
    assert {:ok, report} = PixirMonitor.SelfCheck.run()

    assert report == %{
             ok: true,
             check: "pixir_monitor_loopback",
             listener: "127.0.0.1",
             bootstrap: "one_use_accepted",
             assets: ["app.js", "app.css"],
             runs_schema: "pixir.monitor.runs",
             runs_schema_version: 1
           }

    # A canned success map must not pass: the probe must really bootstrap,
    # reject reuse, read both embedded assets, and fetch the versioned envelope.
    assert_receive {:self_check_request, "POST", "/bootstrap", 200}
    assert_receive {:self_check_request, "POST", "/bootstrap", 401}
    assert_receive {:self_check_request, "GET", "/assets/app.js", 200}
    assert_receive {:self_check_request, "GET", "/assets/app.css", 200}
    assert_receive {:self_check_request, "GET", "/api/runs", 200}
  end

  test "SelfCheck rejects a wrong schema served with HTTP 200" do
    Application.put_env(:pixir_monitor, :run_source, __MODULE__.BadSchemaSource)
    assert {:error, %{kind: "runs_contract_mismatch"}} = PixirMonitor.SelfCheck.run()
    assert_receive {:self_check_request, "GET", "/api/runs", 200}
  end
end
