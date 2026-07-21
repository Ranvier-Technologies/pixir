defmodule PixirMonitor.FifoHandoff do
  @moduledoc """
  Performs the opt-in external-reader launch handoff.

  The module atomically creates its own unpredictable private directory and FIFO,
  then starts a bounded writer before exposing the FIFO path. The writer signals
  only after a reader has opened the pipe; capability issuance happens after that
  signal. Capability-bearing bytes cross the writer's stdin once and are never
  included in return values or errors.

  Direct PID cleanup bounds normal aborts. A shell-side watchdog detects early
  writer death and also bounds the writer if the owning BEAM exits before it can
  perform cleanup. The writer opens without create semantics and verifies the
  opened descriptor is still a FIFO before it signals a connected reader.
  """

  @reader_timeout_ms 60_000
  @write_timeout_ms 2_000
  @writer_setup_timeout_ms 2_000
  @watchdog_seconds 65
  @safe_issue_kinds ~w(launch_limit port_unavailable)
  @writer_script """
  watchdog_seconds="$2"
  perl="$3"
  open_delay_ms="$5"
  "$perl" -e 'my ($seconds, $pid, $fifo, $directory) = @ARGV; for (1 .. $seconds * 10) { select undef, undef, undef, 0.1; if (getppid() != $pid || !kill(0, $pid)) { unlink $fifo; rmdir $directory; exit 0 } } kill 9, $pid; unlink $fifo; rmdir $directory' "$watchdog_seconds" "$$" "$1" "$4" </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  trap 'kill "$watchdog_pid" 2>/dev/null || true' EXIT
  printf 'ARMED:%s\n' "$watchdog_pid"
  exec "$perl" -e 'use Fcntl qw(O_WRONLY); my ($fifo, $delay_ms, $watchdog_pid) = @ARGV; END { kill 9, $watchdog_pid if $watchdog_pid } select undef, undef, undef, $delay_ms / 1000 if $delay_ms > 0; sysopen(my $pipe, $fifo, O_WRONLY) or exit 71; exit 72 unless -p $pipe; $| = 1; print "READY\n"; my $launch_url = <STDIN>; exit 70 unless defined $launch_url; print {$pipe} $launch_url or exit 73; close $pipe or exit 74' "$1" "$open_delay_ms" "$watchdog_pid"
  """

  @type writer :: %{
          port: port(),
          os_pid: pos_integer(),
          watchdog_pid: pos_integer(),
          kill: String.t()
        }
  @type prepared :: %{directory: String.t(), fifo: String.t(), writer: writer()}

  @spec prepare(keyword()) :: {:ok, prepared()} | {:error, map()}
  def prepare(opts \\ []) do
    directory = private_directory()
    fifo = Path.join(directory, "launch.fifo")
    watchdog_seconds = Keyword.get(opts, :watchdog_seconds, @watchdog_seconds)
    writer_open_delay_ms = Keyword.get(opts, :writer_open_delay_ms, 0)

    case mkdir_private(directory) do
      :ok -> prepare_created(directory, fifo, watchdog_seconds, writer_open_delay_ms)
      {:error, reason} -> {:error, setup_error(reason)}
    end
  rescue
    # This error is operator-local rather than API-served, but the same boundary
    # doctrine keeps environment detail out of diagnostics. Report a fixed atom.
    _error -> {:error, setup_error(:fifo_prepare_raised)}
  end

  defp prepare_created(directory, fifo, watchdog_seconds, writer_open_delay_ms) do
    result =
      with :ok <- make_fifo(fifo),
           :ok <- chmod_fifo(fifo),
           {:ok, writer} <-
             start_writer(fifo, directory, watchdog_seconds, writer_open_delay_ms) do
        {:ok, %{directory: directory, fifo: fifo, writer: writer}}
      end

    case result do
      {:ok, _prepared} = ok ->
        ok

      {:error, %{kind: _} = error} ->
        _ = File.rm_rf(directory)
        {:error, error}

      {:error, reason} ->
        _ = File.rm_rf(directory)
        {:error, setup_error(reason)}
    end
  rescue
    # This error is operator-local rather than API-served, but the same boundary
    # doctrine keeps environment detail out of diagnostics. Report a fixed atom.
    _error ->
      _ = File.rm_rf(directory)
      {:error, setup_error(:fifo_prepare_created_raised)}
  end

  @spec handoff(prepared(), (-> {:ok, String.t()} | {:error, map()}), keyword()) ::
          :ok | {:ok, map()} | {:error, map()}
  def handoff(prepared, issue_url, opts \\ []) when is_function(issue_url, 0) do
    reader_timeout = Keyword.get(opts, :reader_timeout_ms, @reader_timeout_ms)
    write_timeout = Keyword.get(opts, :write_timeout_ms, @write_timeout_ms)
    reader_deadline = deadline(reader_timeout)

    result =
      await_reader(
        prepared.writer,
        issue_url,
        reader_deadline,
        reader_timeout,
        write_timeout
      )

    finish(result, prepared.directory)
  end

  defp await_reader(writer, issue_url, reader_deadline, reader_timeout, write_timeout) do
    receive do
      {port, {:data, {:eol, "READY"}}} when port == writer.port ->
        case safe_issue(issue_url) do
          {:ok, url} when is_binary(url) ->
            if Port.command(writer.port, url <> "\n") do
              await_write(writer, deadline(write_timeout))
            else
              close_writer(writer)
              write_error(:writer_closed)
            end

          {:error, error} ->
            close_writer(writer)
            {:error, issue_error(error)}

          other ->
            close_writer(writer)
            {:error, issue_error(other)}
        end

      {port, {:data, _bounded_diagnostic}} when port == writer.port ->
        await_reader(writer, issue_url, reader_deadline, reader_timeout, write_timeout)

      {port, {:exit_status, status}} when port == writer.port ->
        close_writer(writer)
        write_error({:writer_exit, status})
    after
      remaining(reader_deadline) ->
        close_writer(writer)

        {:error,
         %{
           kind: "fifo_reader_timeout",
           message: "No FIFO reader connected before the bounded deadline",
           details: %{timeout_ms: reader_timeout},
           next_actions: [
             "Open the announced FIFO for reading, then retry pixir-monitor serve --launch-mode fifo"
           ]
         }}
    end
  end

  defp safe_issue(issue_url) do
    issue_url.()
  rescue
    _error -> {:error, :issuer_exception}
  catch
    _kind, _reason -> {:error, :issuer_exit}
  end

  defp await_write(writer, write_deadline) do
    receive do
      {port, {:data, _bounded_diagnostic}} when port == writer.port ->
        await_write(writer, write_deadline)

      {port, {:exit_status, 0}} when port == writer.port ->
        :ok

      {port, {:exit_status, status}} when port == writer.port ->
        close_writer(writer)
        write_error({:writer_exit, status})
    after
      remaining(write_deadline) ->
        close_writer(writer)
        write_error(:timeout)
    end
  end

  defp start_writer(fifo, directory, watchdog_seconds, writer_open_delay_ms) do
    with {:ok, shell} <- executable("sh"),
         {:ok, kill} <- executable("kill"),
         {:ok, perl} <- executable("perl"),
         {:ok, port, os_pid} <-
           open_writer(
             shell,
             perl,
             fifo,
             directory,
             watchdog_seconds,
             writer_open_delay_ms
           ) do
      case await_writer_armed(port, deadline(@writer_setup_timeout_ms)) do
        {:ok, watchdog_pid} ->
          {:ok, %{port: port, os_pid: os_pid, watchdog_pid: watchdog_pid, kill: kill}}

        {:error, reason} ->
          close_partial_writer(%{port: port, os_pid: os_pid, kill: kill})
          writer_setup_error(reason)
      end
    else
      {:error, reason} ->
        writer_setup_error(reason)
    end
  rescue
    _error -> writer_setup_error(:writer_start_failed)
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:executable_unavailable, name}}
      path -> {:ok, path}
    end
  end

  defp open_writer(
         shell,
         perl,
         fifo,
         directory,
         watchdog_seconds,
         writer_open_delay_ms
       ) do
    port =
      Port.open(
        {:spawn_executable, shell},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 256},
          args: [
            "-c",
            @writer_script,
            "pixir-monitor-fifo-writer",
            fifo,
            Integer.to_string(max(watchdog_seconds, 1)),
            perl,
            directory,
            Integer.to_string(max(writer_open_delay_ms, 0))
          ]
        ]
      )

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        {:ok, port, os_pid}

      _ ->
        close_port(port)
        {:error, :writer_pid_unavailable}
    end
  end

  defp await_writer_armed(port, setup_deadline) do
    receive do
      {^port, {:data, {:eol, "ARMED:" <> encoded_pid}}} ->
        case Integer.parse(encoded_pid) do
          {pid, ""} when pid > 0 -> {:ok, pid}
          _ -> {:error, :invalid_watchdog_pid}
        end

      {^port, {:data, _bounded_diagnostic}} ->
        await_writer_armed(port, setup_deadline)

      {^port, {:exit_status, status}} ->
        {:error, {:writer_exit, status}}
    after
      remaining(setup_deadline) ->
        {:error, :writer_setup_timeout}
    end
  end

  defp close_partial_writer(%{port: port, os_pid: os_pid, kill: kill}) do
    kill_pid(kill, os_pid)
    close_port(port)
  end

  defp close_writer(writer) do
    kill_pid(writer.kill, writer.watchdog_pid)
    kill_pid(writer.kill, writer.os_pid)
    close_port(writer.port)
  end

  defp kill_pid(kill, pid) when is_binary(kill) and is_integer(pid) and pid > 0 do
    _ = System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp kill_pid(_kill, _pid), do: :ok

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp finish(result, directory) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        result

      {:error, reason, path} ->
        cleanup = cleanup_error(reason, path)

        case result do
          :ok -> {:ok, cleanup}
          {:error, error} -> {:error, attach_cleanup(error, cleanup)}
        end
    end
  end

  defp attach_cleanup(error, cleanup) do
    Map.update(error, :details, %{cleanup: cleanup}, &Map.put(&1, :cleanup, cleanup))
  end

  defp mkdir_private(directory) do
    with {:ok, mkdir} <- executable("mkdir") do
      case System.cmd(mkdir, ["-m", "700", directory], stderr_to_stdout: true) do
        {_bounded_output, 0} -> :ok
        {_bounded_output, status} -> {:error, {:mkdir_exit, status}}
      end
    end
  end

  defp make_fifo(fifo) do
    with {:ok, mkfifo} <- executable("mkfifo") do
      case System.cmd(mkfifo, ["-m", "600", fifo], stderr_to_stdout: true) do
        {_bounded_output, 0} -> :ok
        {_bounded_output, status} -> {:error, {:mkfifo_exit, status}}
      end
    end
  end

  defp chmod_fifo(fifo), do: File.chmod(fifo, 0o600)

  defp private_directory do
    suffix = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "pixir-monitor-external-#{suffix}")
  end

  defp deadline(timeout), do: monotonic_ms() + max(timeout, 0)
  defp remaining(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp setup_error(reason) do
    %{
      kind: "fifo_setup_failed",
      message: "The private launch FIFO could not be created",
      details: %{reason: inspect(reason, limit: 10, printable_limit: 200)},
      next_actions: [
        "Verify that the temporary filesystem supports private named pipes, then retry"
      ]
    }
  end

  defp writer_setup_error(reason) do
    {:error,
     %{
       kind: "fifo_writer_setup_failed",
       message: "The bounded FIFO writer could not be started",
       details: %{reason: inspect(reason, limit: 10, printable_limit: 200)},
       next_actions: ["Verify that sh, kill, and perl are available, then retry"]
     }}
  end

  defp write_error(reason) do
    {:error,
     %{
       kind: "fifo_write_failed",
       message: "The launch handoff could not be written to the connected FIFO",
       details: %{reason: inspect(reason, limit: 10, printable_limit: 200)},
       next_actions: ["Keep the FIFO reader open until it receives one line, then retry"]
     }}
  end

  defp issue_error(%{kind: kind}) when kind in @safe_issue_kinds do
    launch_issue_error(%{source_kind: kind})
  end

  defp issue_error(_reason), do: launch_issue_error(%{})

  defp launch_issue_error(details) do
    %{
      kind: "launch_issue_failed",
      message: "The one-use launch capability could not be issued",
      details: details,
      next_actions: ["Retry the FIFO handoff after checking the local monitor runtime"]
    }
  end

  defp cleanup_error(reason, path) do
    %{
      kind: "fifo_cleanup_failed",
      message: "The private FIFO directory could not be removed",
      details: %{reason: inspect(reason), path: path},
      next_actions: ["Remove the reported private temporary directory after the session"]
    }
  end
end
