defmodule Pixir.Subagents do
  @moduledoc """
  Public facade for BEAM-native Subagent orchestration (ADR 0011).

  Subagents move through a small lifecycle state machine. The usual path is
  `queued -> running -> completed`, but failures, timeouts, cancellation, and
  detached restored children must remain explicit so parents and diagnostics can
  tell "finished cleanly" apart from "needs operator attention".

  `max_depth` is an absolute delegation-depth cap from the root Session. A child
  spawned by the root runs at depth `1`; that child may only spawn another child
  when the configured cap is at least `2`.
  """

  alias Pixir.Subagents.Manager

  @statuses ~w(queued running completed failed timed_out cancelled detached closed)
  @terminal_statuses ~w(completed failed cancelled timed_out closed detached)

  @allowed_transitions %{
    "queued" => ~w(running failed detached closed),
    "running" => ~w(completed failed timed_out cancelled detached),
    "completed" => ~w(running closed),
    "failed" => ~w(running closed),
    "timed_out" => ~w(running closed),
    "cancelled" => ~w(running closed),
    "detached" => [],
    "closed" => []
  }

  @doc "Application child spec."
  def child_spec(opts), do: Manager.child_spec(opts)

  @doc "Default runtime limits."
  def default_limits do
    config = Application.get_env(:pixir, :subagents, [])

    %{
      max_threads: Keyword.get(config, :max_threads, 6),
      max_depth: Keyword.get(config, :max_depth, 1),
      timeout_ms: Keyword.get(config, :timeout_ms, 120_000),
      retry_attempts: Keyword.get(config, :retry_attempts, 1),
      retry_jitter_ms: Keyword.get(config, :retry_jitter_ms, 250)
    }
  end

  @doc "Spawn or queue a Subagent."
  def spawn_agent(parent_session_id, args, opts \\ []),
    do: Manager.spawn_agent(parent_session_id, args, opts)

  @doc "Send follow-up input to an idle Subagent."
  def send_input(parent_session_id, subagent_id, prompt, opts \\ []),
    do: Manager.send_input(parent_session_id, subagent_id, prompt, opts)

  @doc "Wait for selected Subagents to reach a terminal status."
  def wait(parent_session_id, ids, timeout_ms \\ 30_000, opts \\ []),
    do: Manager.wait(parent_session_id, ids, timeout_ms, opts)

  @doc """
  Wait for selected Subagents and return a structured outcome.

  Unlike `wait/4`, this keeps partial fanout visible: timed-out, failed, detached,
  cancelled, and still-incomplete children are bucketed instead of turning the
  parent tool call into an opaque failure. The returned `"partial"` boolean is
  true for any non-completed aggregate status; consumers should use `"status"`
  when they need to distinguish `"partial"` from `"incomplete"`.
  """
  def wait_outcome(parent_session_id, ids, timeout_ms \\ 30_000, opts \\ []),
    do: Manager.wait_outcome(parent_session_id, ids, timeout_ms, opts)

  @doc "Cancel a running Subagent, or close a queued/terminal Subagent as cleanup."
  def close(parent_session_id, id, opts \\ []), do: Manager.close(parent_session_id, id, opts)

  @doc "List Subagents for a parent Session."
  def list(parent_session_id, opts \\ []), do: Manager.list(parent_session_id, opts)

  @doc """
  Return a read-only snapshot of the Subagent Manager runtime for one parent Session.

  This is volatile process health evidence, not durable history. Use the Session Log
  and Session tree for canonical lifecycle facts.
  """
  def diagnostics(parent_session_id, opts \\ []), do: Manager.diagnostics(parent_session_id, opts)

  @doc "Summarize agent maps for model-facing output."
  def summarize(agents) when is_list(agents) do
    agents
    |> Enum.map_join("\n", fn agent ->
      summary = agent["summary"] || agent[:summary] || ""
      id = agent["id"] || agent[:id]
      name = agent["agent"] || agent[:agent]
      status = agent["status"] || agent[:status]
      "- #{id} (#{name}) #{status}: #{summary}"
    end)
  end

  @doc "Build model-facing text for a structured wait outcome."
  def summarize_wait_outcome(%{"summary" => summary}) when is_binary(summary), do: summary
  def summarize_wait_outcome(_outcome), do: "wait_agent outcome unavailable."

  @doc "All known Subagent lifecycle statuses."
  def statuses, do: @statuses

  @doc "Statuses that no longer have a live child runtime."
  def terminal_statuses, do: @terminal_statuses

  @doc "Whether a status is terminal."
  def terminal?(status), do: status in @terminal_statuses

  @doc """
  Whether the public lifecycle contract allows a status transition.

  `closed` is retained as Pixir's local close/cleanup state. Completed, failed,
  timed-out, and cancelled Subagents may be restarted by `send_input/4`; detached
  children cannot be resumed because there is no live process handle.
  """
  def transition_allowed?(from, to) when is_binary(from) and is_binary(to) do
    to in Map.get(@allowed_transitions, from, [])
  end

  def transition_allowed?(_from, _to), do: false

  @doc """
  Reconstruct Subagent relationships and terminal state from parent History.
  """
  def reconstruct(history) when is_list(history) do
    history
    |> Enum.filter(&(&1.type == :subagent_event))
    |> Enum.reduce(%{}, fn %{data: data}, acc ->
      id = data["subagent_id"]

      current =
        Map.get(acc, id, %{
          "id" => id,
          "events" => []
        })

      updated =
        current
        |> Map.merge(Map.take(data, subagent_fields()))
        |> Map.put("events", current["events"] ++ [data["event"]])

      Map.put(acc, id, updated)
    end)
  end

  defp subagent_fields do
    [
      "subagent_id",
      "child_session_id",
      "agent",
      "status",
      "task",
      "depth",
      "max_depth",
      "workspace",
      "workspace_mode",
      "parent_log_path",
      "child_log_path",
      "summary",
      "event",
      "timeout_ms",
      "deadline_at",
      "write_policy",
      "elapsed_ms",
      "reason",
      "next_actions",
      "retry_attempts",
      "retry_max_attempts",
      "current_attempt_index",
      "retry_history"
    ]
  end
end
