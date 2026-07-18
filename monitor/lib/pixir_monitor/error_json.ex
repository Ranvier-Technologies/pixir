defmodule PixirMonitor.ErrorJSON do
  @moduledoc "Renders bounded Phoenix fallback errors without leaking request or capability data."

  def render(template, _assigns), do: %{error: %{kind: "http_error", message: template}}
end
