defmodule Pixir.Delegate.ConfigAdmissionTest do
  use ExUnit.Case, async: false

  alias Pixir.Delegate.CLIContract

  defmodule Runner do
    def run(_, _, _, opts) do
      send(Keyword.fetch!(opts, :test_pid), :runner_called)
      {:ok, %{"ok" => true, "status" => "completed", "children" => []}}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-config-admission-" <> Base.encode16(:crypto.strong_rand_bytes(6))
      )

    File.mkdir_p!(ws)
    prior_home = System.get_env("PIXIR_HOME")
    prior_effort = Application.fetch_env(:pixir, :reasoning_effort)
    System.put_env("PIXIR_HOME", ws)
    Application.delete_env(:pixir, :reasoning_effort)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("PIXIR_HOME", prior_home),
        else: System.delete_env("PIXIR_HOME")

      case prior_effort do
        {:ok, value} -> Application.put_env(:pixir, :reasoning_effort, value)
        :error -> Application.delete_env(:pixir, :reasoning_effort)
      end

      File.rm_rf!(ws)
    end)

    %{ws: ws}
  end

  test "unresolvable caller configuration rejects before dispatch without consulting ambient effort",
       %{ws: ws} do
    raw = %{"reasoning" => %{"effort" => "max"}, "responses_backend" => %{"mode" => "invalid"}}
    config_path = Path.join(ws, "caller.json")
    File.write!(config_path, Jason.encode!(raw))

    for ambient <- [%{}, %{"reasoning" => %{"effort" => "max"}}],
        source <- [[raw_config: raw], [config_path: config_path]],
        flags <- [["--dry-run"], []] do
      File.write!(Path.join(ws, "config.json"), Jason.encode!(ambient))
      assert {:error, rendered} = run(ws, source, flags)
      assert rendered.payload["kind"] == "invalid_spec"
      assert rendered.payload["details"]["reason"] == "provider_configuration_unresolved"
      refute_received :runner_called
    end

    assert Path.wildcard(Path.join([ws, ".pixir", "sessions", "*.ndjson"])) == []
  end

  test "a changing loader is invoked only once even when resolution fails", %{ws: ws} do
    calls = :counters.new(1, [])

    loader = fn _ ->
      :counters.add(calls, 1, 1)

      raw =
        if :counters.get(calls, 1) == 1,
          do: %{
            "reasoning" => %{"effort" => "max"},
            "responses_backend" => %{"mode" => "invalid"}
          },
          else: %{}

      {:ok, %{present?: true, origin: :programmatic, document: raw}}
    end

    assert {:error, rendered} = run(ws, [request_snapshot_loader: loader], [])
    assert rendered.payload["details"]["reason"] == "provider_configuration_unresolved"
    assert :counters.get(calls, 1) == 1
    refute_received :runner_called
  end

  test "unavailable source is rejected without exposing loader failures", %{ws: ws} do
    sentinel = "private-config-source"
    assert {:error, rendered} = run(ws, [request_snapshot_loader: fn _ -> raise sentinel end], [])
    assert rendered.payload["details"]["reason"] == "provider_configuration_unresolved"
    refute Jason.encode!(rendered.payload) =~ sentinel
    refute_received :runner_called
  end

  test "valid source keeps explicit effort precedence and one snapshot read", %{ws: ws} do
    calls = :counters.new(1, [])

    loader = fn _ ->
      :counters.add(calls, 1, 1)

      {:ok,
       %{present?: true, origin: :programmatic, document: %{"reasoning" => %{"effort" => "max"}}}}
    end

    assert {:ok, rendered} =
             run(
               ws,
               [reasoning_effort: "high", request_snapshot_loader: loader],
               ["--dry-run"],
               "gpt-5.5"
             )

    assert rendered.payload["command_ok"]
    assert :counters.get(calls, 1) == 1
    assert {:ok, _} = run(ws, [raw_config: %{"reasoning" => %{"effort" => "max"}}], ["--dry-run"])
    refute_received :runner_called
  end

  defp run(ws, provider_opts, flags, model \\ "gpt-6-astra") do
    spec = %{
      "strategy" => "subagents",
      "mode" => "read_only",
      "task" => "inspect",
      "subagents" => %{"model" => model}
    }

    CLIContract.run(["--spec", "-", "--json"] ++ flags,
      workspace: ws,
      read_stdin: fn -> Jason.encode!(spec) end,
      runner: Runner,
      runtime_opts: [provider_opts: provider_opts, test_pid: self()]
    )
  end
end
