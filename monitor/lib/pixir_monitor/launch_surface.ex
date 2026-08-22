defmodule PixirMonitor.LaunchSurface do
  @moduledoc """
  Owns the launch handoff as an auxiliary, degradable surface.

  A launch handoff never gates serving. `PixirMonitor.CLI` starts this process
  after the listener and projection are healthy, and `serve` reaches and keeps its
  serving state whatever the handoff does. Only failures that make serving itself
  impossible stay fatal in the CLI.

  In `fifo` mode the surface arms one private directory, FIFO, and bounded writer
  at a time. Every arm announces a `launch_ready` frame carrying only the
  non-secret path. A reader that races the writer (`fifo_write_failed`), a reader
  window that expires with nobody attached (`fifo_reader_timeout`), or a refused
  issuance (`launch_issue_failed`) emits exactly one `launch_degraded` frame and
  re-arms a fresh surface, so a supervising agent can always learn the currently
  valid `fifo_path` without restarting the process. A successful handoff also
  re-arms, so a second browser session needs no restart; the capability itself
  stays strictly one-use because every handoff issues its own from the vault.
  Re-arming is bounded by `rearm_limit`: once exhausted the surface emits one
  terminal `launch_surface_exhausted` frame and continues without a FIFO.

  In `darwin` mode the surface fires the bounded launcher once and records a
  bounded outcome (`succeeded`, `failed`, `not_attempted`) that the CLI publishes
  in its serving frame. An operator re-enters with `SIGUSR2`, which mints a fresh
  one-use capability and hands it to the launcher again without a restart.

  No capability byte ever reaches an emitted frame: frames carry only kinds,
  bounded details already sanitized by their producers, and the FIFO path.
  """
  use GenServer

  @rearm_limit 16
  @degradable_kinds ~w(fifo_write_failed fifo_reader_timeout launch_issue_failed fifo_setup_failed fifo_writer_setup_failed fifo_cleanup_failed)
  # SIGUSR2, deliberately not SIGUSR1: ERTS reserves SIGUSR1 for its crash-dump
  # handler, and on OTP 29 `:os.set_signal(:sigusr1, :handle)` does not displace
  # it — the trapped fun runs AND the emulator still writes erl_crash.dump and
  # halts (probed on this runtime). A re-entry mechanism that kills the monitor
  # is the exact fragility this surface exists to remove.
  @reentry_signal :sigusr2

  @type outcome :: %{required(:status) => String.t(), optional(:kind) => String.t(), optional(:details) => map()}

  @doc """
  Starts the launch surface.

  Options: `:launch_mode` (`"darwin" | "fifo"`), `:port`, `:emit` (a one-arity
  frame sink), `:rearm_limit`, `:reader_timeout_ms`, `:platform`, and the
  `:issue_url` / `:handoff` / `:prepare` seams used by the pins.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  Starts the launch surface without linking it to the caller.

  `PixirMonitor.CLI` uses this so no auxiliary exit can reach serving. Linking
  first and calling `Process.unlink/1` afterwards leaves a window while the
  darwin launch runs in `handle_continue(:begin, ...)`. `launch_once/1`
  classifies the injected launcher's raise, throw, and exit modes, but starting
  unlinked remains the defense against any future auxiliary crash escaping that
  boundary.
  """
  @spec start_unlinked(keyword()) :: GenServer.on_start()
  def start_unlinked(opts), do: GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The default re-arm bound; also reported by the dry-run plan."
  @spec rearm_limit() :: pos_integer()
  def rearm_limit, do: @rearm_limit

  @doc "The operator-driven darwin re-entry mechanism, as a bounded label."
  @spec reentry_mechanism() :: String.t()
  def reentry_mechanism, do: "SIGUSR2"

  @doc """
  The bounded launch outcome recorded so far. Never carries capability bytes.

  Deliberately outside the `{:ok, term} | {:error, term}` rule in AGENTS.md, on
  the same reasoning as the `?`-predicate exemption: this is a total query over
  local state and has no failure path to tag. A launch that went wrong is not an
  error of this call — it is the value being reported, as
  `%{status: "failed", kind: ...}`. Wrapping that in `{:ok, _}` would leave the
  caller unwrapping a tuple that is always `:ok`, and would make `{:error, _}`
  ambiguous between "the surface is unreachable" and "the launch failed", which
  is exactly the distinction `PixirMonitor.CLI` keeps (it maps an unreachable
  surface to `launch_surface_unavailable` in its `catch :exit` clause).
  """
  @spec outcome(GenServer.server(), timeout()) :: outcome()
  def outcome(server, timeout \\ 5_000), do: GenServer.call(server, :outcome, timeout)

  @doc """
  Mints a fresh one-use capability and hands it to the launcher again.

  Every re-entry issues its own capability; none is reused, retained, or emitted.

  Returns the same `t:outcome/0` as `outcome/2` and is exempt for the same
  reason. A refused or failed re-entry is reported *in* the outcome
  (`status: "failed"` with a `kind`, or `"not_attempted"` with
  `"reentry_unsupported_in_mode"`), because the whole point of this surface is
  that a launch failure is a reportable state rather than an error that
  propagates. The one-use, TTL-bounded capability contract is enforced by
  `PixirMonitor.Vault`, not by this return shape.
  """
  @spec reenter(GenServer.server(), timeout()) :: outcome()
  def reenter(server, timeout \\ 10_000), do: GenServer.call(server, :reenter, timeout)

  @doc false
  @spec await_quiescent(GenServer.server(), timeout()) :: :armed | :exhausted | :idle | :terminated
  def await_quiescent(server, timeout \\ 5_000) do
    GenServer.call(server, :await_quiescent, timeout)
  catch
    :exit, _reason -> :terminated
  end

  @doc false
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal, 10_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      launch_mode: Keyword.get(opts, :launch_mode, "darwin"),
      port: Keyword.get(opts, :port),
      emit: Keyword.get(opts, :emit, fn _frame -> :ok end),
      rearm_limit: Keyword.get(opts, :rearm_limit, @rearm_limit),
      reader_timeout_ms: Keyword.get(opts, :reader_timeout_ms),
      platform: Keyword.get_lazy(opts, :platform, &platform/0),
      issue_url: Keyword.get(opts, :issue_url),
      prepare: Keyword.get(opts, :prepare, &PixirMonitor.FifoHandoff.prepare/1),
      prepare_opts: Keyword.get(opts, :prepare_opts, []),
      handoff: Keyword.get(opts, :handoff, &PixirMonitor.FifoHandoff.handoff/3),
      install_reentry_trap: Keyword.get(opts, :install_reentry_trap, false),
      attempts: 0,
      armed: nil,
      worker: nil,
      status: :idle,
      outcome: %{status: "not_attempted", kind: "launch_pending"}
    }

    {:ok, state, {:continue, :begin}}
  end

  @impl true
  def handle_continue(:begin, %{launch_mode: "fifo"} = state), do: {:noreply, arm(state)}

  def handle_continue(:begin, state) do
    state = install_reentry_trap(state)
    {:noreply, %{state | outcome: darwin_launch(state), status: :idle}}
  end

  @impl true
  def handle_call(:outcome, _from, state), do: {:reply, state.outcome, state}

  def handle_call(:reenter, _from, %{launch_mode: "darwin"} = state) do
    outcome = darwin_launch(state)
    {:reply, outcome, %{state | outcome: outcome}}
  end

  def handle_call(:reenter, _from, state) do
    outcome = %{status: "not_attempted", kind: "reentry_unsupported_in_mode"}
    {:reply, outcome, state}
  end

  def handle_call(:await_quiescent, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:handoff_armed, worker, prepared}, %{worker: worker} = state) do
    emit(state, %{ok: true, status: "launch_ready", launch_mode: "fifo", fifo_path: prepared.fifo})
    {:noreply, %{state | armed: prepared}}
  end

  def handle_info({:handoff_armed, stale_worker, prepared}, state) do
    # A superseded attempt must not leave its private directory behind.
    if stale_worker != state.worker, do: File.rm_rf(prepared.directory)
    {:noreply, state}
  end

  def handle_info({:handoff_result, worker, result}, %{worker: worker} = state) do
    {:noreply, state |> disarm() |> continue_after(result)}
  end

  def handle_info({:handoff_result, _stale_worker, _result}, state), do: {:noreply, state}

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) when reason != :normal do
    result = {:error, %{kind: "fifo_write_failed", message: "The FIFO handoff worker stopped", details: %{reason: "worker_exit"}, next_actions: []}}
    {:noreply, state |> disarm() |> continue_after(result)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reenter, %{launch_mode: "darwin"} = state) do
    {:noreply, %{state | outcome: darwin_launch(state)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    remove_reentry_trap(state)
    # Order matters, and so does reaping the OS side. The BEAM worker is killed
    # untrappably, so FifoHandoff's own close_writer never runs on this path:
    # the perl writer blocks in `sysopen` BEFORE it reads stdin, so port closure
    # gives it no EOF and it would survive holding the pipe until its 65-second
    # watchdog fired. Kill the worker, reap the writer and watchdog, and only
    # then remove the directory they were writing into.
    kill_worker(state.worker)
    reap_writer(state.armed)
    _ = disarm(state)
    :ok
  end

  defp kill_worker(worker) when is_pid(worker), do: Process.exit(worker, :kill)
  defp kill_worker(_worker), do: :ok

  defp reap_writer(%{writer: %{os_pid: _} = writer}), do: PixirMonitor.FifoHandoff.close_writer(writer)
  defp reap_writer(_armed), do: :ok

  # --- fifo arming -----------------------------------------------------------

  defp arm(%{attempts: attempts, rearm_limit: limit} = state) when attempts > limit do
    emit_exhausted(state, nil)
    %{state | armed: nil, worker: nil, status: :exhausted, outcome: %{status: "not_attempted", kind: "launch_surface_exhausted"}}
  end

  defp arm(state), do: %{state | attempts: state.attempts + 1, armed: nil, status: :armed, worker: spawn_attempt(state)}

  # The bounded writer is a Port, and Port messages reach only the process that
  # opened it, so `prepare` and `handoff` must run in the SAME process. That
  # process is a linked worker rather than the surface itself, because `handoff`
  # blocks for the whole reader window while the surface must stay responsive to
  # `outcome`, `reenter`, and shutdown. The worker reports its armed path back so
  # the surface owns announcement and cleanup.
  defp spawn_attempt(state) do
    owner = self()
    prepare = state.prepare
    prepare_opts = state.prepare_opts
    handoff = state.handoff
    issue = fn -> issue_url(state) end
    opts = handoff_opts(state)

    spawn_link(fn ->
      worker = self()

      case prepare.(prepare_opts) do
        {:ok, prepared} ->
          send(owner, {:handoff_armed, worker, prepared})
          send(owner, {:handoff_result, worker, handoff.(prepared, issue, opts)})

        {:error, error} ->
          send(owner, {:handoff_result, worker, {:error, error}})
      end
    end)
  end

  defp handoff_opts(%{reader_timeout_ms: nil}), do: []
  defp handoff_opts(%{reader_timeout_ms: timeout}), do: [reader_timeout_ms: timeout]

  defp continue_after(state, :ok), do: arm(%{state | status: :idle})
  defp continue_after(state, {:ok, warning}) when is_map(warning), do: state |> emit_warning(warning) |> Map.put(:status, :idle) |> arm()

  defp continue_after(state, {:error, %{kind: kind} = error}) when kind in @degradable_kinds do
    degrade(state, error)
  end

  defp continue_after(state, {:error, error}) do
    # An unclassified handoff error is still auxiliary: report it and stop
    # re-arming rather than terminate a healthy serve. The terminal frame still
    # follows the degraded one, because README documents exactly two ways a
    # supervisor learns a surface stopped: a readiness frame after
    # `launch_degraded`, or `launch_surface_exhausted`. Emitting neither would
    # leave it waiting forever for a FIFO nobody will arm.
    error = normalize(error)
    kind = Map.get(error, :kind, "launch_handoff_failed")
    emit_degraded(state, error)
    emit_exhausted(state, kind)

    %{state | armed: nil, worker: nil, status: :exhausted, outcome: %{status: "failed", kind: kind}}
  end

  defp emit_exhausted(state, kind) do
    frame = %{
      ok: true,
      status: "launch_surface_exhausted",
      launch_mode: state.launch_mode,
      rearm_limit: state.rearm_limit,
      next_actions: ["Restart pixir-monitor serve --launch-mode fifo to arm a new launch surface"]
    }

    emit(state, if(kind, do: Map.put(frame, :kind, kind), else: frame))
  end

  defp degrade(state, error) do
    emit_degraded(state, error)
    arm(%{state | status: :idle})
  end

  defp emit_degraded(state, error) do
    error = normalize(error)

    emit(state, %{
      ok: true,
      status: "launch_degraded",
      launch_mode: state.launch_mode,
      attempt: state.attempts,
      kind: Map.get(error, :kind, "launch_handoff_failed"),
      message: Map.get(error, :message, "The launch handoff did not complete"),
      details: Map.get(error, :details, %{})
    })
  end

  defp emit_warning(state, warning) do
    emit(state, %{ok: true, status: "launch_warning", launch_mode: state.launch_mode, kind: Map.get(warning, :kind, "launch_warning"), message: Map.get(warning, :message, "")})
    state
  end

  defp disarm(%{armed: nil} = state), do: %{state | worker: nil}

  defp disarm(%{armed: prepared} = state) do
    _ = File.rm_rf(prepared.directory)
    %{state | armed: nil, worker: nil}
  end

  # --- darwin launch ---------------------------------------------------------

  defp darwin_launch(%{platform: {:unix, :darwin}} = state) do
    case launch_once(state) do
      :ok ->
        %{status: "succeeded"}

      {:error, error} ->
        error = normalize(error)
        outcome = %{status: "failed", kind: Map.get(error, :kind, "browser_open_failed"), details: Map.get(error, :details, %{})}
        emit(state, Map.merge(%{ok: true, status: "launch_degraded", launch_mode: "darwin"}, Map.take(outcome, [:kind, :details])))
        outcome
    end
  end

  defp darwin_launch(state) do
    outcome = %{
      status: "not_attempted",
      kind: "unsupported_platform",
      details: %{platform: inspect(state.platform)}
    }

    emit(state, %{ok: true, status: "launch_degraded", launch_mode: "darwin", kind: "unsupported_platform", details: outcome.details})
    outcome
  end

  # The capability URL is issued here and passed straight to the launcher; it is
  # bound to no state field, so no later frame can read it back out.
  defp launch_once(state) do
    with {:ok, url} <- issue_url(state) do
      case browser_launcher().(url) do
        :ok ->
          :ok

        # The launcher receives the capability URL, so its own error term is
        # untrusted at this boundary: a callback can echo the URL back inside
        # the map, and `normalize/1` preserves an already-`:kind`-shaped map
        # verbatim into a `launch_degraded` frame. Only the launcher's KIND
        # crosses, never its payload. Same rule as the `rescue` below and as
        # `PixirMonitor.FifoHandoff`'s allowlist of issuer failures.
        {:error, reason} ->
          launcher_error(reason)

        _other ->
          launcher_error(:launcher_contract_violation)
      end
    end
  rescue
    # Same boundary rule as PixirMonitor.Runtime: a raised message can carry the
    # capability URL, so report a fixed atom instead of the exception.
    _error -> launcher_error(:launcher_raised)
  catch
    # Throw and exit payloads are equally untrusted. Never inspect or retain
    # either term: each mode collapses to this module's fixed classification.
    :throw, _reason -> launcher_error(:launcher_threw)
    :exit, _reason -> launcher_error(:launcher_exited)
  end

  # Fixed reasons only. A launcher error never travels as a term: an atom from
  # this module's own vocabulary is mapped through, and everything else — every
  # map, string, and term the callback chose — collapses to a single opaque
  # reason. `inspect/1` runs on the atom, never on the callback's payload.
  @launcher_reasons ~w(launcher_contract_violation launcher_raised launcher_threw launcher_exited)a

  defp launcher_error(reason) when reason in @launcher_reasons, do: launcher_error_frame(inspect(reason))
  defp launcher_error(_reason), do: launcher_error_frame(":launcher_reported_failure")

  defp launcher_error_frame(reason) do
    {:error, %{kind: "browser_open_failed", message: "The monitor could not open the browser", details: %{reason: reason}, next_actions: []}}
  end

  defp browser_launcher, do: Application.get_env(:pixir_monitor, :browser_launcher, &PixirMonitor.Runtime.launch_darwin/1)

  # Same injection idiom as `:browser_launcher`: the darwin outcome pins must be
  # exercisable on the Linux CI runner, and the platform gate is exactly what
  # decides between a launcher attempt and an `unsupported_platform` outcome.
  defp platform, do: Application.get_env(:pixir_monitor, :launch_platform, :os.type())

  defp issue_url(%{issue_url: issuer}) when is_function(issuer, 0), do: issuer.()

  defp issue_url(%{port: port}) when is_integer(port) and port > 0 do
    PixirMonitor.Runtime.issue_launch_url(port)
  end

  defp issue_url(_state) do
    case PixirMonitor.PortRegistry.active_port() do
      {:ok, port} -> PixirMonitor.Runtime.issue_launch_url(port)
      {:error, _} = error -> error
    end
  end

  # --- re-entry --------------------------------------------------------------

  defp install_reentry_trap(%{install_reentry_trap: false} = state), do: state

  defp install_reentry_trap(state) do
    surface = self()
    # The trap id is per-surface, not a fixed atom: a fixed id makes a second
    # install collide with a stale registration and silently route the signal to
    # a dead surface, which is how a re-entry mechanism stops re-entering.
    id = {__MODULE__, :reentry, surface}

    with :ok <- :os.set_signal(@reentry_signal, :handle),
         # The handler must return :ok — System.SignalHandler matches on it, and
         # `send/2` returns the message, which would kill the handler.
         {:ok, trap_id} <-
           System.trap_signal(@reentry_signal, id, fn ->
             send(surface, :reenter)
             :ok
           end) do
      Map.put(state, :reentry_trap, trap_id)
    else
      _unsupported -> state
    end
  rescue
    _error -> state
  end

  defp remove_reentry_trap(state) do
    case Map.get(state, :reentry_trap) do
      nil -> :ok
      trap_id -> _ = System.untrap_signal(@reentry_signal, trap_id)
    end

    :ok
  rescue
    _error -> :ok
  end

  # --- frames ----------------------------------------------------------------

  defp emit(%{emit: emit}, frame) when is_function(emit, 1) do
    _ = emit.(frame)
    :ok
  rescue
    _error -> :ok
  end

  defp emit(_state, _frame), do: :ok

  defp normalize(%{kind: _} = error), do: error
  defp normalize(reason), do: %{kind: "launch_handoff_failed", message: "The launch handoff did not complete", details: %{reason: inspect(reason, limit: 5, printable_limit: 120)}}
end
