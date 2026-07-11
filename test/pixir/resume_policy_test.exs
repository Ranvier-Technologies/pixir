defmodule Pixir.ResumePolicyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pixir.{CLI, Conversation, Log, Session, SessionSupervisor, Subagents}
  alias Pixir.Permissions.WritePolicy

  defmodule ScriptedProvider do
    def stream(%{history: history}, opts) do
      results =
        history
        |> Enum.filter(&(&1.type == :tool_result))
        |> Map.new(&{&1.data["call_id"], &1.data})

      user_messages = Enum.count(history, &(&1.type == :user_message))

      cond do
        not Map.has_key?(results, "pre_inside") ->
          tool_call("pre_inside", "allowed.txt", "before interruption")

        user_messages == 1 ->
          send(Keyword.fetch!(opts, :test_pid), {:provider_blocked, opts[:session_id]})

          receive do
            :release_blocked_provider -> final("unexpected release")
          after
            60_000 -> final("unexpected timeout")
          end

        not Map.has_key?(results, "post_outside") ->
          tool_call("post_outside", "outside.txt", "must be denied after resume")

        not Map.has_key?(results, "post_inside") ->
          tool_call("post_inside", "allowed.txt", "after resume")

        true ->
          final("resume policy held")
      end
    end

    defp tool_call(call_id, path, content) do
      {:ok,
       %{
         text: "",
         reasoning: "",
         reasoning_items: [],
         function_calls: [
           %{call_id: call_id, name: "write", args: %{"path" => path, "content" => content}}
         ],
         finish_reason: :tool_calls
       }}
    end

    defp final(text) do
      {:ok, %{text: text, reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defmodule RootProvider do
    def stream(%{history: history}, _opts) do
      results =
        history
        |> Enum.filter(&(&1.type == :tool_result))
        |> Map.new(&{&1.data["call_id"], &1.data})

      if Map.has_key?(results, "root_write") do
        {:ok, %{text: "root done", reasoning: "", function_calls: [], finish_reason: :stop}}
      else
        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: [
             %{
               call_id: "root_write",
               name: "write",
               args: %{"path" => "root.txt", "content" => "root output"}
             }
           ],
           finish_reason: :tool_calls
         }}
      end
    end
  end

  defmodule FinalProvider do
    def stream(_ctx, _opts),
      do: {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
  end

  defmodule LegacyCeilingWriteProvider do
    # Advances on history: issue the ceiling-widening write once, then stop.
    # A stateless provider that re-issues the same denied write loops the turn
    # forever, because the CLI resume turn re-prompts the model after a policy
    # denial instead of terminating on it. Mirror the sibling ScriptedProvider's
    # history-driven advance.
    def stream(%{history: history}, _opts) do
      attempted? =
        Enum.any?(history, fn event ->
          event.type == :tool_result and event.data["call_id"] == "attested_ceiling_write"
        end)

      if attempted? do
        {:ok, %{text: "held", reasoning: "", function_calls: [], finish_reason: :stop}}
      else
        {:ok,
         %{
           text: "",
           reasoning: "",
           function_calls: [
             %{
               call_id: "attested_ceiling_write",
               name: "write",
               args: %{"path" => "attested-widen.txt", "content" => "must remain denied"}
             }
           ],
           finish_reason: :tool_calls
         }}
      end
    end
  end

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-resume-policy-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    {:ok, parent_sid, parent_pid} =
      SessionSupervisor.start_session(workspace: workspace, role: :build)

    on_exit(fn ->
      stop_session(parent_pid)
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace, parent_sid: parent_sid}
  end

  test "cold public resume restores a bounded-write child's narrow sandbox", %{
    workspace: workspace,
    parent_sid: parent_sid
  } do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "resume-narrow"},
        "allow_writes" => ["allowed.txt"],
        "deny_writes" => [],
        "bash" => "disabled"
      })

    {:ok, child} =
      Subagents.spawn_agent(
        parent_sid,
        %{"task" => "start bounded work", "workspace_mode" => "shared", "timeout_ms" => 60_000},
        workspace: workspace,
        provider: ScriptedProvider,
        provider_opts: [test_pid: self()],
        permission_mode: :auto,
        write_policy: policy
      )

    child_sid = child["child_session_id"]
    assert_receive {:provider_blocked, ^child_sid}, 5_000
    assert File.read!(Path.join(workspace, "allowed.txt")) == "before interruption"
    refute File.exists?(Path.join(workspace, "outside.txt"))

    assert :ok = Conversation.interrupt(child_sid)
    wait_until_turn_stops(child_sid)

    assert {:ok, before_history} = Log.fold(child_sid, workspace: workspace)

    assert %{data: posture} =
             Enum.find(before_history, fn event ->
               event.type == :subagent_event and
                 event.data["event"] == "permission_posture"
             end)

    assert posture["permission_mode"] == "auto"
    assert posture["workspace_mode"] == "shared"
    assert posture["write_policy"]["hash"] == policy["hash"]

    pre_decision = permission_decision(before_history, "pre_inside")
    assert pre_decision.data["decision"] == "allow"
    assert pre_decision.data["gate"] == "write_policy"
    assert decision_policy_hash(pre_decision) == policy["hash"]

    [{child_pid, _metadata}] = Registry.lookup(Pixir.Sessions.Registry, child_sid)
    stop_session(child_pid)
    # terminate_child returns before the Registry monitor fires, so deregistration
    # is async: poll instead of asserting instantly (the cold resume below must see
    # the session gone, but this race is pure test teardown timing).
    wait_until_deregistered(child_sid)

    previous_cli_opts = Application.get_env(:pixir, :cli_turn_opts, :unset)

    Application.put_env(:pixir, :cli_turn_opts,
      provider: ScriptedProvider,
      provider_opts: [test_pid: self()],
      skip_auth?: true
    )

    try do
      File.cd!(workspace, fn ->
        # A write-policy denial is deliberately terminal for its Turn. The first
        # cold resume proves the restored policy denies the outside path; a second
        # public resume proves the same restored policy still permits its allowlist.
        assert {:error, 3} =
                 CLI.route(["resume", child_sid, "attempt the outside write"], :auto)

        assert :ok = CLI.route(["resume", child_sid, "continue inside policy"], :auto)
      end)
    after
      restore_cli_opts(previous_cli_opts)
    end

    assert {:ok, resumed_history} = Log.fold(child_sid, workspace: workspace)
    post_decision = permission_decision(resumed_history, "post_outside")
    assert post_decision.data["decision"] == "deny"
    assert post_decision.data["gate"] == pre_decision.data["gate"]
    assert decision_policy_hash(post_decision) == decision_policy_hash(pre_decision)

    assert File.read!(Path.join(workspace, "allowed.txt")) == "after resume"
    refute File.exists?(Path.join(workspace, "outside.txt"))

    assert %{data: %{"ok" => true}} =
             Enum.find(resumed_history, fn event ->
               event.type == :tool_result and event.data["call_id"] == "post_inside"
             end)
  end

  test "root sessions with write history resume without posture ceremony", %{
    workspace: workspace,
    parent_sid: parent_sid
  } do
    previous_cli_opts = Application.get_env(:pixir, :cli_turn_opts, :unset)
    Application.put_env(:pixir, :cli_turn_opts, provider: RootProvider, skip_auth?: true)

    try do
      File.cd!(workspace, fn ->
        capture_io(:stderr, fn ->
          assert :ok = CLI.route(["write the root file"], :auto)
        end)

        assert File.read!(Path.join(workspace, "root.txt")) == "root output"

        [log_path] =
          Path.wildcard(Path.join([workspace, ".pixir", "sessions", "*.ndjson"]))
          |> Enum.reject(&String.contains?(&1, parent_sid))

        sid = Path.basename(log_path, ".ndjson")

        {:ok, history} = Log.fold(sid, workspace: workspace)

        posture =
          Enum.find(history, fn event ->
            event.type == :subagent_event and event.data["event"] == "permission_posture"
          end)

        assert posture.seq == 0
        assert posture.data["lineage"] == "root"
        assert posture.data["source"] == "root_session_start"
        assert posture.data["permission_mode"] == "auto"
        assert posture.data["write_policy"] == nil

        # THE regression this contract exists for: an operator root that already
        # wrote successfully must resume with no ceremony at all.
        capture_io(:stderr, fn ->
          assert :ok = CLI.route(["resume", sid, "continue"], :auto)
        end)
      end)
    after
      restore_cli_opts(previous_cli_opts)
    end
  end

  test "legacy pre-posture logs need the attested override and never unbounded auto", %{
    workspace: workspace
  } do
    legacy_sid = "legacy-root-#{System.unique_integer([:positive])}"
    Pixir.Paths.ensure_sessions_dir(workspace)

    entries = [
      %{"type" => "user_message", "data" => %{"text" => "old work"}},
      %{
        "type" => "tool_call",
        "data" => %{
          "call_id" => "w1",
          "name" => "write",
          "args" => %{"path" => "old.txt", "content" => "old"}
        }
      },
      %{
        "type" => "tool_result",
        "data" => %{"call_id" => "w1", "ok" => true, "output" => "written"}
      }
    ]

    body =
      entries
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {entry, seq} ->
        Jason.encode!(
          Map.merge(
            %{
              "id" => "legacy-ev-#{seq}",
              "session_id" => legacy_sid,
              "seq" => seq,
              "ts" => "2026-07-10T00:00:00Z"
            },
            entry
          )
        )
      end)

    File.write!(Log.path(legacy_sid, workspace: workspace), body <> "\n")

    previous_cli_opts = Application.get_env(:pixir, :cli_turn_opts, :unset)
    Application.put_env(:pixir, :cli_turn_opts, provider: FinalProvider, skip_auth?: true)

    try do
      File.cd!(workspace, fn ->
        # 1. Plain resume fails closed and the envelope teaches the override.
        out =
          capture_io(fn ->
            capture_io(:stderr, fn ->
              assert {:error, _code} = CLI.route(["--json", "resume", legacy_sid, "hello"], :auto)
            end)
          end)

        payload = Jason.decode!(out)
        assert payload["ok"] == false
        assert payload["error"]["kind"] == "resume_policy_unavailable"
        assert payload["error"]["details"]["reason"] == "missing"

        assert Enum.any?(
                 payload["error"]["details"]["next_actions"],
                 &String.contains?(&1, "assume-legacy-root")
               )

        # 2. The override cannot grant unbounded auto.
        out =
          capture_io(fn ->
            assert {:error, 2} =
                     CLI.route(
                       [
                         "--json",
                         "resume",
                         "--assume-legacy-root",
                         "--legacy-root-reason",
                         "my old root",
                         legacy_sid,
                         "hello"
                       ],
                       :auto
                     )
          end)

        payload = Jason.decode!(out)
        assert payload["error"]["kind"] == "invalid_args"

        assert payload["error"]["details"]["next_actions"] == [
                 "add_--read-only_or_--ask_or_an_explicit_bounded_--write-policy"
               ]

        # 3. The reason is mandatory, and whitespace is not a reason.
        out =
          capture_io(fn ->
            assert {:error, 2} =
                     CLI.route(
                       ["--json", "resume", "--assume-legacy-root", legacy_sid, "hello"],
                       :auto
                     )
          end)

        payload = Jason.decode!(out)
        assert payload["error"]["kind"] == "invalid_args"

        assert payload["error"]["details"]["next_actions"] == [
                 "add_--legacy-root-reason_with_why_this_log_is_yours"
               ]

        out =
          capture_io(fn ->
            assert {:error, 2} =
                     CLI.route(
                       [
                         "--json",
                         "resume",
                         "--assume-legacy-root",
                         "--legacy-root-reason",
                         "   ",
                         legacy_sid,
                         "hello"
                       ],
                       :read_only
                     )
          end)

        payload = Jason.decode!(out)
        assert payload["error"]["kind"] == "invalid_args"

        assert payload["error"]["details"]["usage"] ==
                 "pixir resume --assume-legacy-root --legacy-root-reason TEXT <id> \"prompt\""

        # 4. An explicit read_only attestation recovers the Log and persists
        #    the TRIMMED confession (surrounding whitespace never reaches the Log).
        capture_io(:stderr, fn ->
          assert :ok =
                   CLI.route(
                     [
                       "resume",
                       "--assume-legacy-root",
                       "--legacy-root-reason",
                       "  my old root  ",
                       legacy_sid,
                       "continue"
                     ],
                     :read_only
                   )
        end)

        {:ok, history} = Log.fold(legacy_sid, workspace: workspace)

        attested =
          Enum.find(history, fn event ->
            event.type == :subagent_event and
              event.data["event"] == "permission_posture" and
              event.data["source"] == "operator_attested_legacy_root"
          end)

        assert attested.data["lineage"] == "root"
        assert attested.data["permission_mode"] == "read_only"
        assert attested.data["attestation_reason"] == "my old root"
        assert attested.data["prior_classification"] == "missing"

        # 5. Subsequent resumes need no override and honor the attested ceiling
        #    during a real mutating tool attempt, not merely while parsing flags.
        Application.put_env(:pixir, :cli_turn_opts,
          provider: LegacyCeilingWriteProvider,
          skip_auth?: true
        )

        # The resume turn itself completes (the model adapts after the denied
        # tool call), but the attested read_only ceiling holds during the real
        # write attempt: the durable Log records the denial and no file lands.
        capture_io(fn ->
          assert :ok = CLI.route(["--json", "resume", legacy_sid, "try to widen"], :auto)
        end)

        refute File.exists?(Path.join(workspace, "attested-widen.txt"))

        # The attested ceiling is read_only, so the write is denied at the mode
        # gate (stronger than a write_policy allow-list check): a durable deny
        # decision for the attempt, and no file on disk.
        {:ok, after_history} = Log.fold(legacy_sid, workspace: workspace)
        decision = permission_decision(after_history, "attested_ceiling_write")
        assert decision.data["decision"] == "deny"
      end)
    after
      restore_cli_opts(previous_cli_opts)
    end
  end

  defp permission_decision(history, call_id) do
    Enum.find(history, fn event ->
      event.type == :permission_decision and event.data["call_id"] == call_id
    end) || flunk("missing permission_decision for #{call_id}")
  end

  defp decision_policy_hash(event) do
    event.data["policy_hash"] || get_in(event.data, ["policy", "hash"])
  end

  defp wait_until_turn_stops(session_id, attempts \\ 100)
  defp wait_until_turn_stops(_session_id, 0), do: flunk("turn did not stop")

  defp wait_until_turn_stops(session_id, attempts) do
    if Session.turn_running?(session_id) do
      Process.sleep(10)
      wait_until_turn_stops(session_id, attempts - 1)
    else
      :ok
    end
  end

  defp wait_until_deregistered(session_id, attempts \\ 200)
  defp wait_until_deregistered(_session_id, 0), do: flunk("session did not deregister")

  defp wait_until_deregistered(session_id, attempts) do
    case Registry.lookup(Pixir.Sessions.Registry, session_id) do
      [] ->
        :ok

      _still_registered ->
        Process.sleep(10)
        wait_until_deregistered(session_id, attempts - 1)
    end
  end

  defp stop_session(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp restore_cli_opts(:unset), do: Application.delete_env(:pixir, :cli_turn_opts)
  defp restore_cli_opts(opts), do: Application.put_env(:pixir, :cli_turn_opts, opts)
end
