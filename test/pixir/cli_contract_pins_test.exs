defmodule Pixir.CLIContractPinsTest do
  @moduledoc """
  This suite is the enforcement of `docs/cli-contract.md`; removing or renaming a
  declared field must fail here first.

  Layer confessions: the field-level tree and Provider-usage pins exercise the
  public, no-network projection builders (`Pixir.SessionTree.project/2` and
  `Pixir.SessionDiagnostics.run/2`); the CLI JSON wraps of both surfaces are pinned
  separately through `CLI.route/1` in the success-turn test. The Delegate
  pin exercises the real `Pixir.Delegate.CLIContract.run/2` envelope builder with a
  deterministic injected runner payload; it does not start Provider-backed children.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pixir.{CLI, Event, Fork, Log, SessionDiagnostics, SessionTree}
  alias Pixir.Delegate.CLIContract

  defmodule ScriptedProvider do
    def stream(_request, opts) do
      agent = Keyword.fetch!(opts, :agent)
      result = Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)

      result =
        case result do
          {:sleep, milliseconds, nested} ->
            Process.sleep(milliseconds)
            nested

          other ->
            other
        end

      {result, deliver_deltas?} =
        case result do
          {:no_delta, nested} -> {nested, false}
          other -> {other, true}
        end

      case result do
        {:ok, %{text: text}} when deliver_deltas? and is_binary(text) and text != "" ->
          Keyword.get(opts, :on_delta, fn _delta -> :ok end).({:text_delta, text})

        _other ->
          :ok
      end

      result
    end
  end

  defmodule DelegatePinRunner do
    def run(_request, _spec, _spec_meta, _opts) do
      {:ok,
       %{
         "ok" => false,
         "status" => "partial",
         "kind" => "delegate_result",
         "summary" => "deterministic contract pin",
         "children" => [
           %{
             "index" => 0,
             "status" => "timed_out",
             "child_session_id" => "contract-child-0",
             "child_log_path" => "/tmp/contract-child-0.ndjson",
             "summary" => "child timed out",
             "resume_command" => "pixir resume contract-child-0 \"continue safely\""
           }
         ]
       }}
    end
  end

  test "one-shot and resume success envelopes pin their declared fields" do
    in_tmp_workspace("pixir-cli-contract-turn", fn _workspace ->
      with_cli_provider([stop("first answer"), stop("resumed answer")], fn ->
        first =
          capture_io(fn ->
            assert :ok = CLI.route(["--json", "first prompt"])
          end)
          |> decode_json!()

        assert_success_turn(first, "first answer")

        resumed =
          capture_io(fn ->
            assert :ok =
                     CLI.route([
                       "--json",
                       "resume",
                       first["session_id"],
                       "second prompt"
                     ])
          end)
          |> decode_json!()

        assert_success_turn(resumed, "resumed answer")
        assert resumed["session_id"] == first["session_id"]
        refute Map.has_key?(first, "exit_code")
        refute Map.has_key?(resumed, "exit_code")

        # MAJOR-2 class: the CLI wrap of tree/diagnose is the promised surface,
        # not just the builders underneath.
        tree_wrap =
          capture_io(fn -> assert :ok = CLI.route(["tree", first["session_id"], "--json"]) end)
          |> decode_json!()

        assert tree_wrap["ok"] == true
        assert_field(tree_wrap, "tree", &is_map/1)

        {:ok, built} = Pixir.SessionDiagnostics.run(first["session_id"], workspace: File.cwd!())

        diagnose_wrap =
          capture_io(fn ->
            assert :ok = CLI.route(["diagnose", "session", first["session_id"], "--json"])
          end)
          |> decode_json!()

        assert Map.keys(diagnose_wrap) |> Enum.sort() ==
                 built |> Jason.encode!() |> Jason.decode!() |> Map.keys() |> Enum.sort()
      end)
    end)
  end

  test "an undelivered-delta final keeps --json stdout envelope-only" do
    in_tmp_workspace("pixir-cli-contract-silent", fn _workspace ->
      with_cli_provider([stop("seed answer"), stop_silent("silent final")], fn ->
        first =
          capture_io(fn -> assert :ok = CLI.route(["--json", "seed prompt"]) end)
          |> decode_json!()

        raw =
          capture_io(fn ->
            assert :ok = CLI.route(["--json", "resume", first["session_id"], "quiet prompt"])
          end)

        # The whole capture must be one machine envelope: no flushed answer text
        # may precede it when the transport delivered the answer only as the final.
        resumed = Jason.decode!(String.trim(raw))
        assert resumed["ok"] == true
        assert resumed["output"] == "silent final"
      end)
    end)
  end

  test "a missing resume id still answers --json with a structured envelope" do
    in_tmp_workspace("pixir-cli-contract-missing-id", fn _workspace ->
      raw =
        capture_io(fn ->
          assert {:error, 1} = CLI.route(["--json", "resume", "20990101T000000-000000", "x"])
        end)

      # The promise under pin is the channel, not one specific kind: a pre-session
      # --json failure answers with a structured envelope on stdout, never a bare
      # human line (the missing-id path fails in posture restoration before
      # start_session, with its own kind and exit code).
      envelope = Jason.decode!(String.trim(raw))
      assert envelope["ok"] == false
      structured = assert_field(envelope, "error", &is_map/1)
      assert structured["kind"] == "resume_policy_unavailable"
      assert_field(structured, "message", &is_binary/1)
    end)
  end

  test "incomplete and pre-session error envelopes pin their declared fields" do
    in_tmp_workspace("pixir-cli-contract-incomplete", fn _workspace ->
      with_cli_provider([stop("")], fn ->
        payload =
          capture_io(fn ->
            assert {:error, 6} = CLI.route(["--json", "no final answer"])
          end)
          |> decode_json!()

        assert_field(payload, "ok", &is_boolean/1)
        assert payload["ok"] == false
        assert_field(payload, "status", &is_binary/1)
        assert payload["status"] == "incomplete"
        assert_field(payload, "kind", &is_binary/1)
        assert_field(payload, "session_id", &is_binary/1)
        assert_field(payload, "resume_command", &is_binary/1)
        diagnostics = assert_field(payload, "diagnostics", &is_map/1)
        assert_field(diagnostics, "diagnose_command", &is_binary/1)
        assert_field(payload, "message", &is_binary/1)
        assert_field(payload, "output_truncation", &(is_map(&1) or is_nil(&1)))
        assert_field(payload, "warning_count", &is_integer/1)
        assert_field(payload, "warnings_truncated", &is_boolean/1)
        assert_field(payload, "warnings", &is_list/1)
      end)
    end)

    error =
      capture_io(fn ->
        assert {:error, 2} = CLI.route(["--json", "--write-policy"])
      end)
      |> decode_json!()

    assert_field(error, "ok", &is_boolean/1)
    assert error["ok"] == false
    structured = assert_field(error, "error", &is_map/1)
    assert_field(structured, "kind", &is_binary/1)
    assert structured["kind"] == "invalid_args"
    assert_field(structured, "message", &is_binary/1)
    assert_field(structured, "details", &is_map/1)
  end

  test "timeout envelope pins fail-closed recovery fields" do
    in_tmp_workspace("pixir-cli-contract-timeout", fn _workspace ->
      with_cli_provider(
        [{:sleep, 100, stop("too late")}],
        fn ->
          payload =
            capture_io(fn ->
              assert {:error, 124} = CLI.route(["--json", "timeout prompt"])
            end)
            |> decode_json!()

          assert_field(payload, "ok", &is_boolean/1)
          assert payload["ok"] == false
          assert_field(payload, "status", &is_binary/1)
          assert payload["status"] == "timed_out"
          assert_field(payload, "kind", &is_binary/1)
          assert_field(payload, "session_id", &is_binary/1)
          assert_field(payload, "resume_command", &is_binary/1)
          assert_field(payload, "exit_code", &is_integer/1)
          assert payload["exit_code"] == 124

          recovery = assert_field(payload, "recovery", &is_map/1)
          assert_field(recovery, "classification", &is_binary/1)
          assert_field(recovery, "diagnose_command", &is_binary/1)
          assert_field(recovery, "resume_command", &is_binary/1)
          auto_retry = assert_field(recovery, "auto_retry", &is_map/1)
          assert_field(auto_retry, "safe", &is_boolean/1)
          assert auto_retry["safe"] == false
          assert_field(auto_retry, "reason", &is_binary/1)

          next_actions = assert_field(recovery, "next_actions", &is_list/1)
          assert next_actions != []
          assert Enum.all?(next_actions, &is_binary/1)

          # The warning family is promised only on clean endings; the timeout
          # envelope must omit it rather than fabricate zeros.
          refute Map.has_key?(payload, "warning_count")
          refute Map.has_key?(payload, "warnings_truncated")
          refute Map.has_key?(payload, "warnings")
        end,
        idle_timeout: 10
      )
    end)
  end

  test "Session tree projection pins root, subagent, fork, and nested Session fields" do
    in_tmp_workspace("pixir-cli-contract-tree", fn workspace ->
      parent = "contract-tree-parent"
      subagent_child = "contract-tree-subagent"
      fork_child = "contract-tree-fork"

      append!(workspace, Event.user_message(parent, "root", seq: 0))

      append!(
        workspace,
        Event.subagent_event(
          parent,
          %{
            "subagent_id" => "sub_contract",
            "child_session_id" => subagent_child,
            "event" => "finished",
            "status" => "completed",
            "workspace" => workspace
          },
          seq: 1
        )
      )

      append!(workspace, Event.user_message(subagent_child, "child", seq: 0))
      append!(workspace, Event.assistant_message(subagent_child, "done", seq: 1))

      assert {:ok, _fork} =
               Fork.fork(parent,
                 workspace: workspace,
                 child_session_id: fork_child,
                 to_seq: 1
               )

      assert {:ok, tree} = SessionTree.project(parent, workspace: workspace)

      assert_tree_node(tree)
      assert tree["session_id"] == parent

      assert [subagent] = tree["subagents"]
      assert_field(subagent, "subagent_id", &is_binary/1)
      assert_field(subagent, "events", &is_list/1)
      assert_field(subagent, "first_seq", &is_integer/1)
      assert_field(subagent, "last_seq", &is_integer/1)
      assert_field(subagent, "child_session_id", &is_binary/1)
      assert_field(subagent, "status", &is_binary/1)
      subagent_session = assert_field(subagent, "session", &is_map/1)
      assert_tree_node(subagent_session)

      assert [fork] = tree["forks"]
      assert_field(fork, "child_session_id", &is_binary/1)
      assert_field(fork, "parent_session_id", &is_binary/1)
      assert_field(fork, "fork_root_session_id", &is_binary/1)
      assert_field(fork, "forked_to_seq", &is_integer/1)
      assert_field(fork, "replay_event_count", &is_integer/1)
      assert_field(fork, "from_seq", &is_integer/1)
      assert_field(fork, "strategy", &is_binary/1)
      assert_field(fork, "workspace", &is_binary/1)
      assert_field(fork, "branch_summary", &is_map/1)
      fork_session = assert_field(fork, "session", &is_map/1)
      assert_tree_node(fork_session)
    end)
  end

  test "session diagnosis pins durable Provider-usage fields" do
    in_tmp_workspace("pixir-cli-contract-usage", fn workspace ->
      session_id = "contract-provider-usage"
      usage_id = "evt_contract_usage"

      append!(workspace, Event.user_message(session_id, "measure", seq: 0))

      append!(
        workspace,
        Event.provider_usage(
          session_id,
          %{
            "model" => "gpt-contract",
            "active_transport" => "websocket",
            "continuation_attempted" => true,
            "continuation_reset_reason" => nil,
            "used_previous_response_id" => false,
            "usage_summary" => %{"total_tokens" => 7},
            "output_truncation" => %{
              "status" => "not_truncated",
              "provider_reason" => "response.completed",
              "provider_usage_event_id" => usage_id,
              "call_role" => "final_answer"
            }
          },
          id: usage_id,
          seq: 1
        )
      )

      append!(workspace, Event.assistant_message(session_id, "measured", seq: 2))

      assert {:ok, diagnosis} = SessionDiagnostics.run(session_id, workspace: workspace)
      usage = assert_field(diagnosis, "provider_usage", &is_map/1)
      assert_field(usage, "count", &is_integer/1)
      latest = assert_field(usage, "latest", &is_map/1)
      assert_field(latest, "seq", &is_integer/1)
      assert_field(latest, "model", &is_binary/1)
      assert_field(latest, "active_transport", &is_binary/1)
      assert_field(latest, "continuation_attempted", &is_boolean/1)

      assert_field(
        latest,
        "continuation_reset_reason",
        &(is_binary(&1) or is_nil(&1))
      )

      assert_field(latest, "used_previous_response_id", &is_boolean/1)
      assert_field(latest, "usage_summary", &is_map/1)

      truncation = assert_field(usage, "output_truncation", &is_map/1)
      counts = assert_field(truncation, "counts", &is_map/1)
      assert_field(counts, "not_truncated", &is_integer/1)
      assert_field(counts, "truncated", &is_integer/1)
      assert_field(counts, "unknown", &is_integer/1)
      assert_field(truncation, "latest", &is_map/1)
      assert_field(truncation, "positive_count", &is_integer/1)
      assert_field(truncation, "positive_refs", &is_list/1)
      assert_field(truncation, "positive_refs_truncated", &is_boolean/1)
    end)
  end

  test "Delegate v1 builder pins common envelope and child recovery fields" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "task" => "bounded deterministic contract pin"
      })

    assert {:ok, %{payload: payload, exit_code: 6}} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: DelegatePinRunner
             )

    assert_field(payload, "ok", &is_boolean/1)
    assert_field(payload, "status", &is_binary/1)
    assert_field(payload, "work_complete", &is_boolean/1)
    children = assert_field(payload, "children", &is_list/1)
    assert [child] = children
    assert_field(child, "index", &is_integer/1)
    assert_field(child, "status", &is_binary/1)
    assert_field(child, "reason_code", &is_binary/1)
    assert_field(child, "child_session_id", &is_binary/1)
    assert_field(child, "child_log_path", &is_binary/1)
    assert_field(child, "summary", &is_binary/1)

    if Map.has_key?(child, "retry_history") do
      assert_field(child, "retry_history", &is_list/1)
    end

    assert_field(child, "resume_command", &is_binary/1)
  end

  defp assert_success_turn(payload, output) do
    assert_field(payload, "ok", &is_boolean/1)
    assert payload["ok"] == true
    assert_field(payload, "status", &is_binary/1)
    assert payload["status"] == "completed"
    assert_field(payload, "kind", &is_binary/1)
    assert payload["kind"] == "one_shot_turn"
    assert_field(payload, "session_id", &is_binary/1)
    assert_field(payload, "resume_command", &is_binary/1)
    diagnostics = assert_field(payload, "diagnostics", &is_map/1)
    assert_field(diagnostics, "diagnose_command", &is_binary/1)
    assert_field(payload, "output", &is_binary/1)
    assert payload["output"] == output
    assert_field(payload, "output_truncation", &(is_map(&1) or is_nil(&1)))
    assert_field(payload, "warning_count", &is_integer/1)
    assert_field(payload, "warnings_truncated", &is_boolean/1)
    assert_field(payload, "warnings", &is_list/1)
  end

  defp assert_tree_node(node) do
    assert_field(node, "session_id", &is_binary/1)
    assert_field(node, "workspace", &is_binary/1)
    assert_field(node, "log_path", &is_binary/1)
    assert_field(node, "log_exists", &is_boolean/1)
    assert_field(node, "event_count", &is_integer/1)
    assert_field(node, "event_counts", &is_map/1)
    assert_field(node, "first_event_ts", &(is_binary(&1) or is_nil(&1)))
    assert_field(node, "last_event_ts", &(is_binary(&1) or is_nil(&1)))
    assert_field(node, "subagents", &is_list/1)
    assert_field(node, "forks", &is_list/1)
  end

  defp assert_field(map, key, type_predicate) when is_map(map) do
    assert {:ok, value} = Map.fetch(map, key), "missing declared CLI contract field #{key}"
    assert type_predicate.(value), "wrong type for declared CLI contract field #{key}"
    value
  end

  defp stop(text) do
    {:ok, %{text: text, reasoning: "", function_calls: [], finish_reason: :stop}}
  end

  # The transport-delivered-only-final production path: a final answer that never
  # arrived as deltas, which is exactly what the channel-discipline flush exists for.
  defp stop_silent(text), do: {:no_delta, stop(text)}

  defp with_cli_provider(script, fun, extra_opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    previous = Application.get_env(:pixir, :cli_turn_opts, :unset)

    Application.put_env(
      :pixir,
      :cli_turn_opts,
      Keyword.merge(
        [provider: ScriptedProvider, provider_opts: [agent: agent], skip_auth?: true],
        extra_opts
      )
    )

    try do
      fun.()
    after
      _ = Pixir.SessionSupervisor.stop_all_sessions()

      if Process.alive?(agent) do
        Agent.stop(agent)
      end

      if previous == :unset do
        Application.delete_env(:pixir, :cli_turn_opts)
      else
        Application.put_env(:pixir, :cli_turn_opts, previous)
      end
    end
  end

  defp in_tmp_workspace(prefix, fun) do
    workspace =
      Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    File.cd!(workspace, fn -> fun.(workspace) end)
  end

  defp append!(workspace, event) do
    assert {:ok, _event} = Log.append(event, workspace: workspace)
  end

  defp decode_json!(output) do
    output
    |> String.trim()
    |> Jason.decode!()
  end
end
