defmodule Pixir.Provider.Transport do
  @moduledoc """
  The seam between `Pixir.Provider` and the network, so the SSE parsing can be tested
  without real HTTP. A transport streams an HTTP request and invokes `fun` for each
  low-level chunk — mirroring `Finch.stream/5`'s shape:

      fun.({:status, integer}, acc)
      fun.({:headers, [{k, v}]}, acc)
      fun.({:data, binary}, acc)

  Returns `{:ok, acc}` or `{:error, reason}`. `Pixir.Provider` also accepts a plain
  3-arity function in place of a module implementing this behaviour.
  """

  @type http_request :: %{
          method: atom(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata()
        }
  @type chunk :: {:status, non_neg_integer()} | {:headers, list()} | {:data, binary()}

  @callback stream(http_request(), acc, (chunk(), acc -> acc)) :: {:ok, acc} | {:error, term()}
            when acc: term()
end
