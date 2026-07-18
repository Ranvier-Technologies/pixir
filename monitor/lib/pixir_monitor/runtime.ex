defmodule PixirMonitor.Runtime do
  @moduledoc """
  Coordinates active-port discovery, one-use launch issuance, and browser handoff.

  Capability-bearing URLs stay in memory and cross into macOS automation through the
  private environment of a short-lived launcher process, never in process arguments,
  diagnostics, stdout, or regular files.
  """

  @spec issue_launch_url(pos_integer()) :: {:ok, String.t()} | {:error, map()}
  def issue_launch_url(port) when is_integer(port) and port > 0 do
    with {:ok, capability} <- PixirMonitor.Vault.issue_launch() do
      {:ok, "http://127.0.0.1:#{port}/#launch=#{capability}"}
    end
  end

  @spec launch_browser() :: :ok | {:error, map()}
  def launch_browser do
    with :ok <- supported_platform(),
         {:ok, port} <- PixirMonitor.PortRegistry.wait(),
         {:ok, url} <- issue_launch_url(port),
         :ok <- browser_launcher().(url) do
      :ok
    else
      {:error, _} = error -> error
      # A launcher return outside its :ok | {:error, map} contract is reported
      # as a fixed atom: an arbitrary term must never be inspected into
      # diagnostics from this boundary.
      _other -> browser_error(:launcher_contract_violation)
    end
  rescue
    # Same boundary rule as the contract-violation clause above: a raised
    # exception message can carry the capability launch URL (issue_launch_url
    # runs just before the launcher), so it must never reach diagnostics.
    # Report a fixed atom instead of Exception.message/1.
    _error -> browser_error(:launcher_raised)
  end

  defp supported_platform do
    case :os.type() do
      {:unix, :darwin} ->
        :ok

      type ->
        {:error, %{kind: "unsupported_platform", message: "Automatic browser launch is supported only on macOS", details: %{platform: inspect(type)}, next_actions: ["Run Pixir Monitor on macOS"]}}
    end
  end

  defp browser_launcher do
    Application.get_env(:pixir_monitor, :browser_launcher, &launch_darwin/1)
  end

  @launch_url_env "PIXIR_MONITOR_LAUNCH_URL"
  @launcher_timeout_ms 5_000

  defp launch_darwin(url) do
    {executable, args, env} = darwin_launch_command(url)
    run_launcher_bounded(executable, args, env, @launcher_timeout_ms)
  end

  # The capability URL travels only in the launcher's environment: the osascript
  # script text names the variable, so argv stays free of capability bytes and the
  # launcher terminates on its own (an osascript reading its script from a FIFO
  # never exits; see issue #386).
  @doc false
  @spec darwin_launch_command(String.t()) :: {String.t(), [String.t()], [{String.t(), String.t()}]}
  def darwin_launch_command(url) do
    script = ~s|open location (system attribute "#{@launch_url_env}")|
    {"/usr/bin/osascript", ["-e", script], [{@launch_url_env, url}]}
  end

  # Launcher output is discarded unread: an AppleScript error can echo the resolved
  # location, and capability bytes must never reach diagnostics. The launcher runs as
  # a port so its OS pid is known and a hung launcher is reaped on timeout instead of
  # surviving with the capability still in its environment. Every diagnostics reason
  # is a fixed atom or a bounded integer; no launcher-derived term crosses into
  # browser_error.
  @doc false
  @spec run_launcher_bounded(String.t(), [String.t()], [{String.t(), String.t()}], pos_integer()) :: :ok | {:error, map()}
  def run_launcher_bounded(executable, args, env, timeout_ms) do
    port_env = Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args, env: port_env]
      )

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        await_launcher(port, os_pid, deadline)

      _ ->
        drain_exited_launcher(port)
    end
  rescue
    _error -> browser_error(:launcher_spawn_failed)
  end

  # The deadline is absolute AND checked before each receive: a chatty launcher
  # cannot slide the window, and a launcher flooding output cannot starve the
  # after clause past the deadline either (queued {:data, _} messages match
  # before `after 0` would fire, so the guard must not live in the receive).
  defp await_launcher(port, os_pid, deadline) do
    if remaining_ms(deadline) == 0 do
      # A launcher that exited inside the bound but whose exit_status is
      # already queued at the exact boundary is honored, not misreported as a
      # timeout; the peek is non-blocking.
      receive do
        {^port, {:exit_status, 0}} -> :ok
        {^port, {:exit_status, status}} -> browser_error(%{launcher_exit_status: status})
      after
        0 ->
          reap_launcher(port, os_pid)
          browser_error(:launcher_timeout)
      end
    else
      receive do
        {^port, {:data, _discarded_output}} -> await_launcher(port, os_pid, deadline)
        {^port, {:exit_status, 0}} -> :ok
        {^port, {:exit_status, status}} -> browser_error(%{launcher_exit_status: status})
      after
        remaining_ms(deadline) ->
          reap_launcher(port, os_pid)
          browser_error(:launcher_timeout)
      end
    end
  end

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  # A port without an OS pid is either a launcher that already exited (its
  # exit_status arrives in the mailbox as the port closes itself on process
  # exit) or an unaccountable process; the latter fails closed, because a
  # launcher that cannot be reaped must not be left running with the capability
  # in its environment. The drain window is small but nonzero so a fast-exit
  # launcher whose exit_status is still in flight is not misclassified.
  @drain_exit_status_ms 100

  defp drain_exited_launcher(port) do
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> browser_error(%{launcher_exit_status: status})
    after
      @drain_exit_status_ms ->
        close_port(port)
        browser_error(:launcher_pid_unavailable)
    end
  end

  # Kill and close are independent attempts: a raise in one must not skip the
  # other. The exit_status paths need no close (with :exit_status the port
  # closes itself when the process exits; probed empirically).
  defp reap_launcher(port, os_pid) do
    kill_launcher(os_pid)
    close_port(port)
  end

  defp kill_launcher(os_pid) do
    _ = System.cmd("/bin/kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp browser_error(reason) do
    {:error,
     %{kind: "browser_open_failed", message: "The monitor could not open the browser", details: %{reason: inspect(reason)}, next_actions: ["Verify macOS browser automation is available, then retry"]}}
  end
end
