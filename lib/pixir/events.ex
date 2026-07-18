defmodule Pixir.Events do
  @moduledoc """
  The event bus facade (ADR 0004, decision D-06): the seam between the core and
  every front-end. Front-ends subscribe; the core publishes. A renderer is just a
  subscriber that pattern-matches on `event.type`.

  Dispatch is backed by a `Registry` (`keys: :duplicate`) keyed by `session_id`.
  Callers never touch the Registry directly — only this module. When web/multi-node
  support arrives, the backend swaps to `Phoenix.PubSub` behind the same API.

  Subscribers receive messages shaped as `{:pixir_event, event}` where `event` is a
  `Pixir.Event` map. Subscribers may pass `only: [:status, ...]` to receive a
  bounded set of event types when they are acting as runtime control-plane processes
  instead of full presenters.
  """

  alias Pixir.{Event, SessionId}

  @registry Pixir.Events.Registry

  @doc "Child spec for the backing Registry (added to the supervision tree)."
  @spec registry_child_spec() :: Supervisor.child_spec()
  def registry_child_spec do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Subscribe the calling process to a Session's events. Delivered as
  `{:pixir_event, %Pixir.Event{}}` messages.
  """
  @spec subscribe(String.t(), keyword()) :: :ok | {:error, map()}
  def subscribe(session_id, opts \\ []) do
    with :ok <- SessionId.validate(session_id) do
      {:ok, _} = Registry.register(@registry, session_id, %{only: only(opts)})
      :ok
    end
  end

  @doc "Unsubscribe the calling process from a Session's events."
  @spec unsubscribe(String.t()) :: :ok | {:error, map()}
  def unsubscribe(session_id) do
    with :ok <- SessionId.validate(session_id) do
      Registry.unregister(@registry, session_id)
    end
  end

  @doc """
  Publish an Event to every subscriber of its `session_id`. Returns the event so it
  can be threaded (e.g. logged after publishing). Fan-out only — persistence is the
  Session's responsibility (canonical events go to the Log).
  """
  @spec publish(Event.t()) :: Event.t() | {:error, map()}
  def publish(%{session_id: session_id} = event) do
    with :ok <- SessionId.validate(session_id) do
      Registry.dispatch(@registry, session_id, fn subscribers ->
        for {pid, meta} <- subscribers,
            deliver?(meta, event),
            do: send(pid, {:pixir_event, event})
      end)

      event
    end
  end

  def publish(_event), do: SessionId.validate(nil)

  @doc "Number of live subscribers for a Session (mostly for tests/diagnostics)."
  @spec subscriber_count(String.t()) :: non_neg_integer() | {:error, map()}
  def subscriber_count(session_id) do
    with :ok <- SessionId.validate(session_id) do
      @registry |> Registry.lookup(session_id) |> length()
    end
  end

  defp only(opts) do
    case Keyword.get(opts, :only, :all) do
      :all -> :all
      types when is_list(types) -> MapSet.new(types)
    end
  end

  defp deliver?(%{only: :all}, _event), do: true
  defp deliver?(%{only: types}, %{type: type}), do: MapSet.member?(types, type)
  defp deliver?(_meta, _event), do: true
end
