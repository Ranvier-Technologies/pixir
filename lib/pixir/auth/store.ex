defmodule Pixir.Auth.Store do
  @moduledoc """
  Persistence for the subscription **Credential** at `~/.pixir/auth.json` (ADR 0002).

  Only subscription credentials are written — an `OPENAI_API_KEY` lives in the
  environment and is never persisted. Writes are atomic (temp + rename) and the file
  is mode `0600`. The on-disk shape is a flat JSON object with string keys; `load/1`
  returns the in-memory credential map (atom keys).
  """

  alias Pixir.Paths

  @type credential :: map()

  @doc "Load the stored subscription credential, if any. Accepts `:path` (testing)."
  @spec load(keyword()) :: {:ok, credential()} | {:error, :not_found | map()}
  def load(opts \\ []) do
    file = path(opts)

    case File.read(file) do
      {:error, :enoent} ->
        {:error, :not_found}

      {:ok, contents} ->
        with {:ok, %{} = json} <- Jason.decode(contents),
             %{"kind" => "subscription"} <- json do
          {:ok, from_json(json)}
        else
          _ ->
            {:error,
             err(:corrupt_auth, "auth.json is unreadable or not a subscription credential", %{
               path: file
             })}
        end

      {:error, reason} ->
        {:error,
         err(:auth_read_failed, "could not read auth.json", %{reason: reason, path: file})}
    end
  end

  @doc "Persist a subscription credential atomically (mode 0600)."
  @spec save(credential(), keyword()) :: :ok | {:error, map()}
  def save(%{kind: :subscription} = cred, opts \\ []) do
    file = path(opts)
    Paths.ensure_global_root()
    tmp = file <> ".tmp"
    data = Jason.encode!(to_json(cred), pretty: true)

    with :ok <- File.write(tmp, data),
         _ <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, file),
         _ <- File.chmod(file, 0o600) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)

        {:error,
         err(:auth_write_failed, "could not write auth.json", %{reason: reason, path: file})}
    end
  end

  @doc "Delete the stored credential (logout). Missing file is success."
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    case File.rm(path(opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> :ok
    end
  end

  @doc "Path to auth.json. Accepts `:path` override (testing)."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []), do: Keyword.get(opts, :path) || Paths.auth_file()

  # ── internals ─────────────────────────────────────────────────────────────

  defp to_json(cred) do
    %{
      "kind" => "subscription",
      "access_token" => cred.access_token,
      "refresh_token" => cred.refresh_token,
      "expires_at" => cred.expires_at,
      "account_id" => cred.account_id,
      "obtained_at" => cred.obtained_at
    }
  end

  defp from_json(json) do
    %{
      kind: :subscription,
      access_token: json["access_token"],
      refresh_token: json["refresh_token"],
      expires_at: json["expires_at"],
      account_id: json["account_id"],
      obtained_at: json["obtained_at"]
    }
  end

  defp err(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
