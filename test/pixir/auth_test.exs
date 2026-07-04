defmodule Pixir.AuthTest do
  use ExUnit.Case, async: true

  alias Pixir.Auth
  alias Pixir.Auth.{CallbackServer, CodexOAuth, Store}

  @far_future System.system_time(:millisecond) + 3_600_000
  @past System.system_time(:millisecond) - 1_000

  # Stub OAuth backend injected into the Auth GenServer (no network).
  defmodule StubOAuth do
    def refresh_skew_ms, do: 60_000
    def browser_redirect_uri, do: Pixir.Auth.CallbackServer.redirect_uri()

    def refresh(_refresh_token),
      do: {:ok, sub_cred("refreshed-access", System.system_time(:millisecond) + 3_600_000)}

    def generate_pkce,
      do: %{code_verifier: "verifier-123", code_challenge: "challenge-123"}

    def generate_state, do: "state-abc"

    def build_authorize_url(pkce, state, _opts \\ []),
      do:
        "https://auth.openai.com/oauth/authorize?state=#{state}&code_challenge=#{pkce.code_challenge}"

    def start_callback_server(_opts \\ []), do: {:ok, :stub_listen_socket}

    def wait_for_callback(_socket, _opts),
      do: {:ok, "browser-auth-code"}

    def close_callback_server(_socket), do: :ok

    def start_device_auth,
      do:
        {:ok,
         %{
           device_auth_id: "dev-1",
           user_code: "ABCD-EFGH",
           interval: 1,
           verification_uri: "https://auth.openai.com/codex/device",
           expires_in: 900
         }}

    def poll_for_authorization(_device, _opts \\ []),
      do: {:ok, %{authorization_code: "auth-code", code_verifier: "verifier"}}

    def exchange_for_credential(_code, _verifier, _opts \\ []),
      do: {:ok, sub_cred("logged-in-access", System.system_time(:millisecond) + 3_600_000)}

    def sub_cred(access, expires_at) do
      %{
        kind: :subscription,
        access_token: access,
        refresh_token: "refresh-token",
        expires_at: expires_at,
        account_id: "acct_stub",
        obtained_at: "2026-01-01T00:00:00Z"
      }
    end
  end

  defmodule DeniedBrowserOAuth do
    defdelegate refresh_skew_ms(), to: StubOAuth
    defdelegate browser_redirect_uri(), to: StubOAuth
    defdelegate generate_pkce(), to: StubOAuth
    defdelegate generate_state(), to: StubOAuth
    defdelegate build_authorize_url(pkce, state, opts \\ []), to: StubOAuth
    defdelegate start_callback_server(opts \\ []), to: StubOAuth
    defdelegate close_callback_server(socket), to: StubOAuth
    defdelegate start_device_auth(), to: StubOAuth
    defdelegate poll_for_authorization(device, opts \\ []), to: StubOAuth
    defdelegate exchange_for_credential(code, verifier, opts \\ []), to: StubOAuth
    defdelegate refresh(refresh_token), to: StubOAuth

    def wait_for_callback(_socket, _opts) do
      {:error,
       %{
         ok: false,
         error: %{
           kind: :oauth_denied,
           message: "sign-in was denied or cancelled in the browser",
           details: %{error: "access_denied"},
           next_actions: ["retry `pixir login`"]
         }
       }}
    end
  end

  defmodule TimeoutBrowserOAuth do
    defdelegate refresh_skew_ms(), to: StubOAuth
    defdelegate browser_redirect_uri(), to: StubOAuth
    defdelegate generate_pkce(), to: StubOAuth
    defdelegate generate_state(), to: StubOAuth
    defdelegate build_authorize_url(pkce, state, opts \\ []), to: StubOAuth
    defdelegate start_callback_server(opts \\ []), to: StubOAuth
    defdelegate close_callback_server(socket), to: StubOAuth
    defdelegate start_device_auth(), to: StubOAuth
    defdelegate poll_for_authorization(device, opts \\ []), to: StubOAuth
    defdelegate exchange_for_credential(code, verifier, opts \\ []), to: StubOAuth
    defdelegate refresh(refresh_token), to: StubOAuth

    def wait_for_callback(_socket, _opts) do
      {:error,
       %{
         ok: false,
         error: %{
           kind: :timeout,
           message: "browser login timed out waiting for authorization",
           details: %{},
           next_actions: ["retry `pixir login`"]
         }
       }}
    end
  end

  defmodule PortBusyOAuth do
    defdelegate refresh_skew_ms(), to: StubOAuth
    defdelegate browser_redirect_uri(), to: StubOAuth
    defdelegate generate_pkce(), to: StubOAuth
    defdelegate generate_state(), to: StubOAuth
    defdelegate build_authorize_url(pkce, state, opts \\ []), to: StubOAuth
    defdelegate close_callback_server(socket), to: StubOAuth
    defdelegate wait_for_callback(socket, opts), to: StubOAuth
    defdelegate start_device_auth(), to: StubOAuth
    defdelegate poll_for_authorization(device, opts \\ []), to: StubOAuth
    defdelegate exchange_for_credential(code, verifier, opts \\ []), to: StubOAuth
    defdelegate refresh(refresh_token), to: StubOAuth

    def start_callback_server(_opts \\ []) do
      {:error,
       %{
         ok: false,
         error: %{
           kind: :callback_port_unavailable,
           message: "could not bind 127.0.0.1:1455 for the OAuth callback",
           details: %{host: "127.0.0.1", port: 1455},
           next_actions: ["run `pixir login --device-code`"]
         }
       }}
    end
  end

  # Refresh fails because the refresh token is rejected (4xx) — i.e. the session is dead.
  defmodule DeadTokenOAuth do
    def refresh_skew_ms, do: 60_000

    def refresh(_),
      do:
        {:error,
         %{
           ok: false,
           error: %{
             kind: :token_request_failed,
             message: "token refresh failed",
             details: %{status: 400, body: ~s({"error":"invalid_grant"})}
           }
         }}
  end

  # Refresh fails transiently (network) — should stay retryable, not become terminal.
  defmodule FlakyOAuth do
    def refresh_skew_ms, do: 60_000

    def refresh(_),
      do:
        {:error,
         %{ok: false, error: %{kind: :network, message: "connection refused", details: %{}}}}
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-auth-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".json"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path, name: :"auth_#{System.unique_integer([:positive])}"}
  end

  defp start_auth(ctx, opts) do
    opts =
      Keyword.merge(
        [name: ctx.name, store_path: ctx.path, oauth: StubOAuth, env_api_key: nil],
        opts
      )

    {:ok, _pid} = Auth.start_link(opts)
    ctx.name
  end

  describe "CodexOAuth.account_id_from_token/1" do
    test "extracts chatgpt_account_id from JWT claims" do
      claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_42"}}
      payload = Base.url_encode64(Jason.encode!(claims), padding: false)
      assert {:ok, "acct_42"} = CodexOAuth.account_id_from_token("header." <> payload <> ".sig")
    end

    test "errors when the claim is absent" do
      payload = Base.url_encode64(Jason.encode!(%{"sub" => "x"}), padding: false)
      assert {:error, :no_account_id} = CodexOAuth.account_id_from_token("h." <> payload <> ".s")
    end
  end

  describe "Store" do
    test "save/load round-trips a subscription credential with mode 0600", %{path: path} do
      cred = StubOAuth.sub_cred("acc", @far_future)
      assert :ok = Store.save(cred, path: path)
      assert {:ok, loaded} = Store.load(path: path)
      assert loaded == cred

      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "load is :not_found when absent and clear is idempotent", %{path: path} do
      assert {:error, :not_found} = Store.load(path: path)
      assert :ok = Store.clear(path: path)
    end
  end

  describe "Auth credential resolution" do
    test "OPENAI_API_KEY is used as a fallback", ctx do
      name = start_auth(ctx, env_api_key: "sk-test")
      assert {:ok, "sk-test"} = Auth.access_token(name)
      assert {:ok, [{"authorization", "Bearer sk-test"}]} = Auth.request_headers(name)
      assert %{authenticated?: true, kind: :api_key} = Auth.status(name)
    end

    test "no credential yields a structured not_authenticated error", ctx do
      name = start_auth(ctx, [])
      assert %{authenticated?: false} = Auth.status(name)
      assert {:error, %{error: %{kind: :not_authenticated}}} = Auth.access_token(name)
    end

    test "a stored subscription takes precedence over the env key", %{path: path} = ctx do
      Store.save(StubOAuth.sub_cred("stored-access", @far_future), path: path)
      name = start_auth(ctx, env_api_key: "sk-test")
      assert {:ok, "stored-access"} = Auth.access_token(name)
      assert %{kind: :subscription, account_id: "acct_stub"} = Auth.status(name)
    end
  end

  describe "Auth refresh + headers (subscription)" do
    test "expired subscription is refreshed and re-persisted", %{path: path} = ctx do
      name = start_auth(ctx, [])
      :ok = Auth.set_credential(name, StubOAuth.sub_cred("old-access", @past))

      assert {:ok, "refreshed-access"} = Auth.access_token(name)
      assert {:ok, "refreshed-access"} = Auth.access_token(name)

      assert {:ok, %{access_token: "refreshed-access"}} = Store.load(path: path)
    end

    test "subscription headers include the chatgpt-account-id", ctx do
      name = start_auth(ctx, [])
      :ok = Auth.set_credential(name, StubOAuth.sub_cred("fresh", @far_future))

      assert {:ok, headers} = Auth.request_headers(name)
      assert {"authorization", "Bearer fresh"} in headers
      assert {"chatgpt-account-id", "acct_stub"} in headers
    end

    test "logout clears the subscription and falls back to the env key", %{path: path} = ctx do
      name = start_auth(ctx, env_api_key: "sk-fallback")
      :ok = Auth.set_credential(name, StubOAuth.sub_cred("fresh", @far_future))
      assert %{kind: :subscription} = Auth.status(name)

      assert :ok = Auth.logout(name)
      assert {:error, :not_found} = Store.load(path: path)
      assert %{kind: :api_key} = Auth.status(name)
    end
  end

  describe "Auth refresh failure (C4 hardening)" do
    test "a rejected refresh token surfaces an actionable not_authenticated error, not a crash",
         ctx do
      name = start_auth(ctx, oauth: DeadTokenOAuth)
      :ok = Auth.set_credential(name, StubOAuth.sub_cred("old", @past))

      # Does not crash the Auth process; returns a structured, re-login-actionable error.
      assert {:error, %{ok: false, error: %{kind: :not_authenticated, message: msg}}} =
               Auth.request_headers(name)

      assert msg =~ "pixir login"
      # The GenServer is still alive and answering after a refresh failure.
      assert is_map(Auth.status(name))
    end

    test "a transient refresh failure keeps its retryable kind", ctx do
      name = start_auth(ctx, oauth: FlakyOAuth)
      :ok = Auth.set_credential(name, StubOAuth.sub_cred("old", @past))

      # Network blips stay :network so the Provider's retry/backoff can handle them —
      # they are NOT downgraded to a terminal auth error.
      assert {:error, %{error: %{kind: :network}}} = Auth.access_token(name)
    end
  end

  describe "browser login orchestration" do
    test "runs the flow, surfaces the authorize URL, and installs the credential", ctx do
      name = start_auth(ctx, [])
      test_pid = self()

      assert {:ok, status} =
               Auth.login_browser(name, fn info -> send(test_pid, {:authorize, info}) end)

      assert status.kind == :subscription

      assert_received {:authorize,
                       %{
                         authorize_url: url,
                         state: "state-abc"
                       }}

      assert url =~ "auth.openai.com/oauth/authorize"
      assert {:ok, "logged-in-access"} = Auth.access_token(name)
    end

    test "user denial returns a structured oauth_denied error", ctx do
      name = start_auth(ctx, oauth: DeniedBrowserOAuth)

      assert {:error, %{error: %{kind: :oauth_denied, next_actions: actions}}} =
               Auth.login_browser(name, fn _ -> :ok end)

      assert Enum.any?(actions, &String.contains?(&1, "pixir login"))
    end

    test "timeout returns a structured timeout error", ctx do
      name = start_auth(ctx, oauth: TimeoutBrowserOAuth)

      assert {:error, %{error: %{kind: :timeout}}} =
               Auth.login_browser(name, fn _ -> :ok end)
    end

    test "port unavailable falls back to device-code login", ctx do
      name = start_auth(ctx, oauth: PortBusyOAuth)
      test_pid = self()

      assert {:ok, status} =
               Auth.login(name, %{
                 on_authorize: fn _ -> send(test_pid, :authorize_attempted) end,
                 on_device_code: fn info -> send(test_pid, {:user_code, info}) end,
                 on_fallback: fn _ -> send(test_pid, :fallback) end
               })

      assert status.kind == :subscription
      assert_received :authorize_attempted
      assert_received :fallback

      assert_received {:user_code,
                       %{
                         user_code: "ABCD-EFGH",
                         verification_uri: "https://auth.openai.com/codex/device"
                       }}
    end
  end

  describe "device-code login orchestration" do
    test "runs the flow, shows the user code, and installs the credential", ctx do
      name = start_auth(ctx, [])
      test_pid = self()

      assert {:ok, status} =
               Auth.login_device_code(name, fn info -> send(test_pid, {:user_code, info}) end)

      assert status.kind == :subscription

      assert_received {:user_code,
                       %{
                         user_code: "ABCD-EFGH",
                         verification_uri: "https://auth.openai.com/codex/device"
                       }}

      assert {:ok, "logged-in-access"} = Auth.access_token(name)
    end
  end

  describe "CallbackServer" do
    test "accepts a valid callback and returns the authorization code" do
      state = CodexOAuth.generate_state()
      port = random_free_port()

      assert {:ok, listen_socket} = CallbackServer.listen(port: port)

      parent = self()

      Task.start(fn ->
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
        |> case do
          {:ok, socket} ->
            request =
              "GET /auth/callback?code=abc123&state=#{state} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"

            :gen_tcp.send(socket, request)
            :gen_tcp.recv(socket, 0, 1_000)
            :gen_tcp.close(socket)
            send(parent, :client_done)

          {:error, reason} ->
            send(parent, {:client_error, reason})
        end
      end)

      assert {:ok, "abc123"} =
               CallbackServer.wait_for_callback(listen_socket, state: state, timeout_ms: 2_000)

      assert_receive :client_done, 2_000
      CallbackServer.close(listen_socket)
    end

    test "maps access_denied to oauth_denied" do
      state = CodexOAuth.generate_state()
      port = random_free_port()

      assert {:ok, listen_socket} = CallbackServer.listen(port: port)
      send_callback(port, "/auth/callback?error=access_denied&state=#{state}")

      assert {:error, %{error: %{kind: :oauth_denied}}} =
               CallbackServer.wait_for_callback(listen_socket, state: state, timeout_ms: 2_000)

      CallbackServer.close(listen_socket)
    end

    test "returns callback_port_unavailable when the port is already bound" do
      port = random_free_port()

      assert {:ok, blocker} =
               :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      assert {:error, %{error: %{kind: :callback_port_unavailable}}} =
               CallbackServer.listen(port: port)

      :gen_tcp.close(blocker)
    end

    test "times out when no callback arrives" do
      port = random_free_port()
      assert {:ok, listen_socket} = CallbackServer.listen(port: port)

      assert {:error, %{error: %{kind: :timeout}}} =
               CallbackServer.wait_for_callback(listen_socket,
                 state: "unused",
                 timeout_ms: 50
               )

      CallbackServer.close(listen_socket)
    end
  end

  describe "CodexOAuth browser helpers" do
    test "build_authorize_url includes PKCE and state" do
      pkce = CodexOAuth.generate_pkce()
      state = CodexOAuth.generate_state()
      url = CodexOAuth.build_authorize_url(pkce, state)

      assert url =~ "auth.openai.com/oauth/authorize"
      assert url =~ "code_challenge=#{pkce.code_challenge}"
      assert url =~ "state=#{state}"
      assert url =~ "redirect_uri="
      assert url =~ "originator=pixir"
    end
  end

  defp random_free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp send_callback(port, path) do
    Task.start(fn ->
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      request = "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      :gen_tcp.send(socket, request)
      :gen_tcp.recv(socket, 0, 1_000)
      :gen_tcp.close(socket)
    end)
  end
end
