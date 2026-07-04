defmodule Pixir.Auth do
  @moduledoc """
  Owns the Session's **Credential** and serializes token refresh (ADR 0002).

  A singleton GenServer (one per node). Two credential kinds reach the same Responses
  Provider:

    * `:subscription` — a Codex OAuth token (primary), loaded from `~/.pixir/auth.json`
      and auto-refreshed shortly before expiry.
    * `:api_key` — an `OPENAI_API_KEY` from the environment (fallback). Never persisted.

  Precedence: a stored subscription wins; otherwise `OPENAI_API_KEY` is used; otherwise
  the Session is unauthenticated. Because all calls funnel through this one process,
  refresh is naturally serialized — concurrent Turns never race to refresh.

  The public API takes an optional `server` so tests can run an isolated instance with
  an injected store path and OAuth module.
  """

  use GenServer

  alias Pixir.Auth.{CodexOAuth, Store}

  @type credential :: map()

  # ── lifecycle ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    store_path = Keyword.get(opts, :store_path)
    env_key = Keyword.get(opts, :env_api_key, System.get_env("OPENAI_API_KEY"))

    state = %{
      credential: initial_credential(store_path, env_key),
      store_path: store_path,
      env_api_key: env_key,
      oauth: Keyword.get(opts, :oauth, CodexOAuth)
    }

    {:ok, state}
  end

  # ── public API ──────────────────────────────────────────────────────────

  @doc "Return a valid access token / API key, refreshing the subscription if needed."
  @spec access_token(GenServer.server()) :: {:ok, String.t()} | {:error, map()}
  def access_token(server \\ __MODULE__), do: GenServer.call(server, :access_token)

  @doc "HTTP headers the Provider should send (authorization + account id)."
  @spec request_headers(GenServer.server()) :: {:ok, [{String.t(), String.t()}]} | {:error, map()}
  def request_headers(server \\ __MODULE__), do: GenServer.call(server, :request_headers)

  @doc "Whether a usable credential is present (no refresh attempted)."
  @spec authenticated?(GenServer.server()) :: boolean()
  def authenticated?(server \\ __MODULE__), do: GenServer.call(server, :status).authenticated?

  @doc "Human/diagnostic status of the current credential."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Install a credential (persists subscription credentials)."
  @spec set_credential(GenServer.server(), credential()) :: :ok | {:error, map()}
  def set_credential(server \\ __MODULE__, credential),
    do: GenServer.call(server, {:set_credential, credential})

  @doc "Forget the subscription credential (falls back to `OPENAI_API_KEY` if set)."
  @spec logout(GenServer.server()) :: :ok
  def logout(server \\ __MODULE__), do: GenServer.call(server, :logout)

  @doc """
  Run the browser PKCE login flow (ADR 0002). `on_authorize` is called with
  `%{authorize_url, state}` so the caller can open the browser; this blocks the caller
  (not the GenServer) while waiting for the localhost callback. On success the
  credential is installed and `{:ok, status}` is returned.
  """
  @spec login_browser(GenServer.server(), (map() -> any()), keyword()) ::
          {:ok, map()} | {:error, map()}
  def login_browser(server \\ __MODULE__, on_authorize, opts \\ [])
      when is_function(on_authorize, 1) do
    oauth = GenServer.call(server, :oauth_module)
    timeout_ms = Keyword.get(opts, :timeout_ms, 15 * 60 * 1000)
    callback_opts = Keyword.take(opts, [:host, :port])

    pkce = oauth.generate_pkce()
    state = oauth.generate_state()
    authorize_url = oauth.build_authorize_url(pkce, state)

    on_authorize.(%{authorize_url: authorize_url, state: state})

    with {:ok, listen_socket} <- oauth.start_callback_server(callback_opts) do
      try do
        with {:ok, code} <-
               oauth.wait_for_callback(
                 listen_socket,
                 Keyword.merge(callback_opts, state: state, timeout_ms: timeout_ms)
               ),
             {:ok, credential} <-
               oauth.exchange_for_credential(code, pkce.code_verifier,
                 redirect_uri: oauth.browser_redirect_uri()
               ),
             :ok <- set_credential(server, credential) do
          {:ok, status(server)}
        end
      after
        oauth.close_callback_server(listen_socket)
      end
    end
  end

  @doc """
  Preferred login entry: browser PKCE first, device-code when the callback port is
  unavailable. `callbacks` is a map with:

    * `:on_authorize` — `fn %{authorize_url, state} -> ... end`
    * `:on_device_code` — `fn %{user_code, verification_uri, interval, expires_in} -> ... end`
    * `:on_fallback` — optional `fn message -> ... end` when browser login is skipped
  """
  @spec login(GenServer.server(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def login(server \\ __MODULE__, callbacks, opts \\ []) when is_map(callbacks) do
    on_authorize = Map.get(callbacks, :on_authorize, fn _ -> :ok end)
    on_device_code = Map.get(callbacks, :on_device_code, fn _ -> :ok end)
    on_fallback = Map.get(callbacks, :on_fallback, fn _ -> :ok end)

    case login_browser(server, on_authorize, opts) do
      {:ok, status} ->
        {:ok, status}

      {:error, %{error: %{kind: :callback_port_unavailable, message: message}}} ->
        on_fallback.(message)
        login_device_code(server, on_device_code, opts)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Run the device-code login flow (ADR 0002). `on_user_code` is called with
  `%{user_code, verification_uri, interval, expires_in}` so the caller can display the
  code; this blocks the caller (not the GenServer) while polling. On success the
  credential is installed and `{:ok, status}` is returned.
  """
  @spec login_device_code(GenServer.server(), (map() -> any()), keyword()) ::
          {:ok, map()} | {:error, map()}
  def login_device_code(server \\ __MODULE__, on_user_code, opts \\ [])
      when is_function(on_user_code, 1) do
    oauth = GenServer.call(server, :oauth_module)

    with {:ok, device} <- oauth.start_device_auth(),
         _ <-
           on_user_code.(
             Map.take(device, [:user_code, :verification_uri, :interval, :expires_in])
           ),
         {:ok, %{authorization_code: code, code_verifier: verifier}} <-
           oauth.poll_for_authorization(device, opts),
         {:ok, credential} <- oauth.exchange_for_credential(code, verifier),
         :ok <- set_credential(server, credential) do
      {:ok, status(server)}
    end
  end

  # ── callbacks ───────────────────────────────────────────────────────────

  @impl true
  def handle_call(:access_token, _from, state) do
    case ensure_token(state) do
      {:ok, token, _account_id, state2} -> {:reply, {:ok, token}, state2}
      {:error, err, state2} -> {:reply, {:error, err}, state2}
    end
  end

  def handle_call(:request_headers, _from, state) do
    case ensure_token(state) do
      {:ok, token, nil, state2} ->
        {:reply, {:ok, [{"authorization", "Bearer " <> token}]}, state2}

      {:ok, token, account_id, state2} ->
        {:reply,
         {:ok, [{"authorization", "Bearer " <> token}, {"chatgpt-account-id", account_id}]},
         state2}

      {:error, err, state2} ->
        {:reply, {:error, err}, state2}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, status_of(state.credential), state}

  def handle_call(:oauth_module, _from, state), do: {:reply, state.oauth, state}

  def handle_call({:set_credential, %{kind: :subscription} = cred}, _from, state) do
    case Store.save(cred, path: state.store_path) do
      :ok -> {:reply, :ok, %{state | credential: cred}}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:set_credential, %{kind: :api_key} = cred}, _from, state) do
    {:reply, :ok, %{state | credential: cred}}
  end

  def handle_call(:logout, _from, state) do
    :ok = Store.clear(path: state.store_path)
    {:reply, :ok, %{state | credential: api_key_credential(state.env_api_key)}}
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp initial_credential(store_path, env_key) do
    case Store.load(path: store_path) do
      {:ok, cred} -> cred
      {:error, _} -> api_key_credential(env_key)
    end
  end

  defp api_key_credential(nil), do: nil
  defp api_key_credential(key) when is_binary(key), do: %{kind: :api_key, api_key: key}

  defp ensure_token(%{credential: nil} = state), do: {:error, not_authenticated(), state}

  defp ensure_token(%{credential: %{kind: :api_key, api_key: key}} = state),
    do: {:ok, key, nil, state}

  defp ensure_token(%{credential: %{kind: :subscription} = cred} = state) do
    if fresh?(cred),
      do: {:ok, cred.access_token, cred.account_id, state},
      else: do_refresh(cred, state)
  end

  defp do_refresh(cred, state) do
    case state.oauth.refresh(cred.refresh_token) do
      {:ok, new_cred} ->
        # Persist BEFORE returning: OpenAI rotates the refresh token on every refresh, so
        # a successful refresh whose new token isn't saved would strand the next start with
        # a dead token. If the save fails we still use the fresh token for this call but
        # surface the persistence failure to diagnostics.
        case Store.save(new_cred, path: state.store_path) do
          :ok -> :ok
          {:error, save_err} -> log_save_failure(save_err)
        end

        {:ok, new_cred.access_token, new_cred.account_id, %{state | credential: new_cred}}

      {:error, err} ->
        {:error, refresh_error(err), state}
    end
  end

  # A failed refresh whose cause is a rejected token (4xx) means the refresh token is
  # dead — re-login is the only fix, so re-map it to an actionable `:not_authenticated`.
  # Transient causes (network, 5xx) keep their kind so the Provider can retry.
  defp refresh_error(%{error: %{kind: :token_request_failed, details: %{status: status}}} = err)
       when status in 400..499 do
    put_in(err.error.kind, :not_authenticated)
    |> put_in([:error, :message], "your session expired — run `pixir login` to sign in again")
  end

  defp refresh_error(%{error: %{kind: :no_account_id}} = err),
    do: put_in(err.error.kind, :not_authenticated)

  defp refresh_error(err), do: err

  defp log_save_failure(err) do
    require Logger
    Logger.warning("pixir: refreshed token but failed to persist it: #{inspect(err)}")
  end

  defp fresh?(%{expires_at: exp}) when is_integer(exp),
    do: exp - System.system_time(:millisecond) > CodexOAuth.refresh_skew_ms()

  defp fresh?(_), do: false

  defp status_of(nil), do: %{authenticated?: false, kind: nil}

  defp status_of(%{kind: :api_key}), do: %{authenticated?: true, kind: :api_key}

  defp status_of(%{kind: :subscription} = cred) do
    %{
      authenticated?: true,
      kind: :subscription,
      account_id: cred.account_id,
      expires_at: cred.expires_at,
      expired?: not fresh?(cred)
    }
  end

  defp not_authenticated do
    %{
      ok: false,
      error: %{
        kind: :not_authenticated,
        message: "no credential — run `pixir login` or set OPENAI_API_KEY",
        details: %{}
      }
    }
  end
end
