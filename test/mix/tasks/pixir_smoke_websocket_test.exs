defmodule Mix.Tasks.Pixir.Smoke.WebsocketTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.Websocket, as: SmokeTask

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-smoke-websocket-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    %{output_dir: output_dir}
  end

  test "--json --help is machine-readable and documents the network contract" do
    payload =
      capture_io(fn ->
        assert SmokeTask.run(["--json", "--help"]) == :ok
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.smoke.websocket"
    assert payload["network"] == true
    assert payload["default_model"] == "gpt-5.5"
    assert payload["default_reasoning_effort"] == "low"
    assert "same_socket_continuation" in payload["checks"]
    assert "reconnect_store_false_cache_miss" in payload["checks"]
    assert "cache_routing_candidate_hit" in payload["checks"]
    assert "does_not_open_websocket" in payload["dry_run_guarantees"]
  end

  test "--dry-run --json validates planned checks without auth, network, or writes", %{
    output_dir: output_dir
  } do
    payload =
      capture_io(fn ->
        assert SmokeTask.run(["--dry-run", "--json", "--output", output_dir]) == :ok
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["network"] == false
    assert payload["model"] == "gpt-5.5"
    assert payload["reasoning_effort"] == "low"
    assert payload["estimated_response_create_calls"] == 5
    assert payload["probe_cache_routing"] == false
    assert is_nil(payload["cache_key"])
    assert Path.join(output_dir, "evidence.json") in payload["would_write"]
    refute File.exists?(output_dir)
  end

  test "--probe-cache-routing dry-run documents cache-eligible WebSocket probe", %{
    output_dir: output_dir
  } do
    payload =
      capture_io(fn ->
        assert SmokeTask.run([
                 "--probe-cache-routing",
                 "--dry-run",
                 "--json",
                 "--output",
                 output_dir
               ]) == :ok
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["network"] == false
    assert payload["estimated_response_create_calls"] == 7
    assert payload["probe_cache_routing"] == true
    assert is_binary(payload["cache_key"])
    assert payload["prompt_cache_min_input_tokens"] == 1024
    assert "cache_routing_candidate_hit" in payload["checks"]
    refute File.exists?(output_dir)
  end

  test "invalid reasoning effort returns a structured actionable error" do
    payload =
      capture_io(:stderr, fn ->
        assert catch_exit(SmokeTask.run(["--reasoning-effort", "tiny", "--json"])) ==
                 {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_reasoning_effort"
    assert payload["error"]["details"]["value"] == "tiny"
    assert Enum.any?(payload["next_steps"], &String.contains?(&1, "--reasoning-effort low"))
  end

  test "invalid timeout returns a structured actionable error" do
    payload =
      capture_io(:stderr, fn ->
        assert catch_exit(SmokeTask.run(["--timeout-ms", "0", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_positive_integer"
    assert payload["error"]["details"]["option"] == "timeout_ms"
    assert Enum.any?(payload["next_steps"], &String.contains?(&1, "--timeout-ms"))
  end
end
