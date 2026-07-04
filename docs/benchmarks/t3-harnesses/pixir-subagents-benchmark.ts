/**
 * pixir-subagents-benchmark.ts — benchmark Pixir Subagents through T3 Code's
 * generic ACP runtime.
 *
 * This exercises the T3 runtime surface, not only Pixir internals:
 *   T3 makePixirAcpRuntime -> pixir acp -> model/tool loop -> subagent tools.
 *
 * It is intentionally separate from Pixir's no-network stress adapter
 * (`mix pixir.bench.subagents`). This script can hit the real provider, so keep
 * small `--n` values for interactive contract checks.
 *
 * Run from the T3 Code repo:
 *
 *   bun scripts/pixir-subagents-benchmark.ts --n 2
 *   bun scripts/pixir-subagents-benchmark.ts --n 5 --output /tmp/pixir-t3-bench
 */
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Stream from "effect/Stream";
import { ChildProcessSpawner } from "effect/unstable/process";
import * as NodeServices from "@effect/platform-node/NodeServices";

import { makePixirAcpRuntime } from "../apps/server/src/provider/acp/PixirAcpSupport.ts";
import type { AcpParsedSessionEvent } from "../apps/server/src/provider/acp/AcpRuntimeModel.ts";

const PIXIR_BINARY = process.env.PIXIR_BINARY ?? "../pixir/pixir";

interface Args {
  readonly n: number;
  readonly output: string | undefined;
  readonly model: string | undefined;
  readonly reasoningEffort: string | undefined;
  readonly cwd: string | undefined;
  readonly promptFile: string | undefined;
  readonly baseline: boolean;
  readonly probe: boolean;
  readonly dryRun: boolean;
  readonly json: boolean;
  readonly help: boolean;
}

interface TimedEvent {
  readonly atMs: number;
  readonly event: AcpParsedSessionEvent;
}

function parseArgs(argv: ReadonlyArray<string>): Args {
  let n = 2;
  let output: string | undefined;
  let model: string | undefined;
  let reasoningEffort: string | undefined;
  let cwd: string | undefined;
  let promptFile: string | undefined;
  let baseline = false;
  let probe = false;
  let dryRun = false;
  let json = false;
  let help = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--n") {
      n = Number(argv[++i]);
    } else if (arg.startsWith("--n=")) {
      n = Number(arg.slice("--n=".length));
    } else if (arg === "--output") {
      output = argv[++i];
    } else if (arg.startsWith("--output=")) {
      output = arg.slice("--output=".length);
    } else if (arg === "--model") {
      model = argv[++i];
    } else if (arg.startsWith("--model=")) {
      model = arg.slice("--model=".length);
    } else if (arg === "--reasoning-effort") {
      reasoningEffort = argv[++i];
    } else if (arg.startsWith("--reasoning-effort=")) {
      reasoningEffort = arg.slice("--reasoning-effort=".length);
    } else if (arg === "--cwd") {
      cwd = argv[++i];
    } else if (arg.startsWith("--cwd=")) {
      cwd = arg.slice("--cwd=".length);
    } else if (arg === "--prompt-file") {
      promptFile = argv[++i];
    } else if (arg.startsWith("--prompt-file=")) {
      promptFile = arg.slice("--prompt-file=".length);
    } else if (arg === "--baseline") {
      baseline = true;
    } else if (arg === "--probe") {
      probe = true;
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "--json") {
      json = true;
    } else if (arg === "--help" || arg === "-h") {
      help = true;
    }
  }

  if (!Number.isInteger(n) || n < 0 || (!baseline && !probe && n < 1)) {
    throw new Error(
      `--n must be ${baseline || probe ? "a non-negative" : "a positive"} integer, got ${String(n)}`,
    );
  }

  return {
    n,
    output,
    model,
    reasoningEffort,
    cwd,
    promptFile,
    baseline,
    probe,
    dryRun,
    json,
    help,
  };
}

function helpPayload() {
  return {
    ok: true,
    command: "bun scripts/pixir-subagents-benchmark.ts",
    description: "Probe T3-visible Pixir ACP subagent fan-out.",
    options: [
      "--n 1",
      "--output PATH",
      "--model gpt-5.5",
      "--reasoning-effort low",
      "--cwd PATH",
      "--prompt-file PATH",
      "--baseline",
      "--probe",
      "--dry-run",
      "--json",
    ],
  };
}

function dryRunPayload(args: Args) {
  const outputDir = args.output ?? "<temp>/.pixir/benchmarks/t3-subagents/<run-id>";
  return {
    ok: true,
    mode: "dry_run",
    provider_path: "t3code-pixir-acp",
    would_write: [`${outputDir}/t3-pixir-subagents-result.json`, `${outputDir}/report.md`],
    would_start_provider: !args.baseline,
    estimated_real_network_runs: args.baseline ? 0 : 1,
    command_options: {
      n: args.n,
      model: args.model ?? null,
      reasoning_effort: args.reasoningEffort ?? null,
      cwd: args.cwd ?? null,
      prompt_file: args.promptFile ?? null,
      baseline: args.baseline,
      probe: args.probe,
    },
    requires: [
      "Node 24",
      "T3 Code dependencies installed",
      "Pixir escript at PIXIR_BINARY or ../pixir/pixir for non-baseline runs",
      "Pixir provider authentication for real-network runs",
    ],
  };
}

function errorPayload(kind: string, message: string, details: Record<string, unknown> = {}) {
  return {
    ok: false,
    error: {
      kind,
      message,
      details,
      root_agent_hint:
        "Run with --help or --dry-run --json, fix local state, then rerun the harness.",
    },
  };
}

function summarizeEvent(e: AcpParsedSessionEvent): unknown {
  switch (e._tag) {
    case "AssistantItemStarted":
    case "AssistantItemCompleted":
      return { _tag: e._tag, itemId: e.itemId };
    case "ContentDelta":
      return { _tag: e._tag, itemId: e.itemId, text: e.text };
    case "ToolCallUpdated":
      return {
        _tag: e._tag,
        toolCall: {
          toolCallId: e.toolCall.toolCallId,
          kind: e.toolCall.kind,
          status: e.toolCall.status,
          title: e.toolCall.title,
          command: e.toolCall.command,
          detail: e.toolCall.detail,
        },
      };
    case "PlanUpdated":
      return { _tag: e._tag, payload: e.payload };
    case "ModeChanged":
      return { _tag: e._tag, modeId: e.modeId };
  }
}

function eventText(e: AcpParsedSessionEvent): string {
  return JSON.stringify(summarizeEvent(e));
}

function buildPrompt(n: number): string {
  const tasks = Array.from({ length: n }, (_, index) => {
    const child = index + 1;
    return `${child}. Spawn explorer subagent ${child} with task: "Read-only benchmark child ${child}; reply with exactly three short bullets about the current workspace and do not modify files."`;
  }).join("\n");

  return `T3 Code / Pixir Subagents benchmark contract check.

Please use the spawn_agent tool exactly ${n} times with agent="explorer", max_threads=${Math.min(n, 16)}, max_depth=1, timeout_ms=120000, and workspace_mode="isolated".

${tasks}

After spawning, call wait_agent for every child. Finish with a compact JSON object containing:
- child_ids
- completed_count
- failed_count
- one sentence saying whether T3-visible Pixir fan-out was observable.

Do not modify files.`;
}

function buildProbePrompt(): string {
  return `T3 Code / Pixir provider probe.

Reply with exactly this JSON and do not call tools:
{"provider_reachable":true,"subagents_requested":0}`;
}

function percentile(values: ReadonlyArray<number>, pct: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((pct / 100) * sorted.length) - 1);
  return sorted[index] ?? null;
}

const program = Effect.gen(function* () {
  const args = parseArgs(Bun.argv.slice(2));
  if (args.help) {
    console.log(JSON.stringify(helpPayload(), null, 2));
    return;
  }
  if (args.dryRun) {
    console.log(JSON.stringify(dryRunPayload(args), null, 2));
    return;
  }

  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const nodeFs = yield* Effect.promise(() => import("node:fs"));
  const nodeOs = yield* Effect.promise(() => import("node:os"));
  const nodePath = yield* Effect.promise(() => import("node:path"));

  const startedAt = new Date().toISOString();
  const runId = startedAt.replace(/[-:.]/g, "").replace("Z", "");
  const cwd = args.cwd ?? nodeFs.mkdtempSync(nodePath.join(nodeOs.tmpdir(), "pixir-t3-subagents-"));
  if (!args.cwd) {
    nodeFs.writeFileSync(nodePath.join(cwd, "README.md"), "T3 Pixir Subagents benchmark fixture\n");
  }

  const outputDir =
    args.output ?? nodePath.join(cwd, ".pixir", "benchmarks", "t3-subagents", runId);
  nodeFs.mkdirSync(outputDir, { recursive: true });

  if (args.baseline) {
    const baselineStart = Date.now();
    yield* Effect.sleep("1500 millis");
    const result = {
      run_id: runId,
      scenario: "t3_pixir_harness_baseline",
      provider_path: "t3code-pixir-acp",
      status: "baseline",
      started_at: startedAt,
      n: 0,
      cwd,
      output_dir: outputDir,
      parent_session_id: null,
      parent_log_path: null,
      model: args.model ?? null,
      reasoning_effort: args.reasoningEffort ?? null,
      stop_reason: "baseline",
      metrics: {
        total_turn_ms: Date.now() - baselineStart,
        spawned_visible_count: 0,
        wait_visible_count: 0,
        t3_event_count: 0,
        tool_event_count: 0,
        tool_event_p95_ms: null,
      },
      evidence: {
        requests: [],
        event_tags: [],
        tool_events: [],
        final_text: "",
        codex_comparability:
          "Baseline imports and runs the Pixir T3 harness without starting Pixir ACP or making provider calls.",
      },
    };

    nodeFs.writeFileSync(
      nodePath.join(outputDir, "t3-pixir-subagents-result.json"),
      JSON.stringify(result, null, 2),
    );
    nodeFs.writeFileSync(
      nodePath.join(outputDir, "report.md"),
      [
        "# T3 Pixir Harness Baseline",
        "",
        `Run id: \`${runId}\``,
        "",
        "Status: **baseline**",
        "",
        "No provider session was started.",
        "",
      ].join("\n"),
    );
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  const requests: Array<{
    readonly atMs: number;
    readonly method: string;
    readonly status: string;
  }> = [];
  const events: Array<TimedEvent> = [];

  yield* Effect.scoped(
    Effect.gen(function* () {
      const runtime = yield* makePixirAcpRuntime({
        childProcessSpawner: spawner,
        pixirSettings: { binaryPath: PIXIR_BINARY },
        cwd,
        clientInfo: { name: "t3code-pixir-subagents-benchmark", version: "0.0.0" },
        requestLogger: (event) =>
          Effect.sync(() => {
            requests.push({ atMs: Date.now(), method: event.method, status: event.status });
          }),
      });

      const startResult = yield* runtime.start();
      if (args.model) {
        yield* runtime.setModel(args.model);
      }

      const promptStart = Date.now();
      const pumpFiber = yield* Effect.forkScoped(
        runtime.getEvents().pipe(
          Stream.runForEach((event) =>
            Effect.sync(() => {
              events.push({ atMs: Date.now() - promptStart, event });
            }),
          ),
        ),
      );

      const promptText = args.promptFile
        ? nodeFs.readFileSync(args.promptFile, "utf8")
        : args.probe
          ? buildProbePrompt()
          : buildPrompt(args.n);

      const promptResult = yield* runtime.prompt({
        prompt: [{ type: "text", text: promptText }],
        _meta: {
          ...(args.model ? { model: args.model } : {}),
          ...(args.reasoningEffort ? { reasoning_effort: args.reasoningEffort } : {}),
        },
      });

      yield* Effect.sleep("500 millis");
      yield* Fiber.interrupt(pumpFiber);

      const toolEvents = events.filter(({ event }) => event._tag === "ToolCallUpdated");
      const spawnEvents = toolEvents.filter(({ event }) =>
        eventText(event).includes("Spawned sub_"),
      );
      const waitEvents = toolEvents.filter(({ event }) => eventText(event).includes("completed:"));
      const contentDeltas = events
        .filter(({ event }) => event._tag === "ContentDelta")
        .map(
          ({ event }) => (event as Extract<AcpParsedSessionEvent, { _tag: "ContentDelta" }>).text,
        );
      const eventLatencies = toolEvents.map((e) => e.atMs);
      const finalText = contentDeltas.join("");

      const parentLogPath = nodePath.join(
        cwd,
        ".pixir",
        "sessions",
        `${startResult.sessionId}.ndjson`,
      );

      const result = {
        run_id: runId,
        scenario: args.probe ? "t3_pixir_probe" : "t3_pixir_visible_fanout",
        provider_path: "t3code-pixir-acp",
        status: args.probe
          ? promptResult.stopReason
            ? "passed"
            : "weak"
          : spawnEvents.length >= args.n && waitEvents.length >= 1
            ? "passed"
            : "weak",
        started_at: startedAt,
        n: args.n,
        cwd,
        output_dir: outputDir,
        parent_session_id: startResult.sessionId,
        parent_log_path: parentLogPath,
        model: args.model ?? startResult.modelConfigId ?? null,
        reasoning_effort: args.reasoningEffort ?? null,
        stop_reason: promptResult.stopReason,
        metrics: {
          prompt_to_first_child_event_ms: spawnEvents[0]?.atMs ?? null,
          prompt_to_all_spawned_ms:
            spawnEvents.length >= args.n ? (spawnEvents[args.n - 1]?.atMs ?? null) : null,
          total_turn_ms: Date.now() - promptStart,
          spawned_visible_count: spawnEvents.length,
          wait_visible_count: waitEvents.length,
          t3_event_count: events.length,
          tool_event_count: toolEvents.length,
          tool_event_p95_ms: percentile(eventLatencies, 95),
        },
        evidence: {
          requests,
          event_tags: events.map(({ event }) => event._tag),
          tool_events: toolEvents.map(({ atMs, event }) => ({
            atMs,
            event: summarizeEvent(event),
          })),
          final_text: finalText,
          codex_comparability: args.probe
            ? "This script proves Pixir provider reachability through T3 without requesting subagents."
            : "This script proves T3-visible Pixir fan-out only. A separate Codex provider probe is required before claiming symmetric Codex subagent observability from T3.",
        },
      };

      nodeFs.writeFileSync(
        nodePath.join(outputDir, "t3-pixir-subagents-result.json"),
        JSON.stringify(result, null, 2),
      );
      nodeFs.writeFileSync(
        nodePath.join(outputDir, "report.md"),
        [
          args.probe ? "# T3 Pixir Provider Probe" : "# T3 Pixir Subagents Benchmark",
          "",
          `Run id: \`${runId}\``,
          "",
          `Status: **${result.status}**`,
          "",
          `N: \`${args.n}\``,
          "",
          `Parent session: \`${startResult.sessionId}\``,
          "",
          `Parent log: \`${parentLogPath}\``,
          "",
          "## Metrics",
          "",
          "```json",
          JSON.stringify(result.metrics, null, 2),
          "```",
          "",
          "## Codex Comparability",
          "",
          result.evidence.codex_comparability,
          "",
        ].join("\n"),
      );

      console.log(JSON.stringify(result, null, 2));

      if (result.status !== "passed") {
        throw new Error(`benchmark evidence was ${result.status}`);
      }
    }),
  );
});

Effect.runPromise(program.pipe(Effect.provide(NodeServices.layer))).then(
  () => {
    process.exit(0);
  },
  (err) => {
    const message = err instanceof Error ? err.message : String(err);
    console.error("\n[harness] FAILED", err);
    if (Bun.argv.includes("--json")) {
      console.log(
        JSON.stringify(
          errorPayload("harness_failed", message, { provider_path: "t3code-pixir-acp" }),
          null,
          2,
        ),
      );
    }
    process.exit(1);
  },
);
