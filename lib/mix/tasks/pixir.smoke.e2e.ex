defmodule Mix.Tasks.Pixir.Smoke.E2e do
  @shortdoc "Guided end-to-end: sign in, then run one real Turn against the live model"

  @moduledoc """
  Walks the whole v0.1 pipeline against the real backend, in a throwaway workspace:

    1. **Sign in** — if there's no credential, run the device-code flow (open the URL,
       enter the code). Skipped if already authenticated or `OPENAI_API_KEY` is set.
    2. **Run one Turn** — start a Session in a scratch dir and stream a prompt that
       forces tool use (write then read), exercising the Provider's streaming Responses
       call and the tool loop live.
    3. **Summarize** — fold the Log and report the events, the final answer, and the
       resumable session id.

  Usage:

      mix pixir.smoke.e2e                         # default prompt, scratch workspace
      mix pixir.smoke.e2e --model gpt-5.4         # override the model id
      mix pixir.smoke.e2e --prompt "..."          # custom prompt
      mix pixir.smoke.e2e --probe-model           # validate the model id before the Turn
      mix pixir.smoke.e2e --dry-run-tools         # model calls tools, no disk writes
      mix pixir.smoke.e2e --keep                  # keep the scratch workspace
      mix pixir.smoke.e2e --no-login              # fail instead of prompting to sign in
      mix pixir.smoke.e2e --help                  # print this help and exit
      mix pixir.smoke.e2e --json --help           # print machine-readable help

  Exit code is non-zero if any stage fails (so it can gate a release check).
  """

  use Mix.Task

  alias Pixir.{Auth, Events, Provider, Renderer, Session, SessionSupervisor, Turn}
  alias Pixir.Auth.CodexOAuth
  alias Pixir.Providers.{Registry, ResolvedProviderRequest, ResponsesBackend}

  @default_prompt "Create a file called hello.txt containing exactly 'Hello from Pixir', " <>
                    "then read it back and tell me what it says."

  @switches [
    model: :string,
    prompt: :string,
    probe_model: :boolean,
    dry_run_tools: :boolean,
    keep: :boolean,
    no_login: :boolean,
    help: :boolean,
    json: :boolean
  ]

  @options [
    "--model MODEL",
    "--prompt PROMPT",
    "--probe-model",
    "--dry-run-tools",
    "--keep",
    "--no-login",
    "--json",
    "--help"
  ]

  @impl Mix.Task
  @doc """
  Execute the end-to-end smoke Mix task with the given command-line arguments.

  Parses CLI options, handles `--help`/`--json` (prints help and exits normally), validates unsupported options (fails with a structured error), starts the application, ensures the user is signed in (unless `--no-login`), optionally probes the selected model, and runs a single guided turn against the live backend. Any fatal error will be routed to the task's failure handler which exits the process.
  """
  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, switches: @switches)

    if opts[:help] do
      print_help(!!opts[:json])
      exit(:normal)
    end

    if invalid != [] do
      fail("invalid command-line options", %{
        error: %{
          kind: :invalid_options,
          message: "Unsupported option(s). Run `mix pixir.smoke.e2e --help`.",
          details: %{invalid: invalid}
        }
      })
    end

    Mix.Task.run("app.start")

    with {:ok, resolved} <- explicit_chatgpt_preflight(opts),
         :ok <- ensure_signed_in(opts),
         :ok <- maybe_probe_model(opts, resolved) do
      run_turn(opts)
    else
      {:error, %{stage: stage, error: error}} -> fail(stage, error)
      {:error, error} -> fail("could not sign in", error)
    end
  end

  defp explicit_chatgpt_preflight(opts) do
    request = if opts[:model], do: %{model: opts[:model]}, else: %{}
    profile = %{"mode" => "chatgpt_codex"}

    with {:ok, resolved} <-
           Registry.resolve_request(
             %{
               provider_intent: {:direct, Provider},
               request: request,
               provider_opts: [responses_backend: profile]
             },
             []
           ),
         :ok <-
           resolved
           |> ResolvedProviderRequest.responses_backend()
           |> ResponsesBackend.activation_status() do
      {:ok, resolved}
    else
      {:error, error} ->
        {:error, %{stage: "responses backend preflight", error: error}}
    end
  end

  defp print_help(true) do
    Mix.shell().info(
      Jason.encode!(
        %{
          "ok" => true,
          "command" => "mix pixir.smoke.e2e",
          "network" => true,
          "description" => "Guided end-to-end smoke against the live model.",
          "options" => @options,
          "next_steps" => [
            "Run `mix pixir.smoke.e2e --probe-model --dry-run-tools` for a lower-risk live check.",
            "Run `mix pixir.smoke.login --wait` first if authentication is missing."
          ]
        },
        pretty: true
      )
    )
  end

  defp print_help(_json?) do
    Mix.shell().info(@moduledoc)
  end

  # ── optional step: probe the model before spending a full Turn ─────────────

  defp maybe_probe_model(opts, resolved) do
    if opts[:probe_model] do
      model = probe_model(resolved)
      Mix.shell().info("Step 1.5/3 — probing model #{model} …")

      case Provider.probe(probe_opts(opts, resolved)) do
        {:ok, %{model: m}} ->
          Mix.shell().info("Model #{m} accepted. ✓\n")
          :ok

        # A usage limit means the request reached the model — connectivity and the
        # model id are both fine; it's quota, not a wiring problem.
        {:error, %{error: %{kind: :usage_limit_reached}} = limited} ->
          {:error,
           %{
             stage: "model #{model} is valid and reachable, but the ChatGPT usage limit was hit",
             error: limited
           }}

        {:error, error} ->
          {:error, %{stage: "model #{model} was rejected", error: error}}
      end
    else
      :ok
    end
  end

  defp probe_opts(_opts, resolved), do: [resolved_provider_request: resolved]

  @doc false
  def probe_model(resolved), do: ResolvedProviderRequest.model(resolved)

  # ── step 1: auth ────────────────────────────────────────────────────────

  defp ensure_signed_in(opts) do
    if Auth.authenticated?() do
      Mix.shell().info("Step 1/3 — already signed in (#{Auth.status().kind}). ✓\n")
      :ok
    else
      if opts[:no_login] do
        {:error,
         %{
           error: %{
             kind: :not_authenticated,
             message: "no credential and --no-login given",
             details: %{}
           }
         }}
      else
        guided_login()
      end
    end
  end

  defp guided_login do
    Mix.shell().info("Step 1/3 — sign in with ChatGPT (Codex)\n")

    with {:ok, device} <- CodexOAuth.start_device_auth() do
      Mix.shell().info("""
        Open:  #{device.verification_uri}
        Enter: #{device.user_code}

      Waiting for approval (expires in #{div(device.expires_in, 60)} min)…
      """)

      with {:ok, %{authorization_code: code, code_verifier: verifier}} <-
             CodexOAuth.poll_for_authorization(device),
           {:ok, credential} <- CodexOAuth.exchange_for_credential(code, verifier),
           :ok <- Auth.set_credential(credential) do
        Mix.shell().info("Signed in. ✓\n")
        :ok
      end
    end
  end

  # ── step 2: one real Turn ─────────────────────────────────────────────────

  defp run_turn(opts) do
    workspace = scratch_workspace()
    prompt = opts[:prompt] || @default_prompt
    Mix.shell().info("Step 2/3 — running one Turn in #{workspace}\n  prompt: #{prompt}\n")

    {:ok, sid, _pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)
    :ok = Events.subscribe(sid)

    turn_opts = turn_opts(opts)
    {:ok, _ref} = Session.start_turn(sid, fn ctx -> Turn.run(ctx, prompt, turn_opts) end)

    case Renderer.consume_until_done(idle_timeout: 180_000) do
      :ok ->
        summarize(sid, workspace, opts)

      :timeout ->
        fail("timed out waiting for the model", %{
          error: %{kind: :timeout, message: "no response in 180s", details: %{}}
        })
    end
  end

  defp turn_opts(opts) do
    provider_opts = [responses_backend: %{"mode" => "chatgpt_codex"}]

    provider_opts =
      if opts[:model], do: Keyword.put(provider_opts, :model, opts[:model]), else: provider_opts

    [provider_opts: provider_opts, dry_run: !!opts[:dry_run_tools]]
  end

  # ── step 3: summary ────────────────────────────────────────────────────

  defp summarize(sid, workspace, opts) do
    {:ok, history} = Session.history(sid)
    tool_calls = Enum.filter(history, &(&1.type == :tool_call))
    answer = history |> Enum.reverse() |> Enum.find(&(&1.type == :assistant_message))

    Mix.shell().info("""

    Step 3/3 — summary ✓
      session:     #{sid}
      events:      #{length(history)} canonical (#{length(tool_calls)} tool call(s))
      tools used:  #{tool_calls |> Enum.map(& &1.data["name"]) |> Enum.uniq() |> Enum.join(", ")}
      final answer: #{if answer, do: String.slice(answer.data["text"], 0, 200), else: "(none)"}
    """)

    cleanup(workspace, opts)
    Mix.shell().info("End-to-end smoke passed. ✓")
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp scratch_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-e2e-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    dir
  end

  defp cleanup(workspace, opts) do
    if opts[:keep] do
      Mix.shell().info("  (kept workspace: #{workspace})")
    else
      File.rm_rf!(workspace)
    end
  end

  defp fail(context, %{error: %{kind: kind, message: message, details: details}}) do
    Mix.shell().error("✗ #{context}: #{kind} — #{message}")
    unless details == %{}, do: Mix.shell().error("  details: #{inspect(details)}")
    exit({:shutdown, 1})
  end

  defp fail(context, other) do
    Mix.shell().error("✗ #{context}: #{inspect(other)}")
    exit({:shutdown, 1})
  end
end
