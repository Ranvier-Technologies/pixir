defmodule Pixir.ModelsRefresh do
  @moduledoc """
  Explicit, fail-closed model-catalog discovery.

  Refresh is never invoked implicitly. Each provider is queried only when Pixir has
  an authentication kind supported by that provider's public models endpoint.
  Successful provider lists are merged into the raw config JSON with an atomic write;
  skipped or failed providers retain their existing config keys.
  """

  alias Pixir.{Auth, Config, Paths, Provider}
  alias Pixir.Providers.{ErrBody, Registry}

  @openai_url "https://api.openai.com/v1/models"
  @anthropic_url "https://api.anthropic.com/v1/models"

  @type result :: %{required(String.t()) => term()}

  @doc "Return the current effective catalogs and their local source without network access."
  @spec catalog(keyword()) :: {:ok, result()} | {:error, map()}
  def catalog(opts \\ []) do
    path = Keyword.get(opts, :config_path, Paths.config_file())
    config = Config.load(config_path: path)

    if Map.has_key?(config, "error") do
      {:error,
       error(:config_read_failed, "could not read config.json", %{
         path: Path.expand(path),
         reason: config["error"]
       })}
    else
      effective = config["effective"]

      result = %{
        "config_path" => Path.expand(path),
        "providers" => %{
          "openai" => %{
            "source" => source(effective["models"]),
            "models" => model_ids(Provider.models(config_path: path))
          },
          "anthropic" => %{
            "source" => source(effective["anthropic_models"]),
            "models" => anthropic_model_ids(config_path: path)
          }
        }
      }

      {:ok, maybe_put(result, "models_refreshed_at", effective["models_refreshed_at"])}
    end
  end

  @doc "Query supported model endpoints and atomically persist each successful catalog."
  @spec refresh(keyword()) :: {:ok, result()} | {:error, map()}
  def refresh(opts \\ []) do
    path = Keyword.get(opts, :config_path, Paths.config_file())

    with {:ok, raw} <- read_raw_config(path) do
      refreshed_at = refreshed_at(opts)
      previous = previous_catalogs(path)
      providers = refresh_providers(opts, previous)
      updates = successful_updates(providers)

      if map_size(updates) == 0 do
        {:ok, refresh_result(refreshed_at, providers, path, false)}
      else
        updated_raw =
          raw
          |> Map.merge(updates)
          |> Map.put("models_refreshed_at", refreshed_at)

        case write_raw_config(path, updated_raw) do
          :ok -> {:ok, refresh_result(refreshed_at, providers, path, true)}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp refresh_providers(opts, previous) do
    %{
      "openai" => refresh_openai(opts, previous["openai"]),
      "anthropic" => refresh_anthropic(opts, previous["anthropic"])
    }
  end

  defp refresh_openai(opts, previous) do
    auth = Keyword.get(opts, :auth, Auth)

    case auth_status(auth) do
      %{authenticated?: true, kind: :api_key} ->
        case auth_token(auth) do
          {:ok, key} ->
            request_models(
              opts,
              "openai",
              @openai_url,
              [{"authorization", "Bearer " <> key}],
              previous
            )

          {:error, _error} ->
            %{"status" => "skipped", "reason" => "no_credential"}
        end

      %{authenticated?: true} ->
        %{
          "status" => "skipped",
          "reason" => "auth_kind_unsupported_for_models_endpoint"
        }

      _ ->
        %{"status" => "skipped", "reason" => "no_credential"}
    end
  end

  defp refresh_anthropic(opts, previous) do
    env = Keyword.get(opts, :env, &System.get_env/1)

    case env.("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        request_models(
          opts,
          "anthropic",
          @anthropic_url,
          [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
          previous
        )

      _ ->
        %{"status" => "skipped", "reason" => "no_credential"}
    end
  end

  defp request_models(opts, provider, url, headers, previous) do
    http = Keyword.get(opts, :http, &default_http/1)

    response =
      try do
        http.(%{url: url, headers: headers})
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case response do
      {:ok, %{status: 200, body: body}} ->
        parse_models(body, provider, previous)

      {:ok, %{"status" => 200, "body" => body}} ->
        parse_models(body, provider, previous)

      {:ok, %{status: status, body: body}} ->
        http_error(status, body)

      {:ok, %{"status" => status, "body" => body}} ->
        http_error(status, body)

      {:error, reason} ->
        %{"status" => "error", "kind" => "network", "reason" => inspect(reason)}

      other ->
        %{"status" => "error", "kind" => "invalid_http_response", "reason" => inspect(other)}
    end
  end

  defp parse_models(body, provider, previous) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => data}} when is_list(data) ->
        models =
          data
          |> Enum.flat_map(fn
            %{"id" => id} when is_binary(id) -> [String.trim(id)]
            _ -> []
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if models == [] do
          %{"status" => "error", "kind" => "invalid_models_response", "provider" => provider}
        else
          %{
            "status" => "refreshed",
            "models" => models,
            "added" => models -- previous,
            "removed" => previous -- models
          }
        end

      _ ->
        %{"status" => "error", "kind" => "invalid_json", "provider" => provider}
    end
  end

  defp parse_models(_body, provider, _previous),
    do: %{"status" => "error", "kind" => "invalid_json", "provider" => provider}

  defp http_error(status, body) do
    body = if is_binary(body), do: body, else: inspect(body)
    capture = ErrBody.append(ErrBody.new(), body)
    bounded = ErrBody.body(capture)

    %{
      "status" => "error",
      "kind" => "provider_http_error",
      "status_code" => status,
      "err_body" => bounded
    }
    |> maybe_put("err_body_truncated", ErrBody.truncated?(capture))
  end

  defp default_http(%{url: url, headers: headers}) do
    case Finch.build(:get, url, headers) |> Finch.request(Pixir.Finch) do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_status(auth) do
    Auth.status(auth)
  catch
    :exit, _ -> %{authenticated?: false, kind: nil}
  end

  defp auth_token(auth) do
    Auth.access_token(auth)
  catch
    :exit, _ -> {:error, :auth_unavailable}
  end

  # Diff base = the raw previous source list (config override when present,
  # else built-ins), never the advertised catalog: `Provider.models/1` inserts
  # the machine-global default model at the head, which would pollute
  # added/removed with presentation shaping and leak the operator's default
  # into diffs computed against an explicit :config_path.
  defp previous_catalogs(path) do
    %{
      "openai" => Config.file_models(config_path: path) || Provider.built_in_models(),
      "anthropic" =>
        Config.file_anthropic_models(config_path: path) ||
          Registry.anthropic_built_in_models()
    }
  end

  defp anthropic_model_ids(opts) do
    Registry.models(opts)
    |> Enum.filter(&String.starts_with?(&1["id"], "claude-"))
    |> model_ids()
  end

  defp model_ids(models), do: Enum.map(models, & &1["id"])

  defp successful_updates(providers) do
    Enum.reduce(providers, %{}, fn
      {"openai", %{"status" => "refreshed", "models" => models}}, acc ->
        Map.put(acc, "models", models)

      {"anthropic", %{"status" => "refreshed", "models" => models}}, acc ->
        Map.put(acc, "anthropic_models", models)

      _provider, acc ->
        acc
    end)
  end

  defp refresh_result(refreshed_at, providers, path, wrote?) do
    %{
      "refreshed_at" => refreshed_at,
      "providers" => providers,
      "config_path" => Path.expand(path),
      "wrote_config" => wrote?
    }
  end

  defp read_raw_config(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = raw} ->
            {:ok, raw}

          _ ->
            {:error,
             error(:invalid_config, "config.json must contain a JSON object", %{
               path: Path.expand(path)
             })}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error,
         error(:config_read_failed, "could not read config.json", %{
           path: Path.expand(path),
           reason: reason
         })}
    end
  end

  defp write_raw_config(path, raw) do
    directory = Path.dirname(path)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    data = Jason.encode!(raw, pretty: true) <> "\n"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(tmp, data),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)

        {:error,
         error(:config_write_failed, "could not write config.json", %{
           path: Path.expand(path),
           reason: reason
         })}
    end
  end

  defp refreshed_at(opts) do
    opts
    |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp source([_ | _]), do: "config_override"
  defp source(_), do: "built_in"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
