# Pixir Daily-Driver Ritual

This is the operator ritual for using Pixir daily through ACP clients such as T3Code.
It is not a release gate for strangers and it is not a promise that Pixir is a
standalone Pi-style TUI product.

Use this checklist when:

- you pulled Pixir changes;
- you edited Elixir harness code;
- an ACP client feels stale or surprising;
- you are about to do a serious multi-turn dogfood session;
- you need evidence that the local `./pixir` binary, ACP path, and Provider transport
  are aligned.

## 1. Rebuild The Local Binary

After Elixir changes, rebuild the escript before judging runtime behavior:

```bash
mix escript.build
```

ACP clients should point at this freshly built `./pixir`. If an ACP client is still
using an older binary, it can look like Pixir regressed when the client is simply
running stale code.

## 2. Run Local Diagnostics

```bash
./pixir doctor --json
```

`doctor` is local-only and no-network. It checks the runtime, source-install binary,
credential presence, config shape, workspace/session-log writability, and ACP command
availability. A green `doctor` means the local harness is coherent; it does not prove
that the Provider accepts the selected model.

## 3. Check ACP Client Wiring

For an ACP client such as T3Code, verify the configured binary path points at the
current checkout's built escript:

```text
binaryPath = <this checkout>/pixir
```

This is local dogfood wiring. It is not a packaged T3Code provider install path.

## 4. Run A Continuation Smoke

Before relying on a long-lived ACP session, run the preflight continuation smoke:

```bash
./bin/verify-t3-websocket-continuation.sh preflight
```

This script is an operator check for the T3/Pixir WebSocket-continuation path. Treat
its output as dogfood evidence, not as a replacement for the local Log.

## 5. Do A Human ACP Session Check

In the ACP client:

1. select the Pixir provider;
2. send one prompt;
3. send a second prompt in the same thread;
4. interrupt once if you are validating cancellation behavior;
5. capture the Pixir session id from the UI or diagnostics.

The goal is not to prove that every UI affordance is finished. The goal is to prove
that the current client is talking to the intended `./pixir` binary and that the same
Session can continue across turns.

## 6. Preserve Evidence

For a serious dogfood run, keep the session id and analyzer output with the relevant
handoff or artifact bundle.

Evidence worth keeping:

- session id;
- workspace or project under test;
- `doctor --json` result;
- continuation smoke output;
- analyzer output for the dogfood session;
- any ACP/client issue classified as Presenter, adapter, or Pixir core.

Prefer files over chat summaries. Chat summaries are useful orientation, but they are
not durable evidence.

## 7. Manage Context Explicitly

When a Session grows large, inspect compaction before writing a checkpoint:

```bash
./pixir compact <session-id> --dry-run --json
./pixir compact <session-id>
```

Compaction appends a canonical `history_compaction` Event. It does not rewrite or
delete the original NDJSON Log.

## 8. Branch Deliberately

Use `resume` to continue the same Session and `fork` to branch into a child Session:

```bash
./pixir resume <session-id> "continue from there"
./pixir fork <session-id> --summarize
./pixir tree <session-id> --json
```

Pixir's fork model is inter-session. It is intentionally different from Pi-style
in-file `/tree` navigation.

## Boundaries

This ritual validates:

- source-built Pixir runtime;
- local `./pixir` binary freshness;
- ACP client wiring;
- multi-turn dogfood through ACP;
- Provider usage and continuation evidence;
- operator confidence for daily-driver use.

This ritual does not validate:

- a packaged T3Code provider;
- an upstream T3Code integration;
- a standalone terminal TUI;
- multi-provider support;
- production/SLA readiness;
- external-user installability.

## If Something Fails

Classify the failure before patching:

| Symptom | First classification question |
|---------|-------------------------------|
| T3 shows old behavior | Is the ACP client pointing at the freshly rebuilt `./pixir`? |
| First turn appears wrong in the UI | Is this a Presenter/adapter projection issue or a Pixir Log issue? |
| Continuation evidence is missing | Does `provider_usage` exist in the Session Log? |
| Context pressure is not visible | Does Pixir emit ACP `usage_update`, and does the client render it? |
| A child agent appears successful after timeout | Is the Subagent status actually terminal success, or partial/detached/timed out? |

When code and UI disagree, prefer the append-only Pixir Log and `provider_usage` as the
source of truth, then decide whether the bug belongs to Pixir core, ACP translation, the
adapter, or the client Presenter.
