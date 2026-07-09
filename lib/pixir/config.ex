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

    case read_raw(path, opts) do
      {:ok, raw} ->
        warnings = warnings(raw)
        effective = effective_map(raw, warnings)

        %{
          "path" => Path.expand(path),
          "present" => true,
          "effective" => effective,
          "warnings" => warnings
        }

      {:missing, _} ->
        %{
          "path" => Path.expand(path),
          "present" => false,
          "effective" => effective_map(%{}, []),
          "warnings" => []
        }

      {:error, reason} ->
        %{
          "path" => Path.expand(path),
          "present" => true,
          "error" => inspect(reason),
          "effective" => effective_map(%{}, []),
          "warnings" => []
        }
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

  @doc "Model slug from config.json only (no env/app precedence)."
  @spec file_model(keyword()) :: String.t() | nil
  def file_model(opts \\ []) do
    with %{"present" => true} <- load(opts),
         model when is_binary(model) <- get_in(load(opts), ["effective", "model"]) do
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

  defp read_raw(path, opts) do
    case Keyword.get(opts, :raw_config) do
      raw when is_map(raw) ->
        {:ok, raw}

      _ ->
        case File.read(path) do
          {:ok, contents} ->
            case Jason.decode(contents) do
              {:ok, raw} when is_map(raw) -> {:ok, raw}
              {:ok, _} -> {:error, :not_object}
              {:error, reason} -> {:error, reason}
            end

          {:error, :enoent} ->
            {:missing, path}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

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
      "models" => resolve_models(raw, ignored),
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

  defp web_search_config_status(value) when is_map(value) or is_list(value) do
    with {:ok, normalized} <- normalize_string_key_map(value),
         :ok <- reject_web_search_config_fields(normalized),
         {:ok, _tool} <- HostedTools.web_search(normalized) do
      if Map.get(normalized, "enabled") == false, do: {:ok, nil}, else: {:ok, normalized}
    else
      _ -> :invalid
    end
  end

  defp web_search_config_status(_value), do: :invalid

  defp reject_web_search_config_fields(config) do
    allowed = HostedTools.web_search_config_fields()
    unsupported = config |> Map.keys() |> Enum.reject(&(&1 in allowed))

    if unsupported == [], do: :ok, else: {:error, :unsupported_web_search_config_fields}
  end

  defp normalize_string_key_map(value) when is_map(value) do
    {:ok, Map.new(value, fn {key, val} -> {normalize_config_key(key), val} end)}
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  # Non-pair list elements would raise FunctionClauseError inside Map.new/2
  # before the rescue could run; reject them up front so a malformed
  # config.json array cannot crash Config.load/1.
  defp normalize_string_key_map(value) when is_list(value) do
    if Enum.all?(value, &match?({_key, _val}, &1)) do
      {:ok, Map.new(value, fn {key, val} -> {normalize_config_key(key), val} end)}
    else
      {:error, :invalid_key}
    end
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  defp normalize_config_key(key) when is_binary(key), do: key
  defp normalize_config_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_config_key(key), do: raise(ArgumentError, "invalid config key #{inspect(key)}")

  defp resolve_tail_events(raw, ignored) do
    value =
      case Map.get(raw, "compaction") do
        %{"tail_events" => tail} -> tail
        _ -> nil
      end

    resolve_positive_int(
      Application.get_env(:pixir, :compaction_tail_events),
      value,
      @default_tail_events,
      MapSet.member?(ignored, "compaction.tail_events")
    )
  end

  defp resolve_model_assisted(raw, ignored) do
    app = Application.get_env(:pixir, :compaction_model_assisted)

    cond do
      is_boolean(app) ->
        app

      MapSet.member?(ignored, "compaction.model_assisted") ->
        false

      true ->
        case Map.get(raw, "compaction") do
          %{"model_assisted" => value} when is_boolean(value) -> value
          _ -> false
        end
    end
  end

  defp resolve_model(raw) do
    Application.get_env(:pixir, :model) || System.get_env("PIXIR_MODEL") ||
      case Map.get(raw, "model") do
        model when is_binary(model) -> model
        _ -> nil
      end || @default_model
  end

  defp resolve_models(raw, ignored) do
    if MapSet.member?(ignored, "models") do
      nil
    else
      case Map.get(raw, "models") do
        list when is_list(list) ->
          slugs = Enum.filter(list, &is_binary/1)
          if slugs == [], do: nil, else: slugs

        nil ->
          nil

        _ ->
          nil
      end
    end
  end

  defp resolve_context_windows(raw, ignored) do
    if MapSet.member?(ignored, "context_windows") do
      %{}
    else
      case Map.get(raw, "context_windows") do
        %{} = windows ->
          windows
          |> Enum.filter(fn {_model, tokens} -> is_integer(tokens) and tokens > 0 end)
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
    |> maybe_warn_models(raw)
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
    case nested_string(raw, "reasoning", "effort") do
      nil ->
        warnings

      value ->
        case normalize_reasoning_effort(value) do
          nil ->
            [warning("reasoning.effort", "invalid value #{inspect(value)}; ignoring") | warnings]

          _ ->
            warnings
        end
    end
  end

  defp maybe_warn_text_verbosity(warnings, raw) do
    case nested_string(raw, "text", "verbosity") do
      nil ->
        warnings

      value ->
        case normalize_text_verbosity(value) do
          nil ->
            [warning("text.verbosity", "invalid value #{inspect(value)}; ignoring") | warnings]

          _ ->
            warnings
        end
    end
  end

  defp maybe_warn_web_search(warnings, raw) do
    case Map.get(raw, "web_search") do
      nil ->
        warnings

      value ->
        case web_search_config_status(value) do
          :invalid ->
            [warning("web_search", "invalid value #{inspect(value)}; ignoring") | warnings]

          {:ok, _normalized} ->
            warnings
        end
    end
  end

  defp maybe_warn_host_commands(warnings, raw) do
    case Map.get(raw, "host_commands") do
      nil ->
        warnings

      %{} = host_commands ->
        warnings
        |> maybe_warn_positive_int(
          "host_commands.max_concurrent",
          Map.get(host_commands, "max_concurrent")
        )
        |> maybe_warn_non_negative_int(
          "host_commands.queue_limit",
          Map.get(host_commands, "queue_limit")
        )
        |> maybe_warn_non_negative_int(
          "host_commands.queue_timeout_ms",
          Map.get(host_commands, "queue_timeout_ms")
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
      %{"tail_events" => value} ->
        maybe_warn_positive_int(warnings, "compaction.tail_events", value)

      %{} ->
        warnings

      nil ->
        warnings

      _ ->
        [warning("compaction", "must be an object; ignoring tail_events") | warnings]
    end
  end

  defp maybe_warn_model_assisted(warnings, raw) do
    case Map.get(raw, "compaction") do
      %{"model_assisted" => value} when is_boolean(value) ->
        warnings

      %{"model_assisted" => _} ->
        [warning("compaction.model_assisted", "must be a boolean; ignoring") | warnings]

      _ ->
        warnings
    end
  end

  defp maybe_warn_model(warnings, raw) do
    if Map.has_key?(raw, "model") and not is_binary(raw["model"]) do
      [warning("model", "must be a string; ignoring") | warnings]
    else
      warnings
    end
  end

  defp maybe_warn_models(warnings, raw) do
    case Map.get(raw, "models") do
      nil ->
        warnings

      list when is_list(list) ->
        if valid_models_list?(list) do
          warnings
        else
          [warning("models", "must be an array of model id strings; ignoring") | warnings]
        end

      _ ->
        [warning("models", "must be an array of model id strings; ignoring") | warnings]
    end
  end

  defp maybe_warn_context_windows(warnings, raw) do
    case Map.get(raw, "context_windows") do
      nil ->
        warnings

      %{} = windows ->
        invalid =
          Enum.any?(windows, fn
            {_model, tokens} when is_integer(tokens) and tokens > 0 -> false
            _ -> true
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
      %{^nested_key => value} when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp nested_string(_raw, _key, _nested_key), do: nil

  defp host_commands_raw_value(%{"host_commands" => %{} = host_commands}, key),
    do: Map.get(host_commands, key)

  defp host_commands_raw_value(_raw, _key), do: nil

  defp host_commands_app_value(field) do
    case Application.get_env(:pixir, :host_commands) do
      nil -> nil
      config when is_list(config) -> Keyword.get(config, field)
      %{} = config -> Map.get(config, field) || Map.get(config, Atom.to_string(field))
      _ -> nil
    end
  end

  defp normalize_permission_mode(mode) when mode in [:auto, :ask, :read_only],
    do: {:ok, Atom.to_string(mode)}

  defp normalize_permission_mode("auto"), do: {:ok, "auto"}
  defp normalize_permission_mode("ask"), do: {:ok, "ask"}
  defp normalize_permission_mode("read_only"), do: {:ok, "read_only"}
  defp normalize_permission_mode("read-only"), do: {:ok, "read_only"}

  defp normalize_permission_mode(value),
    do: {:error, "invalid value #{inspect(value)}; expected auto, ask, or read_only"}

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

  defp valid_models_list?(list), do: Enum.all?(list, &is_binary/1)

  defp permission_atom("auto"), do: :auto
  defp permission_atom("ask"), do: :ask
  defp permission_atom("read_only"), do: :read_only
  defp permission_atom(_), do: :auto
end
