/**
 * codex-subagents-observability-probe.ts — probe whether T3 Code can observe
 * Codex subagent/collaboration fan-out through its Codex runtime.
 *
 * This is intentionally a probe, not a benchmark winner/loser claim. It records
 * whether the local Codex app-server emits `collabAgentToolCall` lifecycle items
 * that T3 can see as provider events.
 *
 * Run from the T3 Code repo:
 *
 *   bun scripts/codex-subagents-observability-probe.ts --n 1
 *   bun scripts/codex-subagents-observability-probe.ts --n 2 --output /tmp/codex-probe
 */
import * as NodeServices from "@effect/platform-node/NodeServices";
import { ApprovalRequestId, ThreadId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Stream from "effect/Stream";
import type * as EffectCodexSchema from "effect-codex-app-server/schema";

import {
  makeCodexSessionRuntime,
  type CodexSessionRuntimeOptions,
} from "../apps/server/src/provider/Layers/CodexSessionRuntime.ts";

const CODEX_BINARY = "/opt/homebrew/bin/codex";

interface Args {
  readonly n: number;
  readonly output: string | undefined;
  readonly model: string | undefined;
  readonly reasoningEffort: EffectCodexSchema.V2TurnStartParams__ReasoningEffort | undefined;
  readonly cwd: string | undefined;
  readonly promptFile: string | undefined;
  readonly baseline: boolean;
  readonly probe: boolean;
  readonly dryRun: boolean;
  readonly json: boolean;
  readonly help: boolean;
}

function parseArgs(argv: ReadonlyArray<string>): Args {
  let n = 1;
  let output: string | undefined;
  let model: string | undefined;
  let reasoningEffort: EffectCodexSchema.V2TurnStartParams__ReasoningEffort | undefined;
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
      reasoningEffort = argv[++i] as EffectCodexSchema.V2TurnStartParams__ReasoningEffort;
    } else if (arg.startsWith("--reasoning-effort=")) {
      reasoningEffort = arg.slice(
        "--reasoning-effort=".length,
      ) as EffectCodexSchema.V2TurnStartParams__ReasoningEffort;
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
    command: "bun scripts/codex-subagents-observability-probe.ts",
    description: "Probe T3-visible Codex collab/subagent fan-out lifecycle.",
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
  const outputDir = args.output ?? "<temp>/.benchmarks/codex-subagents/<run-id>";
  return {
    ok: true,
    mode: "dry_run",
    provider_path: "t3code-codex-app-server",
    would_write: [`${outputDir}/codex-subagents-observability.json`, `${outputDir}/report.md`],
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
      "Codex binary at /opt/homebrew/bin/codex for non-baseline runs",
      "Codex authentication for real-network runs",
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

function buildPrompt(n: number): string {
  return `T3 Code / Codex subagents observability probe.

If this runtime exposes a subagent, Task, or collab-agent tool, please use it exactly ${n} time(s). Each child should inspect this tiny workspace read-only and report exactly two bullets. If no subagent/collab tool is available, say so explicitly.

After launching child agents, explicitly wait for every child agent result before writing the final JSON.

Finish with a compact JSON object containing:
- requested_children: ${n}
- completed_children: number
- child_lifecycle_visible_to_you: true/false
- note: one sentence

Do not modify files.`;
}

function buildProbePrompt(): string {
  return `T3 Code / Codex provider probe.

Reply with exactly this JSON and do not request subagents:
{"provider_reachable":true,"subagents_requested":0}`;
}

function providerEventType(event: { readonly payload?: unknown }): string | undefined {
  const payload = event.payload;
  if (!payload || typeof payload !== "object") return undefined;
  const maybeType = (payload as { item?: { type?: unknown }; itemType?: unknown }).item?.type;
  if (typeof maybeType === "string") return maybeType;
  const maybeItemType = (payload as { itemType?: unknown }).itemType;
  return typeof maybeItemType === "string" ? maybeItemType : undefined;
}

function includesCollab(event: unknown): boolean {
  return JSON.stringify(event).includes("collabAgentToolCall");
}

function collabTool(event: unknown): string | undefined {
  const payload = (event as { payload?: { item?: { tool?: unknown } } }).payload;
  return typeof payload?.item?.tool === "string" ? payload.item.tool : undefined;
}

function providerThreadId(event: unknown): string | undefined {
  const payload = (event as { payload?: { threadId?: unknown } }).payload;
  return typeof payload?.threadId === "string" ? payload.threadId : undefined;
}

function approvalRequestId(event: unknown): ApprovalRequestId | undefined {
  const requestId = (event as { requestId?: unknown }).requestId;
  return typeof requestId === "string" ? ApprovalRequestId.make(requestId) : undefined;
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

  const nodeFs = yield* Effect.promise(() => import("node:fs"));
  const nodeOs = yield* Effect.promise(() => import("node:os"));
  const nodePath = yield* Effect.promise(() => import("node:path"));

  const startedAt = new Date().toISOString();
  const runId = startedAt.replace(/[-:.]/g, "").replace("Z", "");
  const cwd = args.cwd ?? nodeFs.mkdtempSync(nodePath.join(nodeOs.tmpdir(), "codex-t3-subagents-"));
  if (!args.cwd) {
    nodeFs.writeFileSync(
      nodePath.join(cwd, "README.md"),
      "T3 Codex subagents observability fixture\n",
    );
  }

  const outputDir = args.output ?? nodePath.join(cwd, ".benchmarks", "codex-subagents", runId);
  nodeFs.mkdirSync(outputDir, { recursive: true });

  if (args.baseline) {
    const baselineStart = Date.now();
    yield* Effect.sleep("1500 millis");
    const result = {
      run_id: runId,
      scenario: "t3_codex_harness_baseline",
      provider_path: "t3code-codex-app-server",
      status: "baseline",
      started_at: startedAt,
      n: 0,
      cwd,
      output_dir: outputDir,
      provider_thread_id: null,
      t3_thread_id: null,
      turn_id: null,
      model: args.model ?? null,
      reasoning_effort: args.reasoningEffort ?? null,
      metrics: {
        total_ms: Date.now() - baselineStart,
        provider_event_count: 0,
        collab_lifecycle_event_count: 0,
        collab_spawn_completed_count: 0,
        collab_wait_completed_count: 0,
        unique_item_types: [],
      },
      evidence: {
        collab_events: [],
        collab_tools: [],
        event_methods: [],
        final_text: "",
        note: "Baseline imports and runs the Codex T3 harness without starting Codex app-server or making provider calls.",
      },
    };

    nodeFs.writeFileSync(
      nodePath.join(outputDir, "codex-subagents-observability.json"),
      JSON.stringify(result, null, 2),
    );
    nodeFs.writeFileSync(
      nodePath.join(outputDir, "report.md"),
      [
        "# T3 Codex Harness Baseline",
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

  const events: Array<{ readonly atMs: number; readonly event: unknown }> = [];
  const threadId = ThreadId.make(`bench-codex-${runId}`);
  const promptStart = Date.now();

  yield* Effect.scoped(
    Effect.gen(function* () {
      const runtimeOptions = {
        threadId,
        binaryPath: CODEX_BINARY,
        cwd,
        runtimeMode: "approval-required",
        ...(args.model ? { model: args.model } : {}),
      } satisfies CodexSessionRuntimeOptions;

      const runtime = yield* makeCodexSessionRuntime(runtimeOptions);
      const session = yield* runtime.start();

      const pumpFiber = yield* Effect.forkScoped(
        runtime.events.pipe(
          Stream.runForEach((event) =>
            Effect.gen(function* () {
              events.push({ atMs: Date.now() - promptStart, event });
              if (
                (event as { kind?: unknown }).kind === "request" &&
                (event as { method?: unknown }).method === "item/commandExecution/requestApproval"
              ) {
                const requestId = approvalRequestId(event);
                if (requestId) {
                  yield* runtime.respondToRequest(requestId, "accept");
                }
              }
            }),
          ),
        ),
      );

      const promptText = args.promptFile
        ? nodeFs.readFileSync(args.promptFile, "utf8")
        : args.probe
          ? buildProbePrompt()
          : buildPrompt(args.n);

      const turn = yield* runtime.sendTurn({
        input: promptText,
        interactionMode: "default",
        ...(args.model ? { model: args.model } : {}),
        ...(args.reasoningEffort ? { effort: args.reasoningEffort } : {}),
      });

      let completed = false;
      for (let waited = 0; waited < 180000 && !completed; waited += 500) {
        yield* Effect.sleep("500 millis");
        completed = events.some(({ event }) => {
          const method = (event as { method?: unknown }).method;
          const payload = (event as { payload?: { turn?: { id?: unknown } } }).payload;
          return (
            method === "turn/completed" && String(payload?.turn?.id ?? "") === String(turn.turnId)
          );
        });
      }

      yield* Effect.sleep("500 millis");
      yield* Fiber.interrupt(pumpFiber);

      const collabEvents = events.filter(({ event }) => includesCollab(event));
      const collabCompletedEvents = collabEvents.filter(
        ({ event }) => (event as { method?: unknown }).method === "item/completed",
      );
      const spawnEvents = collabCompletedEvents.filter(
        ({ event }) => collabTool(event) === "spawnAgent",
      );
      const waitEvents = collabCompletedEvents.filter(({ event }) => collabTool(event) === "wait");
      const eventTypes = events.map(({ event }) => providerEventType(event)).filter(Boolean);
      const parentProviderThreadId = session.resumeCursor?.threadId;
      const assistantDeltas = events
        .filter(({ event }) => {
          if ((event as { method?: unknown }).method !== "item/agentMessage/delta") return false;
          const eventThreadId = providerThreadId(event);
          return parentProviderThreadId ? eventThreadId === parentProviderThreadId : true;
        })
        .map(({ event }) => String((event as { textDelta?: unknown }).textDelta ?? ""))
        .join("");

      const status = args.probe
        ? completed
          ? "passed"
          : "weak"
        : spawnEvents.length >= args.n && waitEvents.length > 0
          ? "observed"
          : collabEvents.length > 0
            ? "weak"
            : "not_observed";
      const result = {
        run_id: runId,
        scenario: args.probe ? "codex_provider_probe" : "codex_visible_fanout_probe",
        provider_path: "t3code-codex-app-server",
        status,
        started_at: startedAt,
        n: args.n,
        cwd,
        output_dir: outputDir,
        provider_thread_id: session.resumeCursor?.threadId ?? null,
        t3_thread_id: threadId,
        turn_id: turn.turnId,
        model: args.model ?? session.model ?? null,
        reasoning_effort: args.reasoningEffort ?? null,
        metrics: {
          total_ms: Date.now() - promptStart,
          provider_event_count: events.length,
          collab_lifecycle_event_count: collabEvents.length,
          collab_spawn_completed_count: spawnEvents.length,
          collab_wait_completed_count: waitEvents.length,
          unique_item_types: [...new Set(eventTypes)],
        },
        evidence: {
          collab_events: collabEvents,
          collab_tools: collabEvents.map(({ event }) => collabTool(event)),
          event_methods: events.map(({ event }) => (event as { method?: unknown }).method),
          final_text: assistantDeltas,
          note:
            args.probe && status === "passed"
              ? "T3 observed Codex provider reachability without requesting subagents."
              : status === "observed"
                ? "T3 observed Codex collabAgentToolCall spawn and wait lifecycle events."
                : status === "weak"
                  ? "T3 observed Codex collabAgentToolCall events, but spawn/wait evidence was incomplete for this run."
                  : "T3 did not observe Codex collabAgentToolCall lifecycle events during this run; this may mean the model did not choose a subagent or the surface is unavailable in this mode.",
        },
      };

      nodeFs.writeFileSync(
        nodePath.join(outputDir, "codex-subagents-observability.json"),
        JSON.stringify(result, null, 2),
      );
      nodeFs.writeFileSync(
        nodePath.join(outputDir, "report.md"),
        [
          args.probe ? "# T3 Codex Provider Probe" : "# T3 Codex Subagents Observability Probe",
          "",
          `Run id: \`${runId}\``,
          "",
          `Status: **${status}**`,
          "",
          `Provider thread: \`${result.provider_thread_id ?? "<none>"}\``,
          "",
          "## Metrics",
          "",
          "```json",
          JSON.stringify(result.metrics, null, 2),
          "```",
          "",
          "## Note",
          "",
          result.evidence.note,
          "",
        ].join("\n"),
      );

      console.log(JSON.stringify(result, null, 2));
      yield* runtime.close;
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
          errorPayload("harness_failed", message, { provider_path: "t3code-codex-app-server" }),
          null,
          2,
        ),
      );
    }
    process.exit(1);
  },
);
