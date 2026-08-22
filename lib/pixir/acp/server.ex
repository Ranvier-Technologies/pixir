defmodule Pixir.ACP.Server do
  @moduledoc """
  The ACP agent (server side) over stdio (ADR 0009): a single `GenServer` that owns the
  stdout writer and the `acp_session_id ↔ pixir_session_id` map, decodes ndjson JSON-RPC
  from stdin, dispatches by method onto `Pixir.Conversation`, and runs each
  `session/prompt` in a supervised Task.

  ## Channel discipline (ADR 0005)

  **stdout carries only JSON-RPC.** Every write goes through this one process, so the
  ndjson stream never interleaves. Prompt Tasks never touch stdout directly — they call
  `emit/2`. Diagnostics go to stderr. The caller (`run/0`) redirects `Logger` to stderr
  before starting so no log line corrupts the stream.

  ## stdin

  A dedicated reader process blocks on `IO.read(io, :line)` and forwards `{:line, l}` /
  `:eof` / `{:io_error, r}` to this server, so the server mailbox is never blocked on raw
  stdin. `run/0` explicitly configures stdio as Unicode because GUI launchers can start
  Pixir without a UTF-8 locale; ACP wire text must remain UTF-8 regardless of the parent
  process environment. On EOF the server stops normally and `run/0` unblocks (exit 0).

  ## Scope

  Implements `initialize`, `session/new`, `session/prompt`, `session/cancel`,
  `authenticate` + `logout` (ACP handshake no-ops; Pixir advertises terminal
  auth through `pixir login`, and owns Credential storage outside the stdio channel),
  `session/set_mode` + `session/set_config_option` (modes, models, and reasoning effort,
  D.2), `session/set_model` (legacy Pixir/T3 compatibility), and `session/load` + `session/resume`
  (lifecycle, A.6); emits `session/update` (incl. `current_mode_update`, `plan`, and the
  additive runtime-driven `config_option_update`, #520) and ORIGINATES `session/request_permission` (interactive permissions,
  A.2 — correlating the client's response against `pending_requests`). Per-turn
  knobs (model, reasoning effort, hosted Web Search, `permission_mode`) ride on
  `session/prompt` `_meta`; sticky model, reasoning-effort, and Web Search
  selections are exposed through `configOptions`; the legacy model catalog +
  auth status ride on `initialize._meta.pixir`.
  Other methods get `-32601`. JSON-RPC errors are reserved for protocol faults; a
  failed Turn is reported as content with `stopReason:"end_turn"` (ADR 0009 §5), and
  the prompt result additionally carries `_meta.pixir.turn_failure` exactly when a
  `turn_failed` event was observed during the prompt. Availability is owned jointly by
  ACP's prompt table and the underlying Session: a terminal update normally remains behind
  a bounded cleanup wait before its PromptResponse, and any residual `:busy` race is an
  explicit `-32602` refusal rather than an empty successful Turn. A stalled Session probe
  or a successor Turn can never hold the ACP Server or the completed request id indefinitely.
  Failure facts are allowlisted: `terminal_status` is one of the current producer
  statuses (`configuration_error`, `provider_error`, `tool_error`, or `interrupted`),
  while `error_kind` is a lower-case ASCII identifier of at most 64 UTF-8 bytes. A
  cleanup `interrupted` classification does not replace earlier non-empty facts from the
  same prompt. Malformed facts are omitted, though an observed `turn_failed` still
  projects an empty facts map so evidence presence is preserved. A refused prompt or
  silent stall claims no failure evidence.
  Permission posture follows the session mode (`plan` → read-only) and
  `_meta.permission_mode "ask"` (→ interactive approval via the ACP asker).

  ## TODO(presenter-session-id)

  ACP clients already receive the Pixir Session id from `session/new`, but tool/model
  projections can still make the parent id invisible to the assistant text layer. The
  next Presenter slice should expose the parent `pixir_session_id` consistently in
  Pixir-specific `_meta`, tool result raw output, or session/status updates so T3/Zed
  prompts can report it without guessing from child ids. Keep this presentation-only:
  the Log remains authoritative and stdout must remain JSON-RPC only.
  """

  use GenServer

  require Logger

  alias Pixir.ACP.{Protocol, Translate}

  alias Pixir.{
    Compaction,
    Config,
    Conversation,
    Event,
    Paths,
    SessionId,
    SessionSupervisor,
    Skills,
    Subagents
  }

  alias Pixir.Providers.{Registry, ResolvedProviderRequest, ResponsesBackend}

  @protocol_version 1
  @idle_timeout 120_000
  @prompt_admission_probe_timeout_ms 25
  @prompt_cleanup_timeout_ms 1_000
  @prompt_cleanup_poll_ms 5
  @turn_failure_terminal_statuses ~w(configuration_error provider_error tool_error interrupted)
  @max_turn_failure_error_kind_bytes 64
  @turn_failure_error_kind_pattern ~r/\A[a-z][a-z0-9_]*\z/

  # Session modes (epic D.2). A `modeId` is a Pixir Agent ROLE (CONTEXT.md):
  # `build` = full access (execute tools), `plan` = read-only (produce a plan,
  # don't mutate). Ids match T3 Code's alias tables so its `resolveRequestedModeId`
  # finds them (`plan` ∈ plan-aliases; `build` is added to the implement-aliases
  # on the T3 side). `build` is the default.
  @default_mode "build"
  @available_modes [
    %{
      "id" => "build",
      "name" => "Build",
      "description" => "Full access - execute tools to complete the task."
    },
    %{
      "id" => "plan",
      "name" => "Plan",
      "description" => "Read-only - produce a step-by-step plan; do not modify files."
    }
  ]
  @mode_ids ["build", "plan"]

  # `default` means "omit reasoning effort and let the selected provider/model
  # choose". Both built-in providers omit the wire field when effort is unset;
  # neither supplies a Pixir-side effort default.
  @reasoning_effort_ids ~w(default low medium high xhigh)
  @web_search_ids ~w(on off)

  defp meta_web_search(true), do: %{"enabled" => true}
  defp meta_web_search(false), do: false
  defp meta_web_search(%{} = value), do: value
  defp meta_web_search(_value), do: nil

  # ── public API ──────────────────────────────────────────────────────────────

  @doc """
  Blocking entrypoint for `pixir acp`. Redirects `Logger` to stderr, starts a linked
  Server reading `:stdio`, and blocks until the Server stops on EOF. Returns `:ok` so the
  CLI router exits 0.
  """
  @spec run() :: :ok
  def run do
    configure_stdio_encoding()
    redirect_logger_to_stderr()
    {:ok, pid} = start_link(io: :stdio)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp configure_stdio_encoding do
    for device <- [:standard_io, :standard_error] do
      case :io.setopts(device, encoding: :unicode) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Start the Server. Opts:

    * `:io` — the stdio device (default `:stdio`; inject a `StringIO`/pipe in tests).
    * `:provider`, `:provider_opts` — passed through to each Turn (test seam).
    * `:prompt_resolve_hook` — test callback after the bounded Session Turn cleanup wait
      and immediately before prompt resolution.
    * `:prompt_before_cleanup_hook` — test callback after terminal status and before the
      bounded Session cleanup wait.
    * `:compaction_complete` — test seam for the runtime-owned structured compaction
      completion; production uses `Pixir.Compaction.complete/2`.
    * `:name` — optional registered name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc "Emit a `session/update` notification (called by prompt Tasks; serializes writes)."
  @spec emit(GenServer.server(), map()) :: :ok
  def emit(server, update_params) when is_map(update_params) do
    GenServer.cast(server, {:notify, "session/update", update_params})
  end

  @doc "Translate and emit a Pixir Event with server-owned presentation state."
  @spec emit_event(GenServer.server(), binary(), Pixir.Event.t()) :: :ok
  def emit_event(server, acp_sid, event) when is_binary(acp_sid) do
    GenServer.cast(server, {:notify_event, acp_sid, event})
  end

  @doc """
  Feed one already-decoded JSON-RPC line into the Server. Test seam that drives the same
  `handle_info({:line, _})` path the reader uses, without real stdio.
  """
  @spec feed(GenServer.server(), binary()) :: :ok
  def feed(server, line) when is_binary(line) do
    send(server, {:line, line})
    :ok
  end

  @doc """
  Apply a runtime-owned config change for one ACP session and push it to the
  client without any client round-trip (#520). After validating and storing the
  new sticky value(s), the Server emits ONE `session/update` carrying
  `sessionUpdate: "config_option_update"` with the COMPLETE `configOptions`
  list reflecting the new values (ACP: an update replaces the advertised set).
  A runtime mode change additionally emits the existing additive
  `current_mode_update`, mirroring the client-driven `session/set_mode` path.

  `changes` maps any of `"mode"`, `"model"`, or `"reasoning_effort"` to its new
  id. Invalid entries are dropped with a stderr warning; unknown sessions are
  ignored (diagnostics to stderr; stdout stays JSON-RPC only). Returns
  `{:ok, :queued}` when the change was handed to the Server, or a structured
  `{:error, %{kind: :invalid_args}}` for malformed arguments. Presenter
  plumbing only — the Log remains authoritative. The live plan→build producer
  is `Pixir.ACP.RuntimeMode.leave_plan/1`, called from `update_plan`.
  """
  @spec runtime_config_change(GenServer.server(), binary(), map()) ::
          {:ok, :queued} | {:error, %{kind: :invalid_args, details: map()}}
  def runtime_config_change(server, acp_sid, changes)
      when is_binary(acp_sid) and is_map(changes) do
    GenServer.cast(server, {:runtime_config_change, acp_sid, changes})
    {:ok, :queued}
  end

  def runtime_config_change(_server, _acp_sid, _changes),
    do:
      {:error,
       %{kind: :invalid_args, details: %{"expected" => "binary session id and changes map"}}}

  @doc """
  Originate a `session/request_permission` request to the client and BLOCK until
  the client responds (A.2). Returns the raw `RequestPermissionResponse` result
  (a map) for `Translate.permission_outcome/1` to interpret, or `{:error, reason}`.

  Called from inside the Executor's Task (the Turn's tool loop), so blocking here
  blocks only that one Task — never the Server GenServer (which keeps writing and
  reading lines, including the eventual response). The Server owns the timeout and
  removes the pending request if a silent client never replies.
  """
  @spec request_permission(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def request_permission(server, params) when is_map(params) do
    GenServer.call(
      server,
      {:client_request, "session/request_permission", params},
      @idle_timeout + 1_000
    )
  catch
    :exit, reason -> {:error, {:request_failed, reason}}
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    io = Keyword.get(opts, :io, :stdio)

    state = %{
      # The stdout writer device. Defaults to the shared `:io` device; tests inject a
      # separate capture device while driving input through `feed/2`.
      out: Keyword.get(opts, :out, io),
      # acp_session_id => pixir_session_id (1:1; identity for v1, but kept as a map so a
      # future non-identity mapping is purely additive).
      sessions: %{},
      # acp_session_id => absolute workspace path. Presentation-only translators use
      # this to resolve relative tool paths into ACP locations without guessing from
      # prose or leaking paths outside the active workspace.
      workspaces: %{},
      # acp_session_id => current mode id ("build" | "plan"), epic D.2. A parallel
      # map (not enriching `sessions` values) to keep existing lookups untouched.
      modes: %{},
      # Durable permission posture restored by session/load or session/resume.
      # Absent entries are ordinary ACP-created sessions; present entries are
      # restrict-never-widen pins for every later prompt.
      resume_postures: %{},
      # acp_session_id => sticky model id (epic A.3). A parallel map like `modes`.
      # An ABSENT entry means "use Pixir's own resolution" (config/env/default);
      # a present entry is the per-session fallback when `session/prompt`'s
      # per-turn `_meta.model` is absent. Validated against the catalog at
      # set-time, so it never hits the per-turn `unknown model` rejection.
      session_models: %{},
      # acp_session_id => sticky reasoning effort. Mirrors `session_models`:
      # an absent entry defers to Config.reasoning_effort/0, while `"default"`
      # deliberately suppresses that config fallback so the provider omits its
      # reasoning-effort field.
      session_efforts: %{},
      # acp_session_id => sticky hosted Web Search preference (`"on"` | `"off"`).
      # This is Presenter-owned, in-memory Session state: it is projected into
      # provider_opts only when a new Turn starts and is never written to History.
      session_web_search: %{},
      # Stable Pixir subagent presentation items already created on the ACP wire.
      # Subsequent lifecycle events for the same subagent become updates, avoiding
      # duplicate items in clients that treat toolCallId creation as unique.
      presented_subagents: MapSet.new(),
      # pixir_sid => %{id: request_id, task: pid, cancel?: boolean}
      prompts: %{},
      # Outbound agent→client requests Pixir originates (A.2,
      # `session/request_permission`). `out_id` is a monotonic counter; outbound
      # ids are NEGATIVE so they can never collide with the client's own request
      # ids (which Pixir only ever reads, never mints). `pending_requests` maps an
      # out_id to the blocked caller (the Executor Task) plus its server-owned
      # timeout, replied when the matching response line arrives or the timer fires.
      out_id: 0,
      pending_requests: %{},
      request_timeout_ms: Keyword.get(opts, :request_timeout_ms, @idle_timeout),
      prompt_idle_timeout_ms: Keyword.get(opts, :prompt_idle_timeout_ms, @idle_timeout),
      prompt_cleanup_timeout_ms:
        Keyword.get(opts, :prompt_cleanup_timeout_ms, @prompt_cleanup_timeout_ms),
      # Test seam after terminal status but before the bounded cleanup wait. It lets race
      # tests install a successor Turn deterministically; production keeps it a no-op.
      prompt_before_cleanup_hook: Keyword.get(opts, :prompt_before_cleanup_hook, fn -> :ok end),
      # Test seam after a terminal status and the bounded Session cleanup wait, but
      # immediately before the Server synchronizes the wire reply. Tests can drive both
      # cancel/terminal orders without timing sleeps; the ordinary path observes the prior
      # Turn as cleared, while the bounded wait cannot be wedged by a successor Turn.
      prompt_resolve_hook: Keyword.get(opts, :prompt_resolve_hook, fn _outcome -> :ok end),
      compaction_complete: Keyword.get(opts, :compaction_complete, &Compaction.complete/2),
      provider: Keyword.get(opts, :provider),
      provider_opts: Keyword.get(opts, :provider_opts, []),
      tool_calls: %{},
      deleted_sessions: MapSet.new(),
      titles: %{},
      # acp_session_id => fingerprint of the last available command list emitted.
      # The command list is presenter state; Skills are rediscovered lazily at
      # lifecycle and prompt boundaries rather than watched or polled.
      command_fingerprints: %{}
    }

    # In tests, `reader: false` skips the stdin reader and lines are driven via `feed/2`.
    if Keyword.get(opts, :reader, true), do: start_reader(io, self())
    {:ok, state}
  end

  # A decoded ndjson line (from the reader or the test `feed/2` seam).
  @impl true
  def handle_info({:line, raw}, state) do
    line = String.trim_trailing(raw, "\n")

    if String.trim(line) == "" do
      {:noreply, state}
    else
      {:noreply, dispatch(Protocol.decode(line), state)}
    end
  end

  def handle_info(:eof, state), do: {:stop, :normal, state}

  def handle_info({:io_error, reason}, state) do
    Logger.error("acp: stdin read error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:pending_request_timeout, out_id}, state) do
    case Map.pop(state.pending_requests, out_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from}, rest} ->
        GenServer.reply(from, {:error, {:request_timed_out, out_id}})
        {:noreply, %{state | pending_requests: rest}}
    end
  end

  def handle_info(
        {:deferred_available_commands, acp_sid, commands, fingerprint},
        state
      ) do
    if Map.get(state.command_fingerprints, acp_sid) == fingerprint do
      write_available_commands(state.out, acp_sid, commands)
    end

    {:noreply, state}
  end

  def handle_info({:deferred_title_update, acp_sid, title}, state) do
    write_title_update(state.out, acp_sid, title)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:notify, method, params}, state) do
    write(state.out, Protocol.notification(method, params))
    {:noreply, state}
  end

  def handle_cast({:notify_event, acp_sid, event}, state) do
    {params, state} = translate_update(event, acp_sid, state)

    if params do
      write(state.out, Protocol.notification("session/update", params))
    end

    {:noreply, state}
  end

  def handle_cast({:runtime_config_change, acp_sid, changes}, state) do
    {:noreply, apply_runtime_config_change(state, acp_sid, changes)}
  end

  # ── dispatch ────────────────────────────────────────────────────────────────

  defp dispatch({:request, id, method, params}, state) do
    handle_request(method, params, id, state)
  end

  defp dispatch({:notification, method, params}, state) do
    handle_notification(method, params, state)
  end

  defp dispatch({:error, {_kind, code, message}}, state) do
    # Parse / invalid-request faults have no recoverable id.
    write(state.out, Protocol.error(nil, code, message))
    state
  end

  # Responses to outbound requests Pixir originated (A.2): correlate against
  # `pending_requests` and reply the blocked caller. A success unblocks with
  # `{:ok, result}`; an error response with `{:error, error}`. An unmatched id
  # (e.g. a late response after a timeout already unblocked the caller) is
  # dropped.
  defp dispatch({:response, id, result}, state), do: resolve_pending(state, id, {:ok, result})

  defp dispatch({:response_error, id, error}, state),
    do: resolve_pending(state, id, {:error, error})

  defp dispatch({:ignore, _id}, state), do: state

  # ── requests ────────────────────────────────────────────────────────────────

  defp handle_request("initialize", params, id, state) do
    log_client_info(params)

    result = %{
      "protocolVersion" => @protocol_version,
      "agentCapabilities" => %{
        # Pixir supports session/load + session/resume (epic A.6) — the core
        # already re-derives History from the on-disk Log (ADR 0003).
        "loadSession" => true,
        "promptCapabilities" => %{
          "image" => true,
          "audio" => false,
          "embeddedContext" => false
        },
        "sessionCapabilities" => %{
          "resume" => %{},
          "list" => %{},
          "close" => %{},
          "delete" => %{}
        }
      },
      "agentInfo" => %{"name" => "pixir", "version" => Pixir.version()},
      "authMethods" => terminal_auth_methods(),
      # Pixir-specific auth/model metadata remains namespaced in ACP's `_meta`
      # extension slot. Canonical model selection is also exposed through the
      # `configOptions` model selector returned by session setup responses.
      "_meta" => %{"pixir" => pixir_meta()}
    }

    write(state.out, Protocol.result(id, result))
    state
  end

  defp handle_request("authenticate", _params, id, state) do
    write(state.out, Protocol.result(id, %{}))
    state
  end

  defp handle_request("logout", _params, id, state) do
    write(state.out, Protocol.result(id, %{}))
    state
  end

  defp handle_request("session/new", params, id, state) do
    case Map.get(params, "cwd") do
      cwd when is_binary(cwd) and cwd != "" ->
        if Path.type(cwd) == :absolute,
          do: new_session(cwd, id, state),
          else: invalid_cwd(id, state)

      _ ->
        invalid_cwd(id, state)
    end
  end

  defp handle_request("session/list", params, id, state) do
    list_sessions(params || %{}, id, state)
  end

  defp handle_request("session/delete", params, id, state) do
    delete_session(params || %{}, id, state)
  end

  defp handle_request("session/close", params, id, state) do
    close_session(params || %{}, id, state)
  end

  defp handle_request("session/prompt", params, id, state) do
    with acp_sid when is_binary(acp_sid) <- Map.get(params, "sessionId"),
         pixir_sid when is_binary(pixir_sid) <- Map.get(state.sessions, acp_sid),
         cwd when is_binary(cwd) <- Map.get(state.workspaces, acp_sid) do
      state = maybe_emit_available_commands(state, acp_sid, cwd)
      start_prompt(acp_sid, pixir_sid, params, id, state)
    else
      _ ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "unknown session"))
        state
    end
  end

  # Spec-pure mode switch (Zed et al.): `session/set_mode {sessionId, modeId}`.
  # `SetSessionModeResponse` is an empty/`_meta`-only object.
  defp handle_request("session/set_mode", params, id, state) do
    set_mode(Map.get(params, "modeId"), params, id, state, :mode_response)
  end

  # The T3 Code runtime drives modes via `session/set_config_option {sessionId,
  # configId:"mode", value}` — honor it too (decision #4: both → one handler).
  # `SetSessionConfigOptionResponse` REQUIRES the full `configOptions` list
  # (with current values), not an empty object — hence the distinct reply shape.
  defp handle_request("session/set_config_option", params, id, state) do
    case Map.get(params, "configId") do
      "mode" ->
        set_mode(Map.get(params, "value"), params, id, state, :config_response)

      "model" ->
        set_model(Map.get(params, "value"), params, id, state, :config_response)

      "reasoning_effort" ->
        set_reasoning_effort(Map.get(params, "value"), params, id, state)

      "web_search" ->
        set_web_search(Map.get(params, "value"), params, id, state)

      other ->
        unknown_config_option(id, state, other)
    end
  end

  # Legacy Pixir/T3 compatibility extension: ACP v1's canonical model selector
  # is `session/set_config_option {configId:"model", value}`. Keep
  # `session/set_model {sessionId, modelId}` so existing local adapters continue
  # to work while new clients can use configOptions.
  defp handle_request("session/set_model", params, id, state) do
    set_model(Map.get(params, "modelId"), params, id, state, :model_response)
  end

  # Reattach to a persisted session, replaying its History (epic A.6).
  defp handle_request("session/load", params, id, state) do
    with sid when is_binary(sid) and sid != "" <- Map.get(params, "sessionId"),
         cwd when is_binary(cwd) and cwd != "" <- Map.get(params, "cwd"),
         :absolute <- Path.type(cwd) do
      load_session(sid, cwd, id, state)
    else
      _ ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "sessionId and cwd required")
        )

        state
    end
  end

  # Reattach without replaying History (the lighter cousin of load).
  defp handle_request("session/resume", params, id, state) do
    with sid when is_binary(sid) and sid != "" <- Map.get(params, "sessionId"),
         cwd when is_binary(cwd) and cwd != "" <- Map.get(params, "cwd"),
         :absolute <- Path.type(cwd) do
      resume_session(sid, cwd, id, state)
    else
      _ ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "sessionId and cwd required")
        )

        state
    end
  end

  defp handle_request(_method, _params, id, state) do
    write(state.out, Protocol.error(id, Protocol.method_not_found(), "method not found"))
    state
  end

  # ── notifications ─────────────────────────────────────────────────────────

  defp handle_notification("session/cancel", params, state) do
    acp_sid = Map.get(params, "sessionId")
    pixir_sid = is_binary(acp_sid) && Map.get(state.sessions, acp_sid)

    if is_binary(pixir_sid) do
      Conversation.interrupt(pixir_sid)
      mark_cancel(state, pixir_sid)
    else
      # Notifications get no reply; an unknown session is logged and dropped.
      Logger.warning("acp: session/cancel for unknown session #{inspect(acp_sid)}")
      state
    end
  end

  defp handle_notification(_method, _params, state), do: state

  # ── session mode helpers (D.2) ───────────────────────────────────────────────

  # Validate the session + mode id, store the new mode, reply (shape depends on
  # the calling method, `reply_kind`), and emit a `current_mode_update` so the
  # client confirms the switch on the wire. An unknown session or unknown mode id
  # is `-32602` (mirrors session/prompt).
  defp set_mode(mode_id, params, id, state, reply_kind) do
    acp_sid = Map.get(params, "sessionId")

    cond do
      not (is_binary(acp_sid) and Map.has_key?(state.sessions, acp_sid)) ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "unknown session"))
        state

      mode_id not in @mode_ids ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "unknown mode", %{"mode" => mode_id})
        )

        state

      true ->
        # `SetSessionModeResponse` is empty; `SetSessionConfigOptionResponse`
        # REQUIRES the full `configOptions` list reflecting the new value.
        result =
          case reply_kind do
            :mode_response ->
              %{}

            :config_response ->
              %{
                "configOptions" =>
                  config_options(
                    mode_id,
                    current_model(state, acp_sid),
                    current_effort(state, acp_sid),
                    current_web_search(state, acp_sid)
                  )
              }
          end

        write(state.out, Protocol.result(id, result))

        emit(self(), %{
          "sessionId" => acp_sid,
          "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
        })

        %{state | modes: Map.put(state.modes, acp_sid, mode_id)}
    end
  end

  # Validate and store a sticky session model. ACP v1 clients should call this
  # through `session/set_config_option`; `session/set_model` is retained as a
  # Pixir/T3 compatibility extension.
  defp set_model(model_id, params, id, state, reply_kind) do
    acp_sid = Map.get(params, "sessionId")

    cond do
      not (is_binary(acp_sid) and Map.has_key?(state.sessions, acp_sid)) ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "unknown session"))
        state

      not (is_binary(model_id) and Registry.model_supported?(model_id)) ->
        # Mirror start_prompt's per-turn rejection: an id outside the advertised
        # catalog (`Registry.model_supported?/1`) is `-32602` with the
        # offending id in `data.model`. Validating here means the stored sticky
        # model never trips the per-turn rejection later.
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "unknown model", %{"model" => model_id})
        )

        state

      true ->
        result =
          case reply_kind do
            :model_response ->
              %{}

            :config_response ->
              %{
                "configOptions" =>
                  config_options(
                    current_mode(state, params),
                    model_id,
                    current_effort(state, acp_sid),
                    current_web_search(state, acp_sid, model: model_id)
                  )
              }
          end

        write(state.out, Protocol.result(id, result))
        %{state | session_models: Map.put(state.session_models, acp_sid, model_id)}
    end
  end

  # Validate and store a sticky per-session reasoning effort. The `"default"`
  # value is an honest explicit state: providers omit their effort field and let
  # the selected model choose, rather than Pixir inventing a default effort.
  defp set_reasoning_effort(effort_id, params, id, state) do
    acp_sid = Map.get(params, "sessionId")

    cond do
      not (is_binary(acp_sid) and Map.has_key?(state.sessions, acp_sid)) ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "unknown session"))
        state

      effort_id not in @reasoning_effort_ids ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "unknown config option value", %{
            "configId" => "reasoning_effort",
            "value" => effort_id
          })
        )

        state

      true ->
        result = %{
          "configOptions" =>
            config_options(
              current_mode(state, params),
              current_model(state, acp_sid),
              effort_id,
              current_web_search(state, acp_sid)
            )
        }

        write(state.out, Protocol.result(id, result))
        %{state | session_efforts: Map.put(state.session_efforts, acp_sid, effort_id)}
    end
  end

  # Validate and store a sticky hosted Web Search preference. `off` is always
  # valid; `on` is accepted only when the currently selected Provider/backend
  # can honor it. The runtime still owns request validation and shaping — ACP
  # stores only the preference that will be threaded into the next Turn.
  defp set_web_search(value, params, id, state) do
    acp_sid = Map.get(params, "sessionId")

    cond do
      not (is_binary(acp_sid) and Map.has_key?(state.sessions, acp_sid)) ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "unknown session"))
        state

      value not in @web_search_ids ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "unknown config option value", %{
            "configId" => "web_search",
            "value" => value
          })
        )

        state

      value == "on" ->
        case resolve_web_search_context(state, acp_sid) do
          {:ok, resolved} ->
            if web_search_supported?(resolved) do
              write_web_search_config_result(state, acp_sid, id, value)
            else
              write_unsupported_web_search(state, id, resolved)
            end

          {:error, error} ->
            write(
              state.out,
              Protocol.error(id, Protocol.invalid_params(), "web_search is unavailable", %{
                "configId" => "web_search",
                "value" => value,
                "reason" => provider_selection_error_reason(error)
              })
            )

            state
        end

      true ->
        write_web_search_config_result(state, acp_sid, id, value)
    end
  end

  defp write_web_search_config_result(state, acp_sid, id, value) do
    result = %{
      "configOptions" =>
        config_options(
          Map.get(state.modes, acp_sid, @default_mode),
          current_model(state, acp_sid),
          current_effort(state, acp_sid),
          value
        )
    }

    write(state.out, Protocol.result(id, result))
    %{state | session_web_search: Map.put(state.session_web_search, acp_sid, value)}
  end

  defp write_unsupported_web_search(state, id, resolved) do
    write(
      state.out,
      Protocol.error(id, Protocol.invalid_params(), "web_search is not supported", %{
        "configId" => "web_search",
        "value" => "on",
        "reason" => "unsupported_backend",
        "provider" => resolved_provider_name(resolved),
        "backend" => resolved_backend_name(resolved)
      })
    )

    state
  end

  defp provider_selection_error_reason(%{error: %{kind: kind}}) when is_atom(kind),
    do: Atom.to_string(kind)

  defp provider_selection_error_reason(_error), do: "invalid_provider_selection"

  defp unknown_config_option(id, state, config_id) do
    write(
      state.out,
      Protocol.error(id, Protocol.invalid_params(), "unknown config option", %{
        "configId" => config_id
      })
    )

    state
  end

  # ── runtime-owned config changes (#520) ──────────────────────────────────────

  # The runtime (not the client) changed a knob. Validate + store each change,
  # then emit ONE additive `config_option_update` carrying the complete
  # `configOptions` list so presenters hear agent-initiated switches without a
  # client round-trip. A mode change also emits `current_mode_update` for
  # parity with the client-driven `session/set_mode` path. Invalid entries are
  # dropped with a stderr warning; nothing invalid is ever advertised.
  defp apply_runtime_config_change(state, acp_sid, changes) do
    cond do
      not Map.has_key?(state.sessions, acp_sid) ->
        # Fixed messages only: caller-supplied ids/values never enter stderr.
        Logger.warning("acp: runtime config change for unknown session")
        state

      true ->
        {state, applied, mode_changed?} =
          Enum.reduce(changes, {state, _applied = [], _mode_changed? = false}, fn
            {"mode", mode_id}, {st, applied, mode_changed?} when mode_id in @mode_ids ->
              if Map.get(st.modes, acp_sid, @default_mode) == mode_id do
                {st, applied, mode_changed?}
              else
                {%{st | modes: Map.put(st.modes, acp_sid, mode_id)}, [:mode | applied], true}
              end

            {"model", model_id}, {st, applied, mode_changed?}
            when is_binary(model_id) and model_id != "" ->
              if Registry.model_supported?(model_id) do
                {%{st | session_models: Map.put(st.session_models, acp_sid, model_id)},
                 [:model | applied], mode_changed?}
              else
                Logger.warning("acp: runtime config change rejected unknown model")

                {st, applied, mode_changed?}
              end

            {"reasoning_effort", effort}, {st, applied, mode_changed?}
            when effort in @reasoning_effort_ids ->
              {%{st | session_efforts: Map.put(st.session_efforts, acp_sid, effort)},
               [:reasoning_effort | applied], mode_changed?}

            {_key, _value}, acc ->
              Logger.warning("acp: ignoring unsupported runtime config change")

              acc
          end)

        if applied == [] do
          state
        else
          if mode_changed? do
            emit(self(), %{
              "sessionId" => acp_sid,
              "update" => %{
                "sessionUpdate" => "current_mode_update",
                "currentModeId" => Map.get(state.modes, acp_sid, @default_mode)
              }
            })
          end

          opts =
            config_options(
              Map.get(state.modes, acp_sid, @default_mode),
              current_model(state, acp_sid),
              current_effort(state, acp_sid),
              current_web_search(state, acp_sid)
            )

          emit(self(), %{
            "sessionId" => acp_sid,
            "update" => %{"sessionUpdate" => "config_option_update", "configOptions" => opts}
          })

          state
        end
    end
  end

  # The current mode for the session named in `params` (default `@default_mode`).
  defp current_mode(state, params) do
    Map.get(state.modes, Map.get(params, "sessionId"), @default_mode)
  end

  # Current effort uses the per-session sticky selection first, then Pixir's
  # effective config. With neither set, both providers omit the wire field, so
  # the truthful ACP value is the explicit `default` option.
  defp current_effort(state, acp_sid) do
    case Map.fetch(state.session_efforts, acp_sid) do
      {:ok, effort} -> effort
      :error -> Config.reasoning_effort() || "default"
    end
  end

  # The displayed Web Search value is effective for the currently selected
  # Provider/backend. A sticky `on` preference becomes `off` while an unsupported
  # model/backend is selected, and becomes `on` again if the Session returns to a
  # supported selection. With no sticky preference, the late-bound runtime
  # default/config value from #523-B is projected through the same resolved seam.
  defp current_web_search(state, acp_sid, opts \\ []) do
    case resolve_web_search_context(state, acp_sid, opts) do
      {:ok, resolved} ->
        if web_search_supported?(resolved) do
          state
          |> effective_web_search_provider_opts(acp_sid, opts)
          |> then(&ResolvedProviderRequest.attach_to_provider_opts(resolved, &1))
          |> Keyword.get(:web_search)
          |> web_search_enabled?()
          |> on_off()
        else
          "off"
        end

      {:error, _error} ->
        "off"
    end
  end

  defp resolve_web_search_context(state, acp_sid, opts \\ []) do
    model = Keyword.get(opts, :model, current_model(state, acp_sid))

    selection = %{
      provider_intent: if(state.provider, do: {:explicit, state.provider}, else: :auto),
      request: %{},
      provider_opts: state.provider_opts |> List.wrap() |> Keyword.put(:model, model)
    }

    Registry.resolve_request(selection)
  end

  defp effective_web_search_provider_opts(state, acp_sid, opts) do
    model = Keyword.get(opts, :model, current_model(state, acp_sid))
    provider_opts = state.provider_opts |> List.wrap() |> Keyword.put(:model, model)

    case Map.get(state.session_web_search, acp_sid) do
      "on" -> Keyword.put(provider_opts, :web_search, %{"enabled" => true})
      "off" -> Keyword.put(provider_opts, :web_search, false)
      nil -> provider_opts
    end
  end

  defp web_search_supported?(resolved) do
    case {
      ResolvedProviderRequest.dialect(resolved),
      ResolvedProviderRequest.responses_backend(resolved)
    } do
      {:responses, %ResponsesBackend{} = backend} ->
        ResponsesBackend.mode(backend) == :chatgpt_codex

      _other ->
        false
    end
  end

  defp web_search_enabled?(nil), do: false
  defp web_search_enabled?(false), do: false
  defp web_search_enabled?(%{"enabled" => false}), do: false
  defp web_search_enabled?(%{enabled: false}), do: false
  defp web_search_enabled?(_value), do: true

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"

  defp resolved_provider_name(resolved) do
    resolved
    |> ResolvedProviderRequest.dialect()
    |> Atom.to_string()
  end

  defp resolved_backend_name(resolved) do
    case ResolvedProviderRequest.responses_backend(resolved) do
      %ResponsesBackend{} = backend -> backend |> ResponsesBackend.mode() |> Atom.to_string()
      :not_applicable -> "not_applicable"
    end
  end

  # The full `configOptions` list (D.2). Selectors are the canonical ACP
  # surfaces for sticky per-session preferences; legacy compatibility fields and
  # methods remain separate from this complete list.
  defp config_options(current_mode, current_model, current_effort, current_web_search) do
    [
      mode_config_option(current_mode),
      model_config_option(current_model),
      reasoning_effort_config_option(current_effort),
      web_search_config_option(current_web_search)
    ]
  end

  # The `mode` select config option mirrored into `session/new` so the runtime's
  # set_config_option dedup knows the current value (D.2).
  defp mode_config_option(current) do
    %{
      "id" => "mode",
      "name" => "Mode",
      "type" => "select",
      "currentValue" => current,
      "category" => "mode",
      # Each select option is `{name, value}` per ACP's SessionConfigSelectOption
      # (NOT `{id, name}` — `value` is the id echoed back on set_config_option).
      "options" =>
        Enum.map(@available_modes, fn m -> %{"name" => m["name"], "value" => m["id"]} end)
    }
  end

  defp model_config_option(current) do
    %{
      "id" => "model",
      "name" => "Model",
      "description" => "Pixir provider model for this session.",
      "category" => "model",
      "type" => "select",
      "currentValue" => current || default_model_id(),
      "options" =>
        Enum.map(Registry.models(), fn model ->
          %{"name" => model["name"], "value" => model["id"]}
        end)
    }
  end

  defp reasoning_effort_config_option(current) do
    %{
      "id" => "reasoning_effort",
      "name" => "Reasoning effort",
      "description" => "Reasoning effort for this session; default lets the provider choose.",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" => current,
      "options" =>
        Enum.map(@reasoning_effort_ids, fn effort ->
          %{"name" => effort, "value" => effort}
        end)
    }
  end

  defp web_search_config_option(current) do
    %{
      "id" => "web_search",
      "name" => "Web search",
      "description" => "Provider-hosted web search for the next Turn.",
      "category" => "capabilities",
      "type" => "select",
      "currentValue" => current,
      "options" => [
        %{"name" => "On", "value" => "on"},
        %{"name" => "Off", "value" => "off"}
      ]
    }
  end

  # ── initialize `_meta` helpers ───────────────────────────────────────────────

  defp terminal_auth_methods do
    [
      %{
        "id" => "pixir-login",
        "name" => "Pixir login",
        "description" => "Sign in to Pixir in a terminal before starting ACP.",
        "type" => "terminal",
        "args" => ["login"]
      }
    ]
  end

  # The `_meta.pixir` block: the model catalog (A.5) plus auth status (A.4),
  # under one namespace so a client reads everything Pixir-specific in one place.
  defp pixir_meta do
    base = %{"models" => Registry.models()}

    case auth_meta() do
      nil -> base
      auth -> Map.put(base, "auth", auth)
    end
  end

  # A point-in-time, string-keyed snapshot of `Pixir.Auth.status/0` for the ACP
  # `_meta` slot (A.4). Defensive: the Auth GenServer may not be running in a
  # bare test harness, so probe `whereis` first and omit the block on any
  # failure rather than crashing the stdio transport. Status is informational —
  # a later login won't update it without a fresh session (acceptable for v1).
  defp auth_meta do
    if Process.whereis(Pixir.Auth) do
      try do
        normalize_auth(Pixir.Auth.status())
      catch
        _, _ -> nil
      end
    end
  end

  defp normalize_auth(%{authenticated?: authed} = status) do
    %{"authenticated" => authed}
    |> put_some("kind", status[:kind] && to_string(status[:kind]))
    |> put_some("account_id", status[:account_id])
    |> put_some("expires_at", status[:expires_at])
    |> put_some("expired", status[:expired?])
  end

  defp normalize_auth(_other), do: nil

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # ── session/new helper ──────────────────────────────────────────────────────

  # A `cwd` that is absent, empty, or relative is rejected — the workspace must
  # be an absolute path (the message and the guard now agree).
  defp invalid_cwd(id, state) do
    write(
      state.out,
      Protocol.error(id, Protocol.invalid_params(), "cwd must be an absolute path")
    )

    state
  end

  defp new_session(cwd, id, state) do
    case Conversation.start(workspace: cwd) do
      {:ok, pixir_sid} ->
        # 1:1 identity mapping: the ACP sessionId is the Pixir session id.
        acp_sid = pixir_sid

        current_model = current_model(state, acp_sid)

        write(
          state.out,
          Protocol.result(
            id,
            session_setup_result(
              acp_sid,
              current_model,
              current_effort(state, acp_sid),
              current_web_search(state, acp_sid, model: current_model)
            )
          )
        )

        state
        |> register_session(acp_sid, pixir_sid, cwd)
        |> schedule_available_commands(acp_sid, cwd)

      {:error, error} ->
        write_start_error(state.out, id, error)
        state
    end
  end

  # The shared setup payload for session/new, session/load, and session/resume:
  # the sessionId plus advertised modes and config options. The current values
  # are effective at the setup boundary; sticky selections are retained when
  # the same server reattaches. The `models` field is a legacy Pixir/T3
  # compatibility extension; canonical ACP clients should read `configOptions`.
  defp session_setup_result(acp_sid, current_model, current_effort, current_web_search) do
    %{
      "sessionId" => acp_sid,
      "modes" => %{
        "currentModeId" => @default_mode,
        "availableModes" => @available_modes
      },
      "models" => models_state(current_model),
      "configOptions" =>
        config_options(@default_mode, current_model, current_effort, current_web_search)
    }
  end

  # Legacy Pixir/T3 model metadata: `currentModelId` + `availableModels`, each
  # with `modelId`/`name` (NOT `id`/`name` — the wire field is `modelId`).
  # Sourced from `Pixir.Provider.models/0`.
  defp models_state(current_model) do
    %{
      "currentModelId" => current_model,
      "availableModels" =>
        Enum.map(Registry.models(), fn m ->
          %{"modelId" => m["id"], "name" => m["name"]}
        end)
    }
  end

  # The current model to advertise for an existing session: sticky selection
  # first, then the server's injected/base Provider selection, then Pixir's
  # default. Sticky selections are in-memory and are not persisted.
  defp current_model(state, acp_sid) do
    Map.get(state.session_models, acp_sid) ||
      Keyword.get(List.wrap(state.provider_opts), :model) ||
      default_model_id()
  end

  # Pixir's default model id, advertised as `currentModelId` at session/new.
  defp default_model_id do
    case Enum.find(Registry.models(), & &1["default"]) do
      %{"id" => id} -> id
      _ -> nil
    end
  end

  defp register_session(state, acp_sid, pixir_sid, cwd, posture \\ nil) do
    state = %{
      state
      | sessions: Map.put(state.sessions, acp_sid, pixir_sid),
        workspaces: Map.put(state.workspaces, acp_sid, cwd),
        modes: Map.put(state.modes, acp_sid, @default_mode),
        command_fingerprints: Map.delete(state.command_fingerprints, acp_sid)
    }

    if posture do
      %{state | resume_postures: Map.put(state.resume_postures, acp_sid, posture)}
    else
      %{state | resume_postures: Map.delete(state.resume_postures, acp_sid)}
    end
  end

  defp write_start_error(out, id, %{error: %{kind: kind, message: message}}) do
    write(
      out,
      Protocol.error(id, Protocol.internal_error(), message, %{"kind" => to_string(kind)})
    )
  end

  # Defense in depth: any non-structured error shape must not crash the stdio
  # transport (a CaseClauseError here would kill the ACP stream).
  defp write_start_error(out, id, other) do
    write(
      out,
      Protocol.error(id, Protocol.internal_error(), "could not start session", %{
        "error" => inspect(other)
      })
    )
  end

  # ── session/list + close + delete helpers ───────────────────────────────────

  defp list_sessions(params, id, state) do
    cwd = Map.get(params, "cwd")
    cursor = Map.get(params, "cursor")
    limit = Map.get(params, "limit", 50)

    cond do
      is_binary(cwd) and Path.type(cwd) != :absolute ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "cwd must be absolute"))
        state

      not (is_nil(cursor) or (is_binary(cursor) and String.starts_with?(cursor, "offset:"))) ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "invalid cursor"))
        state

      true ->
        offset = cursor_offset(cursor)

        if offset < 0 do
          write(state.out, Protocol.error(id, Protocol.invalid_params(), "invalid cursor"))
          state
        else
          roots = if is_binary(cwd), do: [cwd], else: known_workspaces(state)

          sessions =
            roots
            |> Enum.flat_map(&session_summaries(&1, state))
            |> Enum.reject(&MapSet.member?(state.deleted_sessions, &1["sessionId"]))
            |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)

          limit = if is_integer(limit) and limit > 0, do: min(limit, 100), else: 50
          page = Enum.slice(sessions, offset, limit)
          next_offset = offset + length(page)
          result = %{"sessions" => page}

          result =
            if next_offset < length(sessions),
              do: Map.put(result, "cursor", "offset:#{next_offset}"),
              else: result

          write(state.out, Protocol.result(id, result))
          state
        end
    end
  end

  defp close_session(params, id, state) do
    acp_sid = Map.get(params, "sessionId")

    case Map.get(state.sessions, acp_sid) do
      nil ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "unknown session"))
        state

      pixir_sid ->
        Conversation.interrupt(pixir_sid)
        SessionSupervisor.stop_session(pixir_sid)
        write(state.out, Protocol.result(id, %{}))
        forget_session(state, acp_sid, pixir_sid)
    end
  end

  defp forget_session(state, acp_sid, pixir_sid) do
    %{
      state
      | sessions: Map.delete(state.sessions, acp_sid),
        workspaces: Map.delete(state.workspaces, acp_sid),
        modes: Map.delete(state.modes, acp_sid),
        prompts: Map.delete(state.prompts, pixir_sid),
        titles: Map.delete(state.titles, acp_sid),
        session_models: Map.delete(state.session_models, acp_sid),
        session_efforts: Map.delete(state.session_efforts, acp_sid),
        session_web_search: Map.delete(state.session_web_search, acp_sid),
        command_fingerprints: Map.delete(state.command_fingerprints, acp_sid),
        presented_subagents:
          MapSet.reject(state.presented_subagents, fn
            {sid, _subagent_id} -> sid == acp_sid
            _ -> false
          end)
    }
  end

  defp delete_session(params, id, state) do
    sid = Map.get(params, "sessionId")

    cond do
      not is_binary(sid) or sid == "" ->
        write(state.out, Protocol.error(id, Protocol.invalid_params(), "sessionId required"))
        state

      true ->
        case SessionId.validate(sid) do
          {:error, %{error: %{details: details}}} ->
            write_invalid_session_id(state.out, id, details)
            state

          :ok ->
            if Map.has_key?(state.sessions, sid) do
              write(
                state.out,
                Protocol.error(id, Protocol.invalid_params(), "cannot delete active session")
              )

              state
            else
              write(state.out, Protocol.result(id, %{}))
              %{state | deleted_sessions: MapSet.put(state.deleted_sessions, sid)}
            end
        end
    end
  end

  defp cursor_offset(nil), do: 0

  defp cursor_offset("offset:" <> value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> -1
    end
  end

  defp known_workspaces(state), do: state.workspaces |> Map.values() |> Enum.uniq()

  defp session_summaries(cwd, state) do
    dir = Paths.sessions_dir(cwd)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".ndjson"))
        |> Enum.map(fn file -> session_summary(cwd, file, state) end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp session_summary(cwd, file, state) do
    sid = String.replace_suffix(file, ".ndjson", "")

    # Soft-deleted ids still have a Log on disk. Skip them before title lookup so
    # close/forget (which drops the in-memory title cache) cannot crash list on a
    # dead Session. The deleted filter after summaries would be too late.
    if MapSet.member?(state.deleted_sessions, sid) do
      nil
    else
      path = Path.join(Paths.sessions_dir(cwd), file)

      updated =
        case File.stat(path) do
          {:ok, stat} ->
            stat.mtime
            |> NaiveDateTime.from_erl!()
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_iso8601()

          _ ->
            nil
        end

      title = Map.get(state.titles, sid) || title_from_history(sid, cwd)

      %{"sessionId" => sid, "cwd" => cwd}
      |> put_some("title", title)
      |> put_some("updatedAt", updated)
    end
  end

  defp title_from_history(sid, cwd) do
    case Conversation.history(sid) do
      {:ok, history} ->
        title_from_events(history)

      _ ->
        case Pixir.Log.fold(sid, workspace: cwd) do
          {:ok, history} -> title_from_events(history)
          _ -> nil
        end
    end
  end

  defp title_from_events(history) do
    history
    |> Enum.find_value(fn
      %{type: :user_message, data: %{"text" => text}} when is_binary(text) ->
        String.slice(String.trim(text), 0, 80)

      _ ->
        nil
    end)
  end

  defp schedule_available_commands(state, acp_sid, cwd) do
    {:ok, %{skills: skills}} = Skills.discover(cwd)
    commands = available_commands(skills)
    fingerprint = available_commands_fingerprint(commands)

    Process.send_after(
      self(),
      {:deferred_available_commands, acp_sid, commands, fingerprint},
      250
    )

    %{
      state
      | command_fingerprints: Map.put(state.command_fingerprints, acp_sid, fingerprint)
    }
  end

  defp maybe_emit_available_commands(state, acp_sid, cwd) do
    {:ok, %{skills: skills}} = Skills.discover(cwd)
    commands = available_commands(skills)
    fingerprint = available_commands_fingerprint(commands)

    if Map.get(state.command_fingerprints, acp_sid) == fingerprint do
      state
    else
      write_available_commands(state.out, acp_sid, commands)

      %{
        state
        | command_fingerprints: Map.put(state.command_fingerprints, acp_sid, fingerprint)
      }
    end
  end

  defp write_available_commands(out, acp_sid, commands) do
    write(
      out,
      Protocol.notification("session/update", %{
        "sessionId" => acp_sid,
        "update" => %{
          "sessionUpdate" => "available_commands_update",
          "availableCommands" => commands
        }
      })
    )
  end

  defp write_title_update(out, acp_sid, title) do
    write(
      out,
      Protocol.notification("session/update", %{
        "sessionId" => acp_sid,
        "update" => %{
          "sessionUpdate" => "session_info_update",
          "title" => title,
          "_meta" => %{"pixir" => %{"schemaVersion" => 1}}
        }
      })
    )
  end

  # Pure ACP projection of the current Skills index. `compact` is runtime-owned
  # and always wins over a homonymous Skill; `plan` remains a mode, not a command.
  defp available_commands(skills) when is_list(skills) do
    compact = %{
      "name" => "compact",
      "description" => "Record a durable History compaction checkpoint"
    }

    skill_commands =
      skills
      |> Enum.reject(&Map.get(&1, :disable_model_invocation, false))
      |> Enum.reject(&(&1.name in ["compact", "plan"]))
      |> Enum.map(fn skill ->
        %{
          "name" => skill.name,
          "description" => skill.description,
          "input" => %{"hint" => skill.description}
        }
      end)

    [compact | skill_commands]
  end

  defp available_commands_fingerprint(commands) do
    commands
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  # ── session/load + resume helpers (A.6) ──────────────────────────────────────

  # session/load: reattach to a persisted session and REPLAY its History as
  # session/update notifications (so the client repopulates the transcript)
  # before returning the LoadSessionResponse. A missing session is `-32602`.
  defp load_session(acp_sid, cwd, id, state) do
    # Existence check first: Conversation.start yields the :not_found -> -32602
    # contract for an unknown session. Restore the posture only after, so a
    # missing session never surfaces as an internal -32603 from the Log fold.
    if MapSet.member?(state.deleted_sessions, acp_sid) do
      write(
        state.out,
        Protocol.error(id, Protocol.invalid_params(), "session has been deleted", %{
          "id" => acp_sid
        })
      )

      state
    else
      with {:ok, pixir_sid} <- Conversation.start(id: acp_sid, workspace: cwd),
           {:ok, posture} <- restore_reattach_posture(acp_sid, cwd, pixir_sid) do
        replayed_subagents = replay_history(state.out, acp_sid, pixir_sid, cwd)
        current_model = current_model(state, acp_sid)

        write(
          state.out,
          Protocol.result(
            id,
            session_setup_result(
              acp_sid,
              current_model,
              current_effort(state, acp_sid),
              current_web_search(state, acp_sid, model: current_model)
            )
          )
        )

        state
        |> register_session(acp_sid, pixir_sid, cwd, posture)
        |> remember_presented_subagents(replayed_subagents)
        |> schedule_available_commands(acp_sid, cwd)
      else
        {:error, %{error: %{kind: :not_found, message: message}}} ->
          write(
            state.out,
            Protocol.error(id, Protocol.invalid_params(), message, %{"id" => acp_sid})
          )

          state

        {:error, %{error: %{kind: :invalid_args, details: details}}} ->
          write_invalid_session_id(state.out, id, details)
          state

        {:error, error} ->
          write_start_error(state.out, id, error)
          state
      end
    end
  end

  # session/resume: the lighter cousin — reattach WITHOUT replaying History.
  defp resume_session(acp_sid, cwd, id, state) do
    # Existence check first (see load_session): unknown session -> -32602, not
    # an internal -32603 from folding a nonexistent Log.
    with {:ok, pixir_sid} <- Conversation.start(id: acp_sid, workspace: cwd),
         {:ok, posture} <- restore_reattach_posture(acp_sid, cwd, pixir_sid) do
      historical_subagents = presented_subagents_from_history(acp_sid, pixir_sid)
      current_model = current_model(state, acp_sid)

      write(
        state.out,
        Protocol.result(
          id,
          session_setup_result(
            acp_sid,
            current_model,
            current_effort(state, acp_sid),
            current_web_search(state, acp_sid, model: current_model)
          )
        )
      )

      state
      |> register_session(acp_sid, pixir_sid, cwd, posture)
      |> remember_presented_subagents(historical_subagents)
      |> schedule_available_commands(acp_sid, cwd)
    else
      {:error, %{error: %{kind: :not_found, message: message}}} ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), message, %{"id" => acp_sid})
        )

        state

      {:error, %{error: %{kind: :invalid_args, details: details}}} ->
        write_invalid_session_id(state.out, id, details)
        state

      {:error, error} ->
        write_start_error(state.out, id, error)
        state
    end
  end

  defp write_invalid_session_id(out, id, details) do
    data =
      %{"field" => "sessionId"}
      |> maybe_put_string_key("reason", details[:reason] || details["reason"])
      |> maybe_put_string_key("maxBytes", details[:max_bytes] || details["max_bytes"])

    write(out, Protocol.error(id, Protocol.invalid_params(), "invalid session id", data))
  end

  defp maybe_put_string_key(map, _key, nil), do: map
  defp maybe_put_string_key(map, key, value), do: Map.put(map, key, value)

  # Posture restore runs AFTER Conversation.start on purpose (unknown session ->
  # -32602 from the existence check, never -32603 from folding a missing Log).
  # The cost of that order is that a posture failure happens with a Session
  # already live, so this helper stops it before propagating the error: the
  # fail-closed path must not leave an untracked write-capable Session (and its
  # writer lease) behind.
  defp restore_reattach_posture(acp_sid, cwd, pixir_sid) do
    with {:ok, durable_posture} <- Subagents.resume_posture(acp_sid, workspace: cwd),
         {:ok, posture} <- Subagents.restrict_resume_posture(durable_posture, :auto, nil) do
      {:ok, posture}
    else
      {:error, error} ->
        SessionSupervisor.stop_session(pixir_sid)
        {:error, error}
    end
  end

  # Fold the Log and emit each canonical Event as a replay session/update
  # (Translate.replay/2), in order, before the load response.
  defp replay_history(out, acp_sid, pixir_sid, workspace) do
    case Conversation.history(pixir_sid) do
      {:ok, history} ->
        {seen, warning_state} =
          Enum.reduce(history, {MapSet.new(), new_warning_state()}, fn event,
                                                                       {seen, warning_state} ->
            params =
              Translate.replay(
                event,
                acp_sid,
                translate_opts(event, acp_sid, seen, workspace)
              )

            warning_state =
              case track_acp_warning(warning_state, event) do
                {:warning, true, warning, next_warning_state} ->
                  if params, do: write(out, Protocol.notification("session/update", params))

                  if event.type == :assistant_message do
                    warning_params = Translate.output_warning_update(warning, acp_sid)
                    write(out, Protocol.notification("session/update", warning_params))
                  end

                  next_warning_state

                {:warning, false, _warning, next_warning_state} ->
                  if params && event.type != :provider_usage,
                    do: write(out, Protocol.notification("session/update", params))

                  next_warning_state

                :not_warning ->
                  if params, do: write(out, Protocol.notification("session/update", params))
                  warning_state
              end

            {remember_presented_subagent(seen, event, acp_sid), warning_state}
          end)

        maybe_write_acp_warning_summary(out, acp_sid, warning_state)
        seen

      _ ->
        MapSet.new()
    end
  end

  defp presented_subagents_from_history(acp_sid, pixir_sid) do
    case Conversation.history(pixir_sid) do
      {:ok, history} ->
        Enum.reduce(history, MapSet.new(), &remember_presented_subagent(&2, &1, acp_sid))

      _ ->
        MapSet.new()
    end
  end

  defp translate_update(event, acp_sid, state) do
    pixir_sid = Map.get(state.sessions, acp_sid)
    prompt_ref = get_in(state.prompts, [pixir_sid, :id])

    opts =
      translate_opts(
        event,
        acp_sid,
        state.presented_subagents,
        Map.get(state.workspaces, acp_sid)
      )
      |> Keyword.put(:tool_call_args, tool_call_args_for(event, state))
      |> Keyword.put(:tool_name, tool_name_for(event, state))
      |> Keyword.put(:acp_sid, acp_sid)
      |> maybe_put_prompt_ref(prompt_ref)

    {params, state} =
      case track_live_acp_warning(state, event) do
        {:warning, true, warning, state} ->
          params =
            if event.type == :provider_usage do
              Translate.update(event, acp_sid, opts)
            else
              Translate.output_warning_update(warning, acp_sid)
            end

          {params, state}

        {:warning, false, _warning, state} ->
          {nil, state}

        :not_warning ->
          {Translate.update(event, acp_sid, opts), state}
      end

    {params, state} = maybe_title_update(params, state, acp_sid, event)

    state = %{
      state
      | presented_subagents:
          remember_presented_subagent(state.presented_subagents, event, acp_sid),
        tool_calls: remember_tool_call(state.tool_calls, event)
    }

    {params, state}
  end

  defp subagent_seen_opts(%{type: :subagent_event, data: %{"subagent_id" => id}}, acp_sid, seen)
       when is_binary(id) and id != "" do
    [subagent_seen?: MapSet.member?(seen, subagent_key(acp_sid, id))]
  end

  defp subagent_seen_opts(_event, _acp_sid, _seen), do: []

  defp translate_opts(event, acp_sid, seen, workspace) do
    event
    |> subagent_seen_opts(acp_sid, seen)
    |> Keyword.put(:workspace, workspace)
    |> Keyword.put(:acp_sid, acp_sid)
  end

  defp maybe_put_prompt_ref(opts, nil), do: opts
  defp maybe_put_prompt_ref(opts, prompt_ref), do: Keyword.put(opts, :prompt_ref, prompt_ref)

  defp tool_call_args_for(%{type: :tool_result, data: %{"call_id" => id}}, state) do
    get_in(state.tool_calls, [id, :args]) || %{}
  end

  defp tool_call_args_for(_event, _state), do: %{}

  defp tool_name_for(%{type: :tool_result, data: %{"call_id" => id}}, state) do
    get_in(state.tool_calls, [id, :name])
  end

  defp tool_name_for(_event, _state), do: nil

  defp maybe_title_update(nil, state, acp_sid, %{type: :user_message, data: %{"text" => text}})
       when is_binary(text) do
    title = String.slice(String.trim(text), 0, 80)

    if title == "" or Map.has_key?(state.titles, acp_sid) do
      {nil, state}
    else
      Process.send_after(self(), {:deferred_title_update, acp_sid, title}, 250)
      {nil, %{state | titles: Map.put(state.titles, acp_sid, title)}}
    end
  end

  defp maybe_title_update(params, state, _acp_sid, _event), do: {params, state}

  defp remember_presented_subagents(state, presented) do
    %{state | presented_subagents: MapSet.union(state.presented_subagents, presented)}
  end

  defp remember_presented_subagent(
         seen,
         %{type: :subagent_event, data: %{"subagent_id" => id}},
         acp_sid
       )
       when is_binary(id) and id != "" do
    MapSet.put(seen, subagent_key(acp_sid, id))
  end

  defp remember_presented_subagent(seen, _event, _acp_sid), do: seen

  defp remember_tool_call(tool_calls, %{
         type: :tool_call,
         data: %{"call_id" => id, "name" => name, "args" => args}
       })
       when is_binary(id) and is_map(args) do
    Map.put(tool_calls, id, %{name: name, args: args})
  end

  defp remember_tool_call(tool_calls, _event), do: tool_calls

  defp subagent_key(acp_sid, id), do: {acp_sid, id}

  # ── session/prompt helper ────────────────────────────────────────────────────

  defp start_prompt(acp_sid, pixir_sid, params, id, state) do
    meta_opts = extract_meta_opts(params)

    cond do
      prompt_running?(state, pixir_sid) ->
        # Availability belongs to both presenter and runtime state. A terminal status can
        # reach ACP just before Session handles the Turn Task result; checking only the
        # prompt map would admit a Task that Conversation.send/3 then rejects as :busy.
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "a turn is already running")
        )

        state

      not model_allowed?(meta_opts[:model]) ->
        # An unknown per-turn `_meta.model` is rejected early (epic A.5,
        # decision #8) rather than passed through to a backend
        # `model_not_supported` — a clearer, cheaper failure with the catalog
        # owning the truth.
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "unknown model", %{
            "model" => meta_opts[:model]
          })
        )

        state

      true ->
        prompt_blocks = Map.get(params, "prompt", [])
        prompt_text = extract_prompt_text(prompt_blocks)

        if compact_prompt?(prompt_text) do
          run_compact_prompt(acp_sid, pixir_sid, prompt_text, id, state)
        else
          attachments = extract_attachments(params, prompt_blocks)
          server = self()
          turn_opts = maybe_put(turn_opts(state, acp_sid, meta_opts), :attachments, attachments)

          {:ok, task} =
            Task.Supervisor.start_child(Pixir.TurnSupervisor, fn ->
              run_prompt(
                server,
                acp_sid,
                pixir_sid,
                prompt_text,
                turn_opts,
                state.prompt_idle_timeout_ms,
                %{
                  timeout_ms: state.prompt_cleanup_timeout_ms,
                  before_wait: state.prompt_before_cleanup_hook
                },
                state.prompt_resolve_hook
              )
            end)

          put_in(
            state.prompts[pixir_sid],
            Map.merge(%{id: id, task: task, cancel?: false}, new_warning_state())
          )
        end
    end
  end

  defp compact_prompt?(text) when is_binary(text),
    do: String.match?(String.trim(text), ~r/^\/compact(?:\s.*)?$/)

  defp compact_prompt?(_), do: false

  defp run_compact_prompt(acp_sid, pixir_sid, prompt_text, id, state) do
    workspace = Map.get(state.workspaces, acp_sid) || File.cwd!()

    opts =
      [workspace: workspace, trigger: "manual"]
      |> maybe_tail_events(prompt_text)
      |> Keyword.merge(compact_provider_opts(state, acp_sid))

    server = self()
    complete = state.compaction_complete

    {:ok, task} =
      Task.Supervisor.start_child(Pixir.TurnSupervisor, fn ->
        completion = compact_completion(complete, pixir_sid, opts)

        Pixir.ACP.Server.emit(
          server,
          Translate.message_chunk(compact_completion_text(completion), acp_sid)
        )

        maybe_emit_compact_usage(server, acp_sid, pixir_sid, completion)
        GenServer.call(server, {:resolve_prompt, pixir_sid, :done, nil})
      end)

    put_in(
      state.prompts[pixir_sid],
      Map.merge(%{id: id, task: task, cancel?: false}, new_warning_state())
    )
  end

  defp compact_provider_opts(state, acp_sid) do
    opts =
      state.provider_opts
      |> List.wrap()
      |> Keyword.take([
        :transport,
        :auth,
        :model,
        :responses_backend,
        :config_path,
        :raw_config,
        :request_snapshot_loader,
        :native,
        :resolved_provider_request
      ])
      |> Keyword.put(:model, current_model(state, acp_sid))

    case state.provider do
      nil -> opts
      provider -> Keyword.put(opts, :provider, provider)
    end
  end

  defp compact_completion(complete, pixir_sid, opts) do
    case complete.(pixir_sid, opts) do
      {:ok, %{"status" => status} = completion}
      when status in ["recorded", "no_op", "error"] ->
        completion

      other ->
        %{
          "status" => "error",
          "range" => nil,
          "checkpoint" => nil,
          "error" => %{
            ok: false,
            error: %{
              kind: :invalid_state,
              message: "compaction completion returned an invalid result",
              details: %{result: inspect(other)}
            }
          }
        }
    end
  end

  defp compact_completion_text(%{
         "status" => "recorded",
         "range" => range,
         "checkpoint" => %{"seq" => seq}
       })
       when is_map(range) do
    from_seq = range["from_seq"] || "?"
    to_seq = range["to_seq"] || "?"
    "Recorded compaction checkpoint at seq #{seq} for seq #{from_seq}..#{to_seq}."
  end

  defp compact_completion_text(%{"status" => "no_op"} = completion) do
    "Nothing to compact: " <> to_string(completion["reason"] || "no compactable history")
  end

  defp compact_completion_text(%{"status" => "error", "error" => error}) do
    kind = get_in(error, [:error, :kind]) || get_in(error, ["error", "kind"])
    message = get_in(error, [:error, :message]) || get_in(error, ["error", "message"])
    "Compaction failed: " <> compact_failure_text(kind, message)
  end

  defp compact_completion_text(_completion), do: "Compaction failed."

  # A post-compaction gauge is emitted only when the runtime completion carries an
  # actually measured snapshot. Deterministic local compaction currently carries none:
  # it calls no Provider and Pixir owns no tokenizer, so reusing the prior usage would be
  # stale and fabricating zero/estimating from Events would be dishonest.
  defp maybe_emit_compact_usage(
         server,
         acp_sid,
         pixir_sid,
         %{"status" => "recorded", "pressure_snapshot" => snapshot}
       )
       when is_map(snapshot) do
    case Translate.update(Event.context_pressure(pixir_sid, snapshot), acp_sid) do
      nil -> :ok
      update -> Pixir.ACP.Server.emit(server, update)
    end
  end

  defp maybe_emit_compact_usage(_server, _acp_sid, _pixir_sid, _completion), do: :ok

  defp compact_failure_text(kind, message) do
    kind = if is_atom(kind), do: Atom.to_string(kind), else: kind

    kind_text =
      cond do
        is_binary(kind) and byte_size(kind) <= @max_turn_failure_error_kind_bytes ->
          kind

        true ->
          nil
      end

    message_text = if is_binary(message) and message != "", do: message, else: nil

    cond do
      kind_text && message_text -> kind_text <> ": " <> message_text
      message_text -> message_text
      kind_text -> kind_text
      true -> "unknown error"
    end
  end

  defp maybe_tail_events(opts, prompt_text) do
    case prompt_text |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [_cmd, tail] ->
        case Integer.parse(String.trim(tail)) do
          {tail_events, rest} when tail_events > 0 and rest == "" ->
            Keyword.put(opts, :tail_events, tail_events)

          _ ->
            opts
        end

      _ ->
        opts
    end
  end

  defp prompt_running?(state, pixir_sid) do
    Map.has_key?(state.prompts, pixir_sid) or
      turn_running?(pixir_sid, @prompt_admission_probe_timeout_ms, false)
  end

  # A per-turn model knob is allowed when absent (use Pixir's own resolution) or
  # present in the advertised catalog (`Pixir.Providers.Registry.models/0`).
  defp model_allowed?(nil), do: true
  defp model_allowed?(model) when is_binary(model), do: Registry.model_supported?(model)

  # Concatenate text blocks. Image/resource_link blocks are extracted separately
  # as Session Resource attachments; audio/embeddedContext remain unsupported.
  defp extract_prompt_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_prompt_text(_), do: ""

  defp extract_attachments(params, prompt_blocks) do
    top_level =
      case Map.get(params, "attachments") do
        attachments when is_list(attachments) -> attachments
        _ -> []
      end

    block_level =
      case prompt_blocks do
        blocks when is_list(blocks) ->
          blocks
          |> Enum.filter(
            &(is_map(&1) and &1["type"] in ["image", "input_image", "resource_link"])
          )
          |> Enum.map(&normalize_attachment_block/1)

        _ ->
          []
      end

    Enum.filter(top_level ++ block_level, &is_map/1)
  end

  defp normalize_attachment_block(%{"type" => "input_image"} = block) do
    mime_type = block["mimeType"] || block["mime_type"]

    %{
      "type" => "image",
      "name" => block["name"],
      "mimeType" => mime_type,
      "sizeBytes" => block["sizeBytes"] || block["size_bytes"],
      "dataUrl" => image_data_url(block, mime_type)
    }
  end

  defp normalize_attachment_block(%{"type" => "image"} = block) do
    mime_type = block["mimeType"] || block["mime_type"]

    block
    |> Map.put("mimeType", mime_type)
    |> Map.put_new("dataUrl", image_data_url(block, mime_type))
  end

  defp normalize_attachment_block(block), do: block

  defp image_data_url(block, mime_type) do
    cond do
      is_binary(block["dataUrl"]) ->
        block["dataUrl"]

      is_binary(block["data_url"]) ->
        block["data_url"]

      is_binary(block["image_url"]) ->
        block["image_url"]

      is_binary(block["data"]) and is_binary(mime_type) ->
        "data:#{mime_type};base64,#{block["data"]}"

      true ->
        nil
    end
  end

  # A client may pin per-turn knobs via ACP's `_meta` extension slot on
  # `session/prompt` (`_meta.model`, `_meta.reasoning_effort`) — additive to
  # ADR 0009's v1 surface. Sticky session model selection should normally use
  # `session/set_config_option {configId:"model", value}`; `session/set_model`
  # remains a Pixir/T3 compatibility extension.
  # Presenter UX context may arrive at `_meta.presenter_context` or
  # `_meta.pixir.presenter_context`; Pixir renders it into late developer context
  # itself, so the client never assembles Provider input.
  # `_meta` is ACP's sanctioned channel for non-standard fields. Each knob is
  # optional; a missing/blank value falls back to Pixir's own resolution
  # (config/env/default for the model; the model's default reasoning effort).
  defp extract_meta_opts(params) do
    meta = Map.get(params, "_meta")
    meta = if is_map(meta), do: meta, else: %{}
    pixir_meta = if is_map(meta["pixir"]), do: meta["pixir"], else: %{}

    []
    |> maybe_put(:model, meta_string(Map.get(meta, "model")))
    |> maybe_put(:reasoning_effort, meta_string(Map.get(meta, "reasoning_effort")))
    |> maybe_put(:web_search, meta_web_search(Map.get(meta, "web_search")))
    |> maybe_put(:permission_mode, permission_mode_meta(Map.get(meta, "permission_mode")))
    |> maybe_put(:presenter_context, presenter_context_meta(meta, pixir_meta))
  end

  # `_meta.permission_mode` requests an interactive permission posture (A.2,
  # decision #7): T3 Code sends `"ask"` when its RuntimeMode is
  # `approval-required`. Only `"ask"` is honored here (build/plan already drive
  # the base posture via the session mode); anything else is dropped.
  defp permission_mode_meta("ask"), do: :ask
  defp permission_mode_meta(_other), do: nil

  defp presenter_context_meta(meta, pixir_meta) do
    cond do
      is_map(pixir_meta["presenter_context"]) -> pixir_meta["presenter_context"]
      is_list(pixir_meta["presenter_context"]) -> pixir_meta["presenter_context"]
      is_binary(pixir_meta["presenter_context"]) -> pixir_meta["presenter_context"]
      is_map(meta["presenter_context"]) -> meta["presenter_context"]
      is_list(meta["presenter_context"]) -> meta["presenter_context"]
      is_binary(meta["presenter_context"]) -> meta["presenter_context"]
      true -> nil
    end
  end

  defp meta_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp meta_string(_), do: nil

  defp turn_opts(state, acp_sid, meta_opts) do
    mode = turn_mode(Map.get(state.modes, acp_sid, @default_mode))
    # `:permission_mode` is a Turn knob, not a provider opt — pull it out of
    # meta_opts before threading the rest into provider_opts.
    {requested_perm, provider_meta} = Keyword.pop(meta_opts, :permission_mode)
    {presenter_context, provider_meta} = Keyword.pop(provider_meta, :presenter_context)

    # Permission posture (D.3 + A.2): plan mode is always `:read_only`; otherwise
    # `_meta.permission_mode: "ask"` (T3's approval-required) selects `:ask`,
    # else `:auto`. The Turn re-forces `:read_only` for plan regardless.
    requested_permission_mode = resolve_permission_mode(mode, requested_perm)

    {permission_mode, write_policy} =
      case Map.get(state.resume_postures, acp_sid) do
        nil ->
          {requested_permission_mode, nil}

        posture ->
          {:ok, effective_posture} =
            Subagents.restrict_resume_posture(posture, requested_permission_mode, nil)

          {effective_posture.permission_mode, effective_posture.write_policy}
      end

    base =
      [
        mode: mode,
        permission_mode: permission_mode,
        asker: build_asker(permission_mode, acp_sid),
        acp_runtime: %{server: self(), acp_sid: acp_sid}
      ]
      |> maybe_put(:write_policy, write_policy)
      |> maybe_put(:presenter_context, presenter_context)

    base
    |> maybe_put(:provider, state.provider)
    |> maybe_put(
      :provider_opts,
      normalize_provider_opts(
        state.provider_opts,
        with_session_config(state, acp_sid, provider_meta)
      )
    )
  end

  # plan mode is read-only no matter what; build honors a requested `:ask`, else
  # `:auto`.
  defp resolve_permission_mode(:plan, _requested), do: :read_only
  defp resolve_permission_mode(_build, :ask), do: :ask
  defp resolve_permission_mode(_build, _requested), do: :auto

  # The asker: only `:ask` mode ever calls it (`:auto` allows, `:read_only`
  # denies outright). For `:ask`, round-trip a `session/request_permission` over
  # ACP and map the outcome. The closure captures the Server pid + acp_sid; it
  # runs inside the Executor's Task, so the blocking call is safe.
  defp build_asker(:ask, acp_sid) do
    server = self()

    fn request ->
      params = Translate.permission_request(request, acp_sid)
      Translate.permission_outcome(request_permission(server, params))
    end
  end

  defp build_asker(_mode, _acp_sid), do: fn _ -> :deny end

  # Prompt-option precedence: explicit per-turn `_meta` > sticky session value >
  # Pixir config. Explicit entries remain untouched; absent model/effort entries
  # receive their validated sticky values. Turn freezes the final Config fallback
  # in one ResolvedProviderRequest and attaches its private defaults to Provider opts.
  defp with_session_config(state, acp_sid, meta_opts) do
    meta_opts
    |> put_sticky(:model, Map.get(state.session_models, acp_sid))
    |> put_sticky(:reasoning_effort, Map.get(state.session_efforts, acp_sid))
    |> put_sticky_web_search(state, acp_sid)
    |> normalize_provider_default_effort(state)
  end

  defp put_sticky(opts, _key, nil), do: opts

  defp put_sticky(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
  end

  defp put_sticky_web_search(opts, state, acp_sid) do
    if Keyword.has_key?(opts, :web_search) do
      opts
    else
      case Map.get(state.session_web_search, acp_sid) do
        "on" ->
          model_opts =
            case Keyword.get(opts, :model) do
              nil -> []
              model -> [model: model]
            end

          effective = current_web_search(state, acp_sid, model_opts)

          Keyword.put(
            opts,
            :web_search,
            if(effective == "on", do: %{"enabled" => true}, else: false)
          )

        "off" ->
          Keyword.put(opts, :web_search, false)

        nil ->
          opts
      end
    end
  end

  # `default` must suppress a configured effort, not become a provider value.
  # Anthropic treats an explicit nil as omission, and the resolved request preserves
  # that present keyword key. The Responses body normalization receives the non-enum
  # `default` sentinel and converts it to omission at the request-body boundary.
  defp normalize_provider_default_effort(meta_opts, state) do
    if Keyword.get(meta_opts, :reasoning_effort) == "default" do
      # Classify with the SAME model the turn will actually use: per-turn
      # _meta/sticky first, then the server's base provider_opts, then the
      # global default. Classifying before the base opts routed the sentinel
      # down the wrong provider path (fresh-review major on #290).
      model =
        Keyword.get(meta_opts, :model) ||
          Keyword.get(state.provider_opts, :model) ||
          default_model_id()

      provider = state.provider || Registry.resolve(model).provider

      if provider == Pixir.Provider do
        meta_opts
      else
        Keyword.put(meta_opts, :reasoning_effort, nil)
      end
    else
      meta_opts
    end
  end

  # The ACP mode id ("build"/"plan") as the Turn's mode atom.
  defp turn_mode("plan"), do: :plan
  defp turn_mode(_build), do: :build

  # Thread the per-turn `_meta` knobs (model, reasoning_effort) into
  # provider_opts, where `Pixir.Provider.do_stream/2` reads them ahead of the
  # global defaults.
  defp normalize_provider_opts(opts, meta_opts) do
    merged = Keyword.merge(List.wrap(opts), meta_opts)
    if merged == [], do: nil, else: merged
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp mark_cancel(state, pixir_sid) do
    case Map.get(state.prompts, pixir_sid) do
      nil -> state
      prompt -> put_in(state.prompts[pixir_sid], %{prompt | cancel?: true})
    end
  end

  # Reply the caller blocked on outbound request `id` (if still pending) and drop
  # it from the map. An unmatched id (late/duplicate response) is a no-op.
  defp resolve_pending(state, id, reply) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {%{from: from, timer_ref: timer_ref}, rest} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, reply)
        %{state | pending_requests: rest}
    end
  end

  # ── prompt Task body ──────────────────────────────────────────────────────────

  # Runs in the Task: subscribe, send, then own a receive loop (mirroring
  # Conversation.await/2's terminal detection at conversation.ex:113-130) so we can track
  # whether any text streamed and stash the last assistant_message for the fallback.
  defp run_prompt(
         server,
         acp_sid,
         pixir_sid,
         prompt_text,
         turn_opts,
         prompt_idle_timeout_ms,
         prompt_cleanup,
         prompt_resolve_hook
       ) do
    Conversation.subscribe(pixir_sid)

    case Conversation.send(pixir_sid, prompt_text, turn_opts) do
      {:ok, _ref} ->
        {outcome, saw_text?, last_text, failure} =
          consume(server, acp_sid, pixir_sid, prompt_idle_timeout_ms, false, nil)

        fallback_text =
          case outcome do
            :done -> last_text || latest_assistant_text(pixir_sid)
            _ -> last_text
          end

        maybe_fallback(server, acp_sid, saw_text?, fallback_text)
        # The Server resolves the request id and the cancel flag at this point, so a
        # cancel that raced a terminal status still wins (ADR 0009 §5 cancel race).
        finish_prompt(
          server,
          pixir_sid,
          outcome,
          failure,
          prompt_cleanup,
          prompt_resolve_hook
        )

      {:error, :busy} ->
        # The Session is the final admission authority. A non-ACP caller can start a Turn
        # between the Server's availability check and this call, so keep this refusal
        # explicit instead of resolving a request whose user text never ran as end_turn.
        reject_busy_prompt(server, pixir_sid)
    end
  end

  # If a Turn streamed no text_delta, emit the assistant_message as one chunk so no text
  # is lost (ADR 0009 §4 — e.g. the synthetic iteration-cap message at turn.ex:109-110).
  defp maybe_fallback(_server, _acp_sid, true, _last_text), do: :ok
  defp maybe_fallback(_server, _acp_sid, false, last_text) when last_text in [nil, ""], do: :ok

  defp maybe_fallback(server, acp_sid, false, last_text) do
    Pixir.ACP.Server.emit(server, Translate.message_chunk(last_text, acp_sid))
  end

  defp latest_assistant_text(pixir_sid) do
    case Pixir.Session.history(pixir_sid) do
      {:ok, history} ->
        history
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{type: :assistant_message, data: %{"metadata" => %{"partial" => true}}} ->
            nil

          %{type: :assistant_message, data: %{"text" => text}} when is_binary(text) ->
            text

          _event ->
            nil
        end)

      {:error, _error} ->
        nil
    end
  end

  defp finish_prompt(
         server,
         pixir_sid,
         outcome,
         failure,
         prompt_cleanup,
         prompt_resolve_hook
       ) do
    # Turn emits its terminal status before its supervised Task result reaches Session.
    # Prefer to publish the PromptResponse only after the Session clears that Turn, but
    # never let a successor Turn or a stalled state probe swallow the request id forever.
    prompt_cleanup.before_wait.()
    await_turn_cleanup(pixir_sid, prompt_cleanup.timeout_ms)
    prompt_resolve_hook.(outcome)
    :ok = GenServer.call(server, {:resolve_prompt, pixir_sid, outcome, failure})
  end

  defp reject_busy_prompt(server, pixir_sid) do
    :ok = GenServer.call(server, {:reject_busy_prompt, pixir_sid})
  end

  defp await_turn_cleanup(pixir_sid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    do_await_turn_cleanup(pixir_sid, deadline)
  end

  defp do_await_turn_cleanup(pixir_sid, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      remaining_ms == 0 ->
        :ok

      not turn_running?(pixir_sid, remaining_ms, true) ->
        :ok

      true ->
        Process.sleep(min(@prompt_cleanup_poll_ms, remaining_ms))
        do_await_turn_cleanup(pixir_sid, deadline)
    end
  end

  # Mirror of Conversation's terminal detection (conversation.ex:113-130), extended to
  # track text-streamed + last assistant text for the no-deltas fallback (ADR 0009 §4)
  # and the bounded turn-failure facts for the prompt result's `_meta` (#465).
  defp consume(server, acp_sid, pixir_sid, timeout, saw_text?, last_text, failure \\ nil) do
    receive do
      {:pixir_event, event} ->
        Pixir.ACP.Server.emit_event(server, acp_sid, event)

        saw_text? = saw_text? or event.type == :text_delta
        last_text = stash_assistant(event, last_text)
        failure = stash_turn_failure(event, failure)

        case terminal(event) do
          nil -> consume(server, acp_sid, pixir_sid, timeout, saw_text?, last_text, failure)
          outcome -> {outcome, saw_text?, last_text, failure}
        end
    after
      timeout ->
        if turn_running?(pixir_sid) do
          consume(server, acp_sid, pixir_sid, timeout, saw_text?, last_text, failure)
        else
          {:timeout, saw_text?, last_text, failure}
        end
    end
  end

  # #465: keep only the bounded classification facts — never the raw error message or
  # details, which already reach the user as chat content and may embed provider prose.
  # Cancellation cleanup may append its own interruption failure after the Turn already
  # emitted a more specific bounded failure. Keep those earlier facts for ACP instead of
  # replacing `provider_error`/`tool_error` with the less specific cleanup outcome. A prior
  # empty projection does not suppress a later valid interruption classification.
  defp stash_turn_failure(
         %{type: :turn_failed, data: %{"terminal_status" => "interrupted"}},
         failure
       )
       when is_map(failure) and map_size(failure) > 0,
       do: failure

  defp stash_turn_failure(%{type: :turn_failed, data: data}, _failure) when is_map(data),
    do: turn_failure_facts(data)

  defp stash_turn_failure(_event, failure), do: failure

  @doc false
  # Event.turn_failed/2 accepts any map, so this presenter independently enforces the
  # closed producer vocabulary and a conservative token grammar. An empty map remains
  # meaningful: it says turn_failed evidence was observed but neither fact was safe to
  # project. byte_size/1 makes the cap unambiguous for UTF-8 input.
  def turn_failure_facts(data) when is_map(data) do
    %{}
    |> maybe_put_terminal_status(data["terminal_status"])
    |> maybe_put_error_kind(data["error_kind"])
  end

  defp maybe_put_terminal_status(facts, status)
       when status in @turn_failure_terminal_statuses,
       do: Map.put(facts, "terminal_status", status)

  defp maybe_put_terminal_status(facts, _status), do: facts

  defp maybe_put_error_kind(facts, kind) when is_binary(kind) do
    if byte_size(kind) <= @max_turn_failure_error_kind_bytes and
         Regex.match?(@turn_failure_error_kind_pattern, kind) do
      Map.put(facts, "error_kind", kind)
    else
      facts
    end
  end

  defp maybe_put_error_kind(facts, _kind), do: facts

  defp turn_running?(pixir_sid, timeout_ms \\ 5_000, fallback \\ false) do
    case Pixir.Session.turn_running?(pixir_sid, timeout_ms) do
      true -> true
      false -> false
      {:error, _error} -> fallback
    end
  catch
    :exit, _reason -> fallback
  end

  # #465: the chat rendering of a failed Turn stays exactly as ADR 0009 §5 decided
  # (content + `stopReason:"end_turn"`, because a JSON-RPC error surfaces in clients
  # as a provider-failure view and any other stopReason reads as completion). What was
  # missing is a MACHINE-readable channel: the prompt RESULT carries
  # `_meta.pixir.turn_failure` exactly when a `turn_failed` event was OBSERVED during
  # this prompt — the contract is evidence-based, never inferred from the terminal
  # shape (Grok round 1: inferring from `outcome == :error` falsely marked a
  # `Conversation.send` `:busy` refusal, where no Turn ran at all, as a failed Turn).
  # Fields stay bounded: `terminal_status` uses the current closed Turn producer
  # vocabulary and `error_kind` is a lower-case ASCII identifier capped at 64 UTF-8
  # bytes. A cancel that raced a failure keeps `stopReason:"cancelled"` AND carries the
  # facts; the same holds for a prompt-idle `:timeout` whose Turn recorded `turn_failed`
  # and then died without a terminal status.
  @doc false
  def prompt_result(stop_reason, failure) do
    base = %{"stopReason" => stop_reason}

    if is_map(failure) do
      Map.put(base, "_meta", %{"pixir" => %{"turn_failure" => failure}})
    else
      base
    end
  end

  defp stash_assistant(%{type: :assistant_message, data: %{"text" => text}}, _last), do: text
  defp stash_assistant(_event, last), do: last

  defp terminal(%{type: :status, data: %{"status" => "done"}}), do: :done
  defp terminal(%{type: :status, data: %{"status" => "error"}}), do: :error
  defp terminal(%{type: :status, data: %{"status" => "interrupted"}}), do: :interrupted
  defp terminal(_event), do: nil

  @impl true
  def handle_call({:reject_busy_prompt, pixir_sid}, _from, state) do
    case Map.fetch(state.prompts, pixir_sid) do
      {:ok, %{id: id}} ->
        write(
          state.out,
          Protocol.error(id, Protocol.invalid_params(), "a turn is already running")
        )

        {:reply, :ok, %{state | prompts: Map.delete(state.prompts, pixir_sid)}}

      :error ->
        # Another terminal path already consumed the request id. Preserve the one-reply
        # invariant rather than manufacturing an uncorrelated JSON-RPC response.
        {:reply, :ok, state}
    end
  end

  # Read the request id + cancel flag at resolve time so a cancel that raced a terminal
  # status still wins.
  @impl true
  def handle_call({:resolve_prompt, pixir_sid, outcome, failure}, _from, state) do
    id = get_in(state.prompts, [pixir_sid, :id])
    cancel? = get_in(state.prompts, [pixir_sid, :cancel?]) || false
    stop_reason = Translate.stop_reason(outcome, cancel?)

    acp_sid = acp_sid_for_pixir(state, pixir_sid)
    maybe_write_acp_warning_summary(state.out, acp_sid, Map.get(state.prompts, pixir_sid, %{}))
    write(state.out, Protocol.result(id, prompt_result(stop_reason, failure)))
    {:reply, :ok, %{state | prompts: Map.delete(state.prompts, pixir_sid)}}
  end

  # Originate an outbound request: allocate a negative out_id, write it through
  # the single writer, stash `from`, and DON'T reply yet — the reply happens when
  # the matching `{:response, out_id, _}` line arrives (handle_info below). The
  # GenServer stays free to read/write meanwhile, so the blocked caller (an
  # Executor Task) doesn't stall the transport.
  def handle_call({:client_request, method, params}, from, state) do
    out_id = state.out_id - 1
    write(state.out, Protocol.request(out_id, method, params))

    timer_ref =
      Process.send_after(self(), {:pending_request_timeout, out_id}, state.request_timeout_ms)

    pending = %{from: from, timer_ref: timer_ref}

    {:noreply,
     %{state | out_id: out_id, pending_requests: Map.put(state.pending_requests, out_id, pending)}}
  end

  defp new_warning_state do
    %{
      warning_keys: MapSet.new(),
      warning_count: 0,
      latest_warning_order_key: nil
    }
  end

  defp track_live_acp_warning(state, %{type: type} = event)
       when type in [:provider_usage, :assistant_message] do
    case Map.fetch(state.prompts, event.session_id) do
      {:ok, prompt} ->
        case track_acp_warning(prompt, event) do
          {:warning, emit?, warning, prompt} ->
            {:warning, emit?, warning, put_in(state.prompts[event.session_id], prompt)}

          :not_warning ->
            :not_warning
        end

      :error ->
        :not_warning
    end
  end

  defp track_live_acp_warning(_state, _event), do: :not_warning

  defp track_acp_warning(warning_state, event) do
    case acp_event_warning(event) do
      nil ->
        :not_warning

      warning ->
        key = {event.session_id, warning["provider_usage_event_id"]}
        order_key = {warning["provider_usage_seq"], warning["provider_usage_event_id"]}
        keys = Map.get(warning_state, :warning_keys, MapSet.new())
        latest = Map.get(warning_state, :latest_warning_order_key)

        cond do
          MapSet.member?(keys, key) or (not is_nil(latest) and order_key <= latest) ->
            {:warning, false, warning, warning_state}

          MapSet.size(keys) < 256 ->
            {:warning, true, warning,
             warning_state
             |> Map.put(:warning_keys, MapSet.put(keys, key))
             |> Map.update(:warning_count, 1, &(&1 + 1))
             |> Map.put(:latest_warning_order_key, order_key)}

          true ->
            {:warning, false, warning,
             warning_state
             |> Map.update(:warning_count, 1, &(&1 + 1))
             |> Map.put(:latest_warning_order_key, order_key)}
        end
    end
  end

  defp acp_event_warning(%{type: :provider_usage} = event),
    do: Pixir.Provider.OutputTruncationSummary.warning(event)

  defp acp_event_warning(%{type: :assistant_message} = event) do
    case Pixir.Provider.OutputTruncationSummary.assistant_fallback(event) do
      {:ok, _projection, warning} -> warning
      :error -> nil
    end
  end

  defp acp_event_warning(_event), do: nil

  defp maybe_write_acp_warning_summary(out, acp_sid, warning_state) when is_binary(acp_sid) do
    total = Map.get(warning_state, :warning_count, 0)

    if total > 256 do
      params = Translate.output_warning_summary(total, acp_sid)
      write(out, Protocol.notification("session/update", params))
    end
  end

  defp maybe_write_acp_warning_summary(_out, _acp_sid, _warning_state), do: :ok

  defp acp_sid_for_pixir(state, pixir_sid) do
    Enum.find_value(state.sessions, fn {acp_sid, candidate} ->
      if candidate == pixir_sid, do: acp_sid
    end)
  end

  # ── stdin reader ─────────────────────────────────────────────────────────────

  defp start_reader(io, server) do
    spawn_link(fn -> read_loop(io, server) end)
  end

  defp read_loop(io, server) do
    case IO.read(io, :line) do
      :eof ->
        send(server, :eof)

      {:error, reason} ->
        send(server, {:io_error, reason})

      line when is_binary(line) ->
        send(server, {:line, line})
        read_loop(io, server)
    end
  end

  # ── stdout writer (the ONLY stdout writer) ─────────────────────────────────────

  defp write(io, json), do: IO.write(io, [json, ?\n])

  # ── Logger → stderr (ADR 0005) ─────────────────────────────────────────────────

  defp redirect_logger_to_stderr do
    # OTP's `:logger_std_h` rejects an in-place `:type` change with
    # `{:error, {:illegal_config_change, ...}}`, so the only reliable redirect is to
    # remove the default handler and re-add it bound to `:standard_error`. Anything that
    # would otherwise hit `:standard_io` (== stdout) would corrupt the ndjson stream.
    with {:ok, cfg} <- :logger.get_handler_config(:default),
         :ok <- :logger.remove_handler(:default),
         new_cfg = put_in(cfg, [:config, :type], :standard_error),
         :ok <- :logger.add_handler(:default, Map.fetch!(cfg, :module), new_cfg) do
      :ok
    else
      _ ->
        # Last-ditch legacy console backend; ignore if neither path is wired.
        # Keep this dynamic: direct `Logger.configure_backend/2` is deprecated on
        # newer Elixir and trips warnings-as-errors even though this is fallback code.
        # TODO(acp-logger): remove after adopting `:logger_backends` or proving this
        # legacy fallback unreachable.
        try do
          apply(Logger, :configure_backend, [:console, [device: :standard_error]])
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
    end
  end

  defp log_client_info(%{"clientInfo" => %{"name" => name}}),
    do: Logger.info("acp: client #{name} connected")

  defp log_client_info(_params), do: :ok
end
