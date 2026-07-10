# Changelog

All notable changes to Pixir are recorded here. Issue and PR references
(`#N`) point to the private development repository; this public mirror
carries curated history, so those references may not resolve here. Pixir is a developer preview;
the CLI/ACP runtime is the public surface, and there is no stable Elixir library
API yet. Versions follow [Semantic Versioning](https://semver.org/) with the
caveat that pre-1.0 minor versions may still change behavior.

## [Unreleased]

## [0.1.9] - 2026-07-10

### Added
- Orchestrator ergonomics (#205 items 1 and 3): the doctor JSON envelope
  carries an explicit delegation decision — `proceed: "true" | "judge" |
  "block"` with `judge_checks` listing the non-passing check ids (populated
  for `block` too; severity lives in `proceed`, detail in `checks[]`) — and
  the `read` tool gains optional line-based `offset`/`limit` with
  self-teaching continuation: sliced or truncated results end with
  `[truncated: showing lines X-Y of Z; continue with offset=N]` plus
  `lines_total`/`lines_returned`/`offset_effective`/`next_offset` metadata,
  an oversized single line advances past itself with a caveat, and default
  small-file reads stay byte-identical.
- Virtual delegate children (#284 F3): `subagents.workspace_mode:
  "virtual_overlay"` runs each child as a real model conversation against a
  bounded in-memory import of `subagents.read_set` — zero physical snapshots,
  zero real writes. The child's only mutation surface is the new
  `run_virtual_commands` tool (commands only; `read_set`/`limits` come from
  operator context, never model arguments), the Executor confines real reads
  to the imported read set and denies bash/write/nested orchestration for
  virtual children, and each child's proposed changes return as
  `children[].virtual_diff` with a bounded provenance ref in the durable
  `subagent_event` (envelope schema revision 4, additive). A child that
  finishes without producing an artifact fails honestly
  (`virtual_diff_missing`); oversize artifacts fail with the ref preserved.
  Transport retries for virtual children are gated by child-Log evidence
  (ADR 0036): any durable model/tool output blocks the retry, and a child
  that dies after producing a valid artifact keeps it on the failed result.
  Applying an artifact remains a separate explicit operation
  (`apply_virtual_diff`); `workflow_apply_from_compatible: false` is
  confessed on the affordance.
- `pixir gc` (#221 phase 2): `--json` builds an effect-free reclamation plan
  for terminal isolated subagent snapshots in the current workspace;
  `--apply` executes it. Fail-closed classification (reclaimable only when
  every parent-log reference reconstructs terminal — the status vocabulary
  derives from `Pixir.Subagents.terminal?/1`, `closed` included; running,
  detached, and unreferenced dirs are skipped with reasons; corrupt parent
  logs block planning), every `*.ndjson` under any `.pixir/sessions` path preserved
  byte-intact at its original path, per-dir apply errors recorded without
  aborting, and `reclaimable_bytes` reported net of preserved logs.
- Guided resume for transport-dead delegate children (#285): when a child
  dies on a terminal transport error and was not auto-retried, the envelope
  child carries `recovery.kind: "resume_suggested"` with a reason naming the
  error kind, the ready-made resume/diagnose commands, and — for
  write-capable children — notes that the session log is the source of
  truth, applied writes should be inspected before resuming, and a stale
  writer lease fails closed by design. Transport classification reuses the
  #278/#280 retryable vocabularies; when public results collapse the reason,
  the runner reads the latest `turn_failed` from the child Log.
- Native Subagents rehearsal (#204): `spawn_agent {"validate_only": true}`
  runs the exact validation a real spawn runs (shared pure core in the
  Manager) with zero side effects and returns an allowlist plan projection —
  effective knobs and limits, the workspace fidelity contract, effective
  permission, and an explicit `limitations` list confessing what validation
  cannot prove. Non-mutating only on exact boolean `true` (read-only and ask
  postures rehearse without prompting; malformed values fail closed), the
  Turn-level dry-run returns the same normalized plan, and virtual children
  may rehearse spawns while real spawns remain denied there.
- A worked example of the propose→review→apply cycle at
  `docs/examples/propose-review-apply.md` — written into the repository by
  the exact workflow it documents (#284 F4), including the honest limits it
  demonstrated in production: review verdicts are advisory (checkpoints gate
  order and failure, never verdict content) and truncated diffs are
  review-only evidence.

- Workflow apply step (#284 F2): a step may declare `"apply_from":
  "<producer_step_id>"` to explicitly apply the `virtual_diff` a
  `virtual_overlay` step produced — the propose-review-apply DAG. Validated at
  plan time (producer must exist, be virtual, and be in `depends_on`; knobs
  and spawning fields rejected; an explicit non-empty `write_set` is required
  and bounds the artifact paths BEFORE the engine runs), executed without
  spawning a subagent, and evidenced by the engine result stored verbatim in
  the completed-step record; a non-applied outcome fails the step and holds
  dependents.

- ACP exposes `reasoning_effort` as a session config option (#289): a third
  select alongside mode and model (`default|low|medium|high|xhigh`), sticky
  per session, with prompt-time precedence `_meta.reasoning_effort` >
  session option > config. The unset state renders honestly as `default`
  (both providers omit effort from the request body when none is set), and
  selecting `default` suppresses a configured effort rather than inventing a
  value. The requested effort is recorded as durable `subagent_event`
  evidence (operator-side truth); providers do not echo an effective effort
  back, so no such proof is claimed.
- Virtual Diff Apply (#284 F1, ADR 0030): `Pixir.VirtualDiffApply` plans and
  applies `virtual_diff` artifacts through a staged two-phase commit —
  all add/modify content is written to temp files before any target mutates
  (a staging failure, the dominant class, leaves every target byte-identical),
  the rename/delete commit phase has a narrow residual window whose rollback
  is total and non-raising, and the failed result confesses recovery
  (`recovery.rolled_back`, structured `restore_failures` kinds) instead of
  claiming filesystem transactionality it cannot have. Hash-checked
  preconditions, canonical workspace confinement with symlink resolution,
  per-file authorization through the write-policy seam, evidence paths
  protected at the Executor exactly like `write`/`edit`, and the ADR result
  shape as durable evidence (contents stripped). The model-visible
  `apply_virtual_diff` tool defaults `dry_run` to true and only counts as
  mutating when `dry_run` is explicitly false, so plans stay available in
  read-only mode. Apply is never automatic: overlays keep producing
  `apply.status: "not_applied"` until this operation is explicitly invoked.
- Bounded-write workers can self-verify (#240, v1 conservative): the write
  policy's `bash` key accepts `{"verify": [commands]}` alongside `"disabled"`,
  where each operator-declared command must be a literal `mix format` or
  `mix compile` invocation (no shell metacharacters, no parent-directory
  tokens, at most 8 entries). Authorization is exact match against the
  declared list after leading/trailing-whitespace trimming on both sides
  (no substring or prefix matching), after the existing confinement and
  read-only safe-list checks; denials now confess how many verify commands the policy declares.
  The effective list travels with the policy (normalize/metadata/rehydrate)
  and bounded_write dry-run plans report the per-child count. `mix test`
  entries are rejected with their own message: test execution stays with the
  orchestrator until this v1 is dogfooded.
- A no-network regression gauntlet for the Anthropic arc (#274): eight
  pins with canned transports — six end-to-end through `Turn.run`, two at
  the provider seam (`Anthropic.stream`) — covering the pa1
  request body (system blocks + `cache_control` + fenced late context),
  registry routing and its stub fallback, verbatim thinking replay with the
  foreign-dialect guard, the tool loop (including the pa1 fence riding the
  latest tool_result group — the P3 latest-user-message contract), durable
  cache evidence on `provider_usage`, compaction interplay at the Turn level,
  the error taxonomy (rate limit, overflow, overloaded, bounded `err_body`),
  and the fail-closed web_search/hosted-tools rejections.

### Fixed
- Every `bounded_write` workflow spec containing an `apply_from` step was
  rejected by the CLI validation gate — in dry-run AND real runs — because
  the rehearsal ran without the write policy the gate itself had just
  normalized (#291). The F2 apply-step runtime was unreachable through the
  CLI until this fix; the policy is now threaded into the shared rehearsal
  path and the acceptance is pinned end-to-end through the CLI contract.
- ACP prompts now resolve at a single total-order synchronization point
  (#267): a `session/cancel` racing a Turn's terminal status could flip the
  reply's `stopReason` under parallel load because the cancel flag was
  snapshotted in one server call while the reply was written in another.
  Cancel-wins-ties semantics (ADR 0009 §5) are preserved exactly and both
  orders plus the raced tie are pinned through an injectable resolution seam.
- Replay no longer orphans a `skill_view` tool call whose canonical
  `skill_activation` was recorded between the call and its result (#204):
  the activation is deferred past the matching `function_call_output`
  (byte-exact, only when exactly one unresolved matching call exists —
  ambiguous histories fall back to ordinary orphan repair), true orphans
  keep the synthetic repair without losing the activation, and the Anthropic
  history folding mirrors the rule so `tool_use`/`tool_result` adjacency
  cannot drift across providers.
- Workflow steps gained the #239-class gate (#282): in a bounded_write
  workflow, a writer-posture step whose agent resolves to a read-only
  `sandbox_mode` is rejected fail-closed at plan time with step-level
  location details; a read-only `subagents.role` at the spec level is
  correctly ignored by the workflow strategy.
- In-band provider overload errors are retryable again (#278): when the
  Responses stream delivers an `error`/`response.failed` event over HTTP 200
  with a transient type or code (`server_is_overloaded`,
  `service_unavailable_error`, `server_error`, `overloaded`, rate-limit
  codes), the classifier stamps `retryable: true` in the error details —
  mirroring the Anthropic 529 precedent — and BOTH retry layers read that
  classification: the provider's turn-level retry and the delegate's
  read-only-child auto-retry (which keeps honoring the legacy
  `type: "server_error"` shape for events recorded before this change).
- A `bounded_write` delegate spec with a read-only role (e.g. `explorer`) is
  now rejected fail-closed as `invalid_spec` at validation — dry-run and real
  runs identically (#239). The role's `sandbox_mode: "read-only"` used to
  silently override the spec mode: the delegation rehearsed clean, ran, and
  wrote nothing while the envelope looked successful. The rejection names the
  conflicting role and offers the two honest exits (write-capable role, or
  `read_only` mode).
- The pa1 prompt contract is now actually wired into the Anthropic request
  path (#272): when the provider registry reports `prompt_cache:
  :cache_control`, Turn threads the neutral pa1 ingredients (`prompt_mode`,
  `skills_index`, `agent_instructions`, `previous_turn_boundary_seq`) and the
  Anthropic provider assembles the body through `Prompt.build/1` — layer0 and
  skills-index system blocks with their `cache_control` breakpoints, and the
  previously-dropped `developer_context` (plus subagent role instructions)
  fenced into the latest user message as pa1 late context. The planned
  contract (version, breakpoints, layer0_hash) rides `provider_metadata`
  under `"prompt_contract"` as durable evidence. The OpenAI request shape and
  the legacy Anthropic path (no `prompt_mode`) are byte-unchanged.
- Error-body capture on non-2xx provider responses is bounded (#268): both
  transports retain at most 16 KiB through a shared helper, and a capped
  capture is confessed as `err_body_truncated: true` in the classified error
  details (key absent when nothing was dropped).

## [0.1.8]

### Added
- **Anthropic (Claude) as a second provider**, built evidence-first behind the
  existing provider seam (epic #243, design in ADR 0037):
  - Messages API transport core with streaming SSE and a fail-closed error
    taxonomy (#249).
  - `pa1` prompt contract: a frozen, cache-maximal prefix with a deliberate
    `cache_control` breakpoint planner (#254). The planner is unit-tested but
    not yet wired into the live request path — the integration is tracked in
    #272, found by this release's audit.
  - Provider-owned usage as durable evidence: an explicit cache map
    (`usage_summary.cache` with `creation_tokens` / `read_tokens`) on
    `provider_usage` events, `pa1` family identity stamped alongside, costs
    reconciled from Logs rather than estimates (#258).
  - Thinking replay: reasoning events are dialect-labeled at record time and
    re-injected verbatim next to their `tool_use` blocks on the next turn,
    guarded by model identity so a dialect never replays into the wrong
    provider (#262).
  - Tool-use mapping: Pixir tools project to Anthropic `tools` specs and the
    session history folds to Messages with correctly grouped `tool_result`
    blocks (#261).
  - Provider registry: `claude-*` model ids route to the Anthropic provider,
    auth checks are provider-scoped, and `pixir doctor` reports honestly per
    provider — `ANTHROPIC_API_KEY` guidance and data-retention notes only where
    they apply (#265).
- Threaded the opt-in hosted `web_search` knob through effective config, CLI parsing,
  Turn request assembly, delegate validation, spawn-agent stripping, and Anthropic
  fail-closed rejection so Provider-hosted search remains default-off and explicit
  (#255).
- Delegate/CLI attachments channel (#250, ADR 0021): a `tasks[]` entry may be an
  object `{"task": ..., "attachments": [...]}` and one-shot/resume take a
  repeatable `--attach <path>`; each local path becomes a durable Session
  Resource in the child, dry-run plans confess a per-child `attachment_count`,
  unknown task-object keys reject fail-closed, and the model-facing
  `spawn_agent` tool strips caller-authored attachments (operator knob, not a
  model capability).
- Workflow steps accept per-step `model`, `reasoning_effort`, and `attachments`
  (#270): validated at plan time, threaded through the runtime-owned opts
  channel only, and reported honestly in plans (`attachment_count`, omission
  over null); `virtual_overlay` steps reject the knobs, and the model-facing
  `run_workflow` tool strips them from step objects so a workflow-spawning
  model cannot smuggle provider knobs to children.

### Fixed
- Provider `output_items` order is preserved through Turn recording (ADR 0007):
  interleaved reasoning/message/tool items no longer regroup by type (#246).
- Workflow dry-run now validates the DAG through the runner's own path (#263):
  cycles, unknown dependencies, and duplicate step ids are rejected identically
  in attached, async, and dry-run modes — rehearsal parity by construction, not
  by a second copy of the rules.
- Subagent identity is runtime-owned (#234): child ids are always generated and
  task-position `index` arrives via the runtime opts channel, so caller-authored
  `id`/`index` args are ignored and can no longer influence workspace paths or
  forge position evidence in durable logs.
- Attachment URI handling is centralized and hardened (ADR 0021): case-variant
  `FILE://` schemes normalize, `file:` without `//` and URIs carrying query or
  fragment parts are rejected with specific reasons, and paths percent-encode
  correctly on the way in.

## [0.1.7]

### Added
- Delegate subagent children now carry durable `children[].index` task-position
  evidence across attached envelopes, async snapshots, tree projection, and retry
  lineage (#227). The delegate envelope `schema_version` is now `2` to signal the
  additive `children[].index` / `children_order` keys; the
  `pixir.delegate.envelope.v1` family name is unchanged (reserved for breaking
  shape changes).
- Delegate specs are validated fail-closed (#223): unknown top-level or
  `subagents` keys are rejected as structured `invalid_spec` with `field`,
  `json_pointer`, `path`, and `next_actions`, in dry-run and real runs alike,
  so a typo can no longer pass the rehearsal silently.
- New delegate spec provider knobs mirroring ACP `session/prompt` `_meta`
  (#223): `subagents.model` and `subagents.reasoning_effort`
  (`low|medium|high|xhigh`) thread to every child's provider calls with
  spec > config > default resolution; effective values are evidenced by child
  `provider_usage` events, not echoed in the envelope. The model-facing
  `spawn_agent` tool strips caller-authored `model`/`reasoning_effort` args:
  provider knobs are operator decisions, not a capability a spawning model
  grants its children.

### Fixed
- Delegate `--dry-run` now mirrors the runner's task normalization exactly:
  malformed or blank `tasks[]` entries are rejected as `invalid_spec` instead of
  silently planned, and a list-valued `tasks` field owns validation (even when
  empty) before any legacy `task` fallback, matching real-run branch precedence.
- The model-facing `spawn_agent` tool strips caller-authored `index` args so
  task-position evidence in durable `subagent_event` data cannot be forged.
- Workspace confinement no longer misreads leading POSIX environment
  assignments as path arguments (#188): `TMPDIR=/tmp mix test` and
  `PREFIX=/usr/local ./configure` pass, while literal outside paths,
  redirection targets, and non-leading `NAME=VALUE` arguments keep failing
  closed; the window resets after `;`, `&&`, `||`, and `|`. The residual
  runtime-expansion vector (`VAR=/outside cmd $VAR`) is documented in
  SECURITY.md: confinement is a defense-in-depth tripwire, not a sandbox.

## [0.1.6]

### Added
- Published the proc-pressure kernel-pressure evidence bundle (23 files,
  gate-hardened) at `docs/benchmarks/scale/`, and the matching /scale
  kernel-tax section: marginal threads/processes/RSS/kernel-CPU/involuntary
  context switches per additional worker under two labeled machine
  conditions, per-provider-call normalization from durable usage evidence,
  the spawn-tax microbench, and the completion audits with the negative
  result (199/205 loaded) published as the headline. The /scale hero line
  and the N=8 transport-table cause cell were corrected to claims the
  published bundles can back.

### Fixed
- `pixir delegate --help` (and the main help) now document `--timeout-ms` on
  the attached form; the flag was always accepted there but only listed under
  `delegate start`, so contract-of-record readers concluded it was invalid
  (#204).

### Added
- Subagents-strategy delegate result envelopes now give every non-completed
  child the same ready-made recovery commands the one-shot contract ships:
  conditional `children[].resume_command` and `children[].diagnose_command`,
  including children reported `running` at the collection horizon (their
  writer lease fails closed if anything is genuinely alive). Start/lifecycle
  snapshots stay terminal-only, and workflow-strategy children keep their
  step-based evidence without these commands. Without `--json`, per-child
  resume hints print on stderr, matching the one-shot mode contract (#204).

### Changed
- A `bash` call denied because the bounded write policy disables the shell now
  surfaces as `kind: "bash_disabled"` ("shell is disabled by the bounded write
  policy") instead of the misleading `write_policy_denied` ("write denied"),
  with shell-free `next_actions` (`use_native_read_tools`,
  `use_edit_or_write_within_allowed_globs`). The denial keeps exit code 3 but
  is no longer terminal for the child's Turn: the model can adapt with native
  tools instead of dying on a read-only command. Write-allowlist denials keep
  `write_policy_denied` and remain terminal (#218).

### Added
- Delegate spec transport knob: `subagents.transport` (or top-level
  `transport`) accepts `auto` | `websocket` | `http_sse`; invalid values fail
  `--dry-run` with a structured error and the effective value is surfaced as
  `limits.transport` (#205).
- Manager-level bounded auto-retry for read-only subagent children killed by
  mid-stream websocket drops or provider-declared-retryable server errors,
  with jittered re-queueing, an observable `retrying` lifecycle event, and a
  retry confession on delegate envelopes (`children[].retry_attempts`,
  `retry_max_attempts`, `current_attempt_index`, `retry_history`; present only
  when a retry happened) (#205).
- `usage_summary.model` is now populated on provider usage events, and
  subagent session ids are aliased in `pixir tree` projections (#216).
- Isolated subagent workspace snapshots accept extra exclusion directory names
  (directory basenames, byte-exact, matched at any depth) via
  `config :pixir, :subagents, snapshot_excluded_dir_names: [...]` or the
  `:excluded_dir_names` snapshot option; built-in defaults (`.git`, `.pixir`,
  `_build`, ...) always stay in effect, invalid names and a non-keyword
  `:subagents` application env fail closed with structured errors, and the
  effective list is confessed as `excluded_dir_names` in snapshot metadata and
  runtime failure envelopes (never on validation failures, where no effective
  policy ran) (#221).

## [0.1.5]

### Fixed
- Clean CLI exits now release Session writer leases across one-shot, `resume`,
  and attached delegate (parent and children); stale leases from crashed runs
  remain fail-closed behind `--force-release-writer-lease`. Headless
  orchestrators no longer need the force flag on the happy path.
- `Subagents.Manager` survives late timeouts or cancels racing an
  already-terminated child Session; the recorded timeout/cancel evidence is the
  honest record either way.

### Added
- `pixir-delegate` skill family for orchestrating agents
  (`.agents/skills/pixir-delegate*`): a host-neutral delegation judgment core,
  real blind-run demonstrations, deterministic `fanout.sh`/`steer.sh` scripts,
  and variants for Claude Code, Codex root agents, and Pixir-native
  orchestration. Discoverable by Claude Code via `.claude/skills/`.
- Site route `/scale` with measured scale evidence (up to 64 concurrent
  workers) and bounded public claims.
- Delegate CLI contract documentation for expensive orchestrators
  (`docs/examples/delegate-cli-live/README.md`): a per-subcommand exit-code table,
  the read/scope vs write-policy denial distinction (`outside_workspace` vs
  `write_policy_denied`), and honest caveats for `next_actions` and
  `observed_applied_writes`.
- `SECURITY.md` with private vulnerability reporting and a clear
  tripwire-not-a-sandbox disclaimer, and `CONTRIBUTING.md` describing the real
  workflow and invariants.
- Partial-write observability: bounded-write delegate envelopes now report
  `observed_applied_writes` from child Session Logs as an at-least lower bound,
  without changing existing `writes_applied_to` / `contract_status` fields.

### Changed
- Elixir requirement moved to `~> 1.20`; CI runs on Elixir 1.20.2 / OTP 29.
- Delegate error locations now carry machine-readable metadata (`json_pointer`,
  `path`, `step_index`) alongside the human-facing 1-based field label.

### Fixed
- `mix check` no longer hangs after the test phase. The test step nested a BEAM
  node under `cmd env MIX_ENV=test mix ...` that did not exit cleanly on teardown;
  it now shells out with `MIX_ENV` as an environment variable and returns cleanly.
- Bash tool workspace confinement now rejects path escapes beyond `..` — absolute
  out-of-workspace paths, `$HOME`/`~`, and symlink prefixes resolving outside the
  workspace — before crossing the host boundary, surfaced honestly as
  `outside_workspace` rather than a write-policy denial.

## [0.1.4] and earlier

See the release notes at
`docs/release-notes/open-beta-developer-preview.md` for the 0.1.0–0.1.4 developer
preview history (runtime truth and fanout honesty, ACP Registry readiness, and
runtime diagnostics).
