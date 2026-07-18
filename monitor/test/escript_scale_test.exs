unless Code.ensure_loaded?(PixirMonitor.InventoryFixture) do
  Code.require_file("support/inventory_fixture.ex", __DIR__)
end

defmodule PixirMonitor.EscriptScaleTest do
  use ExUnit.Case, async: false

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/scale_browser_harness.mjs")
  @node System.find_executable("node")
  @node_websocket if(is_binary(@node),
                    do: elem(System.cmd(@node, ["-p", "typeof WebSocket"]), 0) == "function\n",
                    else: false
                  )
  @browser Enum.find(
             [
               System.get_env("PIXIR_MONITOR_BROWSER_BIN"),
               System.find_executable("google-chrome"),
               System.find_executable("chromium"),
               System.find_executable("chromium-browser"),
               "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
               "/Applications/Chromium.app/Contents/MacOS/Chromium",
               "/Applications/Helium.app/Contents/MacOS/Helium"
             ],
             &(is_binary(&1) and File.exists?(&1))
           )
  # A missing browser toolchain soft-skips LOCALLY but must fail LOUDLY in CI:
  # since #401 the browser suites are CI-mandatory, and a lost setup step must
  # never demote them back to silent skip-green (the #397 bar; same idiom as
  # the presenter UI seam tier). The CI toolchain assert lives in setup.
  @browser_skip (cond do
                   is_binary(@node) and @node_websocket and is_binary(@browser) -> false
                   System.get_env("CI") in ["true", "1"] -> false
                   true -> "requires Node.js WebSocket support and a Chrome-compatible browser"
                 end)

  setup do
    if System.get_env("CI") in ["true", "1"] do
      toolchain = [node: is_binary(@node), websocket: @node_websocket, browser: is_binary(@browser)]

      assert Enum.all?(Keyword.values(toolchain)),
             "the CI runner lost part of its browser toolchain #{inspect(toolchain)}: " <>
               "browser suites must not silently skip in CI"
    end

    :ok
  end

  setup_all do
    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: @project_root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix escript.build failed: #{output}"
    assert File.exists?(@escript)
    :ok
  end

  @tag skip: @browser_skip
  @tag timeout: 240_000
  test "triage surfaces pin inventory, pagination, and exclusive 32 KiB boundaries" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-escript-scale-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    expansion_prefix =
      "\e<script data-pixir-scale-hostile>window.__pixirScaleInjected=true</script>"

    at_cap_agent = String.duplicate("A", 32_768)
    over_cap_agent = String.duplicate("B", 32_769)

    expansion_cap_agent =
      expansion_prefix <> String.duplicate("Z", 32_768 - byte_size(expansion_prefix))

    assert byte_size(at_cap_agent) == 32_768
    assert byte_size(over_cap_agent) == 32_769
    assert byte_size(expansion_cap_agent) == 32_768

    cap_steps = [
      cap_step("pure-at-cap", at_cap_agent),
      cap_step("pure-over-cap", over_cap_agent),
      cap_step("control-expansion-at-cap", expansion_cap_agent)
    ]

    input_builder = fn ordinal ->
      if ordinal == 256 do
        PixirMonitor.InventoryFixture.input(ordinal, steps: cap_steps)
      else
        PixirMonitor.InventoryFixture.input(ordinal)
      end
    end

    started_at = System.monotonic_time(:millisecond)

    ids =
      PixirMonitor.InventoryFixture.materialize_many!(workspace, 0..512, input_builder: input_builder)

    cap_run_id = Enum.at(ids, 256)
    cap_log = Path.join([workspace, ".pixir", "sessions", cap_run_id <> ".ndjson"])
    File.touch!(cap_log)

    materialization_ms = System.monotonic_time(:millisecond) - started_at

    {output, status} =
      System.cmd(
        @node,
        [
          @harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--browser",
          @browser,
          "--profile-base",
          System.tmp_dir!(),
          "--cap-run-id",
          cap_run_id,
          "--at-cap-unit-id",
          "workflow:inventory-scope:step:pure-at-cap",
          "--over-cap-unit-id",
          "workflow:inventory-scope:step:pure-over-cap",
          "--expansion-cap-unit-id",
          "workflow:inventory-scope:step:control-expansion-at-cap",
          "--browser-timeout-ms",
          "60000",
          "--json"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "scale browser harness failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_scale"

    assert result["phases"] == [
             "every_continuation_exact_through_final_12",
             "all_512_rows_and_no_continuation_remaining",
             "inventory_512_of_513_confessed",
             "pure_32768_full_without_confession",
             "pure_32769_confessed",
             "control_expansion_honesty_at_raw_cap"
           ]

    assert result["launch_fragment_cleared"] == true
    assert result["handoff_cleaned"] == true

    assert result["cleanup"] == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }

    IO.puts(
      Jason.encode!(%{
        "scale_probe" => "triage_f1",
        "logs_materialized" => 513,
        "materialization_ms" => materialization_ms
      })
    )
  end

  defp cap_step(id, agent) do
    %{
      "id" => id,
      "agent" => agent,
      "execution_kind" => "subagent",
      "workspace_mode" => "isolated",
      "posture" => "read_only",
      "depends_on" => []
    }
  end
end
