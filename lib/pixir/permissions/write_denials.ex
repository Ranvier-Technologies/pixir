defmodule Pixir.Permissions.WriteDenials do
  @moduledoc """
  The mandatory `write_denials` confession for bounded-write runs (#446).

  A bounded-write denial is recoverable feedback: the model receives the
  structured denial as a tool output and may adapt inside the same Turn. The
  second denial in that Turn is turn-fatal. Because a run can therefore complete
  cleanly *after* a denial, a completed status alone no longer proves the worker
  never pushed at its boundary — so every bounded-write envelope and every
  workflow checkpoint carries this confession, present even when empty.

  Absence is a schema violation, not an ambiguous silence. A completed status
  with a non-empty confession is a signal for the coordinator to check whether
  the worker's scope was correct, not a defect in the worker.

  The confession is derived from the Log, which stays the source of truth: every
  denial — recoverable or fatal — is a `permission_decision` Event with
  `decision: "deny"` and `gate: "write_policy"`.

  One `write_policy`-gated denial is deliberately *not* confessed: the
  `bash_disabled` kind. The shell being disabled is a property of the bounded
  write mode rather than a write-allowlist violation (#218), it never strikes in
  Turn, and confessing it would report a worker that merely tried to shell out
  as if it had probed its write boundary. The confession classifies exactly the
  events the strike counter classifies.

  ## What each denial names as its target

  Every entry carries a `normalized_path`, and every entry's `normalized_path`
  is what the *call aimed at* — never where the refusal happened to stop. An
  entry with no target at all is one the coordinator cannot reconcile against
  the worker's transcript, so the key is populated for every kind:

  | `matched_rule` | Target in `normalized_path` | Also carries |
  |---|---|---|
  | `no_allow_match`, `deny_match`, `protected_path` | the requested write path | — |
  | `workspace_root_not_writable` | the requested path (`"."` normalized) | — |
  | `path_outside_workspace` | the requested path; it never normalizes | — |
  | `symlink_path_component` | the requested path | `symlink_component` |
  | `path_not_inspectable` | the requested path | `uninspectable_component` |
  | `outside_workspace` (bash) | the requested command | `token` |
  | `child_policy_override_unsupported` | the tool name, `"spawn_agent"` | — |
  | `unsupported_mutating_tool` | the tool name | — |

  The last two rows name a *tool*, not a path, because the denial has neither a
  path nor a command: the worker was refused for handing a child a different
  policy, or for calling a mutating tool the policy does not model. The target
  is therefore ambiguous on its face — `"spawn_agent"` reads the same whether it
  is a tool name or a file of that name — and it is disambiguated by the two
  keys that are always present beside it: `matched_rule` (one of exactly those
  two rules) together with `tool`. That pair is the contract; no separate
  target-kind field is stamped, so a consumer that needs to know what it is
  looking at reads `matched_rule` rather than guessing from the string.

  Where a confinement walk stopped is a *second* fact about the same denial, and
  it lives in its own key (`symlink_component`, `uninspectable_component`)
  precisely so it can never be mistaken for the target. A write to
  `link/deep/out.txt` refused at the `link` component confesses the full
  requested path and reports `symlink_component: "link"` beside it; confessing
  `"link"` as the target would name a write no call ever made.
  """

  alias Pixir.Log

  @empty %{"count" => 0, "denials" => []}

  @doc "The empty confession. Present, not absent, when nothing was denied."
  @spec empty() :: map()
  def empty, do: @empty

  @doc """
  Build the confession from an already-folded Session history.

  Denials are reported in Log order. Each carries the denied tool, the
  normalized path (or the denied command), the matched rule, the policy
  identity, and a `disposition` of `"recovered"`, `"fatal"`, or `"unresolved"`.

  The fatal strike is the denial the Turn actually died on: the last denial of a
  Turn that recorded a `write_policy_denied` `turn_failed`. Every other denial of
  a Turn that reached a terminal event was survived, so it reads as
  `"recovered"` — including denials in earlier Turns of the same Session, whose
  strike counters reset.

  A denial whose own Turn never reached a terminal event in the Log reads as
  `"unresolved"`. A Turn ends at its terminal event *or* at the `user_message`
  that opens the next Turn, whichever comes first: an interrupted Turn (and a
  Turn lost to a Task `DOWN`) records neither `assistant_message` nor
  `turn_failed`, so only the boundary closes it. The Log is the source of truth
  and an incomplete Log — cut off by a crash between the denial and the Turn's
  terminal event, ended by an interrupt, copied partially, or folded while the
  Session is still running — does not say whether the worker adapted. Reporting
  such a denial as `"recovered"` on the strength of a *later* Turn's terminal
  event would be a fail-open claim on missing evidence; `"unresolved"` tells the
  coordinator to go read the Log.
  """
  @spec from_history(list()) :: map()
  def from_history(history) when is_list(history) do
    dispositions = dispositions(history)

    denials =
      history
      |> Enum.filter(&denial?/1)
      |> Enum.map(fn event ->
        denial(event, Map.get(dispositions, seq(event), "unresolved"))
      end)

    %{"count" => length(denials), "denials" => denials}
  end

  def from_history(_history), do: @empty

  @doc """
  Build the confession by folding `session_id`'s Log under `workspace`.

  An *unreadable* Log yields the *unavailable* confession rather than raising or
  reporting zero: `%{"status" => "unavailable", "error" => …, "denials" => []}`,
  with no `count` key at all. "Nothing was denied" and "the evidence could not
  be read" are different facts, and a coordinator that reads only the confession
  must not be able to mistake the second for the first — that is the fail-open
  the whole confession exists to close. The absent `count` makes the difference
  impossible to miss for a consumer that sums counts.

  A *missing* Log is not an unreadable one. `Log.fold/2` folds a Session that
  never wrote an Event to `{:ok, []}`, and a Session that recorded nothing
  genuinely denied nothing, so it confesses `%{"count" => 0, "denials" => []}`
  like any other clean run. `unavailable` is reserved for the cases `Log.fold/2`
  actually reports as errors — a corrupt Log, an unsafe or rejected session id,
  an unreadable file — plus a non-binary `session_id` or `workspace`.
  """
  @spec from_session(String.t(), String.t()) :: map()
  def from_session(session_id, workspace)
      when is_binary(session_id) and is_binary(workspace) do
    case Log.fold(session_id, workspace: workspace) do
      {:ok, history} -> from_history(history)
      {:error, error} -> unavailable(error)
    end
  end

  def from_session(session_id, workspace),
    do: unavailable("invalid session_id or workspace: #{inspect({session_id, workspace})}")

  @doc """
  The confession of a Log that could not be read. Well-formed, never a zero.
  """
  @spec unavailable(term()) :: map()
  def unavailable(error) do
    %{"status" => "unavailable", "error" => describe(error), "denials" => []}
  end

  defp describe(error) when is_binary(error), do: error
  defp describe(%{error: %{message: message}}) when is_binary(message), do: message
  defp describe(%{"message" => message}) when is_binary(message), do: message
  defp describe(error), do: inspect(error)

  # A bounded-write denial: the write-policy gate said no to a *write*.
  # Interactive permission-mode denials carry no `write_policy` gate and are
  # excluded.
  #
  # `bash_disabled` is stamped with the same `write_policy` gate by the Executor
  # but is not a boundary probe: the shell being off is a property of the mode,
  # not a scope the worker drew too small (#218). It never strikes in Turn, so
  # confessing it would manufacture a false "check the worker's scope" signal
  # for a worker that merely tried to shell out. Excluded here to keep the
  # confession and the strike counter classifying the same events.
  defp denial?(%{type: :permission_decision, data: %{"decision" => "deny"} = data})
       when is_map(data),
       do: data["gate"] == "write_policy" and not bash_disabled?(data)

  defp denial?(_event), do: false

  defp bash_disabled?(data),
    do: (data["matched_rule"] || data["rule"]) == "bash_disabled"

  # Resolve every denial's disposition against the Turn that contains it.
  #
  # A denial is only resolved by the terminal event of its *own* Turn: a
  # `turn_failed`, or the `assistant_message` a Turn records when it completes.
  # The last denial before a `write_policy_denied` `turn_failed` is the strike
  # the Turn actually died on and reads `"fatal"`; every other denial of a
  # terminated Turn was survived and reads `"recovered"`.
  #
  # A `user_message` opens a Turn, so it also closes the previous one. Pending
  # denials still open when the next Turn starts belong to a Turn that never
  # recorded a terminal event, and they freeze as `"unresolved"` — the next
  # Turn's `assistant_message` is not evidence about them. This is not a corner
  # case: `Session.interrupt/1` records no `turn_failed` and no
  # `assistant_message` (it emits an ephemeral status and reconciles the orphan
  # tool calls), and a Task `DOWN` with no recorded failure is the same shape.
  # Without the boundary, an interrupt-then-resume Log would launder an
  # unresolved denial into `"recovered"` on the strength of a *different* Turn's
  # evidence — fail-open exactly where this confession must be fail-closed.
  #
  # Denials that never meet any boundary stay out of the map and default to
  # `"unresolved"` at the call site. The Log is the source of truth, and a Log
  # that stops mid-Turn — a crash between the denial and the Turn's terminal
  # event, a partial copy, a fold of a still-running Session — genuinely does not
  # say what happened. Calling that "recovered" would be a fail-open claim: the
  # confession would report a boundary probe as survived on the strength of
  # evidence that is missing. `"unresolved"` says exactly what the Log supports.
  defp dispositions(history) do
    history
    |> Enum.reduce({%{}, []}, fn event, {resolved, pending} ->
      cond do
        denial?(event) ->
          {resolved, [seq(event) | pending]}

        fatal_turn_failure?(event) and pending != [] ->
          [fatal | recovered] = pending
          {resolve(resolved, recovered, "recovered") |> Map.put(fatal, "fatal"), []}

        turn_terminal?(event) ->
          {resolve(resolved, pending, "recovered"), []}

        turn_boundary?(event) ->
          {resolve(resolved, pending, "unresolved"), []}

        true ->
          {resolved, pending}
      end
    end)
    |> elem(0)
  end

  defp resolve(resolved, seqs, disposition),
    do: Enum.reduce(seqs, resolved, &Map.put(&2, &1, disposition))

  # The events that end a Turn in the Log. A Turn that completes records its
  # final `assistant_message`; a Turn that fails records `turn_failed`.
  defp turn_terminal?(%{type: type}) when type in [:assistant_message, :turn_failed], do: true
  defp turn_terminal?(_event), do: false

  # The event that opens a Turn, and therefore closes the previous one whether or
  # not that Turn ever recorded a terminal event. Denials still pending here
  # never met their own Turn's ending.
  #
  # This reads the Turn-*opening* `user_message` and nothing else, which is the
  # only kind production writes: every Turn entrypoint goes through `Turn.run`,
  # which records exactly one `user_message` as its first durable Event, and a
  # Session serializes its Turns. A synthetic Log with a `user_message` recorded
  # *mid*-Turn would freeze a denial that its own Turn later resolved as
  # `"unresolved"` instead of `"recovered"` — wrong, but wrong in the fail-closed
  # direction: it under-claims resolution and sends the coordinator to the Log,
  # which is the same thing it does for every other kind of incomplete evidence.
  defp turn_boundary?(%{type: :user_message}), do: true
  defp turn_boundary?(_event), do: false

  defp fatal_turn_failure?(%{type: :turn_failed, data: data}) when is_map(data),
    do: data["error_kind"] == "write_policy_denied"

  defp fatal_turn_failure?(_event), do: false

  defp denial(%{data: data} = event, disposition) do
    %{
      "tool" => data["tool"],
      # What the worker actually *aimed at*, which is the requested path
      # whenever the Log recorded one. The aim outranks the normalized form
      # because a confinement walk normalizes to where it stopped, not to what
      # was asked for: a write to `link/deep/out.txt` refused at the `link`
      # component stamps `normalized_path: "link"`, and confessing that as the
      # target names a write no call ever made. Where the walk stopped is not
      # lost — it keeps its own key below.
      #
      # The remaining fallbacks cover denials that never produced a path at all:
      # a bash boundary probe carries only `requested_command`. The Executor's
      # `policy_decision_details/1` has no `command` key, which is kept as a
      # last fallback for older Logs. A confession that dropped the target
      # entirely would report a denial the coordinator cannot reconcile.
      "normalized_path" =>
        data["requested_path"] || data["normalized_path"] || data["requested_command"] ||
          data["command"],
      # Where the confinement walk stopped, when it stopped at a component. A
      # second fact about the same denial, never a substitute for the target.
      "symlink_component" => data["symlink_component"],
      "uninspectable_component" => data["uninspectable_component"],
      "matched_rule" => data["matched_rule"] || data["rule"],
      "policy_id" => data["policy_id"],
      "policy_hash" => data["policy_hash"],
      "policy_version" => data["policy_version"],
      "call_id" => data["call_id"],
      "seq" => seq(event),
      "disposition" => disposition
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp seq(%{seq: seq}), do: seq
  defp seq(%{"seq" => seq}), do: seq
  defp seq(_event), do: nil
end
