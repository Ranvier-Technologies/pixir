defmodule Pixir.Auth.CodexOAuth do
  @moduledoc """
  The "Sign in with ChatGPT (Codex)" OAuth flow (ADR 0002), implemented natively over
  Finch. Supports **browser PKCE** (localhost callback on `127.0.0.1:1455`) and the
  **device-code** fallback for headless environments. Constants and request shapes mirror
  the Pi reference implementation.

  Browser flow:

    1. `generate_pkce/0` + `generate_state/0` + `build_authorize_url/2`
    2. `start_callback_server/1` + `wait_for_callback/2` — capture the authorization
       code at `http://localhost:1455/auth/callback`
    3. `exchange_for_credential/3` — exchange the code at `/oauth/token`

  Device-code flow:

    1. `start_device_auth/0` — POST the user-code endpoint → `{device_auth_id,
       user_code, interval}`. The user enters `user_code` at `verification_uri`.
    2. `poll_for_authorization/2` — poll the device-token endpoint until the user
       approves; the server returns an `authorization_code` *and* the PKCE
       `code_verifier` it generated.
    3. `exchange_for_credential/3` — exchange that code at `/oauth/token`

  `refresh/1` swaps a refresh token for a fresh credential. All functions return
  structured errors (ADR 0005).
  """

  alias Pixir.Auth.CallbackServer

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @auth_base "https://auth.openai.com"
  @authorize_url @auth_base <> "/oauth/authorize"
  @token_url @auth_base <> "/oauth/token"
  @device_usercode_url @auth_base <> "/api/accounts/deviceauth/usercode"
  @device_token_url @auth_base <> "/api/accounts/deviceauth/token"
  @device_verification_uri @auth_base <> "/codex/device"
  @device_redirect_uri @auth_base <> "/deviceauth/callback"
  @browser_scope "openid profile email offline_access"
  @originator "pixir"
  @device_timeout_s 15 * 60
  @jwt_claim_path "https://api.openai.com/auth"
  @refresh_skew_ms 60_000

  @type device :: %{
          device_auth_id: String.t(),
          user_code: String.t(),
          interval: pos_integer(),
          verification_uri: String.t(),
          expires_in: pos_integer()
        }

  @type credential :: %{
          kind: :subscription,
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer(),
          account_id: String.t(),
          obtained_at: String.t()
        }

  @doc "How long before expiry we proactively refresh (ms)."
  def refresh_skew_ms, do: @refresh_skew_ms

  @doc "Registered redirect URI for the browser OAuth flow."
  @spec browser_redirect_uri() :: String.t()
  def browser_redirect_uri, do: CallbackServer.redirect_uri()

  @doc "Generate PKCE verifier/challenge pair for the browser flow."
  @spec generate_pkce() :: %{code_verifier: String.t(), code_challenge: String.t()}
  def generate_pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    %{code_verifier: verifier, code_challenge: challenge}
  end

  @doc "Generate an OAuth `state` value for CSRF protection."
  @spec generate_state() :: String.t()
  def generate_state do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc "Build the browser authorize URL for the user to open."
  @spec build_authorize_url(map(), String.t(), keyword()) :: String.t()
  def build_authorize_url(pkce, state, opts \\ []) do
    originator = Keyword.get(opts, :originator, @originator)

    query =
      %{
        "response_type" => "code",
        "client_id" => @client_id,
        "redirect_uri" => browser_redirect_uri(),
        "scope" => @browser_scope,
        "code_challenge" => pkce.code_challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => originator
      }
      |> URI.encode_query()

    @authorize_url <> "?" <> query
  end

  @doc "Start the localhost callback listener. Accepts `:host`, `:port` (testing)."
  @spec start_callback_server(keyword()) :: {:ok, port()} | {:error, map()}
  def start_callback_server(opts \\ []), do: CallbackServer.listen(opts)

  @doc "Wait for one browser callback. Requires `:state`; accepts `:timeout_ms`."
  @spec wait_for_callback(port(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def wait_for_callback(socket, opts), do: CallbackServer.wait_for_callback(socket, opts)

  @doc "Close the callback listen socket."
  @spec close_callback_server(port()) :: :ok
  def close_callback_server(socket), do: CallbackServer.close(socket)

  @doc "Begin device authorization. Returns device info to display to the user."
  @spec start_device_auth() :: {:ok, device()} | {:error, map()}
  def start_device_auth do
    case post_json(@device_usercode_url, %{client_id: @client_id}) do
      {:ok, 200, body} ->
        with {:ok, %{"device_auth_id" => id, "user_code" => code} = json} <- Jason.decode(body) do
          {:ok,
           %{
             device_auth_id: id,
             user_code: code,
             interval: positive_int(json["interval"], 5),
             verification_uri: @device_verification_uri,
             expires_in: @device_timeout_s
           }}
        else
          _ -> {:error, err(:invalid_response, "malformed device-code response", %{body: body})}
        end

      {:ok, 404, _body} ->
        {:error,
         err(:device_code_unsupported, "device-code login is not enabled for this account", %{})}

      {:ok, status, body} ->
        {:error,
         err(:device_auth_failed, "device-code request failed", %{status: status, body: body})}

      {:error, _} = e ->
        e
    end
  end

  @doc """
  Poll until the user approves (or the flow times out). Honors `slow_down` by widening
  the interval (RFC 8628). Returns `{authorization_code, code_verifier}`.
  """
  @spec poll_for_authorization(device(), keyword()) ::
          {:ok, %{authorization_code: String.t(), code_verifier: String.t()}} | {:error, map()}
  def poll_for_authorization(device, opts \\ []) do
    deadline = now_ms() + device.expires_in * 1000
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    poll_loop(device, deadline, sleep)
  end

  defp poll_loop(device, deadline, sleep) do
    if now_ms() >= deadline do
      {:error, err(:timeout, "device-code flow timed out", %{})}
    else
      case poll_once(device) do
        {:ok, result} ->
          {:ok, result}

        {:pending, next_interval} ->
          sleep.(min(next_interval, max(0, deadline - now_ms())))
          poll_loop(device, deadline, sleep)

        {:error, _} = e ->
          e
      end
    end
  end

  # one poll → {:ok, result} | {:pending, next_interval_ms} | {:error, structured}
  defp poll_once(device) do
    body = %{device_auth_id: device.device_auth_id, user_code: device.user_code}

    case post_json(@device_token_url, body) do
      {:ok, 200, rbody} ->
        case Jason.decode(rbody) do
          {:ok, %{"authorization_code" => code, "code_verifier" => verifier}}
          when is_binary(code) and is_binary(verifier) ->
            {:ok, %{authorization_code: code, code_verifier: verifier}}

          _ ->
            {:error, err(:invalid_response, "malformed device-token response", %{body: rbody})}
        end

      {:ok, status, _rbody} when status in [403, 404] ->
        {:pending, max(1_000, device.interval * 1000)}

      {:ok, _status, rbody} ->
        case error_code(rbody) do
          "deviceauth_authorization_pending" -> {:pending, max(1_000, device.interval * 1000)}
          "slow_down" -> {:pending, max(1_000, device.interval * 1000 + 5_000)}
          _ -> {:error, err(:device_auth_failed, "device-token poll failed", %{body: rbody})}
        end

      {:error, _} = e ->
        e
    end
  end

  @doc """
  Exchange an authorization code (+ verifier) for a stored-shape credential.

  Pass `redirect_uri:` for the browser flow; device-code uses the device callback URI by
  default.
  """
  @spec exchange_for_credential(String.t(), String.t(), keyword()) ::
          {:ok, credential()} | {:error, map()}
  def exchange_for_credential(code, verifier, opts \\ []) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @device_redirect_uri)

    form = %{
      grant_type: "authorization_code",
      client_id: @client_id,
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
    }

    with {:ok, tokens} <- post_token(form, :exchange) do
      credential_from_tokens(tokens)
    end
  end

  @doc "Refresh an expired/expiring subscription credential."
  @spec refresh(String.t()) :: {:ok, credential()} | {:error, map()}
  def refresh(refresh_token) do
    form = %{grant_type: "refresh_token", refresh_token: refresh_token, client_id: @client_id}

    with {:ok, tokens} <- post_token(form, :refresh) do
      credential_from_tokens(tokens)
    end
  end

  @doc "Extract `chatgpt_account_id` from an access token's JWT claims."
  @spec account_id_from_token(String.t()) :: {:ok, String.t()} | {:error, :no_account_id}
  def account_id_from_token(access) when is_binary(access) do
    with [_h, payload, _s] <- String.split(access, "."),
         {:ok, raw} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(raw),
         %{"chatgpt_account_id" => id} when is_binary(id) and id != "" <-
           Map.get(claims, @jwt_claim_path, %{}) do
      {:ok, id}
    else
      _ -> {:error, :no_account_id}
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp post_token(form, op) do
    case post_form(@token_url, form) do
      {:ok, status, body} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => a, "refresh_token" => r, "expires_in" => e}}
          when is_binary(a) and is_binary(r) and is_integer(e) ->
            {:ok, %{access: a, refresh: r, expires_at: now_ms() + e * 1000}}

          _ ->
            {:error, err(:invalid_response, "token #{op} response missing fields", %{body: body})}
        end

      {:ok, status, body} ->
        {:error, err(:token_request_failed, "token #{op} failed", %{status: status, body: body})}

      {:error, _} = e ->
        e
    end
  end

  defp credential_from_tokens(%{access: a, refresh: r, expires_at: exp}) do
    case account_id_from_token(a) do
      {:ok, id} ->
        {:ok,
         %{
           kind: :subscription,
           access_token: a,
           refresh_token: r,
           expires_at: exp,
           account_id: id,
           obtained_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, :no_account_id} ->
        {:error, err(:no_account_id, "could not extract chatgpt_account_id from token", %{})}
    end
  end

  defp post_json(url, map),
    do: request(url, [{"content-type", "application/json"}], Jason.encode!(map))

  defp post_form(url, map),
    do:
      request(url, [{"content-type", "application/x-www-form-urlencoded"}], URI.encode_query(map))

  defp request(url, headers, body) do
    case Finch.build(:post, url, headers, body) |> Finch.request(Pixir.Finch) do
      {:ok, %Finch.Response{status: status, body: rbody}} ->
        {:ok, status, rbody}

      {:error, reason} ->
        {:error, err(:network, "request to OpenAI auth failed", %{reason: inspect(reason)})}
    end
  end

  defp error_code(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      {:ok, %{"error" => code}} when is_binary(code) -> code
      _ -> nil
    end
  end

  defp positive_int(v, _default) when is_integer(v) and v > 0, do: v

  defp positive_int(v, default) when is_binary(v),
    do: positive_int(String.to_integer(String.trim(v)), default)

  defp positive_int(_v, default), do: default

  defp now_ms, do: System.system_time(:millisecond)

  defp err(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
