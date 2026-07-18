defmodule PixirMonitor.Security do
  @moduledoc """
  Enforces exact active-port Host validation and immutable browser security headers.

  Forwarded Host headers are intentionally ignored. Route-specific Origin, Fetch
  Metadata, and opaque-session checks are provided as explicit fail-closed helpers.
  """
  import Plug.Conn

  @permissions "accelerometer=(), ambient-light-sensor=(), autoplay=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = register_before_send(conn, &put_headers/1)

    case PixirMonitor.PortRegistry.active_port() do
      {:ok, port} ->
        if conn.host == "127.0.0.1" and conn.port == port do
          conn
        else
          reject(conn, 403, "invalid_host", "Request Host is not the active loopback monitor origin")
        end

      _ ->
        reject(conn, 403, "invalid_host", "Request Host is not the active loopback monitor origin")
    end
  end

  def same_origin_fetch?(conn), do: get_req_header(conn, "sec-fetch-site") == ["same-origin"]

  def exact_origin?(conn) do
    with {:ok, port} <- PixirMonitor.PortRegistry.active_port() do
      get_req_header(conn, "origin") == ["http://127.0.0.1:#{port}"]
    else
      _ -> false
    end
  end

  def authenticated?(conn) do
    conn = fetch_cookies(conn)
    same_origin_fetch?(conn) and PixirMonitor.Vault.valid_session?(conn.cookies["pixir_monitor_session"])
  end

  def reject(conn, status, kind, message) do
    body = Jason.encode_to_iodata!(%{error: %{kind: kind, message: message, details: %{}}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp put_headers(conn) do
    {:ok, csp_hash} = PixirMonitor.Bootstrap.csp_hash()

    csp =
      "default-src 'none'; script-src 'self' 'sha256-#{csp_hash}'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; manifest-src 'self'; worker-src 'self'; trusted-types pixir-bootstrap; require-trusted-types-for 'script';"

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("permissions-policy", @permissions)
  end
end
