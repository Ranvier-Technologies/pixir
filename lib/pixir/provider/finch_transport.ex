defmodule Pixir.Provider.FinchTransport do
  @moduledoc """
  Default `Pixir.Provider.Transport` — streams the Responses request over the shared
  `Pixir.Finch` pool via `Finch.stream/5`.
  """

  @behaviour Pixir.Provider.Transport

  @impl true
  def stream(%{method: method, url: url, headers: headers, body: body}, acc, fun) do
    Finch.build(method, url, headers, body)
    |> Finch.stream(Pixir.Finch, acc, fn
      {:status, status}, a -> fun.({:status, status}, a)
      {:headers, hdrs}, a -> fun.({:headers, hdrs}, a)
      {:data, data}, a -> fun.({:data, data}, a)
    end)
  end
end
