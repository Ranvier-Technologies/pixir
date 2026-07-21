defmodule PixirMonitor.SseDrainTest do
  use ExUnit.Case, async: false

  test "supervisor shutdown drains subscribers and restart clears the draining flag" do
    subscribers = for _ <- 1..3, do: start_subscriber(self())

    on_exit(fn ->
      Enum.each(subscribers, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      if Process.whereis(PixirMonitor.SseDrainer) == nil do
        Supervisor.restart_child(PixirMonitor.Supervisor, PixirMonitor.SseDrainer)
      end
    end)

    Enum.each(subscribers, fn pid ->
      assert_receive {:subscribed, ^pid, {:ok, _sequence}}
    end)

    :ok = Supervisor.terminate_child(PixirMonitor.Supervisor, PixirMonitor.SseDrainer)

    Enum.each(subscribers, fn pid ->
      assert_receive {:closed, ^pid}
    end)

    assert PixirMonitor.SseDrainer.draining?() == true

    # No subscriber may slip in unclosed once the drain has fired: admission is
    # rejected while draining, and re-admitted after the drainer restarts.
    assert {:error, %{kind: "shutting_down"}} = PixirMonitor.InvalidationHub.subscribe()

    {:ok, _pid} = Supervisor.restart_child(PixirMonitor.Supervisor, PixirMonitor.SseDrainer)
    assert PixirMonitor.SseDrainer.draining?() == false

    late = start_subscriber(self())
    assert_receive {:subscribed, ^late, {:ok, _sequence}}
    Process.exit(late, :kill)
  end

  defp start_subscriber(parent) do
    spawn(fn ->
      result = PixirMonitor.InvalidationHub.subscribe()
      send(parent, {:subscribed, self(), result})

      receive do
        :pixir_sse_close -> send(parent, {:closed, self()})
      end
    end)
  end
end
