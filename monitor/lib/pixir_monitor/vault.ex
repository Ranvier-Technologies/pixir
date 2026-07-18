defmodule PixirMonitor.Vault do
  @moduledoc """
  Holds short-lived one-use launch capabilities and opaque browser sessions in memory.

  Values are never persisted or emitted as diagnostics. Capability consumption is an
  atomic GenServer operation and is the monitor's sole HTTP security-state transition.
  """
  use GenServer

  @launch_ttl_ms 30_000
  @session_ttl_ms 86_400_000
  @max_launches 256
  @max_sessions 256

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec issue_launch() :: {:ok, String.t()} | {:error, map()}
  def issue_launch, do: GenServer.call(__MODULE__, {:issue_launch, @launch_ttl_ms})

  @doc false
  def issue_launch_for_test(ttl_ms) when is_integer(ttl_ms),
    do: GenServer.call(__MODULE__, {:issue_launch, ttl_ms})

  @spec consume_launch(String.t()) :: {:ok, String.t()} | {:error, :invalid_or_expired | map()}
  def consume_launch(token), do: GenServer.call(__MODULE__, {:consume, token})

  @spec valid_session?(String.t() | nil) :: boolean()
  def valid_session?(session), do: GenServer.call(__MODULE__, {:valid_session, session})

  @impl true
  def init(_opts), do: {:ok, %{launches: %{}, sessions: %{}}}

  @impl true
  def handle_call({:issue_launch, ttl_ms}, _from, state) do
    launches = prune(state.launches)
    sessions = prune(state.sessions)

    if map_size(launches) >= @max_launches do
      error = %{kind: "launch_limit", message: "Launch capability limit reached", details: %{limit: @max_launches}}
      {:reply, {:error, error}, %{state | launches: launches, sessions: sessions}}
    else
      token = random_value()
      state = %{state | launches: Map.put(launches, token, now() + ttl_ms), sessions: sessions}
      {:reply, {:ok, token}, state}
    end
  end

  def handle_call({:consume, token}, _from, state) do
    launches = prune(state.launches)
    sessions = prune(state.sessions)
    expires_at = Map.get(launches, token)
    state = %{state | launches: launches, sessions: sessions}

    cond do
      not (is_integer(expires_at) and expires_at > now()) ->
        {:reply, {:error, :invalid_or_expired}, state}

      map_size(sessions) >= @max_sessions ->
        error = %{kind: "session_limit", message: "Browser session limit reached", details: %{limit: @max_sessions}}
        {:reply, {:error, error}, state}

      true ->
        session = random_value()

        next =
          state
          |> put_in([:sessions, session], now() + @session_ttl_ms)
          |> update_in([:launches], &Map.delete(&1, token))

        {:reply, {:ok, session}, next}
    end
  end

  def handle_call({:valid_session, session}, _from, state) do
    sessions = prune(state.sessions)
    {:reply, is_binary(session) and Map.has_key?(sessions, session), %{state | sessions: sessions}}
  end

  defp random_value, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: System.monotonic_time(:millisecond)
  defp prune(values), do: Map.filter(values, fn {_value, expires_at} -> expires_at > now() end)
end
