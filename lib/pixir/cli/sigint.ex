defmodule Pixir.CLI.Sigint do
  @moduledoc """
  Installs the CLI interrupt bridge for long-running Pixir turns.

  The escript runs without Mix loaded, so this module keeps runtime checks free of
  direct Mix dependencies while still letting tests disable the OS signal trap by
  default.
  """

  alias Pixir.{Conversation, Session}

  @trap_id :pixir_cli_turn

  @doc false
  @spec install(String.t()) :: {:ok, {atom(), port()}} | :unsupported
  def install(session_id) when is_binary(session_id) do
    if test_env?() and not Application.get_env(:pixir, :cli_sigint_trap, false) do
      :unsupported
    else
      install_trap(session_id)
    end
  end

  defp install_trap(session_id) do
    with :ok <- :os.set_signal(:sigusr1, :handle),
         {:ok, trap_id} <- trap_sigusr1(session_id),
         {:ok, port} <- start_sigint_forwarder(:os.getpid()) do
      {:ok, {trap_id, port}}
    else
      _ -> :unsupported
    end
  end

  @doc false
  @spec remove({atom(), port()}) :: :ok
  def remove({trap_id, port}) when is_atom(trap_id) and is_port(port) do
    Port.close(port)
    _ = System.untrap_signal(:sigusr1, trap_id)
    :ok
  end

  @doc false
  @spec on_interrupt(String.t()) :: :interrupt_turn | :exit_idle
  def on_interrupt(session_id) when is_binary(session_id) do
    if Session.turn_running?(session_id) do
      _ = Conversation.interrupt(session_id)
      :interrupt_turn
    else
      :exit_idle
    end
  end

  defp trap_sigusr1(session_id) do
    System.trap_signal(:sigusr1, @trap_id, fn ->
      case on_interrupt(session_id) do
        :interrupt_turn ->
          :ok

        :exit_idle ->
          if test_env?(), do: :ok, else: System.halt(130)
      end
    end)
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp start_sigint_forwarder(beam_pid) do
    script = ~s(trap 'kill -USR1 #{beam_pid}' INT; while sleep 3600; do :; done)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        {:args, ["-c", script]}
      ])

    {:ok, port}
  end
end
