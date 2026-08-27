import assert from "node:assert/strict";
import { test } from "node:test";

import {
  PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION,
  pixirWebMcpTools,
  registerPixirWebMcp,
  webMcpAvailable,
  type WebMcpRegisterTool
} from "./webmcp.ts";

const TOOL_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,128}$/;

test("webMcpAvailable is false without modelContext", () => {
  assert.equal(webMcpAvailable({}), false);
  assert.equal(webMcpAvailable({ modelContext: {} }), false);
});

test("registerPixirWebMcp is a no-op when modelContext is missing", async () => {
  const result = await registerPixirWebMcp({});
  assert.deepEqual(result, { registered: [] });
});

test("catalog names, read-only hints, and homepage version stay honest", () => {
  const names = pixirWebMcpTools.map((tool) => tool.name);

  assert.deepEqual(names, [
    "pixir.get_started",
    "pixir.preview_scope",
    "pixir.operator_primitives"
  ]);

  for (const tool of pixirWebMcpTools) {
    assert.match(tool.name, TOOL_NAME_PATTERN);
    assert.equal(tool.annotations.readOnlyHint, true);
    assert.equal(tool.inputSchema.type, "object");
    assert.equal(typeof tool.description, "string");
    assert.ok(tool.description.length > 0);
  }

  assert.equal(PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION, "0.1.15");
  assert.equal(
    pixirWebMcpTools[0]?.result.homepage_doctor_example_version,
    PIXIR_HOMEPAGE_DOCTOR_EXAMPLE_VERSION
  );
  assert.match(String(pixirWebMcpTools[1]?.result.what_pixir_is_not), /Not an MCP server/);
  assert.equal(
    pixirWebMcpTools[2]?.result.cli_contract,
    "https://github.com/Ranvier-Technologies/pixir/blob/main/docs/cli-contract.md"
  );
});

test("registers each tool when modelContext exists and execute returns site copy", async () => {
  const registered: Array<{
    name: string;
    annotations?: { readOnlyHint?: boolean };
    execute: (
      input: Record<string, unknown>,
      options: { signal: AbortSignal }
    ) => Promise<unknown>;
  }> = [];

  const registerTool: WebMcpRegisterTool = async (tool) => {
    registered.push(tool);
  };

  const result = await registerPixirWebMcp({
    modelContext: { registerTool }
  });

  assert.deepEqual(result.registered, [
    "pixir.get_started",
    "pixir.preview_scope",
    "pixir.operator_primitives"
  ]);
  assert.equal(registered.length, 3);

  for (const [index, tool] of registered.entries()) {
    assert.equal(tool.annotations?.readOnlyHint, true);
    const output = await tool.execute({}, { signal: new AbortController().signal });
    assert.deepEqual(output, pixirWebMcpTools[index]?.result);
  }
});

test("execute honors abort without returning site copy", async () => {
  let execute:
    | ((
        input: Record<string, unknown>,
        options: { signal: AbortSignal }
      ) => Promise<unknown>)
    | undefined;

  const registerTool: WebMcpRegisterTool = async (tool) => {
    execute = tool.execute;
  };

  await registerPixirWebMcp({ modelContext: { registerTool } });
  assert.ok(execute);

  const controller = new AbortController();
  controller.abort();

  await assert.rejects(() => execute!({}, { signal: controller.signal }), {
    name: "AbortError"
  });
});

test("a failing registerTool does not throw from the page entrypoint", async () => {
  const registerTool: WebMcpRegisterTool = async () => {
    throw new Error("already registered");
  };

  const result = await registerPixirWebMcp({
    modelContext: { registerTool }
  });

  assert.deepEqual(result, { registered: [] });
});
