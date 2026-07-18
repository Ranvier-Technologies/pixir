defmodule PixirMonitor.FifoHandoffTest do
  use ExUnit.Case, async: true

  import Bitwise

  @tag :unix
  test "creates a private FIFO and performs a real one-use reader handoff" do
    if unix_with_mkfifo?() do
      assert {:ok, prepared} = PixirMonitor.FifoHandoff.prepare()
      directory = prepared.directory
      writer_pid = prepared.writer.os_pid
      watchdog_pid = prepared.writer.watchdog_pid

      assert {:ok, directory_stat} = File.stat(directory)
      assert band(directory_stat.mode, 0o777) == 0o700
      assert {:ok, fifo_stat} = File.stat(prepared.fifo)
      assert band(fifo_stat.mode, 0o777) == 0o600
      assert fifo_stat.type == :other

      reader = external_reader(prepared.fifo)
      secret_url = "http://127.0.0.1:4321/#launch=never-print-this-capability"

      assert :ok = PixirMonitor.FifoHandoff.handoff(prepared, fn -> {:ok, secret_url} end)
      assert Task.await(reader) == secret_url <> "\n"
      refute File.exists?(directory)
      refute process_alive?(writer_pid)
      refute process_alive?(watchdog_pid)
    else
      assert true
    end
  end

  @tag :unix
  test "reader timeout is structured and removes the private directory" do
    if unix_with_mkfifo?() do
      assert {:ok, prepared} = PixirMonitor.FifoHandoff.prepare()
      writer_pid = prepared.writer.os_pid
      watchdog_pid = prepared.writer.watchdog_pid

      assert process_alive?(writer_pid)
      assert process_alive?(watchdog_pid)

      assert {:error, error} =
               PixirMonitor.FifoHandoff.handoff(
                 prepared,
                 fn -> flunk("capability must not be issued without a connected reader") end,
                 reader_timeout_ms: 20
               )

      assert error.kind == "fifo_reader_timeout"
      assert is_map(error.details)
      assert is_list(error.next_actions)
      refute File.exists?(prepared.directory)
      refute process_alive?(writer_pid)
      refute process_alive?(watchdog_pid)
    else
      assert true
    end
  end

  @tag :unix
  test "issuer errors are sanitized and remove the private directory" do
    if unix_with_mkfifo?() do
      assert {:ok, prepared} = PixirMonitor.FifoHandoff.prepare()
      writer_pid = prepared.writer.os_pid
      watchdog_pid = prepared.writer.watchdog_pid
      reader = external_reader(prepared.fifo)

      assert {:error, error} =
               PixirMonitor.FifoHandoff.handoff(prepared, fn ->
                 {:error,
                  %{
                    kind: "#launch=must-not-escape",
                    reason: "#launch=must-not-escape"
                  }}
               end)

      assert error.kind == "launch_issue_failed"
      refute inspect(error) =~ "must-not-escape"
      assert Task.await(reader) == ""
      refute File.exists?(prepared.directory)
      refute process_alive?(writer_pid)
      refute process_alive?(watchdog_pid)
    else
      assert true
    end
  end

  @tag :unix
  test "issuer errors preserve only an allowlisted non-secret source kind" do
    if unix_with_mkfifo?() do
      assert {:ok, prepared} = PixirMonitor.FifoHandoff.prepare()
      reader = external_reader(prepared.fifo)

      assert {:error, error} =
               PixirMonitor.FifoHandoff.handoff(prepared, fn ->
                 {:error,
                  %{
                    kind: "port_unavailable",
                    details: %{private: "#launch=must-not-escape"}
                  }}
               end)

      assert error.kind == "launch_issue_failed"
      assert error.details == %{source_kind: "port_unavailable"}
      refute inspect(error) =~ "must-not-escape"
      assert Task.await(reader) == ""
    else
      assert true
    end
  end

  @tag :unix
  test "watchdog bounds and cleans a writer abandoned by its BEAM owner" do
    if unix_with_mkfifo?() do
      parent = self()

      spawn(fn ->
        assert {:ok, prepared} = PixirMonitor.FifoHandoff.prepare(watchdog_seconds: 1)

        send(parent, {
          :abandoned_writer,
          prepared.writer.os_pid,
          prepared.writer.watchdog_pid,
          prepared.directory
        })
      end)

      assert_receive {:abandoned_writer, writer_pid, watchdog_pid, directory}, 2_000
      assert process_alive?(writer_pid)
      assert process_alive?(watchdog_pid)

      assert eventually(fn ->
               not process_alive?(writer_pid) and not process_alive?(watchdog_pid) and
                 not File.exists?(directory)
             end)
    else
      assert true
    end
  end

  @tag :unix
  test "watchdog exits promptly and cleans when its writer dies during setup" do
    if unix_with_mkfifo?() do
      assert {:ok, prepared} = PixirMonitor.FifoHandoff.prepare(watchdog_seconds: 65)
      writer_pid = prepared.writer.os_pid
      watchdog_pid = prepared.writer.watchdog_pid

      assert process_alive?(writer_pid)
      assert process_alive?(watchdog_pid)
      kill_pid(writer_pid)

      assert eventually(fn ->
               not process_alive?(writer_pid) and not process_alive?(watchdog_pid) and
                 not File.exists?(prepared.directory)
             end)
    else
      assert true
    end
  end

  @tag :unix
  test "missing FIFO is not recreated and cannot trigger capability issuance" do
    if unix_with_mkfifo?() do
      assert {:ok, prepared} =
               PixirMonitor.FifoHandoff.prepare(writer_open_delay_ms: 250)

      File.rm!(prepared.fifo)
      parent = self()

      assert {:error, error} =
               PixirMonitor.FifoHandoff.handoff(prepared, fn ->
                 send(parent, :capability_issued_for_missing_fifo)
                 {:ok, "http://127.0.0.1:4321/#launch=must-never-reach-a-file"}
               end)

      assert error.kind == "fifo_write_failed"
      refute_received :capability_issued_for_missing_fifo
      refute File.exists?(prepared.directory)
    else
      assert true
    end
  end

  @tag :unix
  test "regular-file replacement cannot become a capability sink" do
    if unix_with_mkfifo?() do
      outside = Path.join(System.tmp_dir!(), "pixir-monitor-sink-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(outside) end)
      File.write!(outside, "sentinel")

      assert {:ok, prepared} =
               PixirMonitor.FifoHandoff.prepare(writer_open_delay_ms: 250)

      File.rm!(prepared.fifo)
      File.ln!(outside, prepared.fifo)
      secret_url = "http://127.0.0.1:4321/#launch=must-never-reach-a-file"

      assert {:error, error} =
               PixirMonitor.FifoHandoff.handoff(prepared, fn -> {:ok, secret_url} end)

      assert error.kind == "fifo_write_failed"
      assert File.read!(outside) == "sentinel"
      refute File.exists?(prepared.directory)
    else
      assert true
    end
  end

  defp unix_with_mkfifo? do
    match?({:unix, _}, :os.type()) and not is_nil(System.find_executable("mkfifo")) and
      not is_nil(System.find_executable("cat"))
  end

  defp external_reader(fifo) do
    cat = System.find_executable("cat")

    Task.async(fn ->
      {bytes, 0} = System.cmd(cat, [fifo], stderr_to_stdout: true)
      bytes
    end)
  end

  defp process_alive?(pid) do
    {_output, status} =
      System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  end

  defp kill_pid(pid) do
    {_output, status} =
      System.cmd(System.find_executable("kill"), ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

    assert status == 0
  end

  defp eventually(predicate, attempts \\ 120)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      true
    else
      Process.sleep(25)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: false
end
