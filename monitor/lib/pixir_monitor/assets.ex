defmodule PixirMonitor.Assets do
  @moduledoc """
  Embeds the accepted presenter assets into the monitor's BEAM at compile time.

  Runtime serving therefore never depends on a source checkout, current directory, or
  escript filesystem layout. The source asset files remain the byte-for-byte contract.
  """

  @app_js_path Path.expand("../../priv/static/app.js", __DIR__)
  @app_css_path Path.expand("../../priv/static/app.css", __DIR__)
  @external_resource @app_js_path
  @external_resource @app_css_path
  @app_js File.read!(@app_js_path)
  @app_css File.read!(@app_css_path)

  @spec fetch(String.t()) :: {:ok, String.t(), String.t()} | {:error, :not_found}
  def fetch("app.js"), do: {:ok, "text/javascript; charset=utf-8", @app_js}
  def fetch("app.css"), do: {:ok, "text/css; charset=utf-8", @app_css}
  def fetch(_name), do: {:error, :not_found}
end
