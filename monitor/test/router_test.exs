defmodule PixirMonitorTest.Source do
  @behaviour PixirMonitor.RunSource
  def list_runs, do: {:ok, [%{"run" => %{"id" => "run-1", "title" => "Run one"}}]}
  def fetch_run("run-1"), do: {:ok, %{"schema" => "pixir.presenter.run", "schema_version" => 1}}
  def fetch_run(_), do: {:error, %{kind: "run_not_found", message: "Run was not found", details: %{}}}
end

defmodule PixirMonitorTest.FailingSource do
  @behaviour PixirMonitor.RunSource
  def list_runs, do: {:error, :unavailable}
  def fetch_run(_), do: {:error, :unavailable}
end

defmodule PixirMonitorTest.RaisingSource do
  @behaviour PixirMonitor.RunSource
  def list_runs, do: raise("source read failed at /private/tmp/pixir-secret/runs.ndjson")
  def fetch_run(_), do: raise("source read failed at /private/tmp/pixir-secret/runs.ndjson")
end

defmodule PixirMonitorTest.ThrowingSource do
  @behaviour PixirMonitor.RunSource
  def list_runs, do: throw("source threw at /private/tmp/pixir-secret/thrown.ndjson")
  def fetch_run(_), do: throw("source threw at /private/tmp/pixir-secret/thrown.ndjson")
end

defmodule PixirMonitorTest.EchoSource do
  @behaviour PixirMonitor.RunSource
  def list_runs, do: {:ok, []}
  def fetch_run(id), do: {:ok, %{"id" => id}}
end

defmodule PixirMonitor.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  @host "127.0.0.1:41091"
  @origin "http://127.0.0.1:41091"

  setup do
    previous_port = Application.get_env(:pixir_monitor, :active_port)
    previous_source = Application.get_env(:pixir_monitor, :run_source)

    on_exit(fn ->
      restore_env(:active_port, previous_port)
      restore_env(:run_source, previous_source)
    end)

    Application.put_env(:pixir_monitor, :active_port, 41_091, persistent: false)
    Application.put_env(:pixir_monitor, :run_source, PixirMonitorTest.Source)

    :ok
  end

  test "rejects aliases, omitted/wrong ports, and does not trust forwarded Host" do
    for host <- ["localhost:41091", "127.0.0.1", "127.0.0.1:41092"] do
      assert request(:get, "/", host).status == 403
    end

    conn =
      build_conn(:get, "/", "evil.test", "")
      |> put_req_header("x-forwarded-host", @host)
      |> PixirMonitor.Router.call([])

    assert conn.status == 403
  end

  test "shell has fixed title, bootstrap first, no-store, and exact security headers" do
    conn = request(:get, "/")
    assert conn.status == 200
    assert conn.resp_body =~ "<title>Pixir Monitor</title><script>"
    refute conn.resp_body =~ "app.js</script>"
    assert header(conn, "cache-control") == "no-store"
    assert header(conn, "x-content-type-options") == "nosniff"
    assert header(conn, "referrer-policy") == "no-referrer"
    assert header(conn, "cross-origin-opener-policy") == "same-origin"
    assert header(conn, "cross-origin-resource-policy") == "same-origin"
    csp = header(conn, "content-security-policy")
    assert csp =~ "require-trusted-types-for 'script'"
    assert csp =~ "trusted-types pixir-bootstrap;"
    assert {:ok, csp_hash} = PixirMonitor.Bootstrap.csp_hash()
    assert csp =~ "script-src 'self' 'sha256-#{csp_hash}'"
    refute csp =~ "trusted-types default"
    refute csp =~ "'unsafe-inline'"
  end

  test "bootstrap fails closed on Origin and Fetch Metadata" do
    {:ok, launch} = PixirMonitor.Vault.issue_launch()
    body = Jason.encode!(%{launch: launch})

    assert request(:post, "/bootstrap", @host, body, [{"content-type", "application/json"}, {"sec-fetch-site", "same-origin"}]).status == 403
    assert request(:post, "/bootstrap", @host, body, [{"origin", "http://evil.test"}, {"sec-fetch-site", "same-origin"}]).status == 403
    assert request(:post, "/bootstrap", @host, body, [{"origin", @origin}]).status == 403
    assert request(:post, "/bootstrap", @host, body, [{"origin", @origin}, {"sec-fetch-site", "cross-site"}]).status == 403
  end

  test "launch is one-use and cookie is opaque session-only strict HttpOnly" do
    {:ok, launch} = PixirMonitor.Vault.issue_launch()
    body = Jason.encode!(%{launch: launch})
    headers = [{"origin", @origin}, {"sec-fetch-site", "same-origin"}, {"content-type", "application/json"}]

    accepted = request(:post, "/bootstrap", @host, body, headers)
    assert accepted.status == 200
    cookie = header(accepted, "set-cookie")
    assert cookie =~ "pixir_monitor_session="
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Strict"
    refute cookie =~ "Domain="
    refute cookie =~ "Max-Age="
    refute cookie =~ launch

    assert request(:post, "/bootstrap", @host, body, headers).status == 401

    {:ok, expired} = PixirMonitor.Vault.issue_launch_for_test(0)
    expired_body = Jason.encode!(%{launch: expired})
    assert request(:post, "/bootstrap", @host, expired_body, headers).status == 401
  end

  test "safe GETs require cookie and same-origin Fetch Metadata" do
    cookie = session_cookie()
    assert request(:get, "/api/runs").status == 403
    assert request(:get, "/api/runs", @host, "", [{"cookie", cookie}]).status == 403
    assert request(:get, "/api/runs", @host, "", [{"cookie", cookie}, {"sec-fetch-site", "cross-site"}]).status == 403
    assert request(:get, "/api/runs", @host, "", [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]).status == 200
  end

  test "list/detail JSON bytes carry exact SHA-256 and invalid ids fail" do
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    list = request(:get, "/api/runs", @host, "", headers)
    assert header(list, "x-content-sha256") == Base.encode16(:crypto.hash(:sha256, list.resp_body), case: :lower)

    detail = request(:get, "/api/runs/run-1", @host, "", headers)
    assert detail.status == 200
    assert header(detail, "x-content-sha256") == Base.encode16(:crypto.hash(:sha256, detail.resp_body), case: :lower)
    assert request(:get, "/api/runs/..", @host, "", headers).status in [400, 405]
  end

  test "HTTP Detail uses the canonical Session-id byte boundary" do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitorTest.EchoSource)
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    for length <- [160, 161, 235] do
      id = String.duplicate("x", length)
      conn = request(:get, "/api/runs/#{id}", @host, "", headers)
      assert conn.status == 200
      assert %{"id" => ^id} = Jason.decode!(conn.resp_body)
    end

    rejected = request(:get, "/api/runs/#{String.duplicate("x", 236)}", @host, "", headers)
    assert rejected.status == 400

    assert %{"error" => %{"kind" => "invalid_run_id", "details" => %{"max_bytes" => 235}}} =
             Jason.decode!(rejected.resp_body)
  end

  test "RunSource failures remain structured at the HTTP boundary" do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitorTest.FailingSource)
    cookie = session_cookie()
    conn = request(:get, "/api/runs", @host, "", [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}])
    assert conn.status == 503
    assert %{"error" => %{"kind" => "run_source_failed"}} = Jason.decode!(conn.resp_body)
  end

  test "raised RunSource messages do not reach HTTP diagnostics" do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitorTest.RaisingSource)
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]
    list = request(:get, "/api/runs", @host, "", headers)
    detail = request(:get, "/api/runs/run-1", @host, "", headers)

    for conn <- [list, detail] do
      assert conn.status == 503

      assert %{
               "error" => %{
                 "kind" => "run_source_failed",
                 "details" => %{"exception" => "run_source_raised"}
               }
             } = Jason.decode!(conn.resp_body)

      refute conn.resp_body =~ "source read failed at /private/tmp/pixir-secret/runs.ndjson"
    end
  end

  test "thrown RunSource terms do not reach HTTP diagnostics" do
    Application.put_env(:pixir_monitor, :run_source, PixirMonitorTest.ThrowingSource)
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]
    list = request(:get, "/api/runs", @host, "", headers)
    detail = request(:get, "/api/runs/run-1", @host, "", headers)

    for conn <- [list, detail] do
      assert conn.status == 503

      assert %{
               "error" => %{
                 "kind" => "run_source_failed",
                 "details" => %{"reason" => "run_source_thrown"}
               }
             } = Jason.decode!(conn.resp_body)

      refute conn.resp_body =~ "source threw at /private/tmp/pixir-secret/thrown.ndjson"
    end
  end

  test "security headers are pinned for shell, bootstrap, authenticated API, assets, and rejection routes" do
    cookie = session_cookie()
    authenticated = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    conns = [
      request(:get, "/"),
      request(:post, "/bootstrap"),
      request(:get, "/api/runs", @host, "", authenticated),
      request(:get, "/assets/app.js", @host, "", authenticated),
      request(:post, "/api/runs")
    ]

    Enum.each(conns, fn conn ->
      assert header(conn, "cache-control") == "no-store"
      assert header(conn, "x-content-type-options") == "nosniff"
      assert header(conn, "referrer-policy") == "no-referrer"
      assert header(conn, "cross-origin-opener-policy") == "same-origin"
      assert header(conn, "cross-origin-resource-policy") == "same-origin"
      assert header(conn, "permissions-policy") =~ "camera=()"
      assert header(conn, "content-security-policy") =~ "default-src 'none'"
    end)
  end

  test "assets are served from embedded BEAM bytes" do
    cookie = session_cookie()
    headers = [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}]

    for {name, expected_type} <- [{"app.js", "text/javascript; charset=utf-8"}, {"app.css", "text/css; charset=utf-8"}] do
      conn = request(:get, "/assets/#{name}", @host, "", headers)
      assert conn.status == 200
      assert header(conn, "content-type") == expected_type
      assert {:ok, ^expected_type, bytes} = PixirMonitor.Assets.fetch(name)
      assert conn.resp_body == bytes
    end
  end

  test "complete route inventory rejects mutation verbs and action paths" do
    for {method, path} <- [{:post, "/api/runs"}, {:delete, "/api/runs/run-1"}, {:post, "/cancel"}, {:post, "/apply"}, {:get, "/workflow"}] do
      assert request(method, path).status == 405
    end
  end

  defp session_cookie do
    {:ok, launch} = PixirMonitor.Vault.issue_launch()
    accepted = request(:post, "/bootstrap", @host, Jason.encode!(%{launch: launch}), [{"origin", @origin}, {"sec-fetch-site", "same-origin"}, {"content-type", "application/json"}])
    header(accepted, "set-cookie") |> String.split(";", parts: 2) |> hd()
  end

  defp request(method, path, host \\ @host, body \\ "", headers \\ []) do
    Enum.reduce(headers, build_conn(method, path, host, body), fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
    |> PixirMonitor.Router.call([])
  end

  defp build_conn(method, path, supplied_host, body) do
    uri = URI.parse("http://#{supplied_host}")
    %{conn(method, path, body) | host: uri.host, port: uri.port}
  end

  defp restore_env(key, nil), do: Application.delete_env(:pixir_monitor, key, persistent: false)
  defp restore_env(key, value), do: Application.put_env(:pixir_monitor, key, value, persistent: false)

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()
end
