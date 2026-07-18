defmodule Pixir.Config do
  @moduledoc """
  Loader for `~/.pixir/config.json` (ADR 0005 ergonomics).

  Parses user-global knobs, ignores invalid values with warnings (never hard-fails on
  a bad field), and resolves effective values with this precedence for each key:

    1. `config :pixir, :key` (programmatic override)
    2. `~/.pixir/config.json`
    3. built-in default

  Model id keeps the Provider chain: `config :pixir, :model` → `PIXIR_MODEL` →
  `"model"` in config.json → built-in default.

  Legacy keys (`model`, `models`, `context_windows`) remain supported alongside the
  expanded surface (`permission_default`, `reasoning.effort`, `text.verbosity`,
  `bash_timeout_ms`, `bash_timeout_max_ms`, `host_commands`, `max_retries`,
  `stream_idle_timeout_ms`, `compaction.tail_events`).

  `bash_timeout_max_ms` is an override cap, not a way to shorten the configured
  default. The effective cap is never lower than `bash_timeout_ms`; when config asks
  for a lower cap, `load/1` reports a warning and raises the effective cap so the
  default bash command remains executable.
  """

  alias Pixir.Paths
  alias Pixir.Provider.HostedTools
  alias Pixir.Providers.ResponsesBackend

  @default_model "gpt-5.5"
  @default_bash_timeout_ms 120_000
  @default_bash_timeout_max_ms 600_000
  @default_host_command_max_concurrent 4
  @default_host_command_queue_limit 16
  @default_host_command_queue_timeout_ms 5_000
  @default_max_retries 2
  @default_stream_idle_timeout_ms 180_000
  @default_tail_events 40

  @valid_reasoning_efforts ~w(low medium high xhigh)
  @valid_text_verbosities ~w(low medium high)
  @type warning :: %{required(String.t()) => String.t()}
  @type load_result :: %{
          required(String.t()) => term()
        }

  @doc """
  Load and resolve `config.json`.

  Returns a JSON-serializable map with `"path"`, `"present"`, `"effective"`, and
  `"warnings"`. Missing files yield defaults and an empty warning list.
  """
  @spec load(keyword()) :: load_result()
  def load(opts \\ []) do
    path = Keyword.get(opts, :config_path, Paths.config_file())

    case read_source_document(path, opts) do
      {:ok, source} ->
        case decode_source_document_for_load(source) do
          {:ok, raw, profile_error} ->
            {profile_warning, profile_summary} = profile_projection(raw, profile_error)
            warnings = warnings(raw) ++ List.wrap(profile_warning)

            effective =
              raw
              |> effective_map(warnings)
              |> maybe_put_responses_backend(profile_summary)

            %{
              "path" => Path.expand(path),
              "present" => true,
              "effective" => effective,
              "warnings" => warnings
            }

          {:error, error} ->
            config_error_projection(path, error)
        end

      {:missing, _} ->
        %{
          "path" => Path.expand(path),
          "present" => false,
          "effective" => effective_map(%{}, []),
          "warnings" => []
        }

      {:error, error} ->
        config_error_projection(path, error)
    end
  end

  @doc "Resolve one immutable model/backend snapshot from exactly one source-document read."
  @spec request_snapshot(keyword()) :: {:ok, map()} | {:error, map()}
  def request_snapshot(opts \\ []) do
    path = Keyword.get(opts, :config_path, Paths.config_file())

    with {:ok, source} <- invoke_snapshot_loader(path, opts),
         {:ok, raw} <- decode_source_document(source),
         {:ok, backend} <- snapshot_backend(raw) do
      {model, model_source, provider_defaults} = snapshot_request_values(raw)

      {:ok,
       %{
         model: model,
         model_source: model_source,
         responses_backend: backend,
         provider_defaults: provider_defaults,
         config_present?: source.present?
       }}
    else
      {:missing, source} ->
        {model, model_source, provider_defaults} = snapshot_request_values(%{})

        {:ok,
         %{
           model: model,
           model_source: model_source,
           responses_backend: :absent,
           provider_defaults: provider_defaults,
           config_present?: source.present?
         }}

      {:error, %{ok: false, error: %{kind: :invalid_config}}} = error ->
        error

      {:error, %{kind: :invalid_json}} ->
        invalid_config(:config, :invalid_json, "The Pixir configuration JSON is invalid.")

      {:error, %{kind: :read_failed}} ->
        invalid_config(:config, :read_failed, "The Pixir configuration could not be read.")

      {:error, _other} ->
        invalid_config(:config, :read_failed, "The Pixir configuration could not be read.")
    end
  end

  @doc "Resolve only the explicit Responses backend descriptor from one request snapshot."
  @spec responses_backend(keyword()) ::
          {:ok, :absent | ResponsesBackend.t()} | {:error, map()}
  def responses_backend(opts \\ []) do
    case request_snapshot(opts) do
      {:ok, %{responses_backend: backend}} -> {:ok, backend}
      {:error, _} = error -> error
    end
  end

  @doc "Accepted reasoning effort ids."
  @spec valid_reasoning_efforts() :: [String.t()]
  def valid_reasoning_efforts, do: @valid_reasoning_efforts

  @doc "Resolved permission default (`:auto`, `:ask`, or `:read_only`)."
  @spec permission_default(keyword()) :: Permissions.mode()
  def permission_default(opts \\ []) do
    load(opts)
    |> get_in(["effective", "permission_default"])
    |> permission_atom()
  end

  @doc "Resolved reasoning effort, or `nil` to omit and let the model default."
  @spec reasoning_effort(keyword()) :: String.t() | nil
  def reasoning_effort(opts \\ []), do: get_in(load(opts), ["effective", "reasoning", "effort"])

  @doc "Resolved text verbosity, or `nil` to omit and let the model default."
  @spec text_verbosity(keyword()) :: String.t() | nil
  def text_verbosity(opts \\ []), do: get_in(load(opts), ["effective", "text", "verbosity"])

  @spec bash_timeout_ms(keyword()) :: pos_integer()
  def bash_timeout_ms(opts \\ []), do: get_in(load(opts), ["effective", "bash_timeout_ms"])

  @spec bash_timeout_max_ms(keyword()) :: pos_integer()
  def bash_timeout_max_ms(opts \\ []),
    do: get_in(load(opts), ["effective", "bash_timeout_max_ms"])

  @doc "Resolved host-command boundary limits."
  @spec host_commands(keyword()) ::
          {:ok,
           %{
             required(String.t()) => non_neg_integer() | pos_integer()
           }}
  def host_commands(opts \\ []), do: {:ok, get_in(load(opts), ["effective", "host_commands"])}

  @spec max_retries(keyword()) :: non_neg_integer()
  def max_retries(opts \\ []), do: get_in(load(opts), ["effective", "max_retries"])

  @spec stream_idle_timeout_ms(keyword()) :: non_neg_integer()
  def stream_idle_timeout_ms(opts \\ []),
    do: get_in(load(opts), ["effective", "stream_idle_timeout_ms"])

  @spec compaction_tail_events(keyword()) :: pos_integer()
  def compaction_tail_events(opts \\ []),
    do: get_in(load(opts), ["effective", "compaction", "tail_events"])

  @doc "Resolved hosted web search config, or `nil` when disabled/absent."
  @spec web_search(keyword()) :: map() | nil
  def web_search(opts \\ []), do: get_in(load(opts), ["effective", "web_search"])

  @doc "Whether model-assisted compaction is enabled (default `false`)."
  @spec compaction_model_assisted(keyword()) :: boolean()
  def compaction_model_assisted(opts \\ []),
    do: get_in(load(opts), ["effective", "compaction", "model_assisted"])

  @doc "Effective model when config.json is present; application and env precedence still applies."
  @spec file_model(keyword()) :: String.t() | nil
  def file_model(opts \\ []) do
    loaded = load(opts)

    with %{"present" => true} <- loaded,
         model when is_binary(model) <- get_in(loaded, ["effective", "model"]) do
      model
    else
      _ -> nil
    end
  end

  @doc "Models list from config.json only, or `nil` when absent/invalid."
  @spec file_models(keyword()) :: [String.t()] | nil
  def file_models(opts \\ []) do
    case get_in(load(opts), ["effective", "models"]) do
      [_ | _] = models -> models
      _ -> nil
    end
  end

  @doc "Anthropic models list from config.json only, or `nil` when absent/invalid."
  @spec file_anthropic_models(keyword()) :: [String.t()] | nil
  def file_anthropic_models(opts \\ []) do
    case get_in(load(opts), ["effective", "anthropic_models"]) do
      [_ | _] = models -> models
      _ -> nil
    end
  end

  @doc "UTC timestamp written by the last explicit model-catalog refresh, if present."
  @spec models_refreshed_at(keyword()) :: String.t() | nil
  def models_refreshed_at(opts \\ []) do
    get_in(load(opts), ["effective", "models_refreshed_at"])
  end

  @doc "Context-window overrides from config.json (model => positive integer)."
  @spec file_context_windows(keyword()) :: %{String.t() => pos_integer()}
  def file_context_windows(opts \\ []) do
    case get_in(load(opts), ["effective", "context_windows"]) do
      %{} = windows -> windows
      _ -> %{}
    end
  end

  @doc "Merge config defaults into Provider opts without clobbering explicit values."
  @spec merge_provider_opts(keyword(), keyword()) :: keyword()
  def merge_provider_opts(provider_opts, config_opts \\ []) do
    eff = load(config_opts)["effective"]

    provider_opts
    |> Keyword.put_new(:max_retries, eff["max_retries"])
    |> Keyword.put_new(:stream_idle_timeout_ms, eff["stream_idle_timeout_ms"])
    |> put_optional(:reasoning_effort, eff["reasoning"]["effort"])
    |> put_optional(:text_verbosity, eff["text"]["verbosity"])
    |> put_optional(:web_search, eff["web_search"])
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp invoke_snapshot_loader(path, opts) do
    case Keyword.fetch(opts, :request_snapshot_loader) do
      :error ->
        read_source_document(path, opts)

      {:ok, loader} when not is_function(loader) ->
        invalid_loader(:invalid_loader_type)

      {:ok, loader} when not is_function(loader, 1) ->
        invalid_loader(:invalid_loader_arity)

      {:ok, loader} ->
        loader_opts = Keyword.delete(opts, :request_snapshot_loader)

        try do
          loader.(loader_opts)
          |> validate_loader_result()
        rescue
          _error -> invalid_loader(:loader_execution_failed)
        catch
          _kind, _reason -> invalid_loader(:loader_execution_failed)
        end
    end
  end

  defp validate_loader_result({:ok, source}) when is_map(source) do
    with true <- Map.get(source, :present?) == true,
         origin when origin in [:programmatic, :file] <- Map.get(source, :origin),
         document <- Map.get(source, :document),
         true <- valid_source_document?(origin, document) do
      {:ok, %{present?: true, origin: origin, document: document}}
    else
      _ -> invalid_loader(:invalid_loader_result)
    end
  end

  defp validate_loader_result({:missing, source}) when is_map(source) do
    if Map.get(source, :present?) == false and Map.get(source, :origin) == :file and
         is_binary(Map.get(source, :path)) do
      {:missing, %{present?: false, origin: :file, path: Map.get(source, :path)}}
    else
      invalid_loader(:invalid_loader_result)
    end
  end

  defp validate_loader_result({:error, %{kind: :read_failed} = error})
       when map_size(error) == 1,
       do: {:error, error}

  defp validate_loader_result({:error, %{kind: :invalid_json, position: position} = error})
       when map_size(error) == 2 and is_integer(position) and position >= 0,
       do: {:error, error}

  defp validate_loader_result(_result), do: invalid_loader(:invalid_loader_result)

  defp valid_source_document?(:programmatic, document), do: plain_map?(document)
  defp valid_source_document?(:file, document), do: is_binary(document)

  # Frozen #317 seam: one invocation performs at most one File.read/1.
  defp read_source_document(path, opts) do
    case Keyword.fetch(opts, :raw_config) do
      {:ok, raw} when is_map(raw) and not is_struct(raw) ->
        {:ok, %{present?: true, origin: :programmatic, document: raw}}

      {:ok, nil} ->
        read_source_file(path)

      {:ok, _invalid} ->
        {:error, %{kind: :invalid_json, position: 0}}

      :error ->
        read_source_file(path)
    end
  end

  defp read_source_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, %{present?: true, origin: :file, document: contents}}

      {:error, :enoent} ->
        {:missing, %{present?: false, origin: :file, path: Path.expand(path)}}

      {:error, _reason} ->
        {:error, %{kind: :read_failed}}
    end
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp decode_source_document(%{origin: :programmatic, document: raw})
       when is_map(raw) and not is_struct(raw),
       do: normalize_programmatic_document(raw)

  defp decode_source_document(%{origin: :file, document: contents}) when is_binary(contents) do
    with {:ok, ordered, raw} <- decode_file_document(contents),
         {:ok, profile_override} <- duplicate_safe_profile(ordered) do
      {:ok, maybe_override_profile(raw, profile_override)}
    end
  end

  defp decode_source_document(_source), do: invalid_loader(:invalid_loader_result)

  defp decode_source_document_for_load(%{origin: :programmatic, document: raw})
       when is_map(raw) and not is_struct(raw) do
    normalize_programmatic_for_load(raw)
  end

  defp decode_source_document_for_load(%{origin: :file, document: contents}) do
    with {:ok, ordered, raw} <- decode_file_document(contents) do
      case duplicate_safe_profile(ordered) do
        {:ok, profile_override} ->
          {:ok, maybe_override_profile(raw, profile_override), nil}

        {:error, %{ok: false, error: %{kind: :invalid_config} = error}} ->
          {:ok, Map.delete(raw, "responses_backend"), error}

        {:error, _} = error ->
          error
      end
    end
  end

  defp decode_source_document_for_load(_source),
    do: {:error, %{kind: :invalid_json, position: 0}}

  defp decode_file_document(contents) do
    case decode_ordered(contents) do
      {:ok, ordered} ->
        with :ok <- reject_non_profile_duplicates(ordered) do
          {:ok, ordered, ordered_document_to_plain(ordered)}
        end

      {:error, %Jason.DecodeError{} = error} ->
        {:error, %{kind: :invalid_json, position: bounded_position(error.position, contents)}}

      {:error, _} ->
        {:error, %{kind: :invalid_json, position: 0}}
    end
  end

  defp ordered_document_to_plain(%Jason.OrderedObject{values: pairs}) do
    Map.new(pairs, fn {key, value} -> {key, ordered_document_to_plain(value)} end)
  end

  defp ordered_document_to_plain(list) when is_list(list) do
    Enum.map(list, &ordered_document_to_plain/1)
  end

  defp ordered_document_to_plain(value), do: value

  defp reject_non_profile_duplicates(%Jason.OrderedObject{values: pairs}) do
    reject_ordered_pairs(pairs, MapSet.new(), :root)
  end

  defp reject_ordered_pairs([], _seen, _level), do: :ok

  defp reject_ordered_pairs([{key, value} | rest], seen, level) do
    cond do
      MapSet.member?(seen, key) and level == :root and key == "responses_backend" ->
        reject_ordered_pairs(rest, seen, level)

      MapSet.member?(seen, key) ->
        invalid_config(:config, :unknown_field)

      level == :root and key == "responses_backend" ->
        reject_ordered_pairs(rest, MapSet.put(seen, key), level)

      true ->
        with :ok <- reject_ordered_value_duplicates(value) do
          reject_ordered_pairs(rest, MapSet.put(seen, key), level)
        end
    end
  end

  defp reject_ordered_value_duplicates(%Jason.OrderedObject{values: pairs}),
    do: reject_ordered_pairs(pairs, MapSet.new(), :nested)

  defp reject_ordered_value_duplicates(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn value, :ok ->
      case reject_ordered_value_duplicates(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp reject_ordered_value_duplicates(_value), do: :ok

  defp decode_ordered(contents) do
    case Jason.decode(contents, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = object} -> {:ok, object}
      {:ok, _non_object} -> {:error, %{kind: :invalid_json, position: 0}}
      {:error, %Jason.DecodeError{} = error} -> {:error, error}
    end
  end

  defp duplicate_safe_profile(%Jason.OrderedObject{values: pairs}) do
    profiles = for {"responses_backend", value} <- pairs, do: value

    case profiles do
      [] -> {:ok, :absent}
      [profile] -> ordered_to_plain(profile, :responses_backend)
      _duplicates -> invalid_config(:responses_backend, :unknown_field)
    end
  end

  defp ordered_to_plain(%Jason.OrderedObject{values: pairs}, field) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if Map.has_key?(acc, key) do
        {:halt, invalid_config(field, :unknown_field)}
      else
        case ordered_to_plain(value, nested_profile_field(key, field)) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end

  defp ordered_to_plain(list, field) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case ordered_to_plain(value, field) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp ordered_to_plain(value, _field), do: {:ok, value}

  defp nested_profile_field("auth", _field), do: :auth
  defp nested_profile_field(_key, field), do: field

  defp normalize_programmatic_document(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(normalized) ->
          {:halt, invalid_config(:config, :invalid_json)}

        Map.has_key?(acc, normalized) ->
          {:halt, invalid_config(:config, :unknown_field)}

        true ->
          {:cont, {:ok, Map.put(acc, normalized, value)}}
      end
    end)
  end

  defp normalize_programmatic_for_load(raw) do
    raw
    |> Enum.reduce_while({:ok, %{}, nil}, fn {key, value}, {:ok, acc, profile_error} ->
      normalized = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(normalized) ->
          {:halt, invalid_config(:config, :invalid_json)}

        Map.has_key?(acc, normalized) and normalized == "responses_backend" ->
          {:cont, {:ok, Map.delete(acc, normalized), %{details: %{reason: :unknown_field}}}}

        Map.has_key?(acc, normalized) ->
          {:halt, invalid_config(:config, :unknown_field)}

        normalized == "responses_backend" and not is_nil(profile_error) ->
          {:cont, {:ok, acc, profile_error}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized, value), profile_error}}
      end
    end)
  end

  defp maybe_override_profile(raw, :absent), do: raw
  defp maybe_override_profile(raw, profile), do: Map.put(raw, "responses_backend", profile)

  defp snapshot_backend(raw) do
    case Map.fetch(raw, "responses_backend") do
      :error -> {:ok, :absent}
      {:ok, value} -> ResponsesBackend.resolve(value, source: :config)
    end
  end

  defp snapshot_request_values(raw) do
    warnings = warnings(raw)
    ignored = MapSet.new(warnings, & &1["field"])
    {model, model_source} = resolve_model_with_source(raw)

    provider_defaults = %{
      max_retries: resolve_max_retries(raw, ignored),
      stream_idle_timeout_ms: resolve_stream_idle_timeout_ms(raw, ignored),
      reasoning_effort: resolve_reasoning_effort(raw, ignored),
      text_verbosity: resolve_text_verbosity(raw, ignored),
      web_search: resolve_web_search(raw, ignored)
    }

    {model, model_source, provider_defaults}
  end

  defp normalize_model(model) when is_binary(model) do
    if String.valid?(model) do
      case String.trim(model) do
        "" -> nil
        trimmed -> trimmed
      end
    else
      nil
    end
  end

  defp normalize_model(_model), do: nil

  defp profile_projection(_raw, %{details: %{reason: reason}}) do
    {profile_warning(reason), nil}
  end

  defp profile_projection(raw, nil) do
    case Map.fetch(raw, "responses_backend") do
      :error ->
        {nil, nil}

      {:ok, value} ->
        case ResponsesBackend.resolve(value, source: :config) do
          {:ok, backend} ->
            {nil, ResponsesBackend.summary(backend)}

          {:error, %{error: %{details: %{reason: reason}}}} ->
            {profile_warning(reason), nil}
        end
    end
  end

  defp profile_warning(reason) do
    %{
      "field" => "responses_backend",
      "reason" => to_string(reason),
      "message" => "The responses_backend configuration is invalid and was ignored."
    }
  end

  defp maybe_put_responses_backend(effective, nil), do: effective

  defp maybe_put_responses_backend(effective, summary),
    do: Map.put(effective, "responses_backend", summary)

  defp config_error_projection(path, error) do
    %{
      "path" => Path.expand(path),
      "present" => true,
      "error" => public_config_error(error),
      "effective" => effective_map(%{}, []),
      "warnings" => []
    }
  end

  defp public_config_error({:error, error}), do: public_config_error(error)

  defp public_config_error(%{kind: :invalid_json, position: position}),
    do: %{kind: :invalid_json, position: position}

  defp public_config_error(%{kind: :read_failed}), do: %{kind: :read_failed}
  defp public_config_error(%{ok: false, error: error}), do: public_config_error(error)
  defp public_config_error(%{kind: kind}), do: %{kind: kind}
  defp public_config_error(_error), do: %{kind: :invalid_json, position: 0}

  defp bounded_position(position, contents) when is_integer(position),
    do: min(max(position, 0), byte_size(contents))

  defp bounded_position(_position, _contents), do: 0

  defp invalid_loader(reason),
    do:
      invalid_config(:request_snapshot_loader, reason, "The request snapshot loader is invalid.")

  defp invalid_config(field, reason, message \\ "The Pixir configuration is invalid."),
    do: {:error, Pixir.Tool.error(:invalid_config, message, %{field: field, reason: reason})}

  defp effective_map(raw, warnings) do
    ignored = MapSet.new(warnings, & &1["field"])
    bash_timeout_ms = resolve_bash_timeout_ms(raw, ignored)
    # Keep the cap at least as large as the resolved default timeout. Per-run
    # overrides are bounded, but the default itself should remain executable.
    bash_timeout_max_ms = max(resolve_bash_timeout_max_ms(raw, ignored), bash_timeout_ms)

    %{
      "permission_default" => resolve_permission_default(raw, ignored),
      "reasoning" => %{"effort" => resolve_reasoning_effort(raw, ignored)},
      "text" => %{"verbosity" => resolve_text_verbosity(raw, ignored)},
      "bash_timeout_ms" => bash_timeout_ms,
      "bash_timeout_max_ms" => bash_timeout_max_ms,
      "host_commands" => %{
        "max_concurrent" => resolve_host_command_max_concurrent(raw, ignored),
        "queue_limit" => resolve_host_command_queue_limit(raw, ignored),
        "queue_timeout_ms" => resolve_host_command_queue_timeout_ms(raw, ignored)
      },
      "max_retries" => resolve_max_retries(raw, ignored),
      "stream_idle_timeout_ms" => resolve_stream_idle_timeout_ms(raw, ignored),
      "web_search" => resolve_web_search(raw, ignored),
      "compaction" => %{
        "tail_events" => resolve_tail_events(raw, ignored),
        "model_assisted" => resolve_model_assisted(raw, ignored)
      },
      "model" => resolve_model(raw),
      "models" => resolve_models(raw, "models", ignored),
      "anthropic_models" => resolve_models(raw, "anthropic_models", ignored),
      "models_refreshed_at" => resolve_models_refreshed_at(raw),
      "context_windows" => resolve_context_windows(raw, ignored)
    }
  end

  defp resolve_permission_default(raw, ignored) do
    app =
      case Application.get_env(:pixir, :permission_default) do
        mode when mode in [:auto, :ask, :read_only] -> Atom.to_string(mode)
        "auto" -> "auto"
        "ask" -> "ask"
        "read_only" -> "read_only"
        "read-only" -> "read_only"
        _ -> nil
      end

    cond do
      app ->
        app

      MapSet.member?(ignored, "permission_default") ->
        "auto"

      true ->
        case normalize_permission_mode(Map.get(raw, "permission_default")) do
          {:ok, mode} -> mode
          _ -> "auto"
        end
    end
  end

  defp resolve_reasoning_effort(raw, ignored) do
    app = normalize_reasoning_effort(Application.get_env(:pixir, :reasoning_effort))

    cond do
      app ->
        app

      MapSet.member?(ignored, "reasoning.effort") ->
        nil

      true ->
        raw
        |> nested_string("reasoning", "effort")
        |> normalize_reasoning_effort()
    end
  end

  defp resolve_text_verbosity(raw, ignored) do
    app = normalize_text_verbosity(Application.get_env(:pixir, :text_verbosity))

    cond do
      app ->
        app

      MapSet.member?(ignored, "text.verbosity") ->
        nil

      true ->
        raw
        |> nested_string("text", "verbosity")
        |> normalize_text_verbosity()
    end
  end

  defp resolve_bash_timeout_ms(raw, ignored) do
    resolve_positive_int(
      Application.get_env(:pixir, :bash_timeout_ms),
      Map.get(raw, "bash_timeout_ms"),
      @default_bash_timeout_ms,
      MapSet.member?(ignored, "bash_timeout_ms")
    )
  end

  defp resolve_bash_timeout_max_ms(raw, ignored) do
    resolve_positive_int(
      Application.get_env(:pixir, :bash_timeout_max_ms),
      Map.get(raw, "bash_timeout_max_ms"),
      @default_bash_timeout_max_ms,
      MapSet.member?(ignored, "bash_timeout_max_ms")
    )
  end

  defp resolve_host_command_max_concurrent(raw, ignored) do
    resolve_positive_int(
      host_commands_app_value(:max_concurrent),
      host_commands_raw_value(raw, "max_concurrent"),
      @default_host_command_max_concurrent,
      MapSet.member?(ignored, "host_commands") ||
        MapSet.member?(ignored, "host_commands.max_concurrent")
    )
  end

  defp resolve_host_command_queue_limit(raw, ignored) do
    resolve_non_negative_int(
      host_commands_app_value(:queue_limit),
      host_commands_raw_value(raw, "queue_limit"),
      @default_host_command_queue_limit,
      MapSet.member?(ignored, "host_commands") ||
        MapSet.member?(ignored, "host_commands.queue_limit")
    )
  end

  defp resolve_host_command_queue_timeout_ms(raw, ignored) do
    resolve_non_negative_int(
      host_commands_app_value(:queue_timeout_ms),
      host_commands_raw_value(raw, "queue_timeout_ms"),
      @default_host_command_queue_timeout_ms,
      MapSet.member?(ignored, "host_commands") ||
        MapSet.member?(ignored, "host_commands.queue_timeout_ms")
    )
  end

  defp resolve_max_retries(raw, ignored) do
    resolve_non_negative_int(
      Application.get_env(:pixir, :max_retries),
      Map.get(raw, "max_retries"),
      @default_max_retries,
      MapSet.member?(ignored, "max_retries")
    )
  end

  defp resolve_stream_idle_timeout_ms(raw, ignored) do
    resolve_non_negative_int(
      Application.get_env(:pixir, :stream_idle_timeout_ms),
      Map.get(raw, "stream_idle_timeout_ms"),
      @default_stream_idle_timeout_ms,
      MapSet.member?(ignored, "stream_idle_timeout_ms")
    )
  end

  defp resolve_web_search(raw, ignored) when is_struct(ignored, MapSet) do
    app = Application.get_env(:pixir, :web_search)

    cond do
      not is_nil(app) -> normalize_web_search_config(app)
      MapSet.member?(ignored, "web_search") -> nil
      true -> normalize_web_search_config(Map.get(raw, "web_search"))
    end
  end

  defp normalize_web_search_config(nil), do: nil

  defp normalize_web_search_config(value) do
    case web_search_config_status(value) do
      {:ok, normalized} -> normalized
      :invalid -> nil
    end
  end

  # A validated-but-disabled config and a rejected config both normalize to nil;
  # the status form keeps them distinguishable so warnings only name real errors.
  # nil never reaches here: both call sites filter it before dispatching.
  defp web_search_config_status(false), do: {:ok, nil}
  defp web_search_config_status(true), do: {:ok, %{"enabled" => true}}

  defp web_search_config_status(value) when is_map(value) and not is_struct(value) do
    normalize_web_search_status(value)
  end

  defp web_search_config_status(value) when is_list(value) do
    normalize_web_search_status(value)
  end

  defp web_search_config_status(_value), do: :invalid

  defp normalize_web_search_status(value) do
    with {:ok, normalized} <- normalize_string_key_map(value),
         true <- json_safe_config_term?(normalized),
         :ok <- reject_web_search_config_fields(normalized),
         {:ok, _tool} <- HostedTools.web_search(normalized) do
      if Map.get(normalized, "enabled") == false, do: {:ok, nil}, else: {:ok, normalized}
    else
      _ -> :invalid
    end
  end

  defp json_safe_config_term?(value)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: true

  defp json_safe_config_term?(value) when is_binary(value), do: String.valid?(value)

  defp json_safe_config_term?(value) when is_list(value) do
    proper_list?(value) and Enum.all?(value, &json_safe_config_term?/1)
  end

  defp json_safe_config_term?(value) when is_struct(value), do: false

  defp json_safe_config_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_safe_config_term?(nested)
    end)
  end

  defp json_safe_config_term?(_value), do: false

  defp reject_web_search_config_fields(config) do
    allowed = HostedTools.web_search_config_fields()
    unsupported = config |> Map.keys() |> Enum.reject(&(&1 in allowed))

    if unsupported == [], do: :ok, else: {:error, :unsupported_web_search_config_fields}
  end

  defp normalize_string_key_map(value) when is_map(value) and not is_struct(value) do
    normalize_config_pairs(Map.to_list(value))
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  # Non-pair list elements would raise FunctionClauseError inside Map.new/2
  # before the rescue could run; reject them up front so a malformed
  # config.json array cannot crash Config.load/1.
  defp normalize_string_key_map(value) when is_list(value) do
    if proper_list?(value) do
      normalize_config_pairs(value)
    else
      {:error, :invalid_key}
    end
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  defp normalize_config_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} ->
        normalized_key = normalize_config_key(key)

        if Map.has_key?(acc, normalized_key) do
          {:halt, {:error, :invalid_key}}
        else
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_key}}
    end)
  end

  defp normalize_config_key(key) when is_binary(key), do: key
  defp normalize_config_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_config_key(_key), do: raise(ArgumentError, "invalid config key")

  defp resolve_tail_events(raw, ignored) do
    value =
      case Map.get(raw, "compaction") do
        compaction when is_map(compaction) and not is_struct(compaction) ->
          normalized_config_value(compaction, "tail_events")

        _ ->
          nil
      end

    resolve_positive_int(
      Application.get_env(:pixir, :compaction_tail_events),
      value,
      @default_tail_events,
      MapSet.member?(ignored, "compaction") ||
        MapSet.member?(ignored, "compaction.tail_events")
    )
  end

  defp resolve_model_assisted(raw, ignored) do
    app = Application.get_env(:pixir, :compaction_model_assisted)

    cond do
      is_boolean(app) ->
        app

      MapSet.member?(ignored, "compaction") ||
          MapSet.member?(ignored, "compaction.model_assisted") ->
        false

      true ->
        case Map.get(raw, "compaction") do
          compaction when is_map(compaction) and not is_struct(compaction) ->
            case normalized_config_value(compaction, "model_assisted") do
              value when is_boolean(value) -> value
              _ -> false
            end

          _ ->
            false
        end
    end
  end

  defp resolve_model(raw), do: elem(resolve_model_with_source(raw), 0)

  defp resolve_model_with_source(raw) do
    app_model = normalize_model(Application.get_env(:pixir, :model))
    env_model = normalize_model(System.get_env("PIXIR_MODEL"))
    file_model = normalize_model(Map.get(raw, "model"))

    cond do
      app_model -> {app_model, :application}
      env_model -> {env_model, :env}
      file_model -> {file_model, :file}
      true -> {@default_model, :default}
    end
  end

  defp resolve_models(raw, field, ignored) do
    if MapSet.member?(ignored, field) do
      nil
    else
      case Map.get(raw, field) do
        list when is_list(list) ->
          slugs =
            if proper_list?(list),
              do: Enum.filter(list, &(is_binary(&1) and String.valid?(&1))),
              else: []

          if slugs == [], do: nil, else: slugs

        nil ->
          nil

        _ ->
          nil
      end
    end
  end

  defp resolve_models_refreshed_at(%{"models_refreshed_at" => stamp}) when is_binary(stamp) do
    if String.valid?(stamp), do: stamp, else: nil
  end

  defp resolve_models_refreshed_at(_raw), do: nil

  defp resolve_context_windows(raw, ignored) do
    if MapSet.member?(ignored, "context_windows") do
      %{}
    else
      case Map.get(raw, "context_windows") do
        windows when is_map(windows) and not is_struct(windows) ->
          windows
          |> Enum.filter(fn {model, tokens} ->
            is_binary(model) and String.valid?(model) and is_integer(tokens) and tokens > 0
          end)
          |> Map.new()

        _ ->
          %{}
      end
    end
  end

  defp warnings(raw) do
    []
    |> maybe_warn_permission_default(raw)
    |> maybe_warn_reasoning_effort(raw)
    |> maybe_warn_text_verbosity(raw)
    |> maybe_warn_positive_int("bash_timeout_ms", Map.get(raw, "bash_timeout_ms"))
    |> maybe_warn_positive_int("bash_timeout_max_ms", Map.get(raw, "bash_timeout_max_ms"))
    |> maybe_warn_bash_timeout_cap(raw)
    |> maybe_warn_host_commands(raw)
    |> maybe_warn_non_negative_int("max_retries", Map.get(raw, "max_retries"))
    |> maybe_warn_non_negative_int(
      "stream_idle_timeout_ms",
      Map.get(raw, "stream_idle_timeout_ms")
    )
    |> maybe_warn_web_search(raw)
    |> maybe_warn_tail_events(raw)
    |> maybe_warn_model_assisted(raw)
    |> maybe_warn_model(raw)
    |> maybe_warn_models(raw, "models")
    |> maybe_warn_models(raw, "anthropic_models")
    |> maybe_warn_models_refreshed_at(raw)
    |> maybe_warn_context_windows(raw)
  end

  defp maybe_warn_permission_default(warnings, raw) do
    case Map.get(raw, "permission_default") do
      nil ->
        warnings

      value ->
        case normalize_permission_mode(value) do
          {:ok, _} -> warnings
          {:error, message} -> [warning("permission_default", message) | warnings]
        end
    end
  end

  defp maybe_warn_reasoning_effort(warnings, raw) do
    maybe_warn_nested_enum(
      warnings,
      raw,
      "reasoning",
      "effort",
      "reasoning.effort",
      &normalize_reasoning_effort/1
    )
  end

  defp maybe_warn_text_verbosity(warnings, raw) do
    maybe_warn_nested_enum(
      warnings,
      raw,
      "text",
      "verbosity",
      "text.verbosity",
      &normalize_text_verbosity/1
    )
  end

  defp maybe_warn_nested_enum(warnings, raw, parent, child, field, normalize) do
    case Map.get(raw, parent) do
      nil ->
        warnings

      nested when is_map(nested) and not is_struct(nested) ->
        case fetch_normalized_config_value(nested, child) do
          :error ->
            warnings

          {:ok, value} when is_binary(value) ->
            if String.valid?(value) and normalize.(String.trim(value)),
              do: warnings,
              else: [warning(field, "invalid value; ignoring") | warnings]

          {:ok, _value} ->
            [warning(field, "invalid value; ignoring") | warnings]

          :collision ->
            [warning(field, "invalid value; ignoring") | warnings]
        end

      _invalid_parent ->
        [warning(field, "invalid value; ignoring") | warnings]
    end
  end

  defp maybe_warn_web_search(warnings, raw) do
    case Map.get(raw, "web_search") do
      nil ->
        warnings

      value ->
        case web_search_config_status(value) do
          :invalid ->
            [warning("web_search", "invalid value; ignoring") | warnings]

          {:ok, _normalized} ->
            warnings
        end
    end
  end

  defp maybe_warn_host_commands(warnings, raw) do
    case Map.get(raw, "host_commands") do
      nil ->
        warnings

      host_commands when is_map(host_commands) and not is_struct(host_commands) ->
        warnings
        |> maybe_warn_positive_int(
          "host_commands.max_concurrent",
          normalized_config_value(host_commands, "max_concurrent")
        )
        |> maybe_warn_non_negative_int(
          "host_commands.queue_limit",
          normalized_config_value(host_commands, "queue_limit")
        )
        |> maybe_warn_non_negative_int(
          "host_commands.queue_timeout_ms",
          normalized_config_value(host_commands, "queue_timeout_ms")
        )

      _ ->
        [warning("host_commands", "must be an object; ignoring") | warnings]
    end
  end

  defp maybe_warn_positive_int(warnings, field, value) do
    cond do
      is_nil(value) -> warnings
      is_integer(value) and value > 0 -> warnings
      true -> [warning(field, "must be a positive integer; ignoring") | warnings]
    end
  end

  defp maybe_warn_non_negative_int(warnings, field, value) do
    cond do
      is_nil(value) -> warnings
      is_integer(value) and value >= 0 -> warnings
      true -> [warning(field, "must be a non-negative integer; ignoring") | warnings]
    end
  end

  defp maybe_warn_bash_timeout_cap(warnings, raw) do
    timeout = Map.get(raw, "bash_timeout_ms")
    max_timeout = Map.get(raw, "bash_timeout_max_ms")

    if is_integer(timeout) and timeout > 0 and is_integer(max_timeout) and max_timeout > 0 and
         max_timeout < timeout do
      [
        warning(
          "bash_timeout_max_ms.min",
          "is lower than bash_timeout_ms; raising effective cap to bash_timeout_ms"
        )
        | warnings
      ]
    else
      warnings
    end
  end

  defp maybe_warn_tail_events(warnings, raw) do
    case Map.get(raw, "compaction") do
      compaction when is_map(compaction) and not is_struct(compaction) ->
        case fetch_normalized_config_value(compaction, "tail_events") do
          {:ok, value} -> maybe_warn_positive_int(warnings, "compaction.tail_events", value)
          :error -> warnings
          :collision -> [warning("compaction.tail_events", "invalid value; ignoring") | warnings]
        end

      nil ->
        warnings

      _ ->
        [warning("compaction", "must be an object; ignoring tail_events") | warnings]
    end
  end

  defp maybe_warn_model_assisted(warnings, raw) do
    case Map.get(raw, "compaction") do
      compaction when is_map(compaction) and not is_struct(compaction) ->
        case fetch_normalized_config_value(compaction, "model_assisted") do
          {:ok, value} when is_boolean(value) ->
            warnings

          {:ok, _value} ->
            [warning("compaction.model_assisted", "must be a boolean; ignoring") | warnings]

          :error ->
            warnings

          :collision ->
            [warning("compaction.model_assisted", "must be a boolean; ignoring") | warnings]
        end

      nil ->
        warnings

      _invalid_parent ->
        [warning("compaction", "must be an object; ignoring model_assisted") | warnings]
    end
  end

  defp maybe_warn_model(warnings, raw) do
    case Map.fetch(raw, "model") do
      :error ->
        warnings

      {:ok, model} when is_binary(model) ->
        if normalize_model(model),
          do: warnings,
          else: [warning("model", "must be a non-empty string; ignoring") | warnings]

      {:ok, _other} ->
        [warning("model", "must be a string; ignoring") | warnings]
    end
  end

  defp maybe_warn_models(warnings, raw, field) do
    case Map.get(raw, field) do
      nil ->
        warnings

      list when is_list(list) ->
        if valid_models_list?(list) do
          warnings
        else
          [warning(field, "must be an array of model id strings; ignoring") | warnings]
        end

      _ ->
        [warning(field, "must be an array of model id strings; ignoring") | warnings]
    end
  end

  defp maybe_warn_models_refreshed_at(warnings, raw) do
    case Map.get(raw, "models_refreshed_at") do
      nil ->
        warnings

      stamp when is_binary(stamp) ->
        if String.valid?(stamp),
          do: warnings,
          else: [warning("models_refreshed_at", "must be a UTF-8 string; ignoring") | warnings]

      _other ->
        [warning("models_refreshed_at", "must be a UTF-8 string; ignoring") | warnings]
    end
  end

  defp maybe_warn_context_windows(warnings, raw) do
    case Map.get(raw, "context_windows") do
      nil ->
        warnings

      windows when is_map(windows) and not is_struct(windows) ->
        invalid =
          Enum.any?(windows, fn
            {model, tokens}
            when is_binary(model) and is_integer(tokens) and tokens > 0 ->
              not String.valid?(model)

            _ ->
              true
          end)

        if invalid do
          [
            warning(
              "context_windows",
              "invalid entries ignored; expected model => positive integer"
            )
            | warnings
          ]
        else
          warnings
        end

      _ ->
        [warning("context_windows", "must be an object; ignoring") | warnings]
    end
  end

  defp warning(field, message), do: %{"field" => field, "message" => message}

  defp nested_string(%{} = raw, key, nested_key) do
    case Map.get(raw, key) do
      nested when is_map(nested) and not is_struct(nested) ->
        case normalized_config_value(nested, nested_key) do
          value when is_binary(value) -> if String.valid?(value), do: String.trim(value)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp nested_string(_raw, _key, _nested_key), do: nil

  defp host_commands_raw_value(%{"host_commands" => host_commands}, key)
       when is_map(host_commands) and not is_struct(host_commands),
       do: normalized_config_value(host_commands, key)

  defp host_commands_raw_value(_raw, _key), do: nil

  defp host_commands_app_value(field) do
    case Application.get_env(:pixir, :host_commands) do
      nil ->
        nil

      config when is_list(config) ->
        if proper_keyword_list?(config), do: Keyword.get(config, field), else: nil

      config when is_map(config) and not is_struct(config) ->
        normalized_config_value(config, Atom.to_string(field))

      _ ->
        nil
    end
  end

  defp normalize_permission_mode(mode) when mode in [:auto, :ask, :read_only],
    do: {:ok, Atom.to_string(mode)}

  defp normalize_permission_mode("auto"), do: {:ok, "auto"}
  defp normalize_permission_mode("ask"), do: {:ok, "ask"}
  defp normalize_permission_mode("read_only"), do: {:ok, "read_only"}
  defp normalize_permission_mode("read-only"), do: {:ok, "read_only"}

  defp normalize_permission_mode(_value),
    do: {:error, "invalid value; expected auto, ask, or read_only"}

  defp normalize_reasoning_effort(nil), do: nil

  defp normalize_reasoning_effort(effort) when is_atom(effort) and not is_nil(effort),
    do: normalize_reasoning_effort(Atom.to_string(effort))

  defp normalize_reasoning_effort(effort) when is_binary(effort) do
    trimmed = String.trim(effort)
    if trimmed in @valid_reasoning_efforts, do: trimmed, else: nil
  end

  defp normalize_reasoning_effort(_), do: nil

  defp normalize_text_verbosity(nil), do: nil

  defp normalize_text_verbosity(verbosity) when is_atom(verbosity) and not is_nil(verbosity),
    do: normalize_text_verbosity(Atom.to_string(verbosity))

  defp normalize_text_verbosity(verbosity) when is_binary(verbosity) do
    trimmed = String.trim(verbosity)
    if trimmed in @valid_text_verbosities, do: trimmed, else: nil
  end

  defp normalize_text_verbosity(_), do: nil

  defp resolve_positive_int(app, raw, default, ignored?) do
    cond do
      is_integer(app) and app > 0 ->
        app

      ignored? ->
        default

      is_integer(raw) and raw > 0 ->
        raw

      true ->
        default
    end
  end

  defp resolve_non_negative_int(app, raw, default, ignored?) do
    cond do
      is_integer(app) and app >= 0 ->
        app

      ignored? ->
        default

      is_integer(raw) and raw >= 0 ->
        raw

      true ->
        default
    end
  end

  defp valid_models_list?(list) do
    proper_list?(list) and Enum.all?(list, &(is_binary(&1) and String.valid?(&1)))
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp proper_keyword_list?(list) do
    proper_list?(list) and Enum.all?(list, &match?({key, _value} when is_atom(key), &1))
  end

  defp normalized_config_value(map, key) do
    case fetch_normalized_config_value(map, key) do
      {:ok, value} -> value
      :error -> nil
      :collision -> :invalid_normalized_key_collision
    end
  end

  defp fetch_normalized_config_value(map, key) do
    atom_key = existing_config_atom(key)
    string_value = Map.fetch(map, key)
    atom_value = if atom_key, do: Map.fetch(map, atom_key), else: :error

    case {string_value, atom_value} do
      {{:ok, _string}, {:ok, _atom}} -> :collision
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
    end
  end

  defp existing_config_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp permission_atom("auto"), do: :auto
  defp permission_atom("ask"), do: :ask
  defp permission_atom("read_only"), do: :read_only
  defp permission_atom(_), do: :auto
end
