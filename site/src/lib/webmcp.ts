/**
 * Page-side WebMCP registration for pixir.dev.
 *
 * This is not a Pixir MCP server and does not change the CLI/ACP runtime.
 * Spec (draft CG, 26 Aug 2026): https://webmachinelearning.github.io/webmcp/
 */

import { PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION } from "./site-facts.ts";

export { PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION };

const EMPTY_INPUT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {}
} as const;

const READ_ONLY = { readOnlyHint: true as const };

export type WebMcpRegisterTool = (
  tool: {
    name: string;
    title?: string;
    description: string;
    inputSchema?: object;
    annotations?: { readOnlyHint?: boolean };
    execute: (
      input: Record<string, unknown>,
      options: { signal: AbortSignal }
    ) => Promise<unknown>;
  },
  options?: object
) => Promise<unknown>;

export type WebMcpDocument = {
  modelContext?: {
    registerTool?: WebMcpRegisterTool;
  };
};

export type PixirWebMcpToolDefinition = {
  name: string;
  title: string;
  description: string;
  inputSchema: typeof EMPTY_INPUT_SCHEMA;
  annotations: typeof READ_ONLY;
  result: Record<string, unknown>;
};

export const pixirWebMcpTools: readonly PixirWebMcpToolDefinition[] = [
  {
    name: "pixir.get_started",
    title: "Pixir get started",
    description:
      "Returns the public install and first-run path published on pixir.dev: Hex install, pixir doctor --json, and pixir acp, plus Hex/HexDocs/source links. Also reports the version shown in the homepage doctor example. Read-only site copy; does not install software, query Hex, or change any session.",
    inputSchema: EMPTY_INPUT_SCHEMA,
    annotations: READ_ONLY,
    result: {
      source: "https://pixir.dev/",
      homepage_doctor_example_version: PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION,
      version_note: `${PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION} is the version shown in the homepage doctor example. Confirm the published package on Hex; this tool does not query Hex or GitHub.`,
      hex_install: [
        "mix escript.install hex pixir",
        "pixir doctor --json",
        "pixir acp"
      ],
      guidance:
        "Start with Hex when you want the published daily-driver binary. Use a source checkout when you are working on Pixir itself.",
      links: {
        hex: "https://hex.pm/packages/pixir",
        hexdocs: "https://pixir.hexdocs.pm/readme.html",
        source: "https://github.com/Ranvier-Technologies/pixir",
        scale_notes: "https://pixir.dev/scale"
      }
    }
  },
  {
    name: "pixir.preview_scope",
    title: "Pixir preview scope",
    description:
      "Returns what Pixir is and is not according to the public pixir.dev preview-scope copy. Includes the reminder that this page registers WebMCP tools in the browser and that Pixir itself is not an MCP server. Read-only site copy; not live runtime state.",
    inputSchema: EMPTY_INPUT_SCHEMA,
    annotations: READ_ONLY,
    result: {
      source: "https://pixir.dev/#boundary",
      status: "Developer preview",
      public_surface: "CLI and ACP",
      what_pixir_is: {
        summary:
          "Pixir is an Elixir/OTP harness for running agent work as supervised local sessions. Drive it from the CLI or ACP clients; Pixir owns subagent lifecycle, workflow outcomes, failures, timeouts, and replayable evidence without making the presenter the runtime.",
        runtime_spine: "Session -> Turn -> Provider -> Tools",
        evidence:
          "Summaries are not evidence. Logs, artifacts, and status records are. Sessions persist as append-only local NDJSON under .pixir/sessions/.",
        presenter_boundary:
          "Operators and presenters request work; Pixir executes, supervises, and keeps the evidence. Logos on the site identify example operators or presenters and do not imply bundled integrations, endorsement, or production support."
      },
      what_pixir_is_not: [
        "Not a Pi TUI replacement or a finished standalone terminal app.",
        "Not a packaged T3Code provider or a public T3 Code install path. T3 pairing is local dogfood through an adapter.",
        "Not a stable public Elixir API. Hex installs the CLI/ACP runtime; internal modules are documented for transparency.",
        "Not production SLA software. No hosted service promises, telemetry, self-update, or enterprise support contract.",
        "Not an MCP server."
      ],
      this_surface: {
        kind: "webmcp-page-side-tool-registration",
        spec: "https://webmachinelearning.github.io/webmcp/",
        not: "A Pixir MCP server, a backend MCP endpoint, or a change to the CLI/ACP runtime."
      }
    }
  },
  {
    name: "pixir.operator_primitives",
    title: "Pixir operator primitives",
    description:
      "Returns the public operator CLI primitives listed on pixir.dev and the pointer to the checked-in CLI contract. Read-only site copy; does not run those commands or inspect a local Session.",
    inputSchema: EMPTY_INPUT_SCHEMA,
    annotations: READ_ONLY,
    result: {
      source: "https://pixir.dev/#operators",
      public_surface: "CLI and ACP",
      cli_contract:
        "https://github.com/Ranvier-Technologies/pixir/blob/main/docs/cli-contract.md",
      cli_contract_note:
        "The machine surface is a checked-in contract with pinned stable fields. This tool does not execute CLI commands.",
      commands: [
        {
          command: "pixir doctor --json",
          purpose:
            "Check runtime, auth, config, workspace, and ACP readiness from a scriptable diagnostic gate."
        },
        {
          command: "pixir resume <session-id>",
          purpose:
            "Continue from a durable Session instead of starting over from a transcript pasted into chat."
        },
        {
          command: "pixir tree <session-id> --json",
          purpose:
            "Project the Session and Subagent hierarchy from local Logs without calling the model."
        },
        {
          command: "pixir compact <session-id> --dry-run --json",
          purpose:
            "Preview history checkpoints before appending a durable compaction boundary."
        },
        {
          command: "pixir fork <session-id>",
          purpose: "Branch exploration while preserving the original Session as evidence."
        },
        {
          command: "pixir acp",
          purpose:
            "Run Pixir behind ACP clients while keeping JSON-RPC stdout clean and diagnostics separate."
        }
      ]
    }
  }
];

const TOOL_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,128}$/;

function asWebMcpDocument(doc: object): WebMcpDocument {
  return doc as WebMcpDocument;
}

export function webMcpAvailable(doc: object): boolean {
  return typeof asWebMcpDocument(doc).modelContext?.registerTool === "function";
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (!signal?.aborted) {
    return;
  }

  if (signal.reason instanceof Error) {
    throw signal.reason;
  }

  throw new DOMException("Aborted", "AbortError");
}

export async function registerPixirWebMcp(
  doc: object
): Promise<{ registered: string[] }> {
  const registerTool = asWebMcpDocument(doc).modelContext?.registerTool;
  if (typeof registerTool !== "function") {
    return { registered: [] };
  }

  const registered: string[] = [];

  for (const tool of pixirWebMcpTools) {
    if (!TOOL_NAME_PATTERN.test(tool.name)) {
      continue;
    }

    try {
      await registerTool({
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: tool.annotations,
        execute: async (_input, { signal }) => {
          throwIfAborted(signal);
          return tool.result;
        }
      });
      registered.push(tool.name);
    } catch {
      // Already registered (HMR) or an unsupported host shape. Stay a no-op
      // for the marketing page rather than throwing into ordinary browsing.
    }
  }

  return { registered };
}
