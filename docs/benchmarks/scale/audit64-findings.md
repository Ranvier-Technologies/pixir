# Doc-drift audit — 64 módulos, doble runtime (2026-07-05)

Cada módulo auditado independientemente por un worker Pixir (delegate N=64, una VM)
y un proceso codex exec con la MISMA tarea. Consenso = ambos lo marcaron.

## Major por CONSENSO (4)

### lib/pixir/event.ex
- Pixir: The moduledoc overstates type validation by claiming every event type is from the known vocabulary, while public new/4 accepts any atom.
- Codex: The moduledoc promises known-vocabulary event types, but new/4 permits arbitrary atom types.
  - drift: `:type` is always an atom from the known vocabulary. → `new/4` accepts any atom type and does not validate membership in canonical or ephemeral type lists. (lib/pixir/event.ex:12-74)
  - drift: Ephemeral events are only `:text_delta`, `:reasoning_delta`, and `:status`. → The code also defines `:plan` and `:context_pressure` as ephemeral event types. (lib/pixir/event.ex:27-46)

### lib/pixir/subagents/manager.ex
- Pixir: The module is documented with @moduledoc false and all public functions/callbacks lack @doc.
- Codex: The module is hidden with @moduledoc false and all public def heads lack @doc.

### lib/pixir/tools/bash.ex
- Pixir: The moduledoc overstates timeout cleanup by claiming no orphaned process is possible while the code only closes the shell port.
- Codex: The moduledoc overstates timeout cleanup by promising no orphaned processes when the code only closes the Port.
  - drift: Closing the port kills a hung command with no orphaned spawned process. → On timeout the code only calls Port.close(port); it does not create/kill a process group or otherwise reap descendant processes that bash may have spawned. (lib/pixir/tools/bash.ex:9-12,108-116)

### lib/pixir/tools/executor.ex
- Pixir: The moduledoc incorrectly calls `execute_call/2` side-effect-free even though it can execute mutating tools outside the `run/2` guard path.
- Codex: The docs call `execute_call/2` side-effect-free even though it can invoke real tool execution.
  - drift: `execute_call/2` is the side-effect-free core (no Events) used directly in unit tests. → `execute_call/2` emits no Events, but it dispatches to `module.execute/2` when not in dry-run, so it can perform tool side effects; it also bypasses `run/2` authorization/evidence guards. (lib/pixir/tools/executor.ex:7-11,393-402)

## Major por UN solo runtime (7) — revisar con más escepticismo

- **lib/mix/tasks/pixir.bench.real_subagents.ex** (Codex): The moduledoc still frames the task as measuring only provider/model capability despite implemented scenario scoring beyond capability checks.
- **lib/pixir/auth/codex_oauth.ex** (Pixir): The moduledoc promises structured errors for all functions, but a public function returns an unstructured atom error.
- **lib/pixir/config.ex** (Pixir): `file_model/1` is documented as file-only but can return app/env/default effective model values.
- **lib/pixir/log.ex** (Codex): The moduledoc overstates the canonical-event invariant because create_session/3 can write non-canonical events.
- **lib/pixir/permissions.ex** (Codex): safe_command?/1 documentation overstates git mutation detection when git options precede the subcommand.
- **lib/pixir/permissions/write_policy.ex** (Pixir): The moduledoc understates that the policy can allow a limited set of bash commands.
- **lib/pixir/session_lease.ex** (Codex): The moduledoc overstates fail-closed behavior for stale or ambiguous leases because holder authorization only checks holder_id.

## Top funciones públicas sin @doc (según Pixir)

- lib/pixir/subagents/manager.ex: 12
- lib/pixir/provider/connection.ex: 10
- lib/pixir/session.ex: 7
- lib/pixir/config.ex: 5
- lib/pixir/acp/server.ex: 4
- lib/pixir/delegate/daemon_server.ex: 4
- lib/pixir/provider/websocket_client.ex: 4
- lib/pixir/tools/command_boundary.ex: 4
- lib/mix/tasks/pixir.smoke.subagents.ex: 4
- lib/pixir/auth.ex: 4