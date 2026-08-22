defmodule Pixir.ACP.RuntimeModeTest do
  use ExUnit.Case, async: true

  alias Pixir.ACP.RuntimeMode

  defmodule CastProbe do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast(message, test_pid) do
      send(test_pid, message)
      {:noreply, test_pid}
    end
  end

  test "leave_plan is a no-op without an ACP binding or outside plan mode" do
    assert :ok = RuntimeMode.leave_plan(%{})
    assert :ok = RuntimeMode.leave_plan(%{mode: :plan})

    assert :ok =
             RuntimeMode.leave_plan(%{
               mode: :build,
               acp_runtime: %{server: self(), acp_sid: "s1"}
             })
  end

  test "leave_plan queues runtime_config_change for a plan-mode ACP session" do
    {:ok, server} = start_supervised({CastProbe, self()})

    assert {:ok, :queued} =
             RuntimeMode.leave_plan(%{
               mode: :plan,
               acp_runtime: %{server: server, acp_sid: "acp-1"}
             })

    assert_receive {:runtime_config_change, "acp-1", %{"mode" => "build"}}
  end
end
