defmodule PixirMonitor.Router do
  @moduledoc """
  Implements the complete read-only monitor route inventory.

  The sole state transition is launch bootstrap. APIs delegate authoritative data
  to `RunSource`; SSE transports finite invalidation hints only.
  """
  use Plug.Router
  import Plug.Conn

  @max_body_bytes 1_024
  @max_id_bytes Pixir.SessionId.max_bytes()
  @sse_lifetime_ms 300_000
  @sse_max_events 100
  @sse_keepalive_ms 1_000

  plug(PixirMonitor.Security)
  plug(:match)
  plug(:dispatch)

  get "/" do
    {:ok, shell} = PixirMonitor.Bootstrap.shell()
    send_text(conn, 200, "text/html; charset=utf-8", shell)
  end

  post "/bootstrap" do
    if PixirMonitor.Security.exact_origin?(conn) and PixirMonitor.Security.same_origin_fetch?(conn) do
      bootstrap(conn)
    else
      PixirMonitor.Security.reject(conn, 403, "bootstrap_forbidden", "Bootstrap requires the exact monitor origin and same-origin Fetch Metadata")
    end
  end

  get "/assets/app.css" do
    with_auth(conn, fn conn -> serve_asset(conn, "app.css", "text/css; charset=utf-8") end)
  end

  get "/assets/app.js" do
    with_auth(conn, fn conn -> serve_asset(conn, "app.js", "text/javascript; charset=utf-8") end)
  end

  get "/api/workspaces/:key/runs" do
    with_auth(conn, fn conn -> scoped_runs(conn, key) end)
  end

  get "/api/workspaces/:key/runs/:id" do
    with_auth(conn, fn conn -> scoped_run(conn, key, id) end)
  end

  get "/api/runs" do
    with_auth(conn, fn conn ->
      case PixirMonitor.WorkspaceSet.mode() do
        {:ok, :workspace_set} ->
          set_error(conn, 404, "unscoped_route_unavailable", "Use a workspace-scoped Runs route")

        {:ok, :single} ->
          case PixirMonitor.RunSource.list_runs() do
            {:ok, runs} -> send_json(conn, 200, runs)
            {:error, error} -> send_json(conn, 503, %{error: error})
          end
      end
    end)
  end

  get "/api/runs/:id" do
    with_auth(conn, fn conn ->
      case PixirMonitor.WorkspaceSet.mode() do
        {:ok, :workspace_set} ->
          set_error(conn, 404, "unscoped_route_unavailable", "Use a workspace-scoped Run Detail route")

        {:ok, :single} ->
          if valid_id?(id) do
            case PixirMonitor.RunSource.fetch_run(id) do
              {:ok, run} -> send_json(conn, 200, run)
              {:error, %{kind: "run_not_found"} = error} -> send_json(conn, 404, %{error: error})
              {:error, error} -> send_json(conn, 503, %{error: error})
            end
          else
            send_json(conn, 400, %{error: %{kind: "invalid_run_id", message: "Run id is invalid", details: %{max_bytes: @max_id_bytes}}})
          end
      end
    end)
  end

  get "/api/events" do
    with_auth(conn, &stream_events/1)
  end

  match _ do
    PixirMonitor.Security.reject(conn, 405, "method_not_allowed", "The read-only monitor does not expose this route or method")
  end

  defp scoped_runs(conn, key) do
    case PixirMonitor.WorkspaceSet.mode() do
      {:ok, :single} -> PixirMonitor.Security.reject(conn, 405, "method_not_allowed", "The read-only monitor does not expose this route or method")
      {:ok, :workspace_set} -> scoped_result(conn, key, nil)
    end
  end

  defp scoped_run(conn, key, id) do
    case PixirMonitor.WorkspaceSet.mode() do
      {:ok, :single} -> PixirMonitor.Security.reject(conn, 405, "method_not_allowed", "The read-only monitor does not expose this route or method")
      {:ok, :workspace_set} -> scoped_result(conn, key, id)
    end
  end

  defp scoped_result(conn, key, id) do
    result =
      cond do
        PixirMonitor.WorkspaceSet.validate_key(key) != :ok ->
          {:error, %{kind: "invalid_workspace_key", message: "Workspace key is invalid"}}

        not is_nil(id) and not valid_id?(id) ->
          {:error, %{kind: "invalid_run_id", message: "Run id is invalid", details: %{workspace: key, max_bytes: @max_id_bytes}}}

        is_nil(id) ->
          PixirMonitor.WorkspaceSet.list_runs(key)

        true ->
          PixirMonitor.WorkspaceSet.fetch_run(key, id)
      end

    case result do
      {:ok, envelope} -> send_json(conn, 200, envelope)
      {:error, %{kind: "invalid_workspace_key"} = error} -> send_json(conn, 400, %{error: Map.drop(error, [:details])})
      {:error, %{kind: "invalid_run_id"} = error} -> send_json(conn, 400, %{error: error})
      {:error, %{kind: "workspace_not_found"} = error} -> send_json(conn, 404, %{error: error})
      {:error, %{kind: "run_not_found"} = error} -> send_json(conn, 404, %{error: put_run_id(error, id)})
      {:error, error} -> send_json(conn, 503, %{error: unavailable_error(error, key)})
    end
  end

  defp set_error(conn, status, kind, message), do: send_json(conn, status, %{error: %{kind: kind, message: message}})

  defp put_run_id(error, id), do: put_in(error, [:details, :run_id], id)

  defp unavailable_error(error, key) do
    details = %{workspace: key}

    details =
      case get_in(error, [:details, :reason]) do
        reason when is_binary(reason) and byte_size(reason) <= 64 -> Map.put(details, :reason, reason)
        _ -> details
      end

    %{kind: "workspace_unavailable", message: "Workspace projection is unavailable", details: details}
  end

  defp bootstrap(conn) do
    case read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> consume_bootstrap(conn, body)
      {:more, _body, conn} -> PixirMonitor.Security.reject(conn, 413, "body_too_large", "Bootstrap body exceeds the limit")
      {:error, _reason} -> PixirMonitor.Security.reject(conn, 400, "invalid_body", "Bootstrap body could not be read")
    end
  end

  defp consume_bootstrap(conn, body) do
    with {:ok, %{"launch" => token}} when is_binary(token) <- Jason.decode(body),
         true <- byte_size(token) <= 128,
         {:ok, session} <- PixirMonitor.Vault.consume_launch(token) do
      conn
      |> put_resp_cookie("pixir_monitor_session", session,
        http_only: true,
        same_site: "Strict",
        path: "/",
        secure: false
      )
      |> send_json(200, %{ok: true})
    else
      _ -> PixirMonitor.Security.reject(conn, 401, "invalid_launch", "Launch capability is invalid, expired, or already used")
    end
  end

  defp with_auth(conn, callback) do
    if PixirMonitor.Security.authenticated?(conn) do
      callback.(conn)
    else
      PixirMonitor.Security.reject(conn, 403, "authentication_required", "Same-origin monitor authentication is required")
    end
  end

  defp serve_asset(conn, name, content_type) do
    case PixirMonitor.Assets.fetch(name) do
      {:ok, ^content_type, bytes} -> send_text(conn, 200, content_type, bytes)
      {:error, :not_found} -> PixirMonitor.Security.reject(conn, 404, "asset_not_found", "Asset is unavailable")
    end
  end

  defp send_json(conn, status, value) do
    bytes = Jason.encode!(value)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("x-content-sha256", Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))
    |> send_resp(status, bytes)
  end

  defp send_text(conn, status, content_type, bytes) do
    conn |> put_resp_content_type(content_type, nil) |> send_resp(status, bytes)
  end

  defp valid_id?(id) do
    Pixir.SessionId.valid?(id)
  end

  defp stream_events(conn) do
    try do
      case PixirMonitor.InvalidationHub.subscribe() do
        {:ok, _sequence} ->
          Process.send_after(self(), :pixir_sse_close, @sse_lifetime_ms)

          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("x-accel-buffering", "no")
            |> send_chunked(200)

          case chunk(conn, "retry: 500\n\n") do
            {:ok, conn} -> stream_loop(conn, 0)
            {:error, _} -> conn
          end

        {:error, error} ->
          send_json(conn, 503, %{error: error})
      end
    after
      PixirMonitor.InvalidationHub.unsubscribe()
    end
  end

  defp stream_loop(conn, count) when count >= @sse_max_events, do: conn

  defp stream_loop(conn, count) do
    receive do
      {:projection_changed, sequence, workspace, projection_id} ->
        PixirMonitor.InvalidationHub.ack()

        frame =
          case {PixirMonitor.WorkspaceSet.mode(), workspace} do
            {{:ok, :workspace_set}, key} when is_binary(key) -> PixirMonitor.InvalidationHub.frame(sequence, key, projection_id)
            _ -> PixirMonitor.InvalidationHub.frame(sequence, projection_id)
          end

        case chunk(conn, frame) do
          {:ok, conn} -> stream_loop(conn, count + 1)
          {:error, _} -> conn
        end

      :pixir_sse_close ->
        conn
    after
      @sse_keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn, count)
          {:error, _} -> conn
        end
    end
  end
end
