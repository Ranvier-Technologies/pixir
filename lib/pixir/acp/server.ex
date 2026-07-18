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
  (lifecycle, A.6); emits `session/update` (incl. `current_mode_update` and
  `plan`) and ORIGINATES `session/request_permission` (interactive permissions,
  A.2 — correlating the client's response against `pending_requests`). Per-turn
  knobs (model, reasoning effort, `permission_mode`) ride on `session/prompt`
  `_meta`; sticky model and reasoning-effort selection are exposed through
  `configOptions`; the legacy model catalog + auth status ride on `initialize._meta.pixir`.
  Other methods get `-32601`. JSON-RPC errors are reserved for protocol faults; a
  failed Turn is reported as content with `stopReason:"end_turn"` (ADR 0009 §5).
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
  alias Pixir.{Config, Conversation, SessionSupervisor, Subagents}
  alias Pixir.Providers.Registry

  @protocol_version 1
  @idle_timeout 120_000

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

  defp meta_web_search(true), do: %{"enabled" => true}
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
    * `:prompt_resolve_hook` — test callback at the terminal-status/reply boundary.
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
  def feed(server, line) when is_binary(line), do: send(server, {:line, line}) && :ok

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
      # Test seam at the terminal-status/reply boundary. The callback runs in the
      # prompt Task immediately before the Server synchronizes the wire reply, so
      # tests can drive both cancel/terminal orders without timing sleeps.
      prompt_resolve_hook: Keyword.get(opts, :prompt_resolve_hook, fn _outcome -> :ok end),
      provider: Keyword.get(opts, :provider),
      provider_opts: Keyword.get(opts, :provider_opts, [])
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
          "resume" => %{}
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

  defp handle_request("session/prompt", params, id, state) do
    with acp_sid when is_binary(acp_sid) <- Map.get(params, "sessionId"),
         pixir_sid when is_binary(pixir_sid) <- Map.get(state.sessions, acp_sid) do
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
                    current_effort(state, acp_sid)
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
                    current_effort(state, acp_sid)
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
              effort_id
            )
        }

        write(state.out, Protocol.result(id, result))
        %{state | session_efforts: Map.put(state.session_efforts, acp_sid, effort_id)}
    end
  end

  defp unknown_config_option(id, state, config_id) do
    write(
      state.out,
      Protocol.error(id, Protocol.invalid_params(), "unknown config option", %{
        "configId" => config_id
      })
    )

    state
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

  # The full `configOptions` list (D.2). Model and reasoning-effort selectors
  # are the canonical ACP surfaces for their sticky per-session selections; the
  # legacy `models` response field and `session/set_model` method remain model
  # compatibility extensions.
  defp config_options(current_mode, current_model, current_effort) do
    [
      mode_config_option(current_mode),
      model_config_option(current_model),
      reasoning_effort_config_option(current_effort)
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
      "type" => "select",
      "currentValue" => current,
      "options" =>
        Enum.map(@reasoning_effort_ids, fn effort ->
          %{"name" => effort, "value" => effort}
        end)
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

        write(
          state.out,
          Protocol.result(
            id,
            session_setup_result(
              acp_sid,
              default_model_id(),
              current_effort(state, acp_sid)
            )
          )
        )

        register_session(state, acp_sid, pixir_sid, cwd)

      {:error, error} ->
        write_start_error(state.out, id, error)
        state
    end
  end

  # The shared setup payload for session/new, session/load, and session/resume:
  # the sessionId plus advertised modes and config options. `current_model` and
  # `current_effort` are the effective setup values at session/new, load, or
  # resume. Sticky selections are retained when the same server reattaches.
  # The `models` field is a legacy Pixir/T3 compatibility extension; canonical
  # ACP clients should read `configOptions`.
  defp session_setup_result(acp_sid, current_model, current_effort) do
    %{
      "sessionId" => acp_sid,
      "modes" => %{
        "currentModeId" => @default_mode,
        "availableModes" => @available_modes
      },
      "models" => models_state(current_model),
      "configOptions" => config_options(@default_mode, current_model, current_effort)
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

  # The current model to advertise for an existing session (load/resume): the
  # sticky model if one was set on this server, else Pixir's default. (Sticky
  # selections are in-memory and not persisted, so after a cold restart this is
  # the default — the client can re-issue `session/set_model`.)
  defp current_model(state, acp_sid) do
    Map.get(state.session_models, acp_sid) || default_model_id()
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
        modes: Map.put(state.modes, acp_sid, @default_mode)
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

  # ── session/load + resume helpers (A.6) ──────────────────────────────────────

  # session/load: reattach to a persisted session and REPLAY its History as
  # session/update notifications (so the client repopulates the transcript)
  # before returning the LoadSessionResponse. A missing session is `-32602`.
  defp load_session(acp_sid, cwd, id, state) do
    # Existence check first: Conversation.start yields the :not_found -> -32602
    # contract for an unknown session. Restore the posture only after, so a
    # missing session never surfaces as an internal -32603 from the Log fold.
    with {:ok, pixir_sid} <- Conversation.start(id: acp_sid, workspace: cwd),
         {:ok, posture} <- restore_reattach_posture(acp_sid, cwd, pixir_sid) do
      replayed_subagents = replay_history(state.out, acp_sid, pixir_sid, cwd)
      current_model = current_model(state, acp_sid)

      write(
        state.out,
        Protocol.result(
          id,
          session_setup_result(acp_sid, current_model, current_effort(state, acp_sid))
        )
      )

      state
      |> register_session(acp_sid, pixir_sid, cwd, posture)
      |> remember_presented_subagents(replayed_subagents)
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
          session_setup_result(acp_sid, current_model, current_effort(state, acp_sid))
        )
      )

      state
      |> register_session(acp_sid, pixir_sid, cwd, posture)
      |> remember_presented_subagents(historical_subagents)
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
    opts =
      translate_opts(
        event,
        acp_sid,
        state.presented_subagents,
        Map.get(state.workspaces, acp_sid)
      )

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

    state = %{
      state
      | presented_subagents:
          remember_presented_subagent(state.presented_subagents, event, acp_sid)
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
  end

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

  defp subagent_key(acp_sid, id), do: {acp_sid, id}

  # ── session/prompt helper ────────────────────────────────────────────────────

  defp start_prompt(acp_sid, pixir_sid, params, id, state) do
    meta_opts = extract_meta_opts(params)

    cond do
      Map.has_key?(state.prompts, pixir_sid) ->
        # A concurrent prompt on a busy session is a client/state error, not an internal
        # fault — report it as invalid params (per the CodeRabbit review).
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
              state.prompt_resolve_hook
            )
          end)

        put_in(
          state.prompts[pixir_sid],
          Map.merge(%{id: id, task: task, cancel?: false}, new_warning_state())
        )
    end
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
        asker: build_asker(permission_mode, acp_sid)
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
    |> normalize_provider_default_effort(state)
  end

  defp put_sticky(opts, _key, nil), do: opts

  defp put_sticky(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
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
         prompt_resolve_hook
       ) do
    Conversation.subscribe(pixir_sid)

    case Conversation.send(pixir_sid, prompt_text, turn_opts) do
      {:ok, _ref} ->
        {outcome, saw_text?, last_text} =
          consume(server, acp_sid, pixir_sid, prompt_idle_timeout_ms, false, nil)

        fallback_text =
          case outcome do
            :done -> last_text || latest_assistant_text(pixir_sid)
            _ -> last_text
          end

        maybe_fallback(server, acp_sid, saw_text?, fallback_text)
        # The Server resolves the request id and the cancel flag at this point, so a
        # cancel that raced a terminal status still wins (ADR 0009 §5 cancel race).
        finish_prompt(server, pixir_sid, outcome, prompt_resolve_hook)

      {:error, :busy} ->
        finish_prompt(server, pixir_sid, :error, prompt_resolve_hook)
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

  defp finish_prompt(server, pixir_sid, outcome, prompt_resolve_hook) do
    prompt_resolve_hook.(outcome)
    :ok = GenServer.call(server, {:resolve_prompt, pixir_sid, outcome})
  end

  # Mirror of Conversation's terminal detection (conversation.ex:113-130), extended to
  # track text-streamed + last assistant text for the no-deltas fallback (ADR 0009 §4).
  defp consume(server, acp_sid, pixir_sid, timeout, saw_text?, last_text) do
    receive do
      {:pixir_event, event} ->
        Pixir.ACP.Server.emit_event(server, acp_sid, event)

        saw_text? = saw_text? or event.type == :text_delta
        last_text = stash_assistant(event, last_text)

        case terminal(event) do
          nil -> consume(server, acp_sid, pixir_sid, timeout, saw_text?, last_text)
          outcome -> {outcome, saw_text?, last_text}
        end
    after
      timeout ->
        if turn_running?(pixir_sid) do
          consume(server, acp_sid, pixir_sid, timeout, saw_text?, last_text)
        else
          {:timeout, saw_text?, last_text}
        end
    end
  end

  defp turn_running?(pixir_sid) do
    Pixir.Session.turn_running?(pixir_sid)
  catch
    :exit, _reason -> false
  end

  defp stash_assistant(%{type: :assistant_message, data: %{"text" => text}}, _last), do: text
  defp stash_assistant(_event, last), do: last

  defp terminal(%{type: :status, data: %{"status" => "done"}}), do: :done
  defp terminal(%{type: :status, data: %{"status" => "error"}}), do: :error
  defp terminal(%{type: :status, data: %{"status" => "interrupted"}}), do: :interrupted
  defp terminal(_event), do: nil

  # Read the request id + cancel flag at resolve time so a cancel that raced a terminal
  # status still wins.
  @impl true
  def handle_call({:resolve_prompt, pixir_sid, outcome}, _from, state) do
    id = get_in(state.prompts, [pixir_sid, :id])
    cancel? = get_in(state.prompts, [pixir_sid, :cancel?]) || false
    stop_reason = Translate.stop_reason(outcome, cancel?)

    acp_sid = acp_sid_for_pixir(state, pixir_sid)
    maybe_write_acp_warning_summary(state.out, acp_sid, Map.get(state.prompts, pixir_sid, %{}))
    write(state.out, Protocol.result(id, %{"stopReason" => stop_reason}))
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
