defmodule Pixir.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Pixir.Test.RawLogHelpers

  alias Pixir.{CLI, Event, Log, Paths, Subagents}
  alias Pixir.Delegate.Evidence

  defmodule StubProvider do
    def stream(request, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:provider_request, request, opts})
      end

      agent = Keyword.fetch!(opts, :agent)
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
      result = Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)

      result =
        case result do
          {:sleep, ms, nested} ->
            Process.sleep(ms)
            nested

          {:interrupt_after, ms} ->
            session_id = Keyword.fetch!(opts, :session_id)

            spawn(fn ->
              Process.sleep(ms)
              _ = Pixir.Conversation.interrupt(session_id)
            end)

            Process.sleep(ms + 1_000)

            {:ok,
             %{text: "should not arrive", reasoning: "", function_calls: [], finish_reason: :stop}}

          other ->
            other
        end

      case result do
        {:no_delta, inner} ->
          inner

        {:deltas_then_final, deltas, final} ->
          on_delta.({:text_delta, deltas})
          {:ok, %{text: final, reasoning: "", function_calls: [], finish_reason: :stop}}

        _ ->
          case result do
            {:ok, %{text: text}} when text != "" -> on_delta.({:text_delta, text})
            {:delta_then_error, text, _error} -> on_delta.({:text_delta, text})
            _ -> :ok
          end

          case result do
            {:delta_then_error, _text, error} -> error
            other -> other
          end
      end
    end
  end

  defmodule AttachmentCaptureProvider do
    def stream(_request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:attachments, Keyword.get(opts, :attachments, [])})
      {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defmodule UsageAbsentFallbackProvider do
    def stream(_request, opts) do
      sid = Keyword.fetch!(opts, :session_id)

      Pixir.Session.emit(
        sid,
        Pixir.Event.assistant_message(sid, "",
          metadata: %{
            "output_truncation" => %{
              "status" => "truncated",
              "reason" => "provider_content_filter",
              "provider_reason" => "content_filter",
              "provider_usage_event_id" => "evt_usage_absent",
              "provider_usage_seq" => 77,
              "call_role" => "final_answer"
            }
          }
        )
      )

      Keyword.fetch!(opts, :on_delta).({:text_delta, "final authoritative"})

      {:ok,
       %{
         text: "final authoritative",
         reasoning: "",
         function_calls: [],
         finish_reason: :stop,
         output_truncation: %{status: :not_truncated, provider_reason: "fixture_done"}
       }}
    end
  end

  defmodule PartialUsageAbsentFallbackProvider do
    def stream(_request, opts) do
      sid = Keyword.fetch!(opts, :session_id)

      Pixir.Session.emit(
        sid,
        Pixir.Event.assistant_message(sid, "",
          metadata: %{
            "partial" => true,
            "output_truncation" => %{
              "status" => "truncated",
              "reason" => "provider_content_filter",
              "provider_reason" => "content_filter",
              "provider_usage_event_id" => "evt_partial_fallback",
              "provider_usage_seq" => 77,
              "call_role" => "final_answer"
            }
          }
        )
      )

      Keyword.fetch!(opts, :on_delta).({:text_delta, "final authoritative"})

      {:ok,
       %{
         text: "final authoritative",
         reasoning: "",
         function_calls: [],
         finish_reason: :stop,
         output_truncation: %{status: :not_truncated, provider_reason: "fixture_done"}
       }}
    end
  end

  defmodule WebSearchCaptureProvider do
    def stream(request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:web_search_request, Map.get(request, :web_search)})
      {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defmodule WorkflowPartialProvider do
    def stream(%{history: history}, _opts) do
      prompt =
        history
        |> Enum.find(&(&1.type == :user_message))
        |> then(&((&1 && &1.data["text"]) || ""))

      step =
        prompt
        |> String.split("\n")
        |> Enum.find_value("unknown", fn
          "Step: " <> id -> id
          _ -> nil
        end)

      case step do
        "fail" ->
          {:error, Pixir.Tool.error(:command_failed, "planned workflow failure", %{step: step})}

        _ ->
          {:ok,
           %{
             text: "checkpoint_status: checkpoint_ready\nsummary:#{step}",
             reasoning: "",
             function_calls: [],
             finish_reason: :stop
           }}
      end
    end
  end

  defp stop(text),
    do: {:ok, %{text: text, reasoning: "", function_calls: [], finish_reason: :stop}}

  defp tool_calls(calls),
    do: {:ok, %{text: "", reasoning: "", function_calls: calls, finish_reason: :tool_calls}}

  defp with_cli_turn_opts(opts, fun) do
    previous = Application.get_env(:pixir, :cli_turn_opts, :unset)

    Application.put_env(:pixir, :cli_turn_opts, opts)

    try do
      fun.()
    after
      if previous == :unset do
        Application.delete_env(:pixir, :cli_turn_opts)
      else
        Application.put_env(:pixir, :cli_turn_opts, previous)
      end
    end
  end

  defp with_cli_interactive(value, fun) do
    previous = Application.get_env(:pixir, :cli_interactive?, :unset)

    Application.put_env(:pixir, :cli_interactive?, value)

    try do
      fun.()
    after
      if previous == :unset do
        Application.delete_env(:pixir, :cli_interactive?)
      else
        Application.put_env(:pixir, :cli_interactive?, previous)
      end
    end
  end

  defp with_cli_provider(script, fun, extra_opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    with_cli_turn_opts(
      Keyword.merge(
        [
          provider: StubProvider,
          provider_opts: [agent: agent],
          skip_auth?: true
        ],
        extra_opts
      ),
      fun
    )
  end

  defp with_cli_halt(fun) do
    previous = Application.get_env(:pixir, :cli_halt_fun, :unset)

    Application.put_env(:pixir, :cli_halt_fun, fn code -> throw({:pixir_cli_halt, code}) end)

    try do
      fun.()
    after
      if previous == :unset do
        Application.delete_env(:pixir, :cli_halt_fun)
      else
        Application.put_env(:pixir, :cli_halt_fun, previous)
      end
    end
  end

  defp in_tmp_workspace(prefix, fun) do
    ws = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)

    try do
      File.cd!(ws, fn -> fun.(ws) end)
    after
      File.rm_rf!(ws)
    end
  end

  defp with_pixir_home(prefix, fun) do
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("PIXIR_HOME")

    try do
      File.mkdir_p!(home)
      System.put_env("PIXIR_HOME", home)
      fun.(home)
    after
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end

  defp only_session_id!(ws) do
    [path] = Path.wildcard(Path.join([ws, ".pixir", "sessions", "*.ndjson"]))
    path |> Path.basename() |> String.replace_suffix(".ndjson", "")
  end

  defp session_lease_files(ws),
    do: Path.wildcard(Path.join([ws, ".pixir", "session_leases", "*.json"]))

  # GC folds parent logs cold; seed them from raw NDJSON, never constructors
  # (path convention: a decode regression must fail these tests).
  defp write_gc_subagent_event!(ws, session_id, seq, subagent_id, child_workspace, status) do
    data = %{
      "subagent_id" => subagent_id,
      "child_session_id" => "child-#{subagent_id}",
      "event" => status,
      "status" => status,
      "workspace" => child_workspace,
      "workspace_mode" => "isolated"
    }

    path = Log.path(session_id, workspace: ws)
    File.mkdir_p!(Path.dirname(path))

    line =
      Jason.encode!(raw_event(session_id, seq, "subagent_event", data)) <> "\n"

    File.write!(path, line, [:append])
  end

  test "--attach accumulates in order and encodes resource links" do
    in_tmp_workspace("pixir-cli-attach", fn ws ->
      File.write!(Path.join(ws, "one.txt"), "one")
      File.write!(Path.join(ws, "two.txt"), "two")

      with_cli_turn_opts(
        [
          provider: AttachmentCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true,
          session_id: "cli-attach-order"
        ],
        fn ->
          assert :ok = CLI.route(["--attach", "one.txt", "--attach", "two.txt", "hello"])
        end
      )

      # Attachments are a Turn opt consumed by ingestion, never provider opts:
      # the durable evidence is the user_message resources in the session Log.
      # The capture stub pins that boundary: providers must see no attachments.
      assert_received {:attachments, []}
      sid = only_session_id!(ws)
      assert {:ok, history} = Log.fold(sid, workspace: ws)

      assert %{data: %{"resources" => resources}} =
               Enum.find(history, &(&1.type == :user_message))

      assert Enum.map(resources, & &1["name"]) == ["one.txt", "two.txt"]
      assert Enum.all?(resources, &(&1["size_bytes"] == 3))
    end)
  end

  test "--attach reports structured errors for missing values and unsupported commands" do
    assert {:error, 2} = CLI.route(["--attach"])
    assert {:error, 2} = CLI.route(["--attach", "note.txt", "doctor"])
  end

  test "--web-search is accepted for one-shot and resume but rejected for other commands" do
    in_tmp_workspace("pixir-cli-web-search", fn _ws ->
      with_cli_provider([stop("ok")], fn ->
        assert :ok = CLI.route(["--web-search", "hello"])
      end)

      sid = only_session_id!(File.cwd!())

      # The capture provider proves the post-session-id flag is consumed as a
      # flag (request carries the config) instead of leaking into the prompt.
      with_cli_turn_opts(
        [
          provider: WebSearchCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true
        ],
        fn ->
          assert :ok = CLI.route(["resume", sid, "--web-search", "again"])
        end
      )

      assert_received {:web_search_request, %{"enabled" => true}}

      assert {:ok, history} = Log.fold(sid, workspace: File.cwd!())
      resumed_prompt = history |> Enum.filter(&(&1.type == :user_message)) |> List.last()
      assert resumed_prompt.data["text"] == "again"
    end)

    assert {:error, 2} = CLI.route(["--web-search", "doctor"])
  end

  test "--web-search folds into provider_opts without clobbering the injected list" do
    in_tmp_workspace("pixir-cli-web-search-fold", fn _ws ->
      with_cli_turn_opts(
        [
          provider: WebSearchCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true,
          session_id: "cli-web-search-fold"
        ],
        fn ->
          assert :ok = CLI.route(["--web-search", "hello"])
        end
      )

      # The provider stub still received test_pid (the injected provider_opts
      # survived the fold) AND the request carries the flag-derived config.
      assert_received {:web_search_request, %{"enabled" => true}}
    end)
  end

  test "without --web-search the provider request omits web_search" do
    in_tmp_workspace("pixir-cli-web-search-off", fn _ws ->
      with_cli_turn_opts(
        [
          provider: WebSearchCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true,
          session_id: "cli-web-search-off"
        ],
        fn ->
          assert :ok = CLI.route(["hello"])
        end
      )

      assert_received {:web_search_request, nil}
    end)
  end

  test "resume placement --attach threads attachments into turn opts" do
    in_tmp_workspace("pixir-cli-resume-attach", fn ws ->
      File.write!(Path.join(ws, "resume.txt"), "resume")
      sid = "cli-resume-attach"

      assert {:ok, _} =
               Log.append(Event.with_seq(Event.user_message(sid, "one"), 0), workspace: ws)

      with_cli_turn_opts(
        [
          provider: AttachmentCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true
        ],
        fn ->
          assert :ok = CLI.route(["resume", sid, "--attach", "resume.txt", "again"])
        end
      )

      assert_received {:attachments, []}
      assert {:ok, history} = Log.fold(sid, workspace: ws)

      assert %{data: %{"resources" => [resource]}} =
               history
               |> Enum.filter(&(&1.type == :user_message))
               |> Enum.find(&(&1.data["text"] == "again"))

      assert resource["name"] == "resume.txt"
      assert resource["size_bytes"] == byte_size("resume")
    end)
  end

  test "--attach URI encoding round-trips reserved and UTF-8 path characters" do
    in_tmp_workspace("pixir-cli-attach-roundtrip", fn ws ->
      name = "space # question ? café.txt"
      File.write!(Path.join(ws, name), "evidence")

      with_cli_turn_opts(
        [
          provider: AttachmentCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true,
          session_id: "cli-attach-roundtrip"
        ],
        fn ->
          assert :ok = CLI.route(["--attach", name, "hello"])
        end
      )

      # size_bytes matching the real file proves the encoded URI decoded back
      # to the original hostile path (space, #, ?, UTF-8) before File.read.
      assert_received {:attachments, []}
      sid = only_session_id!(ws)
      assert {:ok, history} = Log.fold(sid, workspace: ws)

      assert %{data: %{"resources" => [resource]}} =
               Enum.find(history, &(&1.type == :user_message))

      assert resource["name"] == name
      assert resource["size_bytes"] == byte_size("evidence")
    end)
  end

  test "--attach outside the workspace is accepted as operator-supplied (ADR 0021)" do
    in_tmp_workspace("pixir-cli-attach-outside", fn ws ->
      outside_dir =
        Path.join(System.tmp_dir!(), "pixir-cli-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      on_exit(fn -> File.rm_rf!(outside_dir) end)
      outside = Path.join(outside_dir, "external.txt")
      File.write!(outside, "outside evidence")

      with_cli_turn_opts(
        [
          provider: AttachmentCaptureProvider,
          provider_opts: [test_pid: self()],
          skip_auth?: true,
          quiet?: true
        ],
        fn ->
          assert :ok = CLI.route(["--attach", outside, "hello"])
        end
      )

      # ADR 0021: operator-supplied file:// links are deliberately exempt from
      # workspace read confinement. This pins the CLI half of that decision.
      assert_received {:attachments, []}
      sid = only_session_id!(ws)
      assert {:ok, history} = Log.fold(sid, workspace: ws)

      assert %{data: %{"resources" => [resource]}} =
               Enum.find(history, &(&1.type == :user_message))

      assert resource["name"] == "external.txt"
      assert resource["size_bytes"] == byte_size("outside evidence")
    end)
  end

  test "no args prints usage and succeeds" do
    out = capture_io(fn -> assert :ok = CLI.route([]) end)
    assert out =~ "OTP-native coding agent"
    assert out =~ "pixir resume"
    assert out =~ "pixir gc [--apply] [--json]"
    assert out =~ "pixir delegate"
    assert out =~ "pixir delegate daemon"
  end

  test "help and --help print usage" do
    assert capture_io(fn -> assert :ok = CLI.route(["help"]) end) =~ "Usage:"
    assert capture_io(fn -> assert :ok = CLI.route(["--help"]) end) =~ "Usage:"
  end

  test "--version prints the version and exits (B.2 liveness probe)" do
    for flag <- ["--version", "-v", "version"] do
      out = capture_io(fn -> assert :ok = CLI.route([flag]) end)
      assert String.trim(out) == Pixir.version()
    end
  end

  test "login --help is self-describing without starting the flow" do
    out = capture_io(fn -> assert :ok = CLI.route(["login", "--help"]) end)
    assert out =~ "browser OAuth"
    assert out =~ "127.0.0.1:1455"
    assert out =~ "--device-code"
    assert out =~ "OPENAI_API_KEY"
  end

  test "doctor --help is self-describing without network" do
    out = capture_io(fn -> assert :ok = CLI.route(["doctor", "--help"]) end)
    assert out =~ "first-run diagnostics"
    assert out =~ "--json"
  end

  test "gc --json classifies a closed-referenced snapshot as reclaimable" do
    in_tmp_workspace("pixir-cli-gc-closed", fn ws ->
      closed_dir = Path.join([ws, ".pixir", "subagents", "closed"])
      payload = Path.join([closed_dir, "workspace", "payload.bin"])
      File.mkdir_p!(Path.dirname(payload))
      File.write!(payload, "closed payload")

      write_gc_subagent_event!(
        ws,
        "gc-closed-parent",
        0,
        "closed",
        Path.join(closed_dir, "workspace"),
        "closed"
      )

      output = capture_io(fn -> assert :ok = CLI.route(["gc", "--json"]) end)
      assert {:ok, %{"entries" => [entry]}} = Jason.decode(output)
      assert entry["classification"] == "reclaimable"
    end)
  end

  test "gc --json plans terminal snapshots without changing the filesystem" do
    in_tmp_workspace("pixir-cli-gc-plan", fn ws ->
      terminal_dir = Path.join([ws, ".pixir", "subagents", "terminal"])
      unreferenced_dir = Path.join([ws, ".pixir", "subagents", "unreferenced"])
      terminal_payload = Path.join([terminal_dir, "workspace", "payload.bin"])
      unreferenced_payload = Path.join(unreferenced_dir, "keep.txt")

      File.mkdir_p!(Path.dirname(terminal_payload))
      File.mkdir_p!(unreferenced_dir)
      File.write!(terminal_payload, "terminal payload")
      File.write!(unreferenced_payload, "unreferenced payload")

      write_gc_subagent_event!(
        ws,
        "gc-plan-parent",
        0,
        "terminal",
        Path.join(terminal_dir, "workspace"),
        "completed"
      )

      output = capture_io(fn -> assert :ok = CLI.route(["gc", "--json"]) end)
      assert {:ok, envelope} = Jason.decode(output)
      assert envelope["ok"] == true
      assert envelope["status"] == "planned"
      assert envelope["kind"] == "subagent_gc_plan"
      assert envelope["apply"] == false

      entries = Map.new(envelope["entries"], &{Path.basename(&1["dir"]), &1})
      assert entries["terminal"]["classification"] == "reclaimable"
      assert entries["terminal"]["bytes"] == byte_size("terminal payload")
      assert entries["terminal"]["preserved_log_count"] == 0
      assert entries["unreferenced"]["classification"] == "skipped_unreferenced"
      assert envelope["totals"]["reclaimable_bytes"] == byte_size("terminal payload")
      assert envelope["totals"]["preserved_logs_bytes"] == 0

      assert File.read!(terminal_payload) == "terminal payload"
      assert File.read!(unreferenced_payload) == "unreferenced payload"
    end)
  end

  test "gc blocks planning on a corrupt parent log" do
    in_tmp_workspace("pixir-cli-gc-corrupt", fn ws ->
      dir = Path.join([ws, ".pixir", "subagents", "terminal"])
      File.mkdir_p!(Path.join(dir, "workspace"))
      File.write!(Path.join(dir, "workspace/payload.bin"), "x")

      corrupt = Path.join([ws, ".pixir", "sessions", "corrupt-parent.ndjson"])
      File.mkdir_p!(Path.dirname(corrupt))
      File.write!(corrupt, "{not json at all\n")

      output = capture_io(fn -> assert {:error, _} = CLI.route(["gc", "--json"]) end)
      assert {:ok, envelope} = Jason.decode(output)
      assert envelope["ok"] == false
      assert envelope["status"] == "blocked"
      assert Enum.any?(envelope["next_actions"], &(&1 =~ "parent_log"))

      # Nothing was touched.
      assert File.exists?(Path.join(dir, "workspace/payload.bin"))
    end)
  end

  test "gc --apply records per-dir failures and continues (partial honesty)" do
    in_tmp_workspace("pixir-cli-gc-partial", fn ws ->
      good = Path.join([ws, ".pixir", "subagents", "good"])
      locked = Path.join([ws, ".pixir", "subagents", "locked"])
      File.mkdir_p!(Path.join(good, "workspace"))
      File.mkdir_p!(Path.join(locked, "workspace/frozen"))
      File.write!(Path.join(good, "workspace/a.bin"), "a")
      File.write!(Path.join(locked, "workspace/frozen/b.bin"), "b")

      write_gc_subagent_event!(
        ws,
        "gc-partial-parent",
        0,
        "good",
        Path.join(good, "workspace"),
        "completed"
      )

      write_gc_subagent_event!(
        ws,
        "gc-partial-parent",
        1,
        "locked",
        Path.join(locked, "workspace"),
        "completed"
      )

      # Make the second dir undeletable (read-only + no-exec parent).
      File.chmod!(Path.join(locked, "workspace/frozen"), 0o555)
      File.chmod!(Path.join(locked, "workspace"), 0o555)

      output = capture_io(fn -> assert {:error, _} = CLI.route(["gc", "--apply", "--json"]) end)

      # Restore permissions before in_tmp_workspace's own rm_rf teardown.
      File.chmod!(Path.join(locked, "workspace"), 0o755)
      File.chmod!(Path.join(locked, "workspace/frozen"), 0o755)

      assert {:ok, envelope} = Jason.decode(output)
      assert envelope["ok"] == false
      assert envelope["status"] == "partial"

      entries = Map.new(envelope["entries"], &{Path.basename(&1["dir"]), &1})
      assert entries["good"]["outcome"] == "reclaimed"
      refute File.exists?(Path.join(good, "workspace/a.bin"))
      assert entries["locked"]["outcome"] == "failed"
    end)
  end

  test "gc --apply preserves child Logs and leaves running and unreferenced dirs untouched" do
    in_tmp_workspace("pixir-cli-gc-apply", fn ws ->
      terminal_dir = Path.join([ws, ".pixir", "subagents", "terminal"])
      running_dir = Path.join([ws, ".pixir", "subagents", "running"])
      unreferenced_dir = Path.join([ws, ".pixir", "subagents", "unreferenced"])
      terminal_payload = Path.join([terminal_dir, "workspace", "large.bin"])
      running_payload = Path.join([running_dir, "workspace", "running.txt"])
      unreferenced_payload = Path.join(unreferenced_dir, "unknown.txt")

      child_log =
        Path.join([
          terminal_dir,
          "workspace",
          ".pixir",
          "sessions",
          "child-terminal.ndjson"
        ])

      child_log_bytes = "{\"child\":\"byte-intact\"}\n"

      for path <- [terminal_payload, running_payload, unreferenced_payload, child_log] do
        File.mkdir_p!(Path.dirname(path))
      end

      File.write!(terminal_payload, "delete me")
      File.write!(running_payload, "keep running")
      File.write!(unreferenced_payload, "keep unknown")
      File.write!(child_log, child_log_bytes)

      write_gc_subagent_event!(
        ws,
        "gc-apply-parent",
        0,
        "terminal",
        Path.join(terminal_dir, "workspace"),
        "failed"
      )

      write_gc_subagent_event!(
        ws,
        "gc-apply-parent",
        1,
        "running",
        Path.join(running_dir, "workspace"),
        "running"
      )

      output = capture_io(fn -> assert :ok = CLI.route(["gc", "--apply", "--json"]) end)
      assert {:ok, envelope} = Jason.decode(output)
      assert envelope["ok"] == true
      assert envelope["status"] == "applied"
      assert envelope["kind"] == "subagent_gc_apply"
      assert envelope["apply"] == true

      # File.cwd!/0 resolves the /var -> /private/var symlink on macOS while the
      # fixture path does not; join on basenames instead of absolute equality.
      entries = Map.new(envelope["entries"], &{Path.basename(&1["dir"]), &1})
      assert entries["terminal"]["classification"] == "reclaimable"
      assert entries["terminal"]["outcome"] == "reclaimed"
      assert entries["terminal"]["preserved_log_count"] == 1
      assert entries["running"]["classification"] == "skipped_running"
      assert entries["running"]["outcome"] == "skipped"
      assert entries["unreferenced"]["classification"] == "skipped_unreferenced"
      assert entries["unreferenced"]["outcome"] == "skipped"

      refute File.exists?(terminal_payload)
      assert File.read!(child_log) == child_log_bytes
      assert File.read!(running_payload) == "keep running"
      assert File.read!(unreferenced_payload) == "keep unknown"
      assert envelope["totals"]["preserved_logs_bytes"] == byte_size(child_log_bytes)
    end)
  end

  test "gc --help is self-describing and advertises dry-run and apply" do
    out = capture_io(fn -> assert :ok = CLI.route(["gc", "--help"]) end)
    assert out =~ "effect-free plan"
    assert out =~ "pixir gc --apply --json"
    assert out =~ ".pixir/sessions"
  end

  test "diagnose --help is self-describing without network" do
    out = capture_io(fn -> assert :ok = CLI.route(["diagnose", "--help"]) end)
    assert out =~ "Doctor+ diagnostics"
    assert out =~ "diagnose session"
  end

  test "diagnose session --json prints session diagnostics" do
    ws = Path.join(System.tmp_dir!(), "pixir-cli-diagnose-#{System.unique_integer([:positive])}")
    sid = "diagnose-cli"
    File.mkdir_p!(ws)

    events = [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_ok", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_ok", %{"ok" => true, "output" => "/tmp"})
    ]

    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out =
        capture_io(fn ->
          assert :ok = CLI.route(["diagnose", "session", sid, "--json"])
        end)

      assert {:ok,
              %{
                "ok" => true,
                "session_id" => ^sid,
                "replay" => %{"balanced" => true},
                "workflows" => %{"count" => 0},
                "checks" => checks
              }} = Jason.decode(out)

      assert Enum.any?(checks, &(&1["id"] == "tool_pairing"))
      assert Enum.any?(checks, &(&1["id"] == "workflow_events"))
      assert Enum.any?(checks, &(&1["id"] == "workflow_checkpoints"))
    end)
  end

  test "diagnose session --json projects non-empty workflow evidence from raw NDJSON" do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-cli-diagnose-workflow-#{System.unique_integer([:positive])}"
      )

    sid = "diagnose-cli-workflow"
    File.mkdir_p!(ws)

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "user_message", %{"text" => "run workflow"}),
      raw_event(sid, 1, "workflow_event", %{
        "kind" => "workflow_started",
        "workflow_id" => "wf_cli",
        "workflow_name" => "CLI workflow"
      }),
      raw_event(sid, 2, "workflow_event", %{
        "kind" => "checkpoint_decided",
        "workflow_id" => "wf_cli",
        "workflow_name" => "CLI workflow",
        "step_id" => "inspect",
        "checkpoint_status" => "checkpoint_ready",
        "dependent_safe" => true,
        "workspace_mode" => "shared",
        "execution_kind" => "subagent",
        "checkpoint" => %{
          "status" => "checkpoint_ready",
          "version" => 2,
          "summary" => "ready",
          "known_limitations" => [],
          "typed_schema_ids" => ["workflow_checkpoint.v1"],
          "artifact_refs" => []
        }
      }),
      raw_event(sid, 3, "workflow_event", %{
        "kind" => "workflow_finished",
        "workflow_id" => "wf_cli",
        "workflow_name" => "CLI workflow",
        "status" => "completed",
        "ok" => true,
        "safe_next_actions" => []
      }),
      raw_event(sid, 4, "assistant_message", %{"text" => "done", "metadata" => %{}})
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out =
        capture_io(fn ->
          assert :ok = CLI.route(["diagnose", "session", sid, "--json"])
        end)

      assert {:ok,
              %{
                "ok" => true,
                "session_id" => ^sid,
                "workflows" => %{
                  "count" => 1,
                  "checkpoint_decision_count" => 1,
                  "runs" => [run]
                },
                "checks" => checks
              }} = Jason.decode(out)

      assert run["workflow_id"] == "wf_cli"
      assert run["status"] == "completed"
      assert run["typed_schema_ids"] == ["workflow_checkpoint.v1"]
      assert run["gaps"] == []

      assert %{"status" => "passed"} = Enum.find(checks, &(&1["id"] == "workflow_events"))
      assert %{"status" => "passed"} = Enum.find(checks, &(&1["id"] == "workflow_checkpoints"))
    end)
  end

  test "tree --help is self-describing without network" do
    out = capture_io(fn -> assert :ok = CLI.route(["tree", "--help"]) end)
    assert out =~ "Session/Subagent tree"
    assert out =~ "session_fork"
    assert out =~ "--json"
  end

  test "tree --json includes fork lineage for forked Sessions" do
    ws = Path.join(System.tmp_dir!(), "pixir-cli-tree-fork-#{System.unique_integer([:positive])}")
    parent = "tree-cli-parent"
    child = "tree-cli-child"
    File.mkdir_p!(ws)

    assert {:ok, _} =
             Log.append(Event.with_seq(Event.user_message(parent, "one"), 0), workspace: ws)

    assert {:ok, _} = Pixir.Fork.fork(parent, workspace: ws, child_session_id: child)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out = capture_io(fn -> assert :ok = CLI.route(["tree", parent, "--json"]) end)

      assert {:ok, %{"ok" => true, "tree" => tree}} = Jason.decode(out)
      assert [fork] = tree["forks"]
      assert fork["child_session_id"] == child
      assert fork["fork_root_session_id"] == parent
      assert fork["branch_summary"]["present"] == false
    end)
  end

  test "tree --json preserves boolean error fields" do
    ws = Path.join(System.tmp_dir!(), "pixir-cli-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out = capture_io(fn -> assert {:error, 2} = CLI.route(["tree", "missing", "--json"]) end)
      assert {:ok, %{"ok" => false, "error" => %{"kind" => "not_found"}}} = Jason.decode(out)
    end)
  end

  test "fork --help is self-describing without network" do
    out = capture_io(fn -> assert :ok = CLI.route(["fork", "--help"]) end)
    assert out =~ "child Session"
    assert out =~ "--dry-run"
    assert out =~ "--summarize"
    assert out =~ "resume continues"
    assert out =~ "branch_summary"
  end

  test "fork --dry-run --json prints a machine-readable plan" do
    ws = Path.join(System.tmp_dir!(), "pixir-cli-fork-#{System.unique_integer([:positive])}")
    sid = "fork-cli-parent"
    File.mkdir_p!(ws)

    events = [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two")
    ]

    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out =
        capture_io(fn ->
          assert :ok = CLI.route(["fork", sid, "--dry-run", "--json"])
        end)

      assert {:ok,
              %{
                "ok" => true,
                "recorded" => false,
                "parent_session_id" => ^sid,
                "event_count" => 2,
                "to_seq" => 1
              }} = Jason.decode(out)
    end)
  end

  test "fork --summarize --dry-run --json reports branch summary plan fields" do
    ws = Path.join(System.tmp_dir!(), "pixir-cli-fork-sum-#{System.unique_integer([:positive])}")
    sid = "fork-cli-sum-parent"
    File.mkdir_p!(ws)

    events = [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two")
    ]

    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out =
        capture_io(fn ->
          assert :ok = CLI.route(["fork", sid, "--summarize", "--dry-run", "--json"])
        end)

      assert {:ok,
              %{
                "ok" => true,
                "would_record_branch_summary" => true,
                "branch_summary_strategy" => "deterministic_operational_summary_v1"
              }} = Jason.decode(out)
    end)
  end

  test "compact --help is self-describing without network" do
    out = capture_io(fn -> assert :ok = CLI.route(["compact", "--help"]) end)
    assert out =~ "history_compaction"
    assert out =~ "--dry-run"
    assert out =~ "--tail-events"
  end

  test "inspect-replay --help is self-describing without network" do
    out = capture_io(fn -> assert :ok = CLI.route(["inspect-replay", "--help"]) end)
    assert out =~ "Provider replay input"
    assert out =~ "--after-seq"
    assert out =~ "--json"
  end

  test "delegate --help is self-describing for dry-run and attached runtime" do
    out = capture_io(fn -> assert :ok = CLI.route(["delegate", "--help"]) end)
    assert out =~ "Delegate CLI I/O Contract v1"
    assert out =~ "--dry-run"
    assert out =~ "--json"

    assert out =~
             "pixir delegate --spec <path|-> [--dry-run] [--json] [--contract-version 1] [--timeout-ms N]"

    assert out =~ "strategy=\"subagents\" fanout"
    assert out =~ "strategy=\"workflow\""
    assert out =~ "dependency-wave execution"
    assert out =~ "per-step checkpoint readiness"
    assert out =~ "hold dependents"
    assert out =~ "--progress=stderr-jsonl"
    assert out =~ "--wait-horizon-ms"
    assert out =~ "status reads"
    assert out =~ "durable Session Log evidence"
    assert out =~ "stdout remains one final JSON envelope"
    assert out =~ "attach remains snapshot-first"
    assert out =~ "pixir delegate daemon"
    assert out =~ "start requires a reachable manual foreground"
    assert out =~ "daemon so returned running work survives"
    assert out =~ "status,"
    assert out =~ "attach, and cancel use the daemon when reachable"
    assert out =~ "durable Log snapshots or honest owner-unavailable state"
    assert out =~ "full streaming attach remains future work"
    assert out =~ "workspace-local"

    assert capture_io(fn -> assert :ok = CLI.route(["delegate", "help"]) end) == out
  end

  test "inspect-replay --json prints replay pairing diagnostics" do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-cli-inspect-replay-#{System.unique_integer([:positive])}"
      )

    sid = "inspect-replay-cli"
    File.mkdir_p!(ws)

    events = [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_ok", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_ok", %{"ok" => true, "output" => "/tmp"})
    ]

    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out =
        capture_io(fn ->
          assert :ok = CLI.route(["inspect-replay", sid, "--after-seq", "2", "--json"])
        end)

      assert {:ok,
              %{
                "ok" => true,
                "after_seq" => 2,
                "provider_input" => %{
                  "function_calls" => 1,
                  "function_call_outputs" => 1,
                  "balanced" => true
                }
              }} = Jason.decode(out)
    end)
  end

  test "compact --dry-run --json prints a machine-readable plan" do
    ws = Path.join(System.tmp_dir!(), "pixir-cli-compact-#{System.unique_integer([:positive])}")
    sid = "compact-cli"
    File.mkdir_p!(ws)

    events = [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ]

    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _path} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    on_exit(fn -> File.rm_rf!(ws) end)

    File.cd!(ws, fn ->
      out =
        capture_io(fn ->
          assert :ok =
                   CLI.route(["compact", sid, "--dry-run", "--json", "--tail-events", "1"])
        end)

      assert {:ok,
              %{
                "ok" => true,
                "compactable" => true,
                "recorded" => false,
                "would_compact_events" => 2,
                "event" => %{"range" => %{"from_seq" => 0, "to_seq" => 1}}
              }} = Jason.decode(out)
    end)
  end

  test "CLI flags override permission_default from config" do
    home = Path.join(System.tmp_dir!(), "pixir-cli-perm-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("PIXIR_HOME")

    try do
      File.mkdir_p!(home)

      File.write!(
        Path.join(home, "config.json"),
        Jason.encode!(%{"permission_default" => "ask"})
      )

      System.put_env("PIXIR_HOME", home)

      assert CLI.permission_mode_from_argv(["hello"]) == :ask
      assert CLI.permission_mode_from_argv(["--read-only", "hello"]) == :read_only
      assert CLI.permission_mode_from_argv(["--ask", "hello"]) == :ask
    after
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end

  test "doctor --json prints parseable diagnostics" do
    home = Path.join(System.tmp_dir!(), "pixir-cli-doctor-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("PIXIR_HOME")

    try do
      System.put_env("PIXIR_HOME", home)

      out = capture_io(fn -> assert :ok = CLI.route(["doctor", "--json"]) end)
      assert {:ok, %{"checks" => checks, "ok" => true}} = Jason.decode(out)
      assert Enum.any?(checks, &(&1["id"] == "config"))
      assert Enum.any?(checks, &(&1["id"] == "acp"))
    after
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")
    end
  end

  test "delegate --dry-run --json validates a file spec with JSON-only stdout" do
    in_tmp_workspace("pixir-cli-delegate", fn ws ->
      spec_path = Path.join(ws, "delegate.json")

      File.write!(
        spec_path,
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "inspect README without edits",
          "subagents" => %{"count" => 2}
        })
      )

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok = CLI.route(["delegate", "--spec", spec_path, "--dry-run", "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok,
              %{
                "ok" => true,
                "status" => "planned",
                "kind" => "delegate_plan",
                "contract_version" => 1,
                "dry_run" => true,
                "strategy" => "subagents",
                "beam_coordination" => %{
                  "entrypoint" => "single_pixir_process",
                  "planned_child_count" => 2
                },
                "host_boundary" => %{
                  "external_process_spawns" => 0,
                  "nested_pixir_processes" => 0,
                  "nested_mix_processes" => 0,
                  "shell_polling" => false
                },
                "artifacts" => [],
                "next_actions" => next_actions
              }} = Jason.decode(stdout)

      assert "run_without_--dry-run_for_attached_subagents" in next_actions
    end)
  end

  test "delegate bounded_write dry-run exposes write policy metadata" do
    in_tmp_workspace("pixir-cli-delegate-bounded", fn ws ->
      spec_path = Path.join(ws, "delegate.json")

      File.write!(
        spec_path,
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "mode" => "bounded_write",
          "task" => "edit scoped files",
          "write_policy" => %{
            "version" => 1,
            "metadata" => %{"id" => "delegate-test"},
            "allow_writes" => ["client/src/**"]
          }
        })
      )

      out =
        capture_io(fn ->
          assert :ok = CLI.route(["delegate", "--spec", spec_path, "--dry-run", "--json"])
        end)

      payload = Jason.decode!(out)
      assert payload["ok"] == true
      assert payload["write_policy"]["id"] == "delegate-test"
      assert payload["beam_coordination"]["delegate_mode"] == "bounded_write"
    end)
  end

  defp put_delegate_runtime_seams(agent, outcome) do
    previous = Application.fetch_env(:pixir, :cli_turn_opts)

    Application.put_env(:pixir, :cli_turn_opts,
      spawn_agent: fn _parent_session_id, _args, _opts -> {:ok, agent} end,
      wait_outcome: fn _parent_session_id, _ids, _timeout_ms, _opts -> {:ok, outcome} end
    )

    on_exit(fn ->
      case previous do
        {:ok, prior} -> Application.put_env(:pixir, :cli_turn_opts, prior)
        :error -> Application.delete_env(:pixir, :cli_turn_opts)
      end
    end)
  end

  defp horizon_cut_agent do
    %{
      "id" => "subagent_1",
      "agent" => "worker",
      "status" => "running",
      "summary" => "",
      "child_session_id" => "20260706T000002-cutoff"
    }
  end

  defp horizon_cut_outcome(agent) do
    %{
      "status" => "incomplete",
      "summary" => "horizon reached",
      "counts" => %{"completed" => 0},
      "subagents" => [agent]
    }
  end

  test "delegate partial without --json prints per-child resume hints on stderr" do
    in_tmp_workspace("pixir-cli-delegate-hints", fn ws ->
      agent = horizon_cut_agent()
      put_delegate_runtime_seams(agent, horizon_cut_outcome(agent))

      spec_path = Path.join(ws, "delegate.json")

      File.write!(
        spec_path,
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "cut off at horizon"
        })
      )

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert {:error, 6} = CLI.route(["delegate", "--spec", spec_path])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr =~ "child 20260706T000002-cutoff running"

      assert stderr =~
               ~s{(resume with: pixir resume 20260706T000002-cutoff "Continue from the latest incomplete turn.}

      assert_received {:delegate_stdout, stdout}
      refute stdout =~ "resume with:"
    end)
  end

  test "delegate partial with --json keeps stderr silent; guidance lives in the envelope" do
    in_tmp_workspace("pixir-cli-delegate-hints-json", fn ws ->
      agent = horizon_cut_agent()
      put_delegate_runtime_seams(agent, horizon_cut_outcome(agent))

      spec_path = Path.join(ws, "delegate.json")

      File.write!(
        spec_path,
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "cut off at horizon"
        })
      )

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert {:error, 6} = CLI.route(["delegate", "--spec", spec_path, "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok, payload} = Jason.decode(stdout)
      assert [child] = payload["children"]
      assert child["resume_command"] =~ "pixir resume 20260706T000002-cutoff"
      assert child["diagnose_command"] == "pixir diagnose session 20260706T000002-cutoff --json"
    end)
  end

  test "delegate bounded_write requires write_policy" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "task" => "edit scoped files"
      })

    out =
      capture_io(spec, fn ->
        assert {:error, 2} = CLI.route(["delegate", "--spec", "-", "--dry-run", "--json"])
      end)

    payload = Jason.decode!(out)
    assert payload["ok"] == false
    assert payload["kind"] == "invalid_spec"
    assert payload["message"] =~ "requires write_policy"
  end

  test "delegate --spec - --dry-run --json reads one JSON object from stdin" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "inspect", "task" => "read docs"},
          %{"id" => "summarize", "task" => "summarize docs"}
        ]
      })

    out =
      capture_io(spec, fn ->
        assert :ok = CLI.route(["delegate", "--spec", "-", "--dry-run", "--json"])
      end)

    assert {:ok,
            %{
              "ok" => true,
              "status" => "planned",
              "strategy" => "workflow",
              "spec_source" => %{"kind" => "stdin"},
              "beam_coordination" => %{"planned_child_count" => 2}
            }} = Jason.decode(out)
  end

  test "delegate --spec - --json runs attached subagents with JSON-only stdout" do
    with_cli_provider([{:sleep, 1_000, stop("child summary")}], fn ->
      in_tmp_workspace("pixir-cli-delegate-runner", fn _ws ->
        spec =
          Jason.encode!(%{
            "contract_version" => 1,
            "strategy" => "subagents",
            "task" => "answer from fake provider",
            "mode" => "read_only",
            "subagents" => %{"role" => "explorer", "count" => 1},
            "limits" => %{
              "timeout_ms" => 7_000,
              "delegate_timeout_ms" => 6_000,
              "child_timeout_ms" => 3_000,
              "wait_horizon_ms" => 5_000
            }
          })

        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(spec, fn ->
                assert :ok = CLI.route(["delegate", "--spec", "-", "--json"])
              end)

            send(self(), {:delegate_stdout, stdout})
          end)

        assert stderr == ""
        assert_received {:delegate_stdout, stdout}

        assert {:ok,
                %{
                  "ok" => true,
                  "status" => "completed",
                  "kind" => "delegate_result",
                  "contract_version" => 1,
                  "schema_version" => 5,
                  "schema" => "pixir.delegate.envelope.v1",
                  "command_ok" => true,
                  "work_complete" => true,
                  "outcome" => "completed",
                  "reason_code" => "completed",
                  "dry_run" => false,
                  "strategy" => "subagents",
                  "delegate_id" => delegate_id,
                  "parent_session_id" => session_id,
                  "session_id" => session_id,
                  "handle" => %{
                    "delegate_id" => delegate_id,
                    "parent_session_id" => session_id,
                    "handle_version" => 1
                  },
                  "children" => [
                    %{
                      "subagent_id" => subagent_id,
                      "child_session_id" => child_session_id,
                      "status" => "completed",
                      "outcome" => "completed",
                      "reason_code" => "completed",
                      "summary" => "child summary",
                      "timeout_ms" => 3_000
                    }
                  ],
                  "limits" => %{
                    "timeout_ms" => 7_000,
                    "delegate_timeout_ms" => 6_000,
                    "child_timeout_ms" => 3_000,
                    "wait_horizon_ms" => 5_000,
                    "timeout_semantics" => %{
                      "child_timeout_ms" => "per_child_subagent_execution_timeout",
                      "wait_horizon_ms" => "parent_wait_horizon_for_attached_result_collection"
                    }
                  },
                  "beam_coordination" => %{
                    "mode" => "attached",
                    "entrypoint" => "single_pixir_process",
                    "planned_child_count" => 1,
                    "spawned_child_count" => 1,
                    "completed_child_count" => 1
                  },
                  "host_boundary" => %{
                    "external_process_spawns" => 0,
                    "nested_pixir_processes" => 0,
                    "nested_mix_processes" => 0,
                    "shell_polling" => false
                  },
                  "diagnostics" => %{
                    "tree_command" => tree_command,
                    "diagnose_command" => diagnose_command,
                    "log_path" => log_path,
                    "evidence" => %{
                      "source_of_truth" => "session_log",
                      "workspace_log_path" => log_path,
                      "mirror" => %{"required" => false, "status" => "not_required"}
                    }
                  },
                  "evidence" => %{
                    "source_of_truth" => "session_log",
                    "workspace_log_path" => log_path,
                    "mirror" => %{"required" => false, "status" => "not_required"}
                  }
                }} = Jason.decode(stdout)

        assert is_binary(session_id)
        assert String.starts_with?(delegate_id, "dlg1_")
        assert is_binary(subagent_id)
        assert is_binary(child_session_id)
        assert tree_command == "pixir tree #{session_id} --json"
        assert diagnose_command == "pixir diagnose session #{session_id} --json"
        assert File.exists?(log_path)
        assert String.ends_with?(log_path, "/.pixir/sessions/#{session_id}.ndjson")
      end)
    end)
  end

  test "main releases attached delegate parent and child writer leases before halting" do
    with_cli_halt(fn ->
      with_cli_provider([stop("child one"), stop("child two")], fn ->
        in_tmp_workspace("pixir-main-delegate-lease-cleanup", fn ws ->
          spec =
            Jason.encode!(%{
              "contract_version" => 1,
              "strategy" => "subagents",
              "task" => "answer from fake provider",
              "mode" => "read_only",
              "subagents" => %{"role" => "explorer", "count" => 2},
              "limits" => %{
                "timeout_ms" => 7_000,
                "delegate_timeout_ms" => 6_000,
                "child_timeout_ms" => 3_000,
                "wait_horizon_ms" => 5_000
              }
            })

          stderr =
            capture_io(:stderr, fn ->
              stdout =
                capture_io(spec, fn ->
                  assert {:pixir_cli_halt, 0} =
                           catch_throw(CLI.main(["delegate", "--spec", "-", "--json"]))
                end)

              send(self(), {:delegate_stdout, stdout})
            end)

          assert stderr == ""
          assert_received {:delegate_stdout, stdout}

          assert %{"ok" => true, "status" => "completed", "children" => children} =
                   Jason.decode!(stdout)

          assert length(children) == 2

          assert [] = session_lease_files(ws)
          assert 3 = Path.wildcard(Path.join([ws, ".pixir", "sessions", "*.ndjson"])) |> length()
        end)
      end)
    end)
  end

  test "delegate timeout diagnostics distinguish queued work from child timeout" do
    with_cli_provider([{:sleep, 250, stop("slow child summary")}], fn ->
      in_tmp_workspace("pixir-cli-delegate-queued-timeout", fn ws ->
        spec =
          Jason.encode!(%{
            "contract_version" => 1,
            "strategy" => "subagents",
            "mode" => "read_only",
            "tasks" => [
              "slow running child",
              "queued healthy child",
              "another queued healthy child"
            ],
            "subagents" => %{"role" => "explorer", "max_threads" => 1},
            "limits" => %{
              "timeout_ms" => 500,
              "delegate_timeout_ms" => 500,
              "child_timeout_ms" => 5_000,
              "wait_horizon_ms" => 20
            }
          })

        stdout =
          capture_io(spec, fn ->
            assert {:error, 6} = CLI.route(["delegate", "--spec", "-", "--json"])
          end)

        payload = Jason.decode!(stdout)
        session_id = payload["session_id"]

        try do
          assert payload["status"] == "timed_out"
          assert payload["work_complete"] == false
          assert payload["reason_code"] == "wait_horizon_exhausted_with_queued_work"

          assert %{
                   "classification" => "wait_horizon_exhausted_with_queued_work",
                   "wait_horizon_exhausted" => true,
                   "delegate_timeout_ms" => 500,
                   "child_timeout_ms" => 5_000,
                   "wait_horizon_ms" => 20,
                   "queued_child_count" => 2,
                   "running_child_count" => 1,
                   "incomplete_child_count" => 3,
                   "child_timeout_count" => 0,
                   "failed_child_count" => 0,
                   "cancelled_child_count" => 0
                 } = payload["timeout_diagnostics"]

          assert Enum.map(payload["children"], & &1["status"]) |> Enum.sort() == [
                   "queued",
                   "queued",
                   "running"
                 ]
        after
          Enum.each(payload["children"] || [], fn child ->
            if child["subagent_id"] do
              _ = Subagents.close(session_id, child["subagent_id"], workspace: ws)
            end
          end)
        end
      end)
    end)
  end

  test "delegate bounded_write mirrors evidence outside workspace blast radius" do
    with_pixir_home("pixir-cli-delegate-evidence-home", fn home ->
      with_cli_provider([{:sleep, 1_000, stop("bounded child summary")}], fn ->
        in_tmp_workspace("pixir-cli-delegate-evidence", fn ws ->
          File.mkdir_p!(Path.join(ws, "src"))

          spec =
            Jason.encode!(%{
              "contract_version" => 1,
              "strategy" => "subagents",
              "task" => "inspect and report without editing",
              "mode" => "bounded_write",
              "write_policy" => %{
                "version" => 1,
                "metadata" => %{"id" => "mirror-test"},
                "allow_writes" => ["src/**"]
              },
              "subagents" => %{"role" => "worker", "count" => 1},
              "limits" => %{"timeout_ms" => 7_000, "child_timeout_ms" => 3_000}
            })

          stdout =
            capture_io(spec, fn ->
              assert :ok = CLI.route(["delegate", "--spec", "-", "--json"])
            end)

          payload = Jason.decode!(stdout)
          assert payload["status"] == "completed"
          assert payload["schema_version"] == 5
          assert payload["command_ok"] == true
          assert payload["work_complete"] == true
          assert payload["outcome"] == "completed"
          assert payload["reason_code"] == "completed"

          # The delegate parent's durable root posture records the delegate's
          # own ceiling (bounded policy), never a default unbounded auto — a
          # cold resume of this parent must restore exactly this sandbox.
          {:ok, parent_history} = Log.fold(payload["session_id"], workspace: ws)

          parent_posture =
            Enum.find(parent_history, fn event ->
              event.type == :subagent_event and
                event.data["event"] == "permission_posture"
            end)

          assert parent_posture.seq == 0
          assert parent_posture.data["lineage"] == "root"
          assert parent_posture.data["permission_mode"] == "auto"
          assert parent_posture.data["write_policy"]["allow_writes"] == ["src/**"]

          assert %{
                   "source_of_truth" => "session_log",
                   "workspace_log_path" => workspace_log_path,
                   "mirror" => %{
                     "required" => true,
                     "status" => "mirrored",
                     "session_log_path" => mirror_log_path,
                     "log_copy_path" => mirror_log_path,
                     "metadata_path" => metadata_path,
                     "outside_workspace" => true,
                     "outside_workspace_write_scope" => true,
                     "child_log_count" => 1,
                     "child_logs" => [
                       %{
                         "role" => "child",
                         "status" => "mirrored",
                         "log_copy_path" => child_mirror_log_path
                       }
                     ]
                   }
                 } = payload["evidence"]

          assert String.starts_with?(mirror_log_path, home)
          assert File.exists?(workspace_log_path)
          assert File.exists?(mirror_log_path)
          assert File.exists?(child_mirror_log_path)
          assert File.exists?(metadata_path)

          status_stdout =
            capture_io(fn ->
              assert :ok = CLI.route(["delegate", "status", payload["delegate_id"], "--json"])
            end)

          status_payload = Jason.decode!(status_stdout)
          assert status_payload["evidence"]["mirror"]["required"] == true
          assert status_payload["evidence"]["mirror"]["status"] == "mirrored"

          original_mirror_size = File.stat!(mirror_log_path).size
          File.write!(workspace_log_path, String.duplicate("x", original_mirror_size + 1))

          assert {:ok, diverged_payload} = Evidence.refresh_payload(payload)

          assert diverged_payload["evidence"]["mirror"]["status"] ==
                   "source_diverged_mirror_retained"

          assert File.stat!(mirror_log_path).size == original_mirror_size

          File.write!(workspace_log_path, "x")

          assert {:ok, regressed_payload} = Evidence.refresh_payload(payload)

          assert regressed_payload["evidence"]["mirror"]["status"] ==
                   "source_regressed_mirror_retained"

          assert File.stat!(mirror_log_path).size == original_mirror_size

          File.rm_rf!(Path.join(ws, ".pixir"))

          refute File.exists?(workspace_log_path)
          assert File.exists?(mirror_log_path)
          assert File.exists?(child_mirror_log_path)

          metadata = Jason.decode!(File.read!(metadata_path))
          assert metadata["truth_model"] == "session_log_remains_canonical"
          assert metadata["role"] == "audit_preservation_copy"
          assert metadata["result_envelope"]["status"] == "completed"
          assert metadata["result_envelope"]["work_complete"] == true
          assert Enum.any?(metadata["logs"], &(&1["role"] == "child"))
        end)
      end)
    end)
  end

  test "delegate evidence mirror failure remains structured when PIXIR_HOME is unusable" do
    in_tmp_workspace("pixir-cli-delegate-evidence-failure", fn ws ->
      sid = "delegate-evidence-failure"
      {:ok, handle} = Pixir.Delegate.Handle.build(sid)
      write_raw_log(ws, sid, [raw_event(sid, 0, "user_message", %{"text" => "delegate"})])

      blocked_home = Path.join(ws, "not-a-directory")
      File.write!(blocked_home, "x")
      previous_home = System.get_env("PIXIR_HOME")

      try do
        System.put_env("PIXIR_HOME", blocked_home)

        assert {:ok, payload} =
                 Evidence.refresh_payload(%{
                   "status" => "running",
                   "kind" => "delegate_result",
                   "delegate_id" => handle["delegate_id"],
                   "parent_session_id" => sid,
                   "session_id" => sid,
                   "workspace" => ws,
                   "mode" => "bounded_write"
                 })

        assert payload["evidence"]["mirror"]["status"] == "mirror_failed"
        assert payload["evidence"]["mirror"]["error"]["kind"] == "delegate_evidence_mirror_failed"
      after
        if previous_home,
          do: System.put_env("PIXIR_HOME", previous_home),
          else: System.delete_env("PIXIR_HOME")
      end
    end)
  end

  test "delegate status --json projects durable Subagent lifecycle without stderr" do
    in_tmp_workspace("pixir-cli-delegate-status", fn ws ->
      sid = "delegate-status-cli"
      child_sid = "delegate-status-child"
      {:ok, %{"delegate_id" => delegate_id}} = Pixir.Delegate.Handle.build(sid)

      write_raw_log(ws, sid, [
        raw_event(sid, 0, "user_message", %{"text" => "delegate"}),
        raw_event(sid, 1, "subagent_event", %{
          "subagent_id" => "sub_done",
          "child_session_id" => child_sid,
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => "inspect docs",
          "workspace_mode" => "shared",
          "workspace" => ws
        }),
        raw_event(sid, 2, "subagent_event", %{
          "subagent_id" => "sub_done",
          "child_session_id" => child_sid,
          "event" => "finished",
          "status" => "completed",
          "agent" => "explorer",
          "task" => "inspect docs",
          "workspace_mode" => "shared",
          "workspace" => ws,
          "summary" => "done"
        })
      ])

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok = CLI.route(["delegate", "status", delegate_id, "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok,
              %{
                "ok" => true,
                "status" => "completed",
                "kind" => "delegate_status",
                "schema_version" => 5,
                "schema" => "pixir.delegate.envelope.v1",
                "command_ok" => true,
                "work_complete" => true,
                "outcome" => "completed",
                "reason_code" => "completed",
                "delegate_id" => ^delegate_id,
                "parent_session_id" => ^sid,
                "session_id" => ^sid,
                "handle" => %{"input_kind" => "delegate_id"},
                "children" => [
                  %{
                    "subagent_id" => "sub_done",
                    "child_session_id" => ^child_sid,
                    "status" => "completed",
                    "outcome" => "completed",
                    "reason_code" => "completed",
                    "summary" => "done"
                  }
                ],
                "counts" => %{"completed" => 1, "total" => 1, "active" => 0},
                "host_boundary" => %{
                  "external_process_spawns" => 0,
                  "shell_polling" => false
                },
                "service_state" => "snapshot_only",
                "tree" => %{"event_count" => 3, "subagent_count" => 1}
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate status --json reports unknown sessions as structured not_found" do
    in_tmp_workspace("pixir-cli-delegate-status-missing", fn _ws ->
      stdout =
        capture_io(fn ->
          assert {:error, 2} = CLI.route(["delegate", "status", "missing-session", "--json"])
        end)

      assert {:ok, payload} = Jason.decode(stdout)

      assert %{
               "ok" => false,
               "status" => "rejected",
               "kind" => "not_found",
               "schema_version" => 5,
               "command_ok" => false,
               "work_complete" => false,
               "outcome" => "rejected",
               "reason_code" => "not_found",
               "details" => %{"session_id" => "missing-session"}
             } = payload

      refute Map.has_key?(payload, "children")
    end)
  end

  test "delegate attach --json returns one-shot durable snapshot without stderr" do
    in_tmp_workspace("pixir-cli-delegate-attach", fn ws ->
      sid = "delegate-attach-cli"

      write_raw_log(ws, sid, [
        raw_event(sid, 0, "user_message", %{"text" => "delegate"}),
        raw_event(sid, 1, "subagent_event", %{
          "subagent_id" => "sub_live",
          "child_session_id" => "child-live",
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => "inspect docs",
          "workspace_mode" => "shared",
          "workspace" => ws
        })
      ])

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok = CLI.route(["delegate", "attach", sid, "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok,
              %{
                "ok" => true,
                "status" => "running",
                "kind" => "delegate_attach",
                "schema_version" => 5,
                "schema" => "pixir.delegate.envelope.v1",
                "command_ok" => true,
                "work_complete" => false,
                "outcome" => "running",
                "reason_code" => "work_still_running",
                "service_state" => "snapshot_only",
                "session_id" => ^sid,
                "attach" => %{
                  "mode" => "one_shot_snapshot",
                  "streaming" => false,
                  "source" => "durable_session_log",
                  "service_state" => "snapshot_only"
                },
                "children" => [
                  %{
                    "subagent_id" => "sub_live",
                    "child_session_id" => "child-live",
                    "status" => "running",
                    "outcome" => "running",
                    "reason_code" => "work_still_running"
                  }
                ],
                "host_boundary" => %{
                  "external_process_spawns" => 0,
                  "shell_polling" => false
                }
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate attach --progress emits stderr JSONL and keeps stdout as one final JSON envelope" do
    in_tmp_workspace("pixir-cli-delegate-attach-progress", fn ws ->
      sid = "delegate-attach-progress-cli"

      write_raw_log(ws, sid, [
        raw_event(sid, 0, "user_message", %{"text" => "delegate"}),
        raw_event(sid, 1, "subagent_event", %{
          "subagent_id" => "sub_done",
          "child_session_id" => "child-done",
          "event" => "finished",
          "status" => "completed",
          "agent" => "explorer",
          "task" => "inspect docs",
          "workspace_mode" => "shared",
          "workspace" => ws
        })
      ])

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok =
                       CLI.route([
                         "delegate",
                         "attach",
                         sid,
                         "--progress=stderr-jsonl",
                         "--json"
                       ])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert_received {:delegate_stdout, stdout}

      frames =
        stderr
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert [
               %{
                 "type" => "delegate_terminal",
                 "kind" => "delegate_attach_progress",
                 "sequence" => 1,
                 "status" => "completed",
                 "complete" => true,
                 "terminal" => true,
                 "owner_backed" => false,
                 "source" => "durable_snapshot_after_daemon_fallback"
               }
             ] = frames

      assert {:ok,
              %{
                "ok" => true,
                "status" => "completed",
                "kind" => "delegate_attach",
                "session_id" => ^sid,
                "progress" => %{
                  "requested" => true,
                  "mode" => "stderr-jsonl",
                  "frame_count" => 1,
                  "owner_backed" => false,
                  "source" => "durable_snapshot_after_daemon_fallback",
                  "stdout_contract" => "one_final_json_envelope"
                },
                "attach" => %{
                  "progress" => %{
                    "frame_count" => 1,
                    "terminal_observed" => true
                  }
                },
                "daemon_fallback" => %{"used" => false},
                "host_boundary" => %{
                  "external_process_spawns" => 0,
                  "shell_polling" => false
                }
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate cancel --json is an honest no-op for terminal durable children" do
    in_tmp_workspace("pixir-cli-delegate-cancel-terminal", fn ws ->
      sid = "delegate-cancel-terminal"

      write_raw_log(ws, sid, [
        raw_event(sid, 0, "user_message", %{"text" => "delegate"}),
        raw_event(sid, 1, "subagent_event", %{
          "subagent_id" => "sub_done",
          "child_session_id" => "child-done",
          "event" => "finished",
          "status" => "completed",
          "agent" => "explorer",
          "task" => "done",
          "workspace" => ws
        })
      ])

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok = CLI.route(["delegate", "cancel", sid, "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok,
              %{
                "ok" => true,
                "status" => "completed",
                "kind" => "delegate_cancel",
                "service_state" => "snapshot_only",
                "cancelled_child_count" => 0,
                "durable_status_before" => "completed",
                "manager_child_counts_before" => %{"completed" => 1, "total" => 1}
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate status rejects ignored flags instead of accepting silent no-ops" do
    in_tmp_workspace("pixir-cli-delegate-status-flags", fn _ws ->
      stdout =
        capture_io(fn ->
          assert {:error, 2} =
                   CLI.route([
                     "delegate",
                     "status",
                     "session-id",
                     "--timeout-ms",
                     "1000",
                     "--json"
                   ])
        end)

      assert {:ok,
              %{
                "ok" => false,
                "kind" => "invalid_args",
                "details" => %{"unsupported_options" => ["--timeout-ms"]}
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate runtime rejects spec workspaces outside the caller workspace" do
    in_tmp_workspace("pixir-cli-delegate-workspace", fn _ws ->
      caller_workspace = File.cwd!()

      outside =
        Path.join(System.tmp_dir!(), "pixir-cli-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "should not run",
          "workspace" => outside
        })

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(spec, fn ->
              assert {:error, 2} = CLI.route(["delegate", "--spec", "-", "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok,
              %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" => %{
                  "workspace" => ^outside,
                  "caller_workspace" => ^caller_workspace,
                  "next_actions" => next_actions
                }
              }} = Jason.decode(stdout)

      assert "remove_spec_workspace_escape" in next_actions
    end)
  end

  test "delegate runtime rejects mixed-validity task lists instead of shrinking fanout" do
    in_tmp_workspace("pixir-cli-delegate-mixed-tasks", fn _ws ->
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "tasks" => ["valid task", 123]
        })

      stdout =
        capture_io(spec, fn ->
          assert {:error, 2} = CLI.route(["delegate", "--spec", "-", "--json"])
        end)

      assert {:ok,
              %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "message" => "subagents.tasks entries must be non-empty task strings"
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate runtime preserves spawned children when a later spawn fails" do
    spawn_agent = fn _parent_session_id, args, _opts ->
      case args["task"] do
        "first" ->
          {:ok,
           %{
             "id" => "sub_first",
             "child_session_id" => "child_first",
             "agent" => args["agent"],
             "status" => "running",
             "summary" => nil,
             "task" => args["task"],
             "workspace_mode" => args["workspace_mode"],
             "child_log_path" => nil,
             "next_actions" => []
           }}

        "second" ->
          {:error,
           %{
             ok: false,
             error: %{
               kind: :permission_denied,
               message: "blocked second spawn",
               details: %{task: args["task"]}
             }
           }}
      end
    end

    with_cli_turn_opts([spawn_agent: spawn_agent, skip_auth?: true], fn ->
      in_tmp_workspace("pixir-cli-delegate-partial-spawn", fn _ws ->
        spec =
          Jason.encode!(%{
            "contract_version" => 1,
            "strategy" => "subagents",
            "tasks" => ["first", "second"],
            "limits" => %{"timeout_ms" => 1}
          })

        stdout =
          capture_io(spec, fn ->
            assert {:error, 6} = CLI.route(["delegate", "--spec", "-", "--json"])
          end)

        assert {:ok,
                %{
                  "ok" => false,
                  "status" => "partial",
                  "kind" => "delegate_result",
                  "children" => [
                    %{
                      "subagent_id" => "sub_first",
                      "child_session_id" => "child_first",
                      "status" => "running"
                    }
                  ],
                  "spawn_failure" => %{
                    "kind" => "permission_denied",
                    "message" => "blocked second spawn"
                  },
                  "beam_coordination" => %{
                    "planned_child_count" => 2,
                    "spawned_child_count" => 1
                  },
                  "next_actions" => next_actions
                }} = Jason.decode(stdout)

        assert "inspect_spawn_failure" in next_actions
      end)
    end)
  end

  test "delegate terminal failure keeps parseable stdout and exits 6 by default" do
    provider_error =
      {:error,
       %{
         ok: false,
         error: %{
           kind: :network,
           message: "provider stream failed in child",
           details: %{transport: "test"}
         }
       }}

    with_cli_provider([provider_error], fn ->
      in_tmp_workspace("pixir-cli-delegate-fail-on-incomplete", fn _ws ->
        spec =
          Jason.encode!(%{
            "contract_version" => 1,
            "strategy" => "subagents",
            "task" => "fail from fake provider",
            "mode" => "read_only",
            "limits" => %{"timeout_ms" => 5_000}
          })

        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(spec, fn ->
                assert {:error, 6} =
                         CLI.route([
                           "delegate",
                           "--spec",
                           "-",
                           "--json"
                         ])
              end)

            send(self(), {:delegate_stdout, stdout})
          end)

        assert stderr == ""
        assert_received {:delegate_stdout, stdout}

        assert {:ok,
                %{
                  "ok" => false,
                  "status" => "failed",
                  "kind" => "delegate_result",
                  "children" => [%{"status" => "failed"}],
                  "next_actions" => next_actions
                }} = Jason.decode(stdout)

        assert is_list(next_actions)
      end)
    end)
  end

  test "delegate workflow runtime executes a read-only workflow" do
    with_cli_provider([stop("checkpoint_status: checkpoint_ready\nworkflow done")], fn ->
      in_tmp_workspace("pixir-cli-delegate-workflow", fn _ws ->
        spec =
          Jason.encode!(%{
            "contract_version" => 1,
            "strategy" => "workflow",
            "mode" => "read_only",
            "steps" => [
              %{"id" => "inspect", "task" => "read docs", "agent" => "explorer"}
            ]
          })

        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(spec, fn ->
                assert :ok = CLI.route(["delegate", "--spec", "-", "--json"])
              end)

            send(self(), {:delegate_stdout, stdout})
          end)

        assert stderr == ""
        assert_received {:delegate_stdout, stdout}

        assert {:ok,
                %{
                  "ok" => true,
                  "work_complete" => true,
                  "status" => "completed",
                  "kind" => "delegate_result",
                  "strategy" => "workflow",
                  "workflow_id" => workflow_id,
                  "children" => [
                    %{
                      "step_id" => "inspect",
                      "checkpoint_status" => "checkpoint_ready",
                      "status" => "completed"
                    }
                  ],
                  "held_steps" => [],
                  "failed_steps" => [],
                  "partial_steps" => [],
                  "needs_orchestrator_steps" => [],
                  "next_actions" => []
                }} = Jason.decode(stdout)

        assert is_binary(workflow_id)
      end)
    end)
  end

  test "delegate workflow bounded_write mutates allowlisted shared workspace and mirrors evidence" do
    with_pixir_home("pixir-cli-delegate-workflow-write-home", fn _home ->
      with_cli_provider(
        [
          tool_calls([
            %{
              call_id: "write_notes",
              name: "write",
              args: %{"path" => "notes/out.md", "content" => "bounded workflow wrote here\n"}
            }
          ]),
          stop("checkpoint_status: checkpoint_ready\nwrite done")
        ],
        fn ->
          in_tmp_workspace("pixir-cli-delegate-workflow-write", fn _ws ->
            File.mkdir_p!("notes")

            spec =
              Jason.encode!(%{
                "contract_version" => 1,
                "strategy" => "workflow",
                "mode" => "bounded_write",
                "write_policy" => %{
                  "version" => 1,
                  "metadata" => %{"id" => "workflow-write-test"},
                  "allow_writes" => ["notes/out.md"]
                },
                "steps" => [
                  %{
                    "id" => "write",
                    "task" => "write notes/out.md",
                    "agent" => "worker",
                    "workspace_mode" => "shared",
                    "write_set" => ["notes/out.md"]
                  }
                ]
              })

            stderr =
              capture_io(:stderr, fn ->
                stdout =
                  capture_io(spec, fn ->
                    assert :ok = CLI.route(["delegate", "--spec", "-", "--json"])
                  end)

                send(self(), {:delegate_stdout, stdout})
              end)

            assert stderr == ""
            assert_received {:delegate_stdout, stdout}

            assert File.read!("notes/out.md") == "bounded workflow wrote here\n"

            assert {:ok,
                    %{
                      "ok" => true,
                      "work_complete" => true,
                      "status" => "completed",
                      "kind" => "delegate_result",
                      "strategy" => "workflow",
                      "mode" => "bounded_write",
                      "write_policy" => %{"id" => "workflow-write-test"},
                      "write_destination" => %{
                        "writes_applied_to" => "workspace",
                        "contract_status" => "repo_mutating_success"
                      },
                      "children" => [
                        %{
                          "step_id" => "write",
                          "checkpoint_status" => "checkpoint_ready",
                          "status" => "completed",
                          "workspace_mode" => "shared",
                          "writes_applied_to" => "workspace",
                          "write_policy" => %{"allow_writes" => ["notes/out.md"]}
                        }
                      ],
                      "evidence" => %{
                        "mirror" => %{
                          "required" => true,
                          "status" => "mirrored",
                          "outside_workspace" => true
                        }
                      },
                      "limits" => %{
                        "workflow_mode" => "bounded_write",
                        "write_policy" => %{"id" => "workflow-write-test"}
                      }
                    }} = Jason.decode(stdout)
          end)
        end
      )
    end)
  end

  test "delegate workflow runtime preserves partial and held step evidence" do
    with_cli_turn_opts([provider: WorkflowPartialProvider, skip_auth?: true], fn ->
      in_tmp_workspace("pixir-cli-delegate-workflow-partial", fn _ws ->
        spec =
          Jason.encode!(%{
            "contract_version" => 1,
            "strategy" => "workflow",
            "mode" => "read_only",
            "max_concurrency" => 2,
            "steps" => [
              %{"id" => "fail", "task" => "fail", "agent" => "explorer"},
              %{
                "id" => "held",
                "task" => "held",
                "agent" => "explorer",
                "depends_on" => ["fail"]
              }
            ]
          })

        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(spec, fn ->
                assert {:error, 6} = CLI.route(["delegate", "--spec", "-", "--json"])
              end)

            send(self(), {:delegate_stdout, stdout})
          end)

        assert stderr == ""
        assert_received {:delegate_stdout, stdout}

        assert {:ok,
                %{
                  "ok" => false,
                  "work_complete" => false,
                  "status" => "partial",
                  "kind" => "delegate_result",
                  "strategy" => "workflow",
                  "children" => children,
                  "failed_steps" => [%{"id" => "fail", "checkpoint_status" => "failed"}],
                  "held_steps" => [%{"id" => "held", "checkpoint_status" => "held"}],
                  "safe_next_actions" => safe_next_actions,
                  "next_actions" => next_actions
                }} = Jason.decode(stdout)

        refute Enum.any?([safe_next_actions, next_actions], &is_nil/1)
        assert "retry_failed_steps" in next_actions
        assert Enum.any?(children, &(&1["step_id"] == "fail" and &1["status"] == "failed"))
        assert Enum.any?(children, &(&1["step_id"] == "held" and &1["status"] == "held"))
      end)
    end)
  end

  test "delegate invalid spec emits structured JSON when --json is requested" do
    in_tmp_workspace("pixir-cli-delegate-invalid", fn ws ->
      spec_path = Path.join(ws, "delegate.json")
      File.write!(spec_path, Jason.encode!(%{"task" => "missing strategy"}))

      stdout =
        capture_io(fn ->
          assert {:error, 2} =
                   CLI.route(["delegate", "--spec", spec_path, "--dry-run", "--json"])
        end)

      assert {:ok,
              %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "contract_version" => 1,
                "host_boundary" => %{"external_process_spawns" => 0}
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate invalid timeout reports the actual source path" do
    in_tmp_workspace("pixir-cli-delegate-invalid-timeout", fn ws ->
      spec_path = Path.join(ws, "delegate.json")

      File.write!(
        spec_path,
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "inspect docs",
          "subagents" => %{"count" => 1, "timeout_ms" => "soon"}
        })
      )

      stdout =
        capture_io(fn ->
          assert {:error, 2} = CLI.route(["delegate", "--spec", spec_path, "--json"])
        end)

      assert {:ok,
              %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" => %{
                  "field" => "subagents.timeout_ms",
                  "next_actions" => ["set_subagents_timeout_ms_to_a_positive_integer"]
                }
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate malformed stdin JSON emits JSON on stdout and nothing on stderr" do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io("{not-json", fn ->
            assert {:error, 2} = CLI.route(["delegate", "--spec", "-", "--dry-run", "--json"])
          end)

        send(self(), {:delegate_stdout, stdout})
      end)

    assert stderr == ""
    assert_received {:delegate_stdout, stdout}

    assert {:ok,
            %{
              "ok" => false,
              "status" => "rejected",
              "kind" => "invalid_json",
              "contract_version" => 1
            }} = Jason.decode(stdout)
  end

  test "delegate start --spec --json requires a resident daemon owner" do
    in_tmp_workspace("pixir-cli-delegate-start", fn ws ->
      spec_path = Path.join(ws, "delegate.json")

      File.write!(
        spec_path,
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "answer from fake provider",
          "mode" => "read_only",
          "subagents" => %{"role" => "explorer", "count" => 1},
          "limits" => %{"timeout_ms" => 5_000}
        })
      )

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert {:error, 5} =
                       CLI.route(["delegate", "start", "--spec", spec_path, "--json"])
            end)

          send(self(), {:delegate_stdout, stdout})
        end)

      assert stderr == ""
      assert_received {:delegate_stdout, stdout}

      assert {:ok,
              %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "daemon_required",
                "details" => %{
                  "reason" => "start_without_resident_owner_would_not_survive_cli_process_exit",
                  "daemon_error" => %{"kind" => "daemon_unavailable"}
                }
              }} = Jason.decode(stdout)
    end)
  end

  test "delegate unsupported contract version preserves next actions" do
    spec = Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "x"})

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(spec, fn ->
            assert {:error, 2} =
                     CLI.route([
                       "delegate",
                       "--spec",
                       "-",
                       "--dry-run",
                       "--json",
                       "--contract-version",
                       "2"
                     ])
          end)

        send(self(), {:delegate_stdout, stdout})
      end)

    assert stderr == ""
    assert_received {:delegate_stdout, stdout}

    assert {:ok,
            %{
              "ok" => false,
              "status" => "unsupported",
              "kind" => "unsupported_contract_version",
              "details" => %{
                "observed" => 2,
                "supported" => [1],
                "next_actions" => ["set_contract_version_to_1"]
              }
            }} = Jason.decode(stdout)
  end

  test "delegate empty positional argument returns structured JSON instead of crashing" do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            assert {:error, 2} = CLI.route(["delegate", "", "--json"])
          end)

        send(self(), {:delegate_stdout, stdout})
      end)

    assert stderr == ""
    assert_received {:delegate_stdout, stdout}

    assert {:ok,
            %{
              "ok" => false,
              "status" => "rejected",
              "kind" => "invalid_args",
              "details" => %{"argument" => ""}
            }} = Jason.decode(stdout)
  end

  test "delegate scaffolding TODO roadmap is searchable" do
    source =
      [
        "lib/pixir/delegate.ex",
        "lib/pixir/delegate/cli_contract.ex"
      ]
      |> Enum.map_join("\n", &File.read!/1)

    for marker <- [
          "TODO(delegate-runner)",
          "TODO(delegate-async)",
          "TODO(delegate-handle)",
          "TODO(delegate-progress)",
          "TODO(delegate-artifacts)"
        ] do
      assert source =~ marker
    end
  end

  test "resume --help is self-describing" do
    out = capture_io(fn -> assert :ok = CLI.route(["resume", "--help"]) end)
    assert out =~ "continue a persisted Session"
  end

  test "mutation-free legacy resume is read-only and denies a live write" do
    with_cli_provider(
      [
        tool_calls([
          %{
            call_id: "legacy-write",
            name: "write",
            args: %{"path" => "blocked.txt", "content" => "must not write"}
          }
        ]),
        stop("turn completes after the denied write")
      ],
      fn ->
        in_tmp_workspace("pixir-cli-legacy-resume-read-only", fn ws ->
          sid = "legacy-mutation-free"
          old = Event.user_message(sid, "legacy prompt") |> Event.with_seq(0)
          assert {:ok, ^old} = Log.append(old, workspace: ws)

          # The resume turn completes (the model adapts after the denied tool
          # call), but the mutation-free legacy Log resumes read-only: the write
          # is denied at the mode gate and no file lands.
          capture_io(fn ->
            assert :ok = CLI.route(["--json", "resume", sid, "attempt a write"])
          end)

          refute File.exists?(Path.join(ws, "blocked.txt"))

          {:ok, history} = Log.fold(sid, workspace: ws)

          assert Enum.any?(history, fn event ->
                   event.type == :permission_decision and
                     event.data["call_id"] == "legacy-write" and
                     event.data["decision"] == "deny"
                 end)
        end)
      end
    )
  end

  test "failed legacy-root attestation stops the started Session and releases its lease" do
    with_cli_provider([stop("must not run")], fn ->
      in_tmp_workspace("pixir-cli-attestation-lease-cleanup", fn ws ->
        sid = "legacy-attestation-failure"

        event =
          Event.tool_call(sid, "legacy-write", "write", %{
            "path" => "blocked.txt",
            "content" => "x"
          })
          |> Event.with_seq(0)

        assert {:ok, [_]} = Log.create_session(sid, [event], workspace: ws)
        test_pid = self()

        Application.put_env(:pixir, :cli_attestation_recorder, fn session_id, _event ->
          send(
            test_pid,
            {:attestation_attempt, File.exists?(Paths.session_lease(session_id, ws))}
          )

          {:error, Pixir.Tool.error(:log_write_failed, "injected attestation failure", %{})}
        end)

        try do
          capture_io(fn ->
            capture_io(:stderr, fn ->
              assert {:error, 1} =
                       CLI.route(
                         [
                           "--json",
                           "resume",
                           "--assume-legacy-root",
                           "--legacy-root-reason",
                           "test injection",
                           sid,
                           "continue"
                         ],
                         :read_only
                       )
            end)
          end)

          assert_receive {:attestation_attempt, true}
          refute File.exists?(Paths.session_lease(sid, ws))
          assert Registry.lookup(Pixir.Sessions.Registry, sid) == []
        after
          Application.delete_env(:pixir, :cli_attestation_recorder)
        end
      end)
    end)
  end

  test "resume with no id is a usage error (exit code 2)" do
    err = capture_io(:stderr, fn -> assert {:error, 2} = CLI.route(["resume"]) end)
    assert err =~ "usage: pixir resume"
  end

  test "resume force-release reason requires the force-release flag" do
    err =
      capture_io(:stderr, fn ->
        assert {:error, 2} =
                 CLI.route(["resume", "--force-release-reason", "why", "session-id", "prompt"])
      end)

    assert err =~ "--force-release-reason requires --force-release-writer-lease"
  end

  test "resume refuses active writer lease with exit code 5" do
    with_cli_provider([stop("should not run")], fn ->
      in_tmp_workspace("pixir-cli-resume-active-lease", fn _ws ->
        workspace = File.cwd!()
        sid = "cli-active-writer"
        old = Event.user_message(sid, "old") |> Event.with_seq(0)
        assert {:ok, ^old} = Log.append(old, workspace: workspace)
        lease_path = Paths.session_lease(sid, workspace)
        Paths.ensure_session_leases_dir(workspace)

        File.write!(
          lease_path,
          Jason.encode!(%{
            "version" => 1,
            "purpose" => "session_writer",
            "session_id" => sid,
            "workspace" => workspace,
            "lease_path" => lease_path,
            "holder_id" => "active_cli_holder",
            "heartbeat_at_ms" => System.system_time(:millisecond),
            "heartbeat_at" => "2026-01-01T00:00:00Z",
            "stale_after_ms" => 60_000
          })
        )

        stdout =
          capture_io(fn ->
            assert {:error, 5} = CLI.route(["--json", "resume", sid, "continue"])
          end)

        assert %{
                 "ok" => false,
                 "error" => %{
                   "kind" => "session_writer_active",
                   "details" => %{"lease" => %{"state" => "active"}}
                 }
               } = Jason.decode!(stdout)

        refute stdout =~ "should not run"
      end)
    end)
  end

  test "resume forced-release flag clears stale writer lease before starting" do
    with_cli_provider([stop("resumed answer")], fn ->
      in_tmp_workspace("pixir-cli-resume-force-lease", fn ws ->
        sid = "cli-stale-writer"
        old = Event.user_message(sid, "old") |> Event.with_seq(0)
        assert {:ok, ^old} = Log.append(old, workspace: ws)

        lease_path = Paths.session_lease(sid, ws)
        Paths.ensure_session_leases_dir(ws)

        File.write!(
          lease_path,
          Jason.encode!(%{
            "version" => 1,
            "purpose" => "session_writer",
            "session_id" => sid,
            "workspace" => Path.expand(ws),
            "lease_path" => lease_path,
            "holder_id" => "stale_cli_holder",
            "heartbeat_at_ms" => System.system_time(:millisecond) - 60_000,
            "heartbeat_at" => "2026-01-01T00:00:00Z",
            "stale_after_ms" => 1
          })
        )

        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(fn ->
                assert :ok =
                         CLI.route([
                           "resume",
                           "--force-release-writer-lease",
                           "--force-release-reason",
                           "cli_test",
                           sid,
                           "continue"
                         ])
              end)

            send(self(), {:stdout, stdout})
          end)

        assert_received {:stdout, stdout}
        assert String.trim(stdout) == "resumed answer"
        assert stderr =~ "session #{sid}"

        assert [release_record] =
                 Path.wildcard(Path.join([ws, ".pixir", "session_leases", "releases", "*.json"]))

        assert %{"reason" => "cli_test"} = release_record |> File.read!() |> Jason.decode!()

        case Registry.lookup(Pixir.Sessions.Registry, sid) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(Pixir.SessionSupervisor, pid)
          [] -> :ok
        end
      end)
    end)
  end

  test "main releases resume writer lease before halting on clean completion" do
    with_cli_halt(fn ->
      with_cli_provider([stop("resumed answer")], fn ->
        in_tmp_workspace("pixir-main-resume-lease-cleanup", fn ws ->
          sid = "cli-main-resume-clean"
          old = Event.user_message(sid, "old") |> Event.with_seq(0)
          assert {:ok, ^old} = Log.append(old, workspace: ws)

          stderr =
            capture_io(:stderr, fn ->
              stdout =
                capture_io(fn ->
                  assert {:pixir_cli_halt, 0} =
                           catch_throw(CLI.main(["resume", sid, "continue"]))
                end)

              send(self(), {:stdout, stdout})
            end)

          assert_received {:stdout, stdout}
          assert String.trim(stdout) == "resumed answer"
          assert stderr =~ "session #{sid}"
          assert [] = session_lease_files(ws)
        end)
      end)
    end)
  end

  test "main leaves stale writer lease fail-closed when resume is refused" do
    with_cli_halt(fn ->
      with_cli_provider([stop("should not run")], fn ->
        in_tmp_workspace("pixir-main-resume-stale-lease", fn _ws ->
          workspace = File.cwd!()
          sid = "cli-main-stale-writer"
          old = Event.user_message(sid, "old") |> Event.with_seq(0)
          assert {:ok, ^old} = Log.append(old, workspace: workspace)

          lease_path = Paths.session_lease(sid, workspace)
          Paths.ensure_session_leases_dir(workspace)

          File.write!(
            lease_path,
            Jason.encode!(%{
              "version" => 1,
              "purpose" => "session_writer",
              "session_id" => sid,
              "workspace" => workspace,
              "lease_path" => lease_path,
              "holder_id" => "stale_cli_holder",
              "heartbeat_at_ms" => System.system_time(:millisecond) - 60_000,
              "heartbeat_at" => "2026-01-01T00:00:00Z",
              "stale_after_ms" => 1
            })
          )

          stdout =
            capture_io(fn ->
              assert {:pixir_cli_halt, 5} =
                       catch_throw(CLI.main(["--json", "resume", sid, "continue"]))
            end)

          assert %{"ok" => false, "error" => %{"kind" => "session_writer_stale"}} =
                   Jason.decode!(stdout)

          assert File.exists?(lease_path)
          assert [_lease] = session_lease_files(workspace)
          refute stdout =~ "should not run"
        end)
      end)
    end)
  end

  test "one-shot returns ok only when the turn completes cleanly" do
    with_cli_provider([stop("clean answer")], fn ->
      in_tmp_workspace("pixir-cli-success", fn _ws ->
        err =
          capture_io(:stderr, fn ->
            out = capture_io(fn -> assert :ok = CLI.route(["hello"]) end)
            send(self(), {:stdout, out})
          end)

        assert_received {:stdout, out}
        assert String.trim(out) == "clean answer"
        assert err =~ "session"
        assert err =~ "resume with"
      end)
    end)
  end

  test "main releases one-shot writer lease before halting on clean completion" do
    with_cli_halt(fn ->
      with_cli_provider([stop("clean answer")], fn ->
        in_tmp_workspace("pixir-main-oneshot-lease-cleanup", fn ws ->
          stderr =
            capture_io(:stderr, fn ->
              stdout =
                capture_io(fn ->
                  assert {:pixir_cli_halt, 0} = catch_throw(CLI.main(["hello"]))
                end)

              send(self(), {:stdout, stdout})
            end)

          assert_received {:stdout, stdout}
          assert String.trim(stdout) == "clean answer"
          assert stderr =~ "resume with"
          assert [] = session_lease_files(ws)
        end)
      end)
    end)
  end

  test "one-shot --ask fails fast without an interactive TTY before provider work" do
    with_cli_provider([stop("should not run")], fn ->
      with_cli_interactive(false, fn ->
        in_tmp_workspace("pixir-cli-headless-ask", fn ws ->
          err =
            capture_io(:stderr, fn ->
              out = capture_io(fn -> assert {:error, 3} = CLI.route(["hello"], :ask) end)
              send(self(), {:stdout, out})
            end)

          assert_received {:stdout, out}
          assert out == ""
          assert err =~ "--ask requires an interactive TTY"
          assert err =~ "permission_denied"
          assert Path.wildcard(Path.join([ws, ".pixir", "sessions", "*.ndjson"])) == []
        end)
      end)
    end)
  end

  test "one-shot --json --write-policy reports policy file errors as JSON before auth" do
    in_tmp_workspace("pixir-cli-policy-json-error", fn _ws ->
      File.write!("policy.json", "{")

      out =
        capture_io(fn ->
          assert {:error, 2} = CLI.route(["--json", "--write-policy", "policy.json", "hello"])
        end)

      payload = Jason.decode!(out)
      assert payload["ok"] == false
      assert payload["error"]["kind"] == "invalid_args"
      assert payload["error"]["message"] =~ "not valid JSON"
    end)
  end

  test "--write-policy emits JSON errors even when --json appears later" do
    in_tmp_workspace("pixir-cli-policy-json-order", fn _ws ->
      File.write!("policy.json", "{")

      out =
        capture_io(fn ->
          assert {:error, 2} = CLI.route(["--write-policy", "policy.json", "--json", "hello"])
        end)

      payload = Jason.decode!(out)
      assert payload["ok"] == false
      assert payload["error"]["kind"] == "invalid_args"
      assert payload["error"]["message"] =~ "not valid JSON"
    end)
  end

  test "--write-policy is not silently ignored by non-turn subcommands" do
    in_tmp_workspace("pixir-cli-policy-subcommand", fn _ws ->
      File.write!(
        "policy.json",
        Jason.encode!(%{"version" => 1, "allow_writes" => ["allowed/**"]})
      )

      out =
        capture_io(fn ->
          assert {:error, 2} = CLI.route(["--json", "--write-policy", "policy.json", "doctor"])
        end)

      payload = Jason.decode!(out)
      assert payload["ok"] == false
      assert payload["error"]["kind"] == "invalid_args"
      assert payload["error"]["details"]["command"] == "doctor"
    end)
  end

  test "--write-policy requires auto permission mode" do
    in_tmp_workspace("pixir-cli-policy-mode", fn _ws ->
      File.write!(
        "policy.json",
        Jason.encode!(%{"version" => 1, "allow_writes" => ["allowed/**"]})
      )

      out =
        capture_io(fn ->
          assert {:error, 2} =
                   CLI.route(["--json", "--write-policy", "policy.json", "hello"], :read_only)
        end)

      payload = Jason.decode!(out)
      assert payload["ok"] == false
      assert payload["error"]["kind"] == "invalid_args"
      assert payload["error"]["details"]["mode"] == "read_only"
    end)
  end

  test "one-shot --bash-timeout-ms propagates bounded timeout metadata to bash" do
    with_pixir_home("pixir-cli-bash-timeout", fn _home ->
      with_cli_provider(
        [
          tool_calls([
            %{call_id: "call_bash", name: "bash", args: %{"command" => "echo hi"}}
          ]),
          stop("done")
        ],
        fn ->
          in_tmp_workspace("pixir-cli-bash-timeout", fn ws ->
            out =
              capture_io(fn ->
                assert :ok = CLI.route(["--json", "--bash-timeout-ms", "250", "run bash"])
              end)

            assert %{"ok" => true, "session_id" => sid} = Jason.decode!(out)
            assert {:ok, history} = Log.fold(sid, workspace: ws)

            result =
              Enum.find(
                history,
                &(&1.type == :tool_result and &1.data["call_id"] == "call_bash")
              )

            assert result.data["timeout"] == %{
                     "requested_ms" => 250,
                     "configured_ms" => 250,
                     "effective_ms" => 250,
                     "max_ms" => 600_000,
                     "source" => "cli",
                     "capped" => false
                   }
          end)
        end
      )
    end)
  end

  test "--bash-timeout-ms rejects values above the configured cap as JSON" do
    with_pixir_home("pixir-cli-bash-timeout-cap", fn _home ->
      out =
        capture_io(fn ->
          assert {:error, 2} =
                   CLI.route(["--json", "--bash-timeout-ms", "600001", "run bash"])
        end)

      assert %{
               "ok" => false,
               "error" => %{
                 "kind" => "invalid_args",
                 "details" => %{
                   "max_timeout_ms" => 600_000,
                   "next_actions" => next_actions
                 }
               }
             } = Jason.decode!(out)

      assert "increase_bash_timeout_max_ms_in_config_if_needed" in next_actions
    end)
  end

  test "--bash-timeout-ms emits JSON errors even when --json appears later" do
    with_pixir_home("pixir-cli-bash-timeout-json-order", fn _home ->
      out =
        capture_io(fn ->
          assert {:error, 2} =
                   CLI.route(["--bash-timeout-ms", "not-int", "--json", "run bash"])
        end)

      assert %{
               "ok" => false,
               "error" => %{
                 "kind" => "invalid_args",
                 "details" => %{"value" => "not-int"}
               }
             } = Jason.decode!(out)
    end)
  end

  test "--bash-timeout-ms is not silently ignored by non-turn subcommands" do
    with_pixir_home("pixir-cli-bash-timeout-subcommand", fn _home ->
      out =
        capture_io(fn ->
          assert {:error, 2} = CLI.route(["--json", "--bash-timeout-ms", "500", "doctor"])
        end)

      payload = Jason.decode!(out)
      assert payload["ok"] == false
      assert payload["error"]["kind"] == "invalid_args"
      assert payload["error"]["details"]["command"] == "doctor"
    end)
  end

  test "one-shot --json --write-policy emits terminal policy denial envelope" do
    with_cli_provider(
      [
        tool_calls([
          %{
            call_id: "c",
            name: "write",
            args: %{"path" => "blocked.txt", "content" => "no"}
          }
        ]),
        stop("should not run")
      ],
      fn ->
        in_tmp_workspace("pixir-cli-policy-terminal", fn ws ->
          File.write!(
            "policy.json",
            Jason.encode!(%{
              "version" => 1,
              "metadata" => %{"id" => "cli-test"},
              "allow_writes" => ["allowed/**"]
            })
          )

          out =
            capture_io(fn ->
              assert {:error, 3} =
                       CLI.route(["--json", "--write-policy", "policy.json", "write"])
            end)

          payload = Jason.decode!(out)
          assert payload["ok"] == false
          assert payload["status"] == "error"
          assert payload["exit_code"] == 3
          assert payload["error_kind"] == "write_policy_denied"
          assert payload["details"]["policy_id"] == "cli-test"
          assert payload["diagnostics"]["diagnose_command"] =~ "pixir diagnose session"
          refute File.exists?(Path.join(ws, "blocked.txt"))
        end)
      end
    )
  end

  test "resume --ask fails fast without an interactive TTY before session lookup" do
    with_cli_turn_opts([skip_auth?: true], fn ->
      with_cli_interactive(false, fn ->
        in_tmp_workspace("pixir-cli-headless-ask-resume", fn ws ->
          err =
            capture_io(:stderr, fn ->
              out =
                capture_io(fn ->
                  assert {:error, 3} = CLI.route(["resume", "missing-session", "hello"], :ask)
                end)

              send(self(), {:stdout, out})
            end)

          assert_received {:stdout, out}
          assert out == ""
          assert err =~ "--ask requires an interactive TTY"
          assert err =~ "permission_denied"
          assert Path.wildcard(Path.join([ws, ".pixir", "sessions", "*.ndjson"])) == []
        end)
      end)
    end)
  end

  test "one-shot emits only the final answer on stdout and exits without interactive readiness" do
    with_cli_provider([stop("final report")], fn ->
      in_tmp_workspace("pixir-cli-oneshot-contract", fn ws ->
        err =
          capture_io(:stderr, fn ->
            out = capture_io("", fn -> assert :ok = CLI.route(["hello"]) end)
            send(self(), {:stdout, out})
          end)

        assert_received {:stdout, out}
        assert out == "final report\n"
        refute err =~ "[y/N]"
        assert err =~ "resume with"

        sid = only_session_id!(ws)
        assert {:ok, history} = Log.fold(sid, workspace: ws)
        assert Enum.count(history, &(&1.type == :user_message)) == 1
        assert Enum.count(history, &(&1.type == :assistant_message)) == 1
      end)
    end)
  end

  test "one-shot flushes a final assistant message the stream never delivered as deltas" do
    with_cli_provider([{:no_delta, stop("undelivered final report")}], fn ->
      in_tmp_workspace("pixir-cli-oneshot-flush", fn _ws ->
        err =
          capture_io(:stderr, fn ->
            out = capture_io(fn -> assert :ok = CLI.route(["hello"]) end)
            send(self(), {:stdout, out})
          end)

        assert_received {:stdout, out}
        assert out == "undelivered final report\n"
        assert err =~ "resume with"
      end)
    end)
  end

  test "one-shot emits the authoritative final report when deltas mismatch the final text" do
    with_cli_provider(
      [{:deltas_then_final, "garbled partial", "authoritative final report"}],
      fn ->
        in_tmp_workspace("pixir-cli-oneshot-mismatch", fn ws ->
          err =
            capture_io(:stderr, fn ->
              out = capture_io(fn -> assert :ok = CLI.route(["hello"]) end)
              send(self(), {:stdout, out})
            end)

          assert_received {:stdout, out}
          assert String.ends_with?(out, "\nauthoritative final report\n")
          assert err =~ "resume with"

          sid = only_session_id!(ws)
          assert {:ok, history} = Log.fold(sid, workspace: ws)

          assert [%{data: %{"text" => "authoritative final report"}}] =
                   Enum.filter(history, &(&1.type == :assistant_message))
        end)
      end
    )
  end

  test "one-shot done without a final assistant message is an honest incomplete (exit 6)" do
    with_cli_provider([stop("")], fn ->
      in_tmp_workspace("pixir-cli-oneshot-incomplete", fn ws ->
        err =
          capture_io(:stderr, fn ->
            out = capture_io(fn -> assert {:error, 6} = CLI.route(["hello"]) end)
            send(self(), {:stdout, out})
          end)

        assert_received {:stdout, out}
        assert String.trim(out) == ""
        assert err =~ "[completed without a final assistant message]"

        sid = only_session_id!(ws)
        assert err =~ "pixir diagnose session #{sid} --json"
        assert err =~ "resume with: pixir resume #{sid}"
      end)
    end)
  end

  test "one-shot idle timeout exits 124 with exact resume guidance on stderr" do
    with_cli_provider(
      [{:sleep, 300, stop("late answer")}],
      fn ->
        in_tmp_workspace("pixir-cli-oneshot-timeout", fn ws ->
          err =
            capture_io(:stderr, fn ->
              out = capture_io(fn -> assert {:error, 124} = CLI.route(["hello"]) end)
              send(self(), {:stdout, out})
            end)

          assert_received {:stdout, out}
          assert String.trim(out) == ""
          assert err =~ "[timed out waiting for the model]"

          sid = only_session_id!(ws)
          assert err =~ "inspect evidence with: pixir diagnose session #{sid} --json"
          assert err =~ "resume with: pixir resume #{sid}"

          # Let the scripted turn finish before the tmp workspace is removed.
          Process.sleep(400)
        end)
      end,
      idle_timeout: 50
    )
  end

  test "main releases writer lease on handled idle timeout before halting" do
    with_cli_halt(fn ->
      with_cli_provider(
        [{:sleep, 300, stop("late answer")}],
        fn ->
          in_tmp_workspace("pixir-main-oneshot-timeout-lease-cleanup", fn ws ->
            stderr =
              capture_io(:stderr, fn ->
                stdout =
                  capture_io(fn ->
                    assert {:pixir_cli_halt, 124} = catch_throw(CLI.main(["hello"]))
                  end)

                send(self(), {:stdout, stdout})
              end)

            assert_received {:stdout, stdout}
            assert String.trim(stdout) == ""
            assert stderr =~ "[timed out waiting for the model]"

            sid = only_session_id!(ws)
            assert stderr =~ "resume with: pixir resume #{sid}"
            assert [] = session_lease_files(ws)
          end)
        end,
        idle_timeout: 50
      )
    end)
  end

  test "main releases writer lease on handled SIGINT interrupt before halting" do
    with_cli_halt(fn ->
      with_cli_provider(
        [{:interrupt_after, 25}],
        fn ->
          in_tmp_workspace("pixir-main-oneshot-sigint-lease-cleanup", fn ws ->
            stderr =
              capture_io(:stderr, fn ->
                stdout =
                  capture_io(fn ->
                    assert {:pixir_cli_halt, 130} = catch_throw(CLI.main(["hello"]))
                  end)

                send(self(), {:stdout, stdout})
              end)

            assert_received {:stdout, stdout}
            assert String.trim(stdout) == ""
            assert stderr =~ "[interrupted]"

            sid = only_session_id!(ws)
            assert stderr =~ "resume with: pixir resume #{sid}"
            assert [] = session_lease_files(ws)
          end)
        end,
        idle_timeout: 2_000
      )
    end)
  end

  test "one-shot --json idle timeout includes deterministic recovery guidance" do
    with_cli_provider(
      [{:sleep, 300, stop("late answer")}],
      fn ->
        in_tmp_workspace("pixir-cli-json-oneshot-timeout", fn ws ->
          out = capture_io(fn -> assert {:error, 124} = CLI.route(["--json", "hello"]) end)
          payload = Jason.decode!(out)

          sid = only_session_id!(ws)
          assert payload["ok"] == false
          assert payload["status"] == "timed_out"
          assert payload["exit_code"] == 124
          assert payload["resume_command"] =~ "pixir resume #{sid}"

          assert payload["diagnostics"]["diagnose_command"] ==
                   "pixir diagnose session #{sid} --json"

          assert payload["recovery"]["classification"] == "presenter_idle_timeout"
          assert payload["recovery"]["resume_command"] == payload["resume_command"]
          assert payload["recovery"]["auto_retry"]["safe"] == false

          # Let the scripted turn finish before the tmp workspace is removed.
          Process.sleep(400)
        end)
      end,
      idle_timeout: 50
    )
  end

  test "one-shot exits nonzero when the turn records a provider failure" do
    error =
      {:error,
       %{
         ok: false,
         error: %{kind: :provider_http_error, message: "boom", details: %{}}
       }}

    with_cli_provider([error], fn ->
      in_tmp_workspace("pixir-cli-provider-error", fn ws ->
        err =
          capture_io(:stderr, fn ->
            out = capture_io(fn -> assert {:error, 1} = CLI.route(["hello"]) end)
            send(self(), {:stdout, out})
          end)

        assert_received {:stdout, out}
        assert out =~ "boom"
        assert err =~ "session"
        assert err =~ "resume with"

        sid = only_session_id!(ws)
        assert {:ok, history} = Log.fold(sid, workspace: ws)
        assert Enum.any?(history, &(&1.type == :turn_failed))
      end)
    end)
  end

  test "models reports source honesty without network and refresh emits one JSON envelope" do
    with_pixir_home("pixir-cli-models", fn home ->
      config_path = Path.join(home, "config.json")

      File.write!(
        config_path,
        Jason.encode!(%{
          "anthropic_models" => ["claude-cli-config"],
          "models_refreshed_at" => "2026-01-02T03:04:05Z"
        })
      )

      catalog_output = capture_io(fn -> assert :ok = CLI.route(["models", "--json"]) end)
      catalog = Jason.decode!(catalog_output)
      assert catalog["kind"] == "models_catalog"
      assert catalog["providers"]["openai"]["source"] == "built_in"
      assert catalog["providers"]["anthropic"]["source"] == "config_override"
      assert catalog["models_refreshed_at"] == "2026-01-02T03:04:05Z"

      auth_name = :"cli_models_auth_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Pixir.Auth.start_link(
          name: auth_name,
          store_path: Path.join(home, "isolated-auth.json"),
          env_api_key: "sk-cli"
        )

      http = fn request ->
        send(self(), {:models_http, request.url})
        {:ok, %{status: 200, body: Jason.encode!(%{"data" => [%{"id" => "gpt-cli"}]})}}
      end

      with_cli_turn_opts(
        [
          models_refresh_opts: [
            config_path: config_path,
            auth: auth_name,
            env: fn _ -> nil end,
            http: http,
            now: ~U[2026-03-10 00:00:00Z]
          ]
        ],
        fn ->
          refresh_output =
            capture_io(fn -> assert :ok = CLI.route(["models", "refresh", "--json"]) end)

          refresh = Jason.decode!(refresh_output)
          assert refresh["kind"] == "models_refresh"
          assert refresh["providers"]["openai"]["status"] == "refreshed"
          assert refresh["providers"]["anthropic"]["reason"] == "no_credential"
          assert refresh["wrote_config"] == true
          assert_received {:models_http, "https://api.openai.com/v1/models"}
        end
      )
    end)
  end

  test "models rejects unknown arguments with exit 2" do
    assert {:error, 2} = CLI.route(["models", "surprise"])

    output =
      capture_io(fn -> assert {:error, 2} = CLI.route(["models", "surprise", "--json"]) end)

    envelope = Jason.decode!(output)
    assert envelope["status"] == "invalid_args"
    assert envelope["next_actions"] == ["remove_unsupported_models_arguments"]
  end

  test "one-shot exits nonzero even when failed provider stream preserved partial text" do
    error =
      {:error,
       %{
         ok: false,
         error: %{
           kind: :network,
           message: "Provider stream process exited.",
           details: %{transport: "websocket"}
         }
       }}

    with_cli_provider([{:delta_then_error, "Useful partial answer.", error}], fn ->
      in_tmp_workspace("pixir-cli-partial-provider-error", fn ws ->
        err =
          capture_io(:stderr, fn ->
            out = capture_io(fn -> assert {:error, 1} = CLI.route(["hello"]) end)
            send(self(), {:stdout, out})
          end)

        assert_received {:stdout, out}
        assert String.trim(out) == "Useful partial answer."
        assert err =~ "session"
        assert err =~ "resume with"

        sid = only_session_id!(ws)
        assert {:ok, history} = Log.fold(sid, workspace: ws)

        assert [%{data: %{"metadata" => metadata}}] =
                 Enum.filter(history, &(&1.type == :assistant_message))

        assert metadata["partial"] == true
        assert Enum.any?(history, &(&1.type == :turn_failed))
      end)
    end)
  end

  test "one-shot JSON lets Turn profile preflight govern before CLI Auth" do
    profiles = [{%{"mode" => "future"}, "invalid_config", "unknown_mode"}]

    for {profile, expected_kind, expected_reason} <- profiles do
      with_cli_turn_opts(
        [
          config_opts: [
            raw_config: %{
              "model" => "gpt-5.4-mini",
              "responses_backend" => profile
            }
          ],
          provider_opts: [
            auth: :missing_cli_profile_auth,
            transport: fn _request, _acc, _fun -> flunk("transport must not run") end
          ]
        ],
        fn ->
          in_tmp_workspace("pixir-cli-profile-preflight", fn ws ->
            out =
              capture_io(fn ->
                assert {:error, 1} = CLI.route(["--json", "profile preflight"])
              end)

            payload = Jason.decode!(out)
            assert payload["kind"] == "one_shot_turn"
            assert payload["status"] == "error"
            assert payload["exit_code"] == 1
            assert payload["terminal_status"] == "configuration_error"
            assert payload["error_kind"] == expected_kind

            assert payload["details"] == %{
                     "field" =>
                       if(expected_kind == "invalid_config",
                         do: "mode",
                         else: "responses_backend"
                       ),
                     "reason" => expected_reason
                   }

            sid = payload["session_id"]
            assert {:ok, history} = Log.fold(sid, workspace: ws)

            assert Enum.map(Enum.take(history, -2), & &1.type) == [
                     :user_message,
                     :turn_failed
                   ]

            assert hd(history).type in [:permission_posture, :subagent_event]

            refute inspect(payload) =~ "stage.example"
            refute inspect(history) =~ "stage.example"
          end)
        end
      )
    end
  end

  test "one-shot JSON bounds Provider-output warnings at 255/256/257 with honest totals" do
    for count <- [255, 256, 257] do
      script = truncation_script(count, "exact answer #{count}")

      with_cli_provider(script, fn ->
        in_tmp_workspace("pixir-cli-output-truncation-#{count}", fn _ws ->
          File.write!("fixture.txt", "fixture\n")

          output =
            capture_io(fn ->
              assert :ok = CLI.route(["--json", "read repeatedly"])
            end)

          payload = Jason.decode!(output)
          assert payload["output"] == "exact answer #{count}"
          assert payload["output_truncation"]["status"] == "truncated"
          assert payload["warning_count"] == count
          assert length(payload["warnings"]) == min(count, 256)
          assert payload["warnings_truncated"] == (count == 257)

          assert Enum.map(payload["warnings"], & &1["provider_usage_seq"]) ==
                   Enum.sort(Enum.map(payload["warnings"], & &1["provider_usage_seq"]))
        end)
      end)
    end
  end

  test "one-shot human output stays exact and emits one suppression footer at 257" do
    with_cli_provider(truncation_script(257, "exact provider bytes"), fn ->
      in_tmp_workspace("pixir-cli-output-truncation-human", fn _ws ->
        File.write!("fixture.txt", "fixture\n")

        stderr =
          capture_io(:stderr, fn ->
            stdout = capture_io(fn -> assert :ok = CLI.route(["read repeatedly"]) end)
            send(self(), {:truncation_stdout, stdout})
          end)

        assert_received {:truncation_stdout, "exact provider bytes\n"}

        assert length(Regex.scan(~r/warning: provider output was truncated/, stderr)) == 256

        assert length(
                 Regex.scan(
                   ~r/warning: additional provider-output truncation notices suppressed/,
                   stderr
                 )
               ) == 1

        assert stderr =~ "(total=257, shown=256)"
      end)
    end)
  end

  test "empty and whitespace final output preserve exit 6 with additive neutral evidence" do
    for {output, reasoning} <- [{"", ""}, {"   ", ""}, {"", "reasoning-only"}] do
      result =
        truncated_stop(output)
        |> then(fn {:ok, result} -> {:ok, %{result | reasoning: reasoning}} end)

      with_cli_provider([result], fn ->
        in_tmp_workspace("pixir-cli-empty-output-truncation", fn _ws ->
          json =
            capture_io(fn ->
              assert {:error, 6} = CLI.route(["--json", "empty"])
            end)

          payload = Jason.decode!(json)
          assert payload["status"] == "incomplete"
          assert payload["ok"] == false
          assert payload["output_truncation"]["status"] == "truncated"
          assert payload["warning_count"] == 1
          assert payload["warnings_truncated"] == false
        end)
      end)
    end
  end

  test "both built-in Provider paths preserve empty whitespace and reasoning-only exit 6" do
    in_tmp_workspace("pixir-cli-built-in-empty", fn ws ->
      auth_name = :"cli_empty_auth_#{System.unique_integer([:positive])}"

      {:ok, auth_pid} =
        Pixir.Auth.start_link(
          name: auth_name,
          store_path: Path.join(ws, "isolated-auth.json"),
          env_api_key: "sk-cli"
        )

      on_exit(fn -> if Process.alive?(auth_pid), do: GenServer.stop(auth_pid) end)

      for fixture <- [:empty, :whitespace, :reasoning_only] do
        openai_events =
          case fixture do
            :empty -> []
            :whitespace -> [%{type: "response.output_text.delta", delta: "   "}]
            :reasoning_only -> [%{type: "response.reasoning_summary_text.delta", delta: "think"}]
          end

        openai_events =
          openai_events ++
            [
              %{
                type: "response.incomplete",
                response: %{
                  status: "incomplete",
                  incomplete_details: %{reason: "max_output_tokens"}
                }
              }
            ]

        openai_transport = fn _request, acc, fun ->
          acc = fun.({:status, 200}, acc)

          acc =
            Enum.reduce(openai_events, acc, fn event, current ->
              fun.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, current)
            end)

          {:ok, acc}
        end

        anthropic_events =
          case fixture do
            :empty ->
              []

            :whitespace ->
              [
                {"content_block_delta",
                 %{
                   type: "content_block_delta",
                   index: 0,
                   delta: %{type: "text_delta", text: "   "}
                 }}
              ]

            :reasoning_only ->
              [
                {"content_block_delta",
                 %{
                   type: "content_block_delta",
                   index: 0,
                   delta: %{type: "thinking_delta", thinking: "think"}
                 }}
              ]
          end

        anthropic_events =
          anthropic_events ++
            [{"message_delta", %{type: "message_delta", delta: %{stop_reason: "max_tokens"}}}]

        anthropic_transport = fn _request, acc, fun ->
          acc = fun.({:status, 200}, acc)

          acc =
            Enum.reduce(anthropic_events, acc, fn {name, event}, current ->
              chunk = "event: #{name}\ndata: " <> Jason.encode!(event) <> "\n\n"
              fun.({:data, chunk}, current)
            end)

          {:ok, acc}
        end

        rows = [
          {Pixir.Provider, [auth: auth_name, transport: openai_transport, max_retries: 0]},
          {Pixir.Providers.Anthropic,
           [api_key: "fixture-token", transport: anthropic_transport, max_retries: 0]}
        ]

        for {provider, provider_opts} <- rows do
          with_cli_turn_opts(
            [provider: provider, provider_opts: provider_opts, skip_auth?: true],
            fn ->
              json =
                capture_io(fn ->
                  assert {:error, 6} = CLI.route(["--json", "#{fixture} built-in"])
                end)

              payload = Jason.decode!(json)
              assert payload["status"] == "incomplete"
              assert payload["output_truncation"]["status"] == "truncated"
              assert payload["warning_count"] == 1
            end
          )
        end
      end
    end)
  end

  test "one-shot JSON counts a validated usage-absent assistant fallback once" do
    with_cli_turn_opts([provider: UsageAbsentFallbackProvider, skip_auth?: true], fn ->
      in_tmp_workspace("pixir-cli-output-truncation-fallback", fn _ws ->
        output = capture_io(fn -> assert :ok = CLI.route(["--json", "fallback"]) end)
        payload = Jason.decode!(output)

        assert payload["output"] == "final authoritative"
        assert payload["output_truncation"]["status"] == "not_truncated"
        assert payload["warning_count"] == 1
        assert [%{"provider_usage_event_id" => "evt_usage_absent"}] = payload["warnings"]
        assert payload["warnings_truncated"] == false
      end)
    end)
  end

  test "one-shot JSON rejects a partial usage-absent assistant fallback" do
    with_cli_turn_opts([provider: PartialUsageAbsentFallbackProvider, skip_auth?: true], fn ->
      in_tmp_workspace("pixir-cli-output-truncation-partial-fallback", fn _ws ->
        output = capture_io(fn -> assert :ok = CLI.route(["--json", "fallback"]) end)
        payload = Jason.decode!(output)

        assert payload["output"] == "final authoritative"
        assert payload["output_truncation"]["status"] == "not_truncated"
        assert payload["warning_count"] == 0
        assert payload["warnings"] == []
        refute inspect(payload) =~ "evt_partial_fallback"
      end)
    end)
  end

  defp truncation_script(count, final_text) do
    intermediate =
      for index <- 1..max(count - 1, 0) do
        call = %{
          call_id: "call_#{index}",
          name: "read",
          args: %{"path" => "fixture.txt"}
        }

        {:ok,
         %{
           text: "",
           reasoning: "",
           function_calls: [call],
           output_items: [{:function_call, call}],
           finish_reason: :tool_calls,
           output_truncation: truncated_evidence()
         }}
      end

    intermediate ++ [truncated_stop(final_text)]
  end

  defp truncated_stop(text) do
    {:ok,
     %{
       text: text,
       reasoning: "",
       function_calls: [],
       finish_reason: :stop,
       output_truncation: truncated_evidence()
     }}
  end

  defp truncated_evidence do
    %{
      status: :truncated,
      reason: :provider_output_limit,
      provider_reason: "fixture_limit"
    }
  end
end
