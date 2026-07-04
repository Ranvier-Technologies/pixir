defmodule Pixir.SessionSupervisor do
  @moduledoc """
  `DynamicSupervisor` of `Pixir.Session` processes (ADR 0001). A Session is started
  on demand — for a new conversation or to `resume` a persisted one — and is
  `:transient`, so it stays down once it finishes cleanly.
  """

  use DynamicSupervisor

  alias Pixir.Session

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a Session. Accepts `:id` (generated if absent), `:workspace`, `:role`,
  `:force_release_writer_lease?`, and `:force_release_reason`. Forced lease release is
  a break-glass resume path for stale/ambiguous writer evidence; active leases are
  refused. Returns `{:ok, session_id, pid}` so the caller always learns the id.
  """
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_session(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :id, &Session.gen_id/0)
    id = Keyword.fetch!(opts, :id)

    case DynamicSupervisor.start_child(__MODULE__, {Session, opts}) do
      {:ok, pid} -> {:ok, id, pid}
      {:error, {:already_started, pid}} -> {:ok, id, pid}
      {:error, _} = err -> err
    end
  end
end
