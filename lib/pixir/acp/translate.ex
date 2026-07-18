defmodule Pixir.ACP.Translate do
  @moduledoc """
  Pure mapping from Pixir bus `Events` to ACP `session/update` notification params, and
  from a terminal `Conversation.await/2` outcome to an ACP `PromptResponse` stopReason
  (ADR 0009, §§4-5). No IO, no process state.

  This is **presentation only** — the canonical Log is never altered. Streamed
  `text_delta`s become `agent_message_chunk`s; the canonical `assistant_message` (the
  same text) is intentionally dropped here to avoid duplication, and is re-emitted only
  by the no-deltas fallback path in `Pixir.ACP.Server`. File-oriented tool calls can
  include ACP locations when the Server supplies the session workspace; paths are resolved
  from structured tool args, never inferred from prose.

  ## TODO(presenter-current-scope)

  Subagent and Workflow projections should carry enough structured scope for a Presenter
  to distinguish "children from this current tool/workflow/delegate" from "all children
  on the parent Session". This is a presentation concern: add parent session id, current
  turn/tool/workflow identifiers, and checkpoint/partial metadata to ACP-friendly
  `_meta.pixir` shapes before changing any canonical Event vocabulary.
  """

  alias Pixir.Event
  alias Pixir.Provider.OutputTruncationSummary

  @type acp_sid :: String.t()
  @type await_outcome :: :done | :error | :interrupted | :timeout

  @doc """
  Translate a Pixir `Event` into the full `session/update` params
  (`%{"sessionId" => acp_sid, "update" => update}`), or `nil` when the event maps to
  nothing on the wire.
  """
  @spec update(Event.t(), acp_sid(), keyword()) :: map() | nil
  def update(event, acp_sid, opts \\ [])

  def update(%{type: :text_delta, data: %{"chunk" => chunk}}, acp_sid, _opts) do
    wrap(acp_sid, %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => text_block(chunk)
    })
  end

  def update(%{type: :reasoning_delta, data: %{"chunk" => chunk}}, acp_sid, _opts) do
    wrap(acp_sid, %{
      "sessionUpdate" => "agent_thought_chunk",
      "content" => text_block(chunk)
    })
  end

  def update(%{type: :tool_call, data: %{"call_id" => id, "name" => name} = data}, acp_sid, opts) do
    args = Map.get(data, "args", %{})

    wrap(
      acp_sid,
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => id,
        "title" => title(name, args),
        "kind" => kind(name),
        "status" => "in_progress"
      }
      |> put_optional("locations", tool_locations(name, args, opts))
      |> put_optional("rawInput", semantic_tool_input(name, args))
    )
  end

  def update(%{type: :tool_result, data: %{"call_id" => id, "ok" => ok} = data}, acp_sid, _opts) do
    wrap(
      acp_sid,
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => id,
        "status" => if(ok, do: "completed", else: "failed"),
        "content" => [%{"type" => "content", "content" => text_block(result_text(ok, data))}]
      }
      |> put_optional("rawOutput", semantic_tool_output(data))
    )
  end

  def update(%{type: :subagent_event, data: %{"subagent_id" => id} = data}, acp_sid, opts)
      when is_binary(id) and id != "" do
    wrap(acp_sid, subagent_update(acp_sid, data, Keyword.get(opts, :subagent_seen?, false)))
  end

  def update(%{type: :plan, data: %{"entries" => entries}}, acp_sid, _opts)
      when is_list(entries) do
    wrap(acp_sid, %{
      "sessionUpdate" => "plan",
      "entries" => Enum.map(entries, &plan_entry/1)
    })
  end

  # Context pressure / remaining window gauge (ADR 0020 + this change).
  # Emitted as an ephemeral bus event by Turn after provider usage is assessed. Routine
  # snapshots update a live gauge; notices/recovery events add human-facing pressure
  # guidance. Forwarded over ACP so clients such as T3 Code can surface an accurate
  # live badge (used / remaining / tier) instead of stale numbers. This is
  # presentation-only (like :status / :plan) — never part of Provider input and never
  # logged.
  #
  # ACP wire shape:
  #   session/update with "sessionUpdate": "usage_update"
  #   fields: used, size, _meta.pixir.{presentation,tier,model,remainingTokens,ratio,...}
  #
  # `usage_update` is the protocol surface T3 already validates for context gauges.
  # Pixir-specific pressure semantics stay under `_meta.pixir` so the canonical
  # runtime vocabulary does not leak as a custom ACP update kind.
  def update(%{type: :context_pressure, data: data}, acp_sid, _opts) do
    input = Map.get(data, "input_tokens") || Map.get(data, "context_pressure_input_tokens")
    window = Map.get(data, "window_tokens")

    if non_negative_integer?(input) and non_negative_integer?(window) do
      remaining = max(0, window - input)

      meta =
        %{
          "tier" => Map.get(data, "tier"),
          "model" => Map.get(data, "model"),
          "remainingTokens" => remaining,
          "ratio" => Map.get(data, "ratio") || Map.get(data, "context_pressure_ratio")
        }
        |> put_optional("presentation", Map.get(data, "presentation"))
        |> put_optional("checkpointToSeq", Map.get(data, "checkpoint_to_seq"))
        |> put_optional("nextActions", Map.get(data, "next_actions"))
        |> put_optional("message", Map.get(data, "message"))
        |> put_optional("trigger", Map.get(data, "trigger"))

      wrap(acp_sid, %{
        "sessionUpdate" => "usage_update",
        "used" => input,
        "size" => window,
        "_meta" => %{"pixir" => meta}
      })
    end
  end

  def update(%{type: :provider_usage} = event, acp_sid, _opts) do
    case OutputTruncationSummary.warning(event) do
      nil -> nil
      warning -> output_warning_update(warning, acp_sid)
    end
  end

  # assistant_message / reasoning / user_message / permission_decision / status: no direct
  # wire form (context_pressure is handled above). assistant_message is handled only
  # by the Server's no-deltas fallback; status drives the stopReason via await's
  # terminal return.
  def update(_event, _acp_sid, _opts), do: nil

  @doc """
  Map a canonical History Event to a `session/update` for `session/load` REPLAY
  (epic A.6) — a fuller mapping than `update/2`, which intentionally drops
  user/assistant (live streaming re-emits deltas, not the canonical message).
  On load there are no deltas, so clean canonical messages ARE the transcript:
  `user_message`→`user_message_chunk`, clean `assistant_message`→`agent_message_chunk`,
  `tool_call`/`tool_result` as in live. **Reasoning is omitted** (opaque encrypted
  `rs_` items carry no displayable summary — ADR 0007; the summary text is
  ephemeral and never logged). Partial assistant evidence and `turn_failed` are audit
  evidence, not clean transcript content. Returns `nil` for events with no transcript
  form.
  """
  @spec replay(Event.t(), acp_sid(), keyword()) :: map() | nil
  def replay(event, acp_sid, opts \\ [])

  def replay(%{type: :user_message, data: %{"text" => text}}, acp_sid, _opts) do
    wrap(acp_sid, %{"sessionUpdate" => "user_message_chunk", "content" => text_block(text)})
  end

  def replay(
        %{type: :assistant_message, data: %{"metadata" => %{"partial" => true}}},
        _acp_sid,
        _opts
      ),
      do: nil

  def replay(%{type: :assistant_message, data: %{"text" => text}}, acp_sid, _opts) do
    wrap(acp_sid, %{"sessionUpdate" => "agent_message_chunk", "content" => text_block(text)})
  end

  def replay(%{type: :provider_usage} = event, acp_sid, opts), do: update(event, acp_sid, opts)

  # tool_call / tool_result / subagent_event replay identically to the live wire form.
  def replay(%{type: type} = event, acp_sid, opts)
      when type in [:tool_call, :tool_result, :subagent_event] do
    update(event, acp_sid, opts)
  end

  # turn_failed / reasoning / permission_decision / status / plan / context_pressure:
  # nothing to replay as clean transcript content.
  # context_pressure is a live gauge only (ephemeral by construction).
  def replay(%{type: :turn_failed}, _acp_sid, _opts), do: nil
  def replay(%{type: :context_pressure}, _acp_sid, _opts), do: nil
  def replay(_event, _acp_sid, _opts), do: nil

  @doc """
  Build a one-off `agent_message_chunk` `session/update` for a piece of assistant text.
  Used by the Server's fallback when a Turn streamed no `text_delta` (ADR 0009 §4).
  """
  @spec message_chunk(String.t(), acp_sid()) :: map()
  def message_chunk(text, acp_sid) when is_binary(text) do
    wrap(acp_sid, %{"sessionUpdate" => "agent_message_chunk", "content" => text_block(text)})
  end

  @doc "Build the pinned schema-valid, non-transcript ACP warning update."
  @spec output_warning_update(map(), acp_sid()) :: map()
  def output_warning_update(warning, acp_sid) do
    wrap(acp_sid, %{
      "sessionUpdate" => "session_info_update",
      "_meta" => %{
        "pixir" => %{
          "schemaVersion" => 1,
          "presentation" => %{"type" => "provider_output_warning"},
          "warning" =>
            %{
              "kind" => warning["kind"],
              "severity" => warning["severity"],
              "providerUsageEventId" => warning["provider_usage_event_id"],
              "providerUsageSeq" => warning["provider_usage_seq"],
              "reason" => warning["reason"],
              "providerReason" => warning["provider_reason"],
              "callRole" => warning["call_role"]
            }
            |> Map.reject(fn {_key, value} -> is_nil(value) end)
        }
      }
    })
  end

  @doc "Build the terminal ACP summary after the 256-notice cap was exceeded."
  @spec output_warning_summary(non_neg_integer(), acp_sid()) :: map()
  def output_warning_summary(total, acp_sid) do
    wrap(acp_sid, %{
      "sessionUpdate" => "session_info_update",
      "_meta" => %{
        "pixir" => %{
          "schemaVersion" => 1,
          "presentation" => %{"type" => "provider_output_warning_summary"},
          "warningSummary" => %{
            "warningCount" => total,
            "warningsShown" => 256,
            "warningsTruncated" => true
          }
        }
      }
    })
  end

  @doc """
  Map a terminal `await` outcome to an ACP stopReason. `cancel_requested?` covers the
  cancel-vs-terminal race: if `session/cancel` arrived, resolve `"cancelled"` even if a
  `done`/`error` slipped in first. A turn-level error is reported as content, not a
  protocol error, so it resolves `"end_turn"` (ADR 0009 §5).
  """
  @spec stop_reason(await_outcome(), boolean()) :: String.t()
  def stop_reason(_outcome, true), do: "cancelled"
  def stop_reason(:interrupted, _cancel?), do: "cancelled"
  def stop_reason(:done, _cancel?), do: "end_turn"
  def stop_reason(:error, _cancel?), do: "end_turn"
  def stop_reason(:timeout, _cancel?), do: "end_turn"

  @doc """
  Build the `session/request_permission` PARAMS (A.2) from an asker request
  `%{tool, args, reason, call_id}`. Offers exactly two options per decision #7:
  `allow_once` / `reject_once` (ADR 0006 defers persistent allow-lists). Reuses
  `title/2`/`kind/1` so the toolCall reads like the live `tool_call` update.
  """
  @spec permission_request(map(), acp_sid()) :: map()
  def permission_request(%{tool: tool} = request, acp_sid) do
    args = Map.get(request, :args, %{})

    %{
      "sessionId" => acp_sid,
      "toolCall" => %{
        "toolCallId" => Map.get(request, :call_id, ""),
        "title" => title(tool, args),
        "kind" => kind(tool)
      },
      "options" => [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "reject", "name" => "Reject", "kind" => "reject_once"}
      ]
    }
  end

  @doc """
  Map a `RequestPermissionResponse` (the `{:ok, result}` / `{:error, _}` from
  `Server.request_permission/2`) to the Executor's decision: `:allow | {:deny,
  reason}`. A `selected` outcome whose optionId is an allow option → `:allow`;
  a reject option, a `cancelled` outcome, or any error/malformed response →
  `{:deny, reason}` (default-deny: anything we can't read as an explicit allow
  is a denial).
  """
  @spec permission_outcome({:ok, map()} | {:error, term()}) :: :allow | {:deny, String.t()}
  def permission_outcome(
        {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}}
      ),
      do: :allow

  def permission_outcome({:ok, %{"outcome" => %{"outcome" => "selected"}}}),
    do: {:deny, "rejected by user"}

  def permission_outcome({:ok, %{"outcome" => %{"outcome" => "cancelled"}}}),
    do: {:deny, "cancelled"}

  def permission_outcome({:error, _reason}), do: {:deny, "permission request failed"}

  def permission_outcome(_other), do: {:deny, "denied"}

  @doc "ACP tool `kind` for a Pixir tool registry name (cosmetic — drives only an icon)."
  @spec kind(String.t()) :: String.t()
  def kind("read"), do: "read"
  def kind("skills_list"), do: "read"
  def kind("skill_view"), do: "read"
  def kind("wait_agent"), do: "read"
  def kind("list_agents"), do: "read"
  def kind("spawn_agent"), do: "execute"
  def kind("send_input"), do: "execute"
  def kind("close_agent"), do: "execute"
  def kind("run_workflow"), do: "execute"
  def kind("resource_view"), do: "read"
  def kind("write"), do: "edit"
  def kind("edit"), do: "edit"
  def kind("bash"), do: "execute"
  def kind(_other), do: "other"

  # ── internals ──────────────────────────────────────────────────────────────

  defp wrap(acp_sid, update), do: %{"sessionId" => acp_sid, "update" => update}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp semantic_tool_input(name, args)
       when name in ~w(spawn_agent wait_agent list_agents close_agent send_input run_workflow) do
    %{
      "_meta" => %{
        "pixir" => %{
          "presentation" => %{
            "type" => semantic_tool_type(name),
            "tool" => name
          }
        }
      },
      "args" => args || %{}
    }
  end

  defp semantic_tool_input(_name, _args), do: nil

  defp tool_locations(name, args, opts)
       when name in ~w(read write edit) and is_map(args) do
    workspace = Keyword.get(opts, :workspace)
    path = args["path"]

    with true <- is_binary(path) and path != "",
         {:ok, location_path} <- location_path(path, workspace) do
      [%{"path" => location_path}]
    else
      _ -> nil
    end
  end

  defp tool_locations(_name, _args, _opts), do: nil

  defp location_path(path, workspace) when is_binary(workspace) and workspace != "" do
    root = Path.expand(workspace)
    abs = Path.expand(path, root)

    if inside_workspace?(abs, root) do
      {:ok, abs}
    else
      :error
    end
  end

  defp location_path(_path, _workspace), do: :error

  defp inside_workspace?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp semantic_tool_type("run_workflow"), do: "workflow_tool"
  defp semantic_tool_type(_name), do: "subagent_tool"

  defp semantic_tool_output(%{"subagent" => subagent}) when is_map(subagent) do
    semantic_output("subagent_tool_result", %{"subagent" => subagent})
  end

  defp semantic_tool_output(%{"subagents" => subagents}) when is_list(subagents) do
    semantic_output("subagent_tool_result", %{"subagents" => subagents})
  end

  defp semantic_tool_output(%{"workflow" => workflow}) when is_map(workflow) do
    semantic_output("workflow_tool_result", %{"workflow" => workflow})
  end

  defp semantic_tool_output(_data), do: nil

  defp semantic_output(type, data) do
    Map.put(data, "_meta", %{
      "pixir" => %{
        "presentation" => %{
          "type" => type
        }
      }
    })
  end

  defp subagent_update(acp_sid, data, seen?) do
    status = data["status"] || data["event"] || "unknown"
    tool_call_id = subagent_tool_call_id(acp_sid, data["subagent_id"])
    title = subagent_title(data)
    detail = subagent_detail(data)
    semantic = subagent_semantic_data(data)

    cond do
      subagent_terminal?(status, data["event"]) ->
        subagent_tool_update(tool_call_id, title, subagent_acp_status(status), detail, semantic)

      seen? ->
        subagent_tool_update(tool_call_id, title, "in_progress", detail, semantic)

      true ->
        %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => tool_call_id,
          "title" => title,
          "kind" => "other",
          "status" => "in_progress",
          "rawInput" => semantic,
          "content" => [%{"type" => "content", "content" => text_block(detail)}]
        }
    end
  end

  defp subagent_tool_update(tool_call_id, title, status, detail, semantic) do
    %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => tool_call_id,
      "title" => title,
      "kind" => "other",
      "status" => status,
      "rawOutput" => semantic,
      "content" => [%{"type" => "content", "content" => text_block(detail)}]
    }
  end

  defp subagent_tool_call_id(acp_sid, id), do: "pixir:#{acp_sid}:subagent:#{id}"

  defp subagent_title(data) do
    agent = data["agent"] || "default"
    id = data["subagent_id"]
    "Subagent #{id} (#{agent})"
  end

  defp subagent_detail(data) do
    status = data["status"] || data["event"] || "unknown"
    summary = data["summary"]
    task = data["task"]

    cond do
      is_binary(summary) and summary != "" -> "#{status}: #{summary}"
      is_binary(task) and task != "" -> "#{status}: #{truncate(task)}"
      true -> status
    end
  end

  defp subagent_semantic_data(data) do
    %{
      "_meta" => %{
        "pixir" => %{
          "presentation" => %{
            "type" => "subagent_lifecycle",
            "tool" => "subagent_event"
          }
        }
      },
      "subagent" => %{
        "id" => data["subagent_id"],
        "child_session_id" => data["child_session_id"],
        "agent" => data["agent"],
        "task" => data["task"],
        "depth" => data["depth"],
        "workspace" => data["workspace"],
        "event" => data["event"],
        "status" => data["status"],
        "summary" => data["summary"]
      }
    }
  end

  defp subagent_terminal?(status, event),
    do:
      status in ~w(completed failed cancelled timed_out closed detached) or
        event in ~w(finished failed cancelled timed_out closed)

  defp subagent_acp_status(status) when status in ~w(completed closed), do: "completed"
  defp subagent_acp_status(_status), do: "failed"

  # Normalize one plan entry to the ACP `PlanEntry` schema: `priority ∈
  # {high,medium,low}` (default medium), `status ∈ {pending,in_progress,
  # completed}` (default pending), and a never-empty `content` string. Tolerates
  # atom or string keys/values from the bus.
  @plan_priorities ~w(high medium low)
  @plan_statuses ~w(pending in_progress completed)

  defp plan_entry(entry) when is_map(entry) do
    %{
      "content" => plan_content(get_field(entry, "content")),
      "priority" => clamp(get_field(entry, "priority"), @plan_priorities, "medium"),
      "status" => clamp(get_field(entry, "status"), @plan_statuses, "pending")
    }
  end

  defp plan_entry(other),
    do: %{"content" => to_text(other), "priority" => "medium", "status" => "pending"}

  # Read a field by its string key, falling back to the atom key. The keys are
  # fixed literals (content/priority/status), so the atoms already exist — but
  # guard with `to_existing_atom` so a stray non-atom key never crashes.
  defp get_field(map, key) do
    Map.get(map, key) ||
      case safe_atom(key) do
        nil -> nil
        atom -> Map.get(map, atom)
      end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp plan_content(value) do
    case to_text(value) |> String.trim() do
      "" -> "(untitled step)"
      content -> content
    end
  end

  defp clamp(value, allowed, default) do
    str = value |> to_text() |> String.trim()
    if str in allowed, do: str, else: default
  end

  defp text_block(text), do: %{"type" => "text", "text" => to_text(text)}

  # A short, schema-required, never-nil title for a tool_call.
  defp title(name, args) when is_map(args) do
    cond do
      is_binary(args["path"]) -> "#{name} #{args["path"]}"
      is_binary(args["command"]) -> "#{name}: #{truncate(args["command"])}"
      is_binary(args["cmd"]) -> "#{name}: #{truncate(args["cmd"])}"
      true -> name
    end
  end

  defp title(name, _args), do: name

  defp truncate(s) when is_binary(s) do
    if String.length(s) > 60, do: String.slice(s, 0, 57) <> "...", else: s
  end

  defp result_text(true, data), do: to_text(Map.get(data, "output", ""))

  defp result_text(false, %{"error" => %{kind: kind, message: message}}),
    do: "#{kind}: #{message}"

  defp result_text(false, %{"error" => %{"kind" => kind, "message" => message}}),
    do: "#{kind}: #{message}"

  defp result_text(false, data), do: to_text(Map.get(data, "output") || Map.get(data, "error"))

  defp to_text(text) when is_binary(text), do: text
  defp to_text(nil), do: ""
  defp to_text(other), do: inspect(other)
end
