defmodule Pixir.Permissions.WriteDenialsTest do
  use ExUnit.Case, async: true

  alias Pixir.Permissions.WriteDenials

  defp deny(seq, opts \\ []) do
    %{
      type: :permission_decision,
      seq: seq,
      data:
        %{
          "decision" => "deny",
          "gate" => "write_policy",
          "tool" => Keyword.get(opts, :tool, "write"),
          "normalized_path" => "p#{seq}",
          "matched_rule" => "no_allow_match",
          "policy_id" => "test",
          "policy_hash" => "sha256:abc",
          "policy_version" => 1,
          "call_id" => "c#{seq}"
        }
        |> Map.merge(Keyword.get(opts, :extra, %{}))
    }
  end

  defp turn_failed(seq, kind \\ "write_policy_denied"),
    do: %{type: :turn_failed, seq: seq, data: %{"error_kind" => kind}}

  defp message(seq), do: %{type: :assistant_message, seq: seq, data: %{"text" => "ok"}}

  # The event every production Turn opens with. Its absence from a fixture is
  # what let a later Turn's terminal event launder an earlier Turn's denial.
  defp user_message(seq), do: %{type: :user_message, seq: seq, data: %{"text" => "go"}}

  test "an empty history confesses zero denials rather than nothing" do
    assert WriteDenials.from_history([]) == %{"count" => 0, "denials" => []}
    assert WriteDenials.empty() == %{"count" => 0, "denials" => []}
  end

  test "a surviving denial reads as recovered" do
    assert %{"count" => 1, "denials" => [denial]} =
             WriteDenials.from_history([deny(1), message(2)])

    assert denial["disposition"] == "recovered"
    assert denial["tool"] == "write"
    assert denial["normalized_path"] == "p1"
    assert denial["matched_rule"] == "no_allow_match"
    assert denial["policy_id"] == "test"
    assert denial["policy_hash"] == "sha256:abc"
    assert denial["policy_version"] == 1
  end

  test "only the denial the Turn died on reads as fatal" do
    history = [deny(1), message(2), deny(3), deny(4), turn_failed(5)]

    assert %{"count" => 3, "denials" => denials} = WriteDenials.from_history(history)

    assert Enum.map(denials, & &1["disposition"]) == ["recovered", "recovered", "fatal"]
  end

  test "a turn_failed from another cause never marks a denial fatal" do
    history = [deny(1), turn_failed(2, "provider_error")]

    assert %{"denials" => [%{"disposition" => "recovered"}]} =
             WriteDenials.from_history(history)
  end

  test "interactive permission denials are not bounded-write denials" do
    history = [%{type: :permission_decision, seq: 1, data: %{"decision" => "deny"}}]

    assert WriteDenials.from_history(history) == %{"count" => 0, "denials" => []}
  end

  test "allow decisions on the write_policy gate are not denials" do
    history = [
      %{
        type: :permission_decision,
        seq: 1,
        data: %{"decision" => "allow", "gate" => "write_policy"}
      }
    ]

    assert WriteDenials.from_history(history) == %{"count" => 0, "denials" => []}
  end

  # The Executor stamps `requested_command` (never `command`) on bash denials —
  # see `Pixir.Tools.Executor.policy_decision_details/1`. This event is the real
  # production shape, not a fabricated one: a confession that dropped the command
  # would report a denial with nothing to reconcile.
  test "a denied command is reported when there is no path" do
    history = [
      deny(1,
        tool: "bash",
        extra: %{
          "normalized_path" => nil,
          "requested_command" => "cat /etc/passwd",
          "token" => "/etc/passwd",
          "matched_rule" => "outside_workspace",
          "rule" => "outside_workspace"
        }
      )
    ]

    assert %{"denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["normalized_path"] == "cat /etc/passwd"
    assert denial["matched_rule"] == "outside_workspace"
  end

  # A write that reaches outside the workspace is confined *before* the path can
  # be normalized: `WritePolicy.confine_policy_path/2` stamps `requested_path`
  # with a `normalized_path` of nil, and the Executor forwards both. This is the
  # production shape of a `path_outside_workspace` denial — no `command` key
  # exists on it — so a confession that only fell back to `requested_command`
  # would report the probe with no target at all.
  test "an outside-workspace write is confessed with the path it requested" do
    history = [
      deny(1,
        tool: "write",
        extra: %{
          "normalized_path" => nil,
          "requested_path" => "../outside/secrets.env",
          "matched_rule" => "path_outside_workspace",
          "rule" => nil
        }
      ),
      message(2)
    ]

    assert %{"count" => 1, "denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["normalized_path"] == "../outside/secrets.env"
    assert denial["matched_rule"] == "path_outside_workspace"
    assert denial["disposition"] == "recovered"
  end

  # The aim outranks the normalized form. Normalization is lossy in exactly the
  # direction that matters here: a confinement walk normalizes to where it
  # stopped, so the requested path is the only field that always names what the
  # call asked for.
  test "the requested path wins over the normalized one" do
    history = [
      deny(1,
        extra: %{"requested_path" => "./sub/../p1"}
      ),
      message(2)
    ]

    assert %{"denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["normalized_path"] == "./sub/../p1"
  end

  # The walk-stop component is a second fact, reported in its own key. It never
  # replaces the target: a coordinator reading this entry learns both which
  # write was refused and which component refused it.
  test "a symlink denial confesses the aim and the walk-stop component separately" do
    history = [
      deny(1,
        extra: %{
          "matched_rule" => "symlink_path_component",
          "requested_path" => "link/deep/out.txt",
          "symlink_component" => "link",
          "normalized_path" => "link"
        }
      ),
      message(2)
    ]

    assert %{"denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["normalized_path"] == "link/deep/out.txt"
    assert denial["symlink_component"] == "link"
  end

  test "an uninspectable-path denial keeps its component in its own key" do
    history = [
      deny(1,
        extra: %{
          "matched_rule" => "path_not_inspectable",
          "requested_path" => "locked/deep/f.txt",
          "uninspectable_component" => "locked",
          "normalized_path" => "locked"
        }
      ),
      message(2)
    ]

    assert %{"denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["normalized_path"] == "locked/deep/f.txt"
    assert denial["uninspectable_component"] == "locked"
  end

  test "a bash_disabled denial is not a boundary probe and is never confessed" do
    history = [
      deny(1,
        tool: "bash",
        extra: %{
          "normalized_path" => nil,
          "requested_command" => "npm run build --silent",
          "matched_rule" => "bash_disabled",
          "rule" => "bash_disabled"
        }
      ),
      message(2)
    ]

    assert WriteDenials.from_history(history) == %{"count" => 0, "denials" => []}
  end

  test "bash_disabled is excluded even when only the legacy rule key carries it" do
    history = [
      deny(1,
        tool: "bash",
        extra: %{"normalized_path" => nil, "matched_rule" => nil, "rule" => "bash_disabled"}
      )
    ]

    assert WriteDenials.from_history(history) == %{"count" => 0, "denials" => []}
  end

  test "a bash denial that is a real boundary probe is still confessed" do
    # An outside-workspace token raises the `write_policy_denied` kind, so it
    # strikes in Turn and belongs in the confession: excluding `bash_disabled`
    # must not excuse every bash denial.
    history = [
      deny(1,
        tool: "bash",
        extra: %{
          "normalized_path" => nil,
          "requested_command" => "cat ../../etc/passwd",
          "matched_rule" => "outside_workspace",
          "rule" => "outside_workspace"
        }
      ),
      message(2)
    ]

    assert %{"count" => 1, "denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["matched_rule"] == "outside_workspace"
    assert denial["normalized_path"] == "cat ../../etc/passwd"
  end

  test "a denial with no following terminal Turn event reads as unresolved" do
    # The Log is the source of truth, and a truncated Log is an incomplete one:
    # a crash between the denial and the Turn's terminal event leaves the
    # disposition genuinely unknown. Reporting "recovered" would be a fail-open
    # claim the Log does not support.
    assert %{"count" => 1, "denials" => [denial]} = WriteDenials.from_history([deny(1)])
    assert denial["disposition"] == "unresolved"
  end

  test "a denial followed only by mid-Turn events is still unresolved" do
    tool_result = %{type: :tool_result, seq: 2, data: %{"call_id" => "c1"}}

    assert %{"denials" => [denial]} = WriteDenials.from_history([deny(1), tool_result])
    assert denial["disposition"] == "unresolved"
  end

  test "only the denials of an unterminated Turn are unresolved" do
    # The first Turn terminated cleanly; the second was cut off mid-flight.
    history = [deny(1), message(2), deny(3)]

    assert %{"denials" => denials} = WriteDenials.from_history(history)
    assert Enum.map(denials, & &1["disposition"]) == ["recovered", "unresolved"]
  end

  # The production Turn boundary. `Session.interrupt/1` records no `turn_failed`
  # and no `assistant_message` — it emits an ephemeral status and reconciles the
  # orphan tool calls — and a Task `DOWN` without a recorded failure is the same
  # shape. The Log of an interrupted Turn therefore ends mid-Turn, and the next
  # Turn opens with a `user_message`. Without treating that as a boundary, the
  # *next* Turn's `assistant_message` would close the interrupted Turn's denial
  # as "recovered": a fail-open claim built on another Turn's evidence.
  test "a later Turn's terminal event never recovers an interrupted Turn's denial" do
    history = [
      user_message(1),
      deny(2),
      # Turn A dies here: interrupt records no terminal event.
      user_message(3),
      message(4)
    ]

    assert %{"count" => 1, "denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["seq"] == 2
    assert denial["disposition"] == "unresolved"
  end

  # The Task-DOWN shape: the Turn is gone with no `turn_failed`, the Session is
  # resumed, and the resumed Turn both denies and dies fatally. The earlier
  # denial stays unresolved; only the resumed Turn's own strike is fatal.
  test "a resumed Turn's fatal strike does not reclassify the dead Turn's denial" do
    history = [
      user_message(1),
      deny(2),
      user_message(3),
      deny(4),
      deny(5),
      turn_failed(6)
    ]

    assert %{"denials" => denials} = WriteDenials.from_history(history)

    assert Enum.map(denials, &{&1["seq"], &1["disposition"]}) == [
             {2, "unresolved"},
             {4, "recovered"},
             {5, "fatal"}
           ]
  end

  # The boundary must not swallow the ordinary case: a denial and the terminal
  # event of its *own* Turn still read as recovered when a `user_message` opened
  # that Turn.
  test "a denial resolved inside its own Turn still reads as recovered" do
    history = [user_message(1), deny(2), message(3), user_message(4), message(5)]

    assert %{"denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["disposition"] == "recovered"
  end

  test "a bash_disabled denial never absorbs the fatal disposition of a real strike" do
    history = [
      deny(1,
        tool: "bash",
        extra: %{"matched_rule" => "bash_disabled", "rule" => "bash_disabled"}
      ),
      deny(2),
      turn_failed(3)
    ]

    assert %{"count" => 1, "denials" => [denial]} = WriteDenials.from_history(history)
    assert denial["seq"] == 2
    assert denial["disposition"] == "fatal"
  end

  # A zero-count success and "the Log could not be read" are different facts,
  # and only one of them says the worker never probed its boundary. Collapsing
  # them let a coordinator read a corrupt child Log as a clean run — fail-open
  # on the one surface this confession exists to keep honest. An id `Log.fold/2`
  # rejects outright is the cheapest deterministic unreadable Log there is.
  test "an unreadable Log confesses that it is unavailable, not that nothing was denied" do
    confession = WriteDenials.from_session("../../etc/passwd", "/nonexistent/workspace")

    assert confession["status"] == "unavailable"
    assert confession["denials"] == []
    # No count at all: a consumer that sums counts cannot silently add a zero
    # for a child whose evidence was never read.
    assert confession["count"] == nil
    assert is_binary(confession["error"])
  end

  # A Log file that is simply absent is not a read failure: `Log.fold/2` folds a
  # never-written Session to an empty history, and a Session that recorded
  # nothing genuinely denied nothing. Only a Log that exists and cannot be read
  # is "unavailable".
  test "a Session with no Log yet is a zero-count success, not an unavailable one" do
    workspace = Path.join(System.tmp_dir!(), "pixir-wd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert WriteDenials.from_session("s_neverwritten", workspace) ==
             %{"count" => 0, "denials" => []}
  end

  test "a readable Log with no denials is still a zero-count success" do
    assert WriteDenials.empty() == %{"count" => 0, "denials" => []}
    refute Map.has_key?(WriteDenials.empty(), "status")
  end
end
