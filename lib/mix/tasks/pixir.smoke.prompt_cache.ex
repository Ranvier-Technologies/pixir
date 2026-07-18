defmodule Mix.Tasks.Pixir.Smoke.PromptCache do
  @shortdoc "Real-network smoke for OpenAI prompt-cache accounting"

  @moduledoc """
  Probes whether the Provider reports prompt-cache usage for comparable long-prefix
  requests.

  This is a manual, opt-in, real-network smoke. It does not prove every future Session
  will hit cache; it verifies the current backend/model path returns usage accounting
  and reports whether `cached_tokens` were observed.

  Usage:

      mix pixir.smoke.prompt_cache --dry-run --json
      mix pixir.smoke.prompt_cache --json
      mix pixir.smoke.prompt_cache --model gpt-5.5 --reasoning-effort low --json
      mix pixir.smoke.prompt_cache --prompt-cache-retention 24h --json
      mix pixir.smoke.prompt_cache --help

  Options:

    * `--model MODEL` - Provider model. Default: `gpt-5.5`.
    * `--reasoning-effort EFFORT` - one of `low`, `medium`, `high`, `xhigh`.
      Default: `low`.
    * `--cache-key KEY` - prompt-cache key to reuse across the two requests.
    * `--prompt-cache-retention VALUE` - explicit retention request, one of `24h` or
      `in_memory`. On the ChatGPT/Codex backend Pixir's Provider gates this field until
      support is proven.
    * `--dry-run` - validate and print the planned probe without auth or network.
    * `--json` - print machine-readable evidence or errors.
    * `--help` - print this help and exit.
  """

  use Mix.Task

  alias Pixir.{Event, Provider, Tool}
  alias Pixir.Provider.Cache

  @command "mix pixir.smoke.prompt_cache"
  @schema_version 1
  @default_model "gpt-5.5"
  @default_reasoning_effort "low"
  @valid_reasoning_efforts ~w(low medium high xhigh)
  @valid_retention ~w(24h in_memory)
  @switches [
    model: :string,
    reasoning_effort: :string,
    cache_key: :string,
    prompt_cache_retention: :string,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]
  @aliases [h: :help]

  @impl Mix.Task
  @spec run([String.t()]) :: no_return() | :ok
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :help, false) do
      print_help(json?)
      :ok
    else
      run_with_options(opts, invalid, json?)
    end
  end

  defp run_with_options(opts, invalid, json?) do
    if invalid != [] do
      fail!(
        :invalid_options,
        "Unsupported command-line option(s).",
        %{"invalid" => inspect(invalid)},
        ["Run `#{@command} --help` to see supported options."],
        json?
      )
    end

    config = parse_config!(opts, json?)

    if config.dry_run? do
      print_success(dry_run_payload(config), json?)
      :ok
    else
      Mix.Task.run("app.start")
      run_probe!(config, json?)
      :ok
    end
  end

  defp parse_config!(opts, json?) do
    model = Keyword.get(opts, :model, @default_model)

    reasoning_effort =
      opts
      |> Keyword.get(:reasoning_effort, @default_reasoning_effort)
      |> String.trim()

    unless reasoning_effort in @valid_reasoning_efforts do
      fail!(
        :invalid_reasoning_effort,
        "--reasoning-effort must be one of: #{Enum.join(@valid_reasoning_efforts, ", ")}.",
        %{"value" => reasoning_effort, "allowed" => @valid_reasoning_efforts},
        ["Use `--reasoning-effort low` for the cheapest representative probe."],
        json?
      )
    end

    retention = Keyword.get(opts, :prompt_cache_retention)

    if retention && retention not in @valid_retention do
      fail!(
        :invalid_prompt_cache_retention,
        "--prompt-cache-retention must be one of: #{Enum.join(@valid_retention, ", ")}.",
        %{"value" => retention, "allowed" => @valid_retention},
        ["Use `--prompt-cache-retention 24h` only when the backend path has accepted it."],
        json?
      )
    end

    cache_key =
      Keyword.get(opts, :cache_key) ||
        case Cache.stable_hash(["prompt-cache-smoke-v1", model, reasoning_effort]) do
          {:ok, hash} ->
            "px-smoke:" <> hash

          {:error, reason} ->
            fail!(
              :cache_key_hash_failed,
              "Could not build the default prompt-cache key.",
              %{"reason" => Exception.message(reason)},
              ["Pass an explicit stable key with `--cache-key`."],
              json?
            )
        end

    %{
      model: model,
      reasoning_effort: reasoning_effort,
      cache_key: cache_key,
      prompt_cache_retention: retention,
      dry_run?: Keyword.get(opts, :dry_run, false)
    }
  end

  defp print_help(true) do
    print_json(%{
      "ok" => true,
      "schema_version" => @schema_version,
      "command" => @command,
      "network" => true,
      "options" => [
        "--model MODEL",
        "--reasoning-effort EFFORT",
        "--cache-key KEY",
        "--prompt-cache-retention 24h|in_memory",
        "--dry-run",
        "--json",
        "--help"
      ],
      "dry_run_guarantees" => [
        "does_not_require_auth",
        "does_not_call_provider",
        "does_not_write_files"
      ],
      "proof_states" => ["usage_reported", "cached_tokens_observed_or_explained"],
      "next_steps" => [
        "Run `#{@command} --dry-run --json` first.",
        "Run `#{@command} --json` when a small real-network probe is acceptable.",
        "Treat cached_tokens=0 as evidence, not failure, if the prompt is below threshold or routing misses."
      ]
    })
  end

  defp print_help(_json?) do
    Mix.shell().info(@moduledoc)
  end

  defp dry_run_payload(config) do
    requests = probe_requests(config)

    %{
      "ok" => true,
      "schema_version" => @schema_version,
      "mode" => "dry_run",
      "command" => @command,
      "network" => false,
      "model" => config.model,
      "reasoning_effort" => config.reasoning_effort,
      "prompt_cache_key" => config.cache_key,
      "prompt_cache_retention" => config.prompt_cache_retention,
      "estimated_real_network_requests" => length(requests),
      "stable_prefix_words" => stable_prefix() |> String.split(~r/\s+/, trim: true) |> length(),
      "would_call" => Enum.map(requests, & &1["label"]),
      "would_send" => %{
        "prompt_cache_key" => true,
        "prompt_cache_retention" => not is_nil(config.prompt_cache_retention),
        "store" => false,
        "stream" => true
      },
      "next_steps" => [
        "Run `#{@command} --json` to execute the live probe.",
        "Use `--model gpt-5.5 --reasoning-effort low` for representative low-cost checks."
      ]
    }
  end

  defp run_probe!(config, json?) do
    runs =
      config
      |> probe_requests()
      |> Enum.map(&run_request!(&1, config, json?))

    payload = %{
      "ok" => true,
      "schema_version" => @schema_version,
      "mode" => "run",
      "command" => @command,
      "network" => true,
      "model" => config.model,
      "reasoning_effort" => config.reasoning_effort,
      "prompt_cache_key" => config.cache_key,
      "prompt_cache_retention" => config.prompt_cache_retention,
      "runs" => runs,
      "cache_hit_observed" => Enum.any?(runs, &(cache_read_tokens(&1["usage_summary"]) > 0)),
      "caveats" => [
        "cached_tokens is the evidence; latency is not used as proof",
        "the first comparable request may warm cache and still report zero cached tokens",
        "routing can miss even when the prefix and cache key are stable"
      ]
    }

    print_success(payload, json?)
  end

  defp run_request!(request, config, json?) do
    started = System.monotonic_time(:millisecond)

    provider_request = %{
      model: config.model,
      system_prompt:
        "You are a prompt-cache smoke probe. Reply with exactly the requested token.",
      history: [Event.user_message("prompt-cache-smoke", request["prompt"])],
      prompt_cache_key: config.cache_key,
      prompt_cache_retention: config.prompt_cache_retention
    }

    opts = [reasoning_effort: config.reasoning_effort, on_delta: fn _ -> :ok end, max_retries: 0]

    case Provider.stream(provider_request, opts) do
      {:ok, result} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started

        %{
          "label" => request["label"],
          "elapsed_ms" => elapsed_ms,
          "text" => Tool.truncate(result.text, 1_000),
          "usage_available" => not is_nil(result.usage),
          "usage_summary" => stringify(result.usage_summary)
        }

      {:error, %{error: error}} ->
        fail!(
          error.kind,
          error.message,
          stringify(error.details || %{}),
          [
            "Verify credentials with `./pixir doctor --json`.",
            "Retry with `#{@command} --dry-run --json` to inspect the planned payload.",
            "If this is a usage limit, wait for reset or use a cheaper model/effort."
          ],
          json?
        )
    end
  end

  defp probe_requests(config) do
    prefix = stable_prefix()

    [
      %{
        "label" => "warmup",
        "prompt" => prefix <> "\n\nVariant: warmup. Reply exactly: CACHE_WARMUP"
      },
      %{
        "label" => "candidate_hit",
        "prompt" => prefix <> "\n\nVariant: candidate-hit. Reply exactly: CACHE_HIT"
      }
    ]
    |> Enum.map(&Map.put(&1, "cache_key", config.cache_key))
  end

  defp stable_prefix do
    paragraph = """
    Pixir prompt-cache smoke stable prefix. This text is intentionally synthetic,
    non-secret, and repeated so the Provider sees a long shared prefix before the
    final variant instruction. It describes no local files, no people, no paths, and
    no credentials. The useful measurement is returned Provider usage, especially
    cached_tokens inside input token details.
    """

    1..34
    |> Enum.map(fn i -> "Block #{String.pad_leading(to_string(i), 2, "0")}. #{paragraph}" end)
    |> Enum.join("\n")
  end

  defp print_success(payload, true), do: print_json(payload)
  defp print_success(payload, _json?), do: Mix.shell().info(human_summary(payload))

  defp human_summary(%{"mode" => "dry_run"} = payload) do
    """
    #{payload["command"]} dry-run
    model: #{payload["model"]}
    reasoning_effort: #{payload["reasoning_effort"]}
    requests: #{payload["estimated_real_network_requests"]}
    prompt_cache_key: #{payload["prompt_cache_key"]}
    """
    |> String.trim()
  end

  defp human_summary(%{"mode" => "run"} = payload) do
    hit? = if payload["cache_hit_observed"], do: "yes", else: "no"

    """
    #{payload["command"]} completed
    model: #{payload["model"]}
    cache hit observed: #{hit?}
    """
    |> String.trim()
  end

  defp print_json(payload), do: Mix.shell().info(Jason.encode!(payload, pretty: true))

  defp fail!(kind, message, details, next_steps, true) do
    print_json(%{
      "ok" => false,
      "schema_version" => @schema_version,
      "command" => @command,
      "error" => %{
        "kind" => to_string(kind),
        "message" => message,
        "details" => details
      },
      "next_steps" => next_steps
    })

    exit({:shutdown, 1})
  end

  defp fail!(kind, message, _details, next_steps, _json?) do
    Mix.shell().error("#{kind}: #{message}")
    Enum.each(next_steps, &Mix.shell().error("next: #{&1}"))
    exit({:shutdown, 1})
  end

  defp cache_read_tokens(%{"cache" => %{"read_tokens" => value}}) when is_integer(value),
    do: value

  defp cache_read_tokens(%{"cached_tokens" => value}) when is_integer(value), do: value
  defp cache_read_tokens(_summary), do: 0

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
