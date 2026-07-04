defmodule Mix.Tasks.Pixir.Smoke.WebSearch do
  @shortdoc "Opt-in real-network smoke for OpenAI hosted web search"

  @moduledoc """
  Probes Pixir's OpenAI Responses hosted `web_search` path.

  This is a manual, opt-in, real-network smoke. It verifies request shaping and whether
  the active backend/model emits Provider-hosted web search evidence. It does not use
  Pixir local browser automation and does not treat search output as Pixir's source of
  truth.

  Usage:

      mix pixir.smoke.web_search --dry-run --json
      mix pixir.smoke.web_search --json
      mix pixir.smoke.web_search --model gpt-5.5 --reasoning-effort low --json
      mix pixir.smoke.web_search --search-context-size low --json
      mix pixir.smoke.web_search --help

  Options:

    * `--model MODEL` - Provider model. Default: `gpt-5.5`.
    * `--reasoning-effort EFFORT` - one of `low`, `medium`, `high`, `xhigh`.
      Default: `low`.
    * `--search-context-size SIZE` - hosted web search context size: `low`, `medium`,
      or `high`. Default: `low`.
    * `--query TEXT` - search prompt. Default asks for OpenAI's web search docs.
    * `--dry-run` - validate and print the planned request shape without auth/network.
    * `--json` - print machine-readable evidence or errors.
    * `--help` - print this help and exit.
  """

  use Mix.Task

  alias Pixir.{Auth, Event, Provider, Tool}

  @command "mix pixir.smoke.web_search"
  @schema_version 1
  @default_model "gpt-5.5"
  @default_reasoning_effort "low"
  @default_search_context_size "low"
  @valid_reasoning_efforts ~w(low medium high xhigh)
  @valid_search_context_sizes ~w(low medium high)
  @default_query """
  Use OpenAI hosted web search to find the official OpenAI documentation page for
  Responses web search tools. Reply with WEB_SEARCH_SMOKE_OK, the page title, and one
  concise source URL.
  """

  @switches [
    model: :string,
    reasoning_effort: :string,
    search_context_size: :string,
    query: :string,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]
  @aliases [h: :help]

  @impl Mix.Task
  @spec run([String.t()]) :: no_return() | :ok
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :help, false) do
      print_help(json?)
      :ok
    else
      run_with_options(opts, argv, invalid, json?)
    end
  end

  defp run_with_options(opts, argv, invalid, json?) do
    if invalid != [] do
      fail!(
        :invalid_options,
        "Unsupported command-line option(s).",
        %{"invalid" => inspect(invalid)},
        ["Run `#{@command} --help` to see supported options."],
        json?
      )
    end

    if argv != [] do
      fail!(
        :unexpected_args,
        "Unexpected positional argument(s).",
        %{"argv" => argv},
        ["Run `#{@command} --help`; this smoke only accepts named options."],
        json?
      )
    end

    config = parse_config!(opts, json?)
    request = provider_request(config)

    if config.dry_run? do
      print_success(dry_run_payload(config, request), json?)
      :ok
    else
      Mix.Task.run("app.start")
      ensure_auth!(json?)
      run_probe!(config, request, json?)
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

    search_context_size =
      opts
      |> Keyword.get(:search_context_size, @default_search_context_size)
      |> String.trim()

    unless search_context_size in @valid_search_context_sizes do
      fail!(
        :invalid_search_context_size,
        "--search-context-size must be one of: #{Enum.join(@valid_search_context_sizes, ", ")}.",
        %{"value" => search_context_size, "allowed" => @valid_search_context_sizes},
        ["Use `--search-context-size low` for the cheapest smoke."],
        json?
      )
    end

    query =
      opts
      |> Keyword.get(:query, @default_query)
      |> String.trim()

    if query == "" do
      fail!(
        :empty_query,
        "--query cannot be empty.",
        %{},
        ["Pass a concise query or omit --query to use the default OpenAI-docs probe."],
        json?
      )
    end

    %{
      model: model,
      reasoning_effort: reasoning_effort,
      search_context_size: search_context_size,
      query: query,
      dry_run?: Keyword.get(opts, :dry_run, false)
    }
  end

  defp provider_request(config) do
    %{
      model: config.model,
      system_prompt:
        "You are a Pixir hosted-web-search smoke probe. Use hosted web_search when available.",
      history: [Event.user_message("web-search-smoke", config.query)],
      web_search: %{
        search_context_size: config.search_context_size,
        include_sources: true
      }
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
        "--search-context-size low|medium|high",
        "--query TEXT",
        "--dry-run",
        "--json",
        "--help"
      ],
      "dry_run_guarantees" => [
        "does_not_require_auth",
        "does_not_call_provider",
        "does_not_write_files"
      ],
      "proof_states" => [
        "request_shape_contains_web_search",
        "web_search_call_observed",
        "citations_or_sources_reported_if_backend_emits_them"
      ],
      "next_steps" => [
        "Run `#{@command} --dry-run --json` first.",
        "Run `#{@command} --json` when a small real-network probe is acceptable.",
        "If the backend rejects web_search, keep the feature disabled for that dialect."
      ]
    })
  end

  defp print_help(_json?), do: Mix.shell().info(@moduledoc)

  defp dry_run_payload(config, request) do
    case Provider.request_body_preview(request, reasoning_effort: config.reasoning_effort) do
      {:ok, body} ->
        %{
          "ok" => true,
          "schema_version" => @schema_version,
          "mode" => "dry_run",
          "command" => @command,
          "network" => false,
          "model" => config.model,
          "reasoning_effort" => config.reasoning_effort,
          "search_context_size" => config.search_context_size,
          "would_send" => request_shape(body),
          "next_steps" => [
            "Run `#{@command} --json` to execute the live probe.",
            "Use `--model gpt-5.5 --reasoning-effort low` for representative low-cost checks."
          ]
        }

      {:error, reason} ->
        fail!(
          reason.kind,
          reason.message,
          stringify(reason.details || %{}),
          ["Run `#{@command} --help` and check the web_search option shape."],
          true
        )
    end
  end

  defp request_shape(body) do
    %{
      "store" => body["store"],
      "stream" => body["stream"],
      "tool_choice" => body["tool_choice"],
      "include" => body["include"] || [],
      "tools" => body["tools"] || [],
      "input_items" => length(body["input"] || []),
      "instructions_preview" => Tool.truncate(body["instructions"] || "", 400),
      "first_input_preview" =>
        body
        |> Map.get("input", [])
        |> List.first()
        |> input_preview()
    }
  end

  defp run_probe!(config, request, json?) do
    started = System.monotonic_time(:millisecond)

    opts = [
      reasoning_effort: config.reasoning_effort,
      on_delta: fn _ -> :ok end,
      max_retries: 0
    ]

    case Provider.stream(request, opts) do
      {:ok, result} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started
        web_search = result.web_search || %{}

        payload = %{
          "ok" => true,
          "schema_version" => @schema_version,
          "mode" => "run",
          "command" => @command,
          "network" => true,
          "model" => config.model,
          "reasoning_effort" => config.reasoning_effort,
          "search_context_size" => config.search_context_size,
          "elapsed_ms" => elapsed_ms,
          "text" => Tool.truncate(result.text, 1_000),
          "web_search_observed" => (web_search["call_count"] || 0) > 0,
          "citation_or_source_observed" =>
            (web_search["annotation_count"] || 0) > 0 or (web_search["source_count"] || 0) > 0,
          "web_search" => stringify(web_search),
          "usage_available" => not is_nil(result.usage),
          "usage_summary" => stringify(result.usage_summary),
          "caveats" => [
            "hosted web search is Provider evidence, not a Pixir local tool_call",
            "citations depend on backend event shape and include support",
            "T3 remains a presenter; Pixir owns this Provider request shape"
          ]
        }

        validate_probe_payload!(payload, json?)
        print_success(payload, json?)

      {:error, %{error: error}} ->
        fail!(
          error.kind,
          error.message,
          stringify(error.details || %{}),
          [
            "Verify credentials with `./pixir doctor --json`.",
            "Retry with `#{@command} --dry-run --json` to inspect the planned payload.",
            "If the backend reports an unknown tool/type, keep hosted web search disabled for this dialect."
          ],
          json?
        )
    end
  end

  defp validate_probe_payload!(%{"web_search_observed" => false} = payload, json?) do
    fail!(
      :web_search_not_observed,
      "The Provider response completed but did not emit hosted web_search evidence.",
      %{
        "web_search" => payload["web_search"],
        "usage_summary" => payload["usage_summary"]
      },
      [
        "Retry once; model/provider behavior can vary for short probes.",
        "If this persists, keep hosted web search disabled for this backend/model.",
        "Use `#{@command} --dry-run --json` to confirm Pixir is still sending the hosted tool."
      ],
      json?
    )
  end

  defp validate_probe_payload!(%{"citation_or_source_observed" => false} = payload, json?) do
    fail!(
      :web_search_evidence_missing,
      "Hosted web_search ran, but the Provider response did not include citations or sources.",
      %{
        "web_search" => payload["web_search"],
        "usage_summary" => payload["usage_summary"]
      },
      [
        "Confirm the request includes `web_search_call.action.sources`.",
        "If only final text is available, treat the run as unsupported for durable source evidence.",
        "Keep Presenter rendering deferred until structural source evidence is present."
      ],
      json?
    )
  end

  defp validate_probe_payload!(_payload, _json?), do: :ok

  defp ensure_auth!(json?) do
    if Auth.authenticated?() do
      :ok
    else
      fail!(
        :not_authenticated,
        "No Pixir credential is available.",
        %{},
        [
          "Run `mix pixir.smoke.login --wait` and approve the device-code flow.",
          "Alternatively set OPENAI_API_KEY for this shell."
        ],
        json?
      )
    end
  end

  defp input_preview(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn item -> item["text"] || item["type"] || "" end)
    |> Enum.join("\n")
    |> Tool.truncate(400)
  end

  defp input_preview(_), do: nil

  defp print_success(payload, true), do: print_json(payload)
  defp print_success(payload, _json?), do: Mix.shell().info(human_summary(payload))

  defp human_summary(%{"mode" => "dry_run"} = payload) do
    """
    #{payload["command"]} dry-run
    model: #{payload["model"]}
    reasoning_effort: #{payload["reasoning_effort"]}
    search_context_size: #{payload["search_context_size"]}
    """
    |> String.trim()
  end

  defp human_summary(%{"mode" => "run"} = payload) do
    observed? = if payload["web_search_observed"], do: "yes", else: "no"
    cited? = if payload["citation_or_source_observed"], do: "yes", else: "no"

    """
    #{payload["command"]} completed
    model: #{payload["model"]}
    web search observed: #{observed?}
    citation/source observed: #{cited?}
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

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
