# lib/pixir/tools — tools + the Executor

The model's hands: `read`, `write`, `edit`, `bash`, behind one `Pixir.Tool` behaviour and a
central `Executor` that confines, gates, and records every call.

## Map

- `tool.ex` — the behaviour: `__tool__/0` (name + description + JSON schema) + `execute/2`,
  with a default effect-free `dry_run/2` (overridable). Also `error/3` (the envelope) and
  `truncate/2` (16 KB model-channel cap).
- `executor.ex` — the enforcement point: validates args, confines paths to the Workspace,
  applies the permission policy, records `tool_call`/`tool_result`, honors `dry_run` centrally.
- `read.ex` / `write.ex` / `edit.ex` / `bash.ex` — the four file/shell tools. `edit` is
  exact-match, unique-unless-`replace_all`. `bash` runs via a `Port`, killed on
  `bash_timeout_ms` (120s).
- `skills_list.ex` / `skill_view.ex` — progressive Skill disclosure. `skills_list` lists
  bounded Skill metadata only; supporting resources such as Workflow Templates are loaded
  explicitly through `skill_view`.
- `run_workflow.ex` — executes concrete Workflows or instantiates a referenced
  Skill-backed Workflow Template through the existing Workflow runtime. Do not add a
  second script/runtime path here.
- `registry.ex` / `workspace.ex` — tool registry + path confinement.

## Contract every tool obeys (ADR 0005 — enforced in review + `test/support/tool_contract.ex`)

1. **Dry-runnable** — side-effecting tools (`write`/`edit`/`bash`) return a structured *plan*
   (`%{"would" => ..., ...}`) and mutate nothing. Read-only tools are trivially compliant.
2. **Self-describing** — `__tool__/0` is the help; descriptions are written for a fresh agent.
3. **Structured errors** — `Tool.error(kind, message, details)` → `%{ok: false, error: %{…}}`.
4. **Channel discipline** — tool output for the model is **token-bounded** via `Tool.truncate/2`
   (with a `…[truncated]` marker); no ANSI/spinners; a tool never reads stdin.

Permissions (ADR 0006): `:auto` default · `:ask` gates writes + unsafe shell · `:read_only`
denies mutation. Policy in `../permissions.ex`, applied by the Executor.

## Error kinds & the bash-exit rule

The stable `kind` vocabulary is enumerated in `t:Pixir.Tool.kind/0` (the single source of
truth — add a kind there deliberately, not ad hoc). Use `Tool.error(kind, message, details)`.

A `bash` command that runs but exits nonzero is **not** an error: it returns a successful
result `%{"output", "exit_code", "ok" => false}` so the model can read the output and reason
(a no-match `grep` exiting 1 is normal). There is no `:nonzero_exit` kind — branch on
`exit_code`/`ok`. (ADR 0005, deliberate divergence.)
