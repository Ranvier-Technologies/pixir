defmodule Pixir.Event do
  @moduledoc """
  The one Event type (ADR 0004): a plain tagged map with a common envelope

      %{id: id, session_id: session_id, seq: seq, ts: ts, type: type, data: data}

  built exclusively through the constructors here. The same shape serves live
  display (over `Pixir.Events`) and durable replay (the NDJSON `Pixir.Log`).

  ## Key conventions (round-trip rule)

  The envelope keys (`:id`, `:session_id`, `:seq`, `:ts`, `:type`, `:data`) are
  always atoms, and `:type` is always an atom from the known vocabulary. The `:data`
  payload uses **string keys** — the JSON wire form — so that an Event survives a
  Log round-trip (`append` then `fold`) structurally unchanged. Every consumer (the
  Provider folding History, the Renderer displaying live or replayed events) sees the
  same shape whether the Event is fresh or reloaded.

  ## Canonical vs ephemeral

    * **Canonical** events — `:user_message`, `:assistant_message`, `:reasoning`,
      `:skill_activation`, `:subagent_event`, `:workflow_event`, `:session_fork`,
      `:branch_summary`, `:history_compaction`, `:provider_usage`, `:turn_failed`,
      `:tool_call`, `:tool_result`, `:permission_decision` — are stamped with a per-Session
      monotonic `seq`, appended to the Log, and define **History** (a fold over them).
    * **Ephemeral** events — `:text_delta`, `:reasoning_delta`, `:status` — are
      broadcast for live display and never persisted (`seq` stays `nil`).

  Streaming deltas are ephemeral; canonical `:assistant_message` events remain the
  durable turn record. In provider-error paths, a partial assistant message may be
  preserved with metadata for diagnostics and replay safety.
  """

  @type type :: atom()
  @type t :: %{
          required(:id) => String.t(),
          required(:session_id) => String.t(),
          required(:seq) => non_neg_integer() | nil,
          required(:ts) => String.t(),
          required(:type) => type(),
          required(:data) => map()
        }

  @canonical_types ~w(user_message assistant_message reasoning skill_activation subagent_event workflow_event session_fork branch_summary history_compaction provider_usage turn_failed tool_call tool_result permission_decision)a
  @ephemeral_types ~w(text_delta reasoning_delta status plan context_pressure)a

  @doc "The set of canonical (persisted) event types."
  @spec canonical_types() :: [type()]
  def canonical_types, do: @canonical_types

  @doc "The set of ephemeral (live-only) event types."
  @spec ephemeral_types() :: [type()]
  def ephemeral_types, do: @ephemeral_types

  @doc """
  Build an Event. `seq` is left `nil` here; the owning `Pixir.Session` stamps it on
  canonical events when appending to the Log (see `with_seq/2`).
  """
  @spec new(String.t(), type(), map(), keyword()) :: t()
  def new(session_id, type, data \\ %{}, opts \\ [])
      when is_binary(session_id) and is_atom(type) and is_map(data) do
    %{
      id: Keyword.get_lazy(opts, :id, &gen_id/0),
      session_id: session_id,
      seq: Keyword.get(opts, :seq),
      ts: Keyword.get_lazy(opts, :ts, &now/0),
      type: type,
      data: normalize_data!(data)
    }
  end

  @doc "True if the Event's type is canonical (must be logged)."
  @spec canonical?(t()) :: boolean()
  def canonical?(%{type: type}), do: type in @canonical_types

  @doc "True if the Event's type is ephemeral (live-only, never logged)."
  @spec ephemeral?(t()) :: boolean()
  def ephemeral?(%{type: type}), do: type in @ephemeral_types

  @doc "Return the Event with its monotonic `seq` stamped."
  @spec with_seq(t(), non_neg_integer()) :: t()
  def with_seq(event, seq) when is_integer(seq) and seq >= 0, do: %{event | seq: seq}

  # ── Canonical constructors ────────────────────────────────────────────────

  @doc """
  User input that opens a Turn.

  Optional `:resources` is a list of Session Resource descriptors (ADR 0021).
  Descriptors contain local identity and hashes only; raw image bytes or base64
  payloads must never be placed in the Log.
  """
  @spec user_message(String.t(), String.t(), keyword()) :: t()
  def user_message(session_id, text, opts \\ []) do
    data =
      case Keyword.get(opts, :resources) do
        resources when is_list(resources) and resources != [] ->
          %{"text" => text, "resources" => resources}

        _ ->
          %{"text" => text}
      end

    new(session_id, :user_message, data, Keyword.delete(opts, :resources))
  end

  @doc """
  Final assistant answer for a Turn (the persisted form of streamed text).

  Optional `:metadata` is string-keyed audit context for unusual terminal paths, such
  as a partial answer preserved after a Provider stream error. Provider replay uses
  only the text; metadata is local evidence for diagnostics.
  """
  @spec assistant_message(String.t(), String.t(), keyword()) :: t()
  def assistant_message(session_id, text, opts \\ []) do
    data =
      case Keyword.get(opts, :metadata) do
        metadata when is_map(metadata) and metadata != %{} ->
          %{"text" => text, "metadata" => metadata}

        _ ->
          %{"text" => text}
      end

    new(session_id, :assistant_message, data, Keyword.delete(opts, :metadata))
  end

  @doc """
  An encrypted reasoning item (`rs_…`) the model produced and the Responses API
  requires re-injected on subsequent turns (ADR 0007). `item` is the raw, opaque
  provider object (string-keyed, incl. `encrypted_content`); `model` is the model id
  that produced it, so replay can drop items captured under a different model.
  """
  @spec reasoning(String.t(), map(), String.t(), keyword()) :: t()
  def reasoning(session_id, item, model, opts \\ [])
      when is_map(item) and is_binary(model) do
    new(session_id, :reasoning, %{"item" => item, "model" => model}, opts)
  end

  @doc """
  A Skill selected for a Turn (ADR 0010). `data` is a string-keyed snapshot that
  includes the Skill identity, source/scope, resolved path, content hash, and the
  `SKILL.md` content used for that Turn.
  """
  @spec skill_activation(String.t(), map(), keyword()) :: t()
  def skill_activation(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :skill_activation, data, opts)
  end

  @doc """
  A parent-visible Subagent lifecycle event (ADR 0011). `data` carries
  `subagent_id`, `child_session_id`, `event`, `status`, `agent`, `task`,
  `depth`, `workspace`, and optional `summary`. Terminal events may also carry
  durable operator evidence such as `reason`, `elapsed_ms`, `timeout_ms`, and
  `next_actions` so parent Sessions and diagnostics can explain child outcomes
  without re-running the child.
  """
  @spec subagent_event(String.t(), map(), keyword()) :: t()
  def subagent_event(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :subagent_event, data, opts)
  end

  @doc """
  A durable Workflow run decision (ADR 0032). `data` uses a string-keyed `kind` such as
  `workflow_started`, `step_scheduled`, `checkpoint_decided`, `step_held`, or
  `workflow_finished`. It records decisions and references, not live progress noise or
  large duplicated artifacts.
  """
  @spec workflow_event(String.t(), map(), keyword()) :: t()
  def workflow_event(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :workflow_event, data, opts)
  end

  @doc """
  Durable fork lineage for a child Session (ADR 0024). `data` records the parent Session,
  fork-tree root, replay boundary, workspaces, and replay evidence. Provider replay
  treats this as lineage metadata, not conversational History.
  """
  @spec session_fork(String.t(), map(), keyword()) :: t()
  def session_fork(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :session_fork, data, opts)
  end

  @doc """
  A lossy synthesis of context carried into a Fork (ADR 0024). `data` includes `summary`,
  source range, `strategy`, and explicit `limitations`. Distinct from `history_compaction`.
  """
  @spec branch_summary(String.t(), map(), keyword()) :: t()
  def branch_summary(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :branch_summary, data, opts)
  end

  @doc """
  A durable History compaction checkpoint. `data` is a string-keyed summary with the
  compacted `range`, deterministic `summary`, and audit metadata used by Provider
  replay to keep context bounded without losing the Log as source of truth.
  """
  @spec history_compaction(String.t(), map(), keyword()) :: t()
  def history_compaction(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :history_compaction, data, opts)
  end

  @doc """
  Durable Provider accounting for one model call. `data` is string-keyed evidence such as
  model, call index, prompt-cache key metadata, raw usage, and normalized usage summary.
  This is Harness observability and is never replayed as model context.
  """
  @spec provider_usage(String.t(), map(), keyword()) :: t()
  def provider_usage(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :provider_usage, data, opts)
  end

  @doc """
  Durable audit evidence for a Turn that ended without a clean final assistant answer.

  Provider replay treats this as audit-only unless a future Prompt Contract explicitly
  chooses model-visible failure text. `data` should include `terminal_status`,
  `error_kind`, `error_message`, and any safe structured `details`/`next_actions`.
  """
  @spec turn_failed(String.t(), map(), keyword()) :: t()
  def turn_failed(session_id, data, opts \\ []) when is_map(data) do
    new(session_id, :turn_failed, data, opts)
  end

  @doc """
  A tool/function the model asked to run. `args` is the model-supplied argument map
  (string keys, as decoded from JSON).
  """
  @spec tool_call(String.t(), String.t(), String.t(), map(), keyword()) :: t()
  def tool_call(session_id, call_id, name, args, opts \\ [])
      when is_binary(call_id) and is_binary(name) and is_map(args) do
    new(session_id, :tool_call, %{"call_id" => call_id, "name" => name, "args" => args}, opts)
  end

  @doc """
  The outcome of executing a tool call. `result` is a string-keyed map; by convention
  it carries `"ok"` plus either `"output"` or a structured `"error"` (ADR 0005).
  """
  @spec tool_result(String.t(), String.t(), map(), keyword()) :: t()
  def tool_result(session_id, call_id, result, opts \\ [])
      when is_binary(call_id) and is_map(result) do
    new(session_id, :tool_result, Map.put(result, "call_id", call_id), opts)
  end

  @doc "A permission decision for a gated tool call (ADR 0006)."
  @spec permission_decision(String.t(), String.t(), atom(), keyword()) :: t()
  def permission_decision(session_id, call_id, decision, opts \\ []) when is_binary(call_id) do
    details = opts |> Keyword.get(:details, %{}) |> stringify_data()

    new(
      session_id,
      :permission_decision,
      Map.merge(%{"call_id" => call_id, "decision" => to_string(decision)}, details),
      Keyword.delete(opts, :details)
    )
  end

  defp stringify_data(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_data(value)} end)

  defp stringify_data(list) when is_list(list), do: Enum.map(list, &stringify_data/1)
  defp stringify_data(value), do: value

  # ── Ephemeral constructors ────────────────────────────────────────────────

  @doc "A chunk of streamed assistant text."
  @spec text_delta(String.t(), String.t(), keyword()) :: t()
  def text_delta(session_id, chunk, opts \\ []),
    do: new(session_id, :text_delta, %{"chunk" => chunk}, opts)

  @doc "A chunk of streamed reasoning text."
  @spec reasoning_delta(String.t(), String.t(), keyword()) :: t()
  def reasoning_delta(session_id, chunk, opts \\ []),
    do: new(session_id, :reasoning_delta, %{"chunk" => chunk}, opts)

  @doc "A coarse status transition for live display (e.g. `\"thinking\"`)."
  @spec status(String.t(), String.t(), keyword()) :: t()
  def status(session_id, status, opts \\ []),
    do: new(session_id, :status, %{"status" => status}, opts)

  @doc """
  A live to-do list (ACP plan, epic D.1). `entries` is the COMPLETE current plan
  (ACP replaces the whole list per update — never a delta); each entry is a
  string-keyed `%{"content" => ..., "priority" => "high|medium|low", "status" =>
  "pending|in_progress|completed"}`. Ephemeral/presentation-only — like
  `:status`, a plan never enters the Log (ADR 0003); the Provider fold has no
  notion of it.
  """
  @spec plan(String.t(), [map()], keyword()) :: t()
  def plan(session_id, entries, opts \\ []) when is_list(entries),
    do: new(session_id, :plan, %{"entries" => entries}, opts)

  @doc """
  A context-pressure notice (ADR 0020): the advisory/warning/recovery output for
  the human channel. `data` is string-keyed (`"tier"`, gauge evidence, optional
  `"next_actions"` / `"message"`). Ephemeral by construction — like `:status`, it
  never enters the Log, so it can never reach Provider input or any replay path.
  """
  @spec context_pressure(String.t(), map(), keyword()) :: t()
  def context_pressure(session_id, data, opts \\ []) when is_map(data),
    do: new(session_id, :context_pressure, data, opts)

  # ── internals ─────────────────────────────────────────────────────────────

  defp normalize_data!(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        cond do
          is_binary(key) ->
            key

          is_atom(key) ->
            Atom.to_string(key)

          true ->
            raise ArgumentError, "event data key must be a string or atom, got: #{inspect(key)}"
        end

      if Map.has_key?(acc, normalized_key) do
        raise ArgumentError,
              "event data key collision after normalization for #{inspect(normalized_key)}"
      end

      Map.put(acc, normalized_key, normalize_data_value!(value))
    end)
  end

  defp normalize_data_value!(value) when is_map(value), do: normalize_data!(value)

  defp normalize_data_value!(value) when is_list(value),
    do: Enum.map(value, &normalize_data_value!/1)

  defp normalize_data_value!(value), do: value

  defp gen_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
