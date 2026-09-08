# Changelog

All notable changes to Pixir are recorded here. Issue and PR references
(`#N`) point to the private development repository; this public mirror
carries curated history, so those references may not resolve here. Pixir is a developer preview;
the CLI/ACP runtime is the public surface, and there is no stable Elixir library
API yet. Versions follow [Semantic Versioning](https://semver.org/) with the
caveat that pre-1.0 minor versions may still change behavior.

## [Unreleased]

## [0.1.16] - 2026-09-06

### Added
- Virtual-overlay children can explicitly select a successful `deliverable` artifact,
  so later unmarked reads do not displace it. Selection survives cold projection;
  applying the artifact remains a separate permissioned operation (#631).
- Astra catalog support and model/backend-aware `max` reasoning effort across
  Config, Provider, ACP, Delegate, Subagents and Workflows. Admission is limited
  to exact `gpt-6-astra` on the supported ChatGPT/Codex Responses route; incompatible
  combinations fail explicitly, and catalog presence does not grant account access
  (#616, #617, #622).
- Compiled build identity in Core/Monitor diagnostics, so operators can distinguish
  a running artifact's source revision and fingerprint from later checkout changes
  (#618). Delegate envelopes now use additive schema revision 11.
- Source-only `bin/verify --release` with explicit application coverage, toolchain
  gates, bounded commands and durable evidence. Monitor acceptance includes the opt-in
  real browser lifecycle; offline success does not certify live Providers or publication
  (#614, #620).
- Delegation results now optionally include an evidence-gated landing manifest for
  completed children whose durable Logs report successful shared-workspace `write`,
  `edit`, or `apply_virtual_diff` paths, or a referenced `virtual_diff` still in
  `not_applied` state. Entries carry current regular-file drift checks and ready
  dry-run actions that resolve the artifact from the named child Session Log without
  embedding it; empty manifests preserve prior output bytes, and matching
  structured/text child and path caps confess omission counts. Landing manifests
  cover delegated child Sessions on `wait_agent`, child-backed workflow, and Delegate
  presentation surfaces; in-process Workflow virtual-overlay steps keep their
  existing direct `virtual_diff` presentation and are outside this manifest scope.
  Landing manifests introduced additive envelope revision 10 before the build-identity
  addition in revision 11 (#589, #618).

### Changed
- Virtual-command feedback prioritizes command outcomes within bounded output using
  the shared truncation marker. Virtual edits remain invocation-local: subsequent
  calls reimport source files. This avoids per-child physical workspace copies, not
  durable Logs or artifacts. The Tool/Prompt Contract advances to `px8`/`pa5`,
  intentionally restarting prompt-cache warming; no model-speed gain is claimed
  (#631).
- Session tree projection folds each selected Log once per query instead of repeating
  whole-tree reads. Anthropic replay accumulates messages and items linearly while
  preserving wire ordering; these improve local processing, not context size or
  Provider token usage (#613, #614).
- Monitor consumes the shared Core bounded Log reader, keeping prefix/tail evidence
  within the existing 8 MiB and 20,000-event limits. Partial parents remain navigable;
  partial child evidence does not invent attempts, complete usage, clean mutation
  history or liveness. Exact omitted bytes and unknown omitted-event totals are the
  explicitly accepted contract; genuinely unprojectable Logs remain named failures.
  Normal replay and canonical Logs are unchanged (#549, #621, #623–#626).
- Repository delegation Skills resolve and validate the caller's explicit/local/PATH
  Pixir binary deterministically. Invalid explicit overrides fail rather than silently
  selecting another installation; these Skills remain outside the Hex package (#616).

### Fixed
- WebSocket continuation recovery recognizes structured missing-response evidence
  and permits only one clean full replay before observable progress. Tool declarations,
  callbacks and other effects veto replay/fallback; failed recovery cannot retain a
  failed response identity. Caller timeout or connection-process loss also vetoes
  replay when reducer progress can no longer be recovered (#629, #633).
- Invalid context-window overrides no longer discard valid siblings. Missing or
  invalid usage is reported as unavailable rather than healthy zero usage; an actual
  integer zero remains valid. OpenAI and Anthropic preserve this distinction before
  accounting normalization and through durable usage summaries. Historical summaries
  without provenance are not retroactively repaired; unknown model capacities are
  not guessed (#630, #633).
- Delegate forwards the selected transport into actual child Provider options,
  including Workflow children, while preserving unrelated inherited options (#632).
- Write/Edit replacement preserves ordinary rwx bits and uses exclusive temporary
  files without overwriting unrelated temp paths. No ownership, ACL, xattr or special
  privilege-bit preservation is promised (#619).
- Session tree projection excludes recognized self-scoped metadata from descendant
  edges. Benchmark cleanup synchronously stops scenario-owned Sessions while preserving
  unrelated Sessions; queue and timeout tests use stronger lifecycle evidence (#619).
- Present-invalid WorkspaceSet configuration fails explicitly across Monitor consumers
  instead of deduplicating, truncating or silently falling back to single mode (#614).
- ACP test response polling consumes captured frames incrementally; closed-port and
  timed-out-child await tests no longer treat a 500 ms scheduler budget as correctness.
  Home isolation is verified through behavior, and Monitor CI is isolated (#615, #627).
- Public package installation docs no longer advertise the private development
  repository, and package hygiene tests check the actual file allowlist (#614).
- Bash process-group liveness checks support the BusyBox fallback without changing
  the process-group termination contract (#607).
- The CLI presenter idle watchdog now extends its wait while a silent in-flight bash
  process is alive. Each extension is the smaller of the presenter interval and the
  process's remaining effective timeout plus kill-escalation grace; closed, dead, and
  over-cap entries cannot extend it, while genuinely idle sessions retain the existing
  exit-124 recovery path (#575).
- ExUnit now replaces any ambient `PIXIR_HOME` with a suite-local scratch home, preventing an operator `responses_backend` configuration from changing Provider and Turn test resolution (#586).
- `pixir resume` now rejects a supplied `--write-policy` whose canonical hash differs
  from the Session's pinned mandate, naming both hashes and directing the operator to
  resume without the flag or start a fresh Session instead of silently enforcing the
  original policy. A narrower differing file now refuses too rather than combining with
  the pinned policy by intersection. Sessions with no pinned mandate retain the existing
  documented one-Turn supplied-policy overlay, after which a flagless resume returns to
  their durable unbounded posture (#574).

## [0.1.15] - 2026-08-24

### Added
- New `presenter_idle_timeout_ms` config key (default `300_000`) controls the CLI
  one-shot/resume `Conversation.await` idle deadline between Session events; ACP has its
  own loop and does not honor this key. Pixir's three clocks are transport
  (`stream_idle_timeout_ms`, silence within one Provider stream), that CLI await deadline,
  and bash hang cap (`bash_timeout_ms`, per tool call). The presenter default deliberately
  exceeds the bash default plus cleanup grace so a timed-out tool can return before the
  CLI gives up. Agents may still raise a bash call's `timeout_ms` up to
  `bash_timeout_max_ms` (600 seconds by default), above the presenter default; the
  extension-during-tools step, not this ordering, structurally closes that race.
  `stream_idle_timeout_ms` was never the CLI presenter knob (#575).
- The `bash` tool schema now accepts an optional positive integer `timeout_ms` so an
  agent can raise or lower a command's runtime bound; requests remain capped by the
  operator's `bash_timeout_max_ms` (#575).
- `config.json` accepts an extensible `skills` object with `user_scope: false`
  to exclude `~/.agents/skills` from Skills discovery and Turn prompt indexes;
  omission preserves the existing user-scope behavior (#567).

### Changed
- Reverted the #570 build-mode style sentence in both prompt families: its measured
  effect on output quality was negative, so the build bases return to their prior
  bytes. Plan-mode bytes are unchanged. The OpenAI-family Prompt Contract bumps from
  `px6` to `px7` and the separate Anthropic lineage from `pa3` to `pa4`, intentionally
  invalidating each prompt-cache family once with attributable `provider_usage`
  evidence (#570).
- Timed-out `bash` commands now confess the spawned OS pid and the SIGTERM/SIGKILL
  escalation used. Cleanup best-effort terminates direct children with `pkill -P`,
  signals the spawned pid, waits a short grace period, escalates when needed, and then
  closes the port; deliberately double-forked daemons remain out of scope (#575).
- Bash's schema change bumps the OpenAI-family Prompt Contract from `px5` to `px6`
  and the separate Anthropic lineage from `pa2` to `pa3`. This intentionally
  invalidates each prompt-cache family once, attributable in `provider_usage`
  evidence under ADR 0020 and ADR 0037 (#575).

### Fixed
- The public `/scale` page no longer claims compatibility with "any Open Responses
  endpoint": the copy now states the ADR 0002 amendment's evidence level (mode
  shipped in v0.1.11, endpoint compatibility observed live against a local
  open-source server during the v0.1.12 cycle), completing the half of #500 that
  the v0.1.14 CHANGELOG overstated as absorbed (#500).
- Bash timeout kill escalation now uses the POSIX `--` separator when signalling
  the negative process group, so SIGTERM/SIGKILL delivery and the aliveness check
  work on procps-ng `kill` as well as BSD `kill`; previously on Linux the signals
  never landed on exec-flattened childless commands even when the escalation
  confessed `sigkill` (#592). BusyBox `kill` remains unsupported for the
  group alive-check (#594).
- The bounded-write outside-workspace shell scanner now permits the exact `/dev/null`
  sink token while continuing to reject every other outside-workspace absolute path
  (#579).
- Integrator re-verification guidance now comes from one shared source and reaches
  terminal `wait_agent`, `run_workflow`, and `pixir delegate` presentation surfaces
  whenever completed, timed-out, or closed children may have left integrable work;
  incomplete polls and failed/cancelled-only outcomes remain unchanged (#577).
- Workspace-local `.pixir/` roots now seed an exclusive, best-effort `.gitignore`
  containing `*`, preventing agent `git add .` operations from committing Session state
  while preserving any operator-managed ignore file (#580).
- ACP server tests now poll for the response matching each JSON-RPC request id without
  flushing output, then independently await expected `sessionUpdate` notifications by
  predicate so early and late asynchronous updates cannot hide prompt responses (#571).
- `wait_agent` results now guide the integrating parent to re-verify completed child
  results with the workspace's own typechecks, tests, and work-brief verification
  commands before committing or declaring the work done. This is guidance, not
  enforcement (#569).
- One-shot presenter idle timeouts now consult bounded in-memory Subagent presence only
  when a positive idle deadline expires. Running children require a live child timeout;
  retry-queued children require the active bounded `wait_agent` waiter. Diagnostics
  idempotently hydrates restarted Manager state using the live parent Session workspace,
  with a fold-tolerant call timeout, so isolated child paths cannot corrupt restored
  parent roots. The expiry path drains a just-queued terminal parent event before
  selecting exit 124, while genuinely idle trees retain the existing
  `presenter_idle_timeout` recovery envelope (#568).

## [0.1.14] - 2026-08-22

### Added
- Native OpenAI compaction is a default-on overlay after OpenAI Responses
  resolve (#535, #537, #538; tracker #522 stays open). Overlay-on
  `openai_responses` Turns whose host is `chatgpt_codex` or official
  `api.openai.com` send product `compact_threshold` 200000
  (`Pixir.Compaction.compact_threshold/0`). `open_responses` and Anthropic
  stay off (`native_unavailable`); explicit `compaction.native: false` wins
  (`overlay_off`). Local `history_compaction` remains the durable checkpoint;
  `native_replay` is an optional replay window on that Event (ADR 0040).
  Recovery stays local. Official `POST /responses/compact` is only
  `https://api.openai.com/v1/responses/compact`. `chatgpt_codex` standalone
  compact stays local and does not POST to the Codex `/compact` 404 host
  (`Pixir.Provider.Compact.standalone_supported?/1`). This release does not
  close #522 or #512.
- ACP v1 presenter surface: `session/list`, `session/close`, and in-memory
  `session/delete` (Log stays; no durable hide sidecar — #515 closed as
  YAGNI), slash-as-Skills (`available_commands_update` on load/resume and
  when the Skills fingerprint changes), `write`/`edit` diffs, stable
  `messageId` on chunks, and `/compact` as a runtime command with a
  structured completion and no fake usage gauge (#521, #524, #529).
  `web_search` is a sticky `configOption` select (`on`/`off`) (#530).
  Runtime-owned config changes push the complete `configOptions` list as
  `config_option_update`; `update_plan` in plan mode is the live plan→build
  producer (#560, #561; #520 closed after Zed dogfood). Epic #512 stays
  open.
- Monitor Instrument Manual plus the dotted-label affordance (#553). Compact
  advisory-chip verdict words route through that shared classifier (#557).

### Changed
- Hosted `web_search` now defaults on only after the request resolves to
  `chatgpt_codex`. `open_responses` and Anthropic stay off. An explicit
  `false` from config, CLI, `_meta`, or spawn args still wins. Invalid
  config cannot enable search by accident. Evidence remains `provider_usage`
  (#527; Part of #523, #523-B).
- Site terminal-proof copy reports `0.1.14` instead of the stale `0.1.12`
  doctor version (`site/src/components/TerminalProof.astro`; #500 asked for
  0.1.13 and is absorbed here).

### Fixed
- Delegate horizon overrides no longer reconstruct as phantom nil-id children (#479).
- Name-less or non-binary-name tool calls now count as write-capable evidence during fail-closed resume posture restoration (#480).
- Malformed Provider-committed call warnings no longer render tool argument values (#473).
- Monitor child-log write evidence now requires a binary `call_id` on both the write call and successful result, preventing missing IDs from fabricating observed paths (#481).
- ACP `session/prompt` admission reflects Session state: a busy or residual
  turn is an explicit `-32602` refusal rather than an empty successful Turn (#486).
- Warm Subagent resume posture is bound to lineage proof after the last valid
  boundary; earlier posture in the seed Log is ignored (#487).
- Session record failures on the Turn egress path classify as
  `:session_record_unavailable` instead of crashing the Turn they report (#501).
- Delegate horizon admission fails closed on the daemon async-start path as
  well as the plan path (#502).
- Delegate fanout validates process and envelope verdicts before treating a
  child as completed (#504).
- Failed child Session Resource staging is compensated so a partial stage
  does not leave orphan dirs (#505).
- Monitor launcher throw and exit are contained; a launch-surface failure
  no longer takes down `serve` (#503).
- Monitor activity-ledger identities are scoped to a stable workspace plus
  run id, so two workspaces cannot share a ledger key (#506).
- Turn declarations are fenced by Session incarnation, so a predecessor
  Session cannot declare committed calls onto a successor (#509).
- Logical Turn cancellation is fenced to the Turn that owns the interrupt,
  so a successor is not cancelled by a stale signal (#510).
- Committed function calls still declare after a dead native-threshold gate
  (`:noproc`); a gone overlay Task no longer drops wire-committed calls (#536).
- CLI INT-relay helper is reaped on port close so inherited fds do not hang
  pipelines that consume pixir output (#547).
- Subcommand-shaped argv (`pixir <word> --flag…`) is refused before any
  Session starts, instead of falling through to auto-mode prompt (#546, #562).
- Monitor names every unprojected Log in limitations (`id`, size, recency,
  real error kind) instead of a silent drop (#550). Presentation-honesty
  wave tightens truncation, run-unavailable, and provenance-absent copy
  (#548). Unlinkable run ids are rejected at the list envelope and counted
  as dropped (#559). Browser tmp globs are scoped per ExUnit run (#558).
  Partial-fold of oversized logs (#549) is not in this release.
- ExUnit no longer reads the operator `~/.pixir` or `~/.agents/skills`
  (`PIXIR_HOME` / Skills `user_home`); planted bleed names fail the suite
  if isolation is skipped (#563, #564).

## [0.1.13] - 2026-08-02

### Added
- New `:dangling_tool_call` error kind in the provider family of the `Pixir.Tool`
  error taxonomy (#462). It classifies the Responses API's in-band rejection of a
  request whose input carries a `function_call` with no matching
  `function_call_output` — delivered as `invalid_request_error` over HTTP 200 with
  `param: "input"` — and carries the rejected `call_id` in `details`. The
  structural gate comes first, and only once it passes is the `call_id` parsed
  out of the message; prose alone never classifies. The kind is
  never retryable at the provider layer; the bounded recovery that consumes it
  lives in the Turn.
- Delegate admission fails closed on short caller horizons (#433): a declared
  `--timeout-ms` shorter than the plan's critical path is rejected with a
  structured error and a `suggested_timeout_ms`, the dry-run carries the same
  verdict as a non-mutating `would_reject` advisory, and
  `--allow-short-horizon` remains the explicit break-glass. Envelope schema
  revision 6.
- Dry-run plans carry an advisory `plan_warnings[]` (#443): when a declared
  workflow timeout caps a step's own declared budget, the warning names the
  offending step (`step_index`/`step_id`/`json_pointer`/`path`), the declared
  and capping timeouts, and the `effective_step_timeout_ms` the step will
  actually receive. Advisory only — it never changes `would_reject`, an
  admission verdict, or an exit code. Envelope schema revision 7.
- Workflow steps can opt in to scheduling against an unverified dependency
  (#436): `allow_unverified_depends_on` names, per step, the specific upstream
  dependencies the step may start against when their checkpoint exists but has
  not passed verification — for lanes that audit on partial results. The step's
  own checkpoint then confesses it: `verification.unverified_dependencies` plus
  a `"ran_against_unverified_dependencies"` known limitation. The default
  remains verified-only; the opt-in is per step and per named dependency,
  never global.
- A child cancelled by its parent now gets a terminal `cancelled_by_parent`
  event appended to its own Log (#444), so the child's record ends with an
  honest terminal instead of trailing off mid-Turn.
- ACP `session/prompt` results carry machine-readable turn-failure facts
  (#465): `_meta.pixir.turn_failure` is attached exactly when a `turn_failed`
  event was observed during the prompt — bounded, type-guarded fields
  (`terminal_status`, `error_kind`), never the message or details, which
  already travel as chat content. The chat rendering of ADR 0009 §5 (content +
  `stopReason:"end_turn"`) is unchanged; the ADR is amended in place.
- Monitor: a child Session id resolves to its owning parent run (#438), child
  write evidence and policy denials fold into the mutation basis (#439), owner
  residency is reported separately from owner brokenness in liveness (#440),
  keyed workspace sets widen to a bounded 2..8 sources (#442), and child
  activity arriving after the parent run went terminal is reported instead of
  dropped (#447).

### Changed
- Delegate child entries carry a `warm_start` lineage projection (#435), on
  `subagents` children and workflow steps alike: `warm_started`,
  `seed_session_id`, `fork_root_session_id`, `replay_event_count`, `strategy`,
  and `boundary_marker_kind`. The key is unconditional — a cold child reports
  the absence of a seed rather than omitting it, so a consumer can tell a cold
  run from an unreported one. `tasks[]` entries and workflow steps accept an
  optional `seed_session_id` spec key to request the warm start. The delegate
  envelope's additive schema revision is now `9`; the
  `pixir.delegate.envelope.v1` family name is unchanged.
- A bounded-write denial is recoverable feedback instead of an unconditional
  Turn kill (#446). The first denial in a Turn no longer halts the tool loop:
  the remaining calls of that provider response still run, and the structured
  denial — denied tool, requested and normalized path, matched rule, policy
  identity, `next_actions` — is delivered to the model as that call's tool
  output on the next round-trip, so a worker that probes a path can write inside
  the allowlist, fall back to read-only work, or finish with an honest report
  instead of costing a coordinator a full adjudication and a `pixir resume`. The
  **second** denial in the same Turn is turn-fatal, unchanged in shape:
  `turn_failed` with the terminal tool-error record and the same exit code. N = 2
  is fixed — no flag, no policy key, no environment variable. The strike is keyed
  on the denial kind, so allowlist misses, workspace-root targets,
  child-broadening refusals, outside-workspace bash tokens, and denials surfaced
  through `apply_virtual_diff` all count the same; `bash_disabled` remains
  non-terminal and never strikes. The counter is Turn-scoped and resets on every
  Turn including a resumed one, so prior denials in a Session's Log are never
  recounted.
- A bash command whose path reaches outside the workspace now raises the
  `write_policy_denied` kind rather than `outside_workspace` **when a bounded
  write policy is in force** (#446). It is a boundary probe like any other, so it
  strikes, is turn-fatal on the second strike, and enters the confession — the
  three surfaces now classify one set of events instead of three. The rule that
  refused the command survives unchanged in `matched_rule: "outside_workspace"`,
  and the plain workspace-confinement error raised outside any bounded-write run
  keeps the `outside_workspace` kind, since it is not a policy denial at all.
- Every denial, recoverable or fatal, is still a `permission_decision` Log Event
  with `gate: "write_policy"` and its policy identity intact — recoverability does
  not reduce the audit record. Identity now survives the confinement and root
  denials too (`path_outside_workspace`, `workspace_root_not_writable`,
  `symlink_path_component`, `path_not_inspectable`), which are raised before the
  allowlist is consulted and previously carried no `policy_id`/`policy_hash`/
  `policy_version` for the coordinator to reconcile against.
- Delegate envelopes and workflow checkpoints gained a mandatory `write_denials`
  confession (#446). It appears at the envelope top level and on each child entry,
  and in the `workflow_checkpoint.v1` checkpoint payload, present even when there
  were no denials — and even when the run produced no children at all — so its
  absence is a schema violation rather than an ambiguous silence. Every
  bounded-write checkpoint carries it, including held, virtual-overlay, and
  apply steps that never spawn a subagent and so confess an empty one. Each entry
  reports the tool, the target it aimed at — the requested path, or the denied
  command, or the tool name for the two denials that aim at no path at all
  (`child_policy_override_unsupported`, `unsupported_mutating_tool`). The target
  is always the aim and never where a refusal stopped: a write to
  `link/deep/out.txt` refused at the `link` component confesses the full
  requested path, with the failing component reported beside it in its own
  `symlink_component` / `uninspectable_component` key, so the coordinator can
  tell *which* write under `link/` was refused. Each entry also reports the
  matched rule, the policy identity, and a
  `disposition` of `recovered`, `fatal`, or `unresolved`.
  `unresolved` is the honest reading of a denial whose **own** Turn never reached
  a terminal event in the Log — a crash mid-Turn, an interrupt, a partial Log, a
  fold of a running Session: Pixir does not infer recovery from missing evidence.
  A Turn ends at its terminal event or at the `user_message` that opens the next
  Turn, whichever comes first, so an interrupted or supervisor-killed Turn — which
  records neither `assistant_message` nor `turn_failed` — has its denial frozen as
  `unresolved` instead of being closed by the *next* Turn's terminal event on a
  resumed Session. A Log that exists but cannot be read now confesses
  `status: "unavailable"` with an `error` and **no** `count`, at the child level
  and contagiously on the aggregate, so a coordinator summing counts can never
  add a zero for evidence it never saw; a Session that simply never wrote a Log
  is unaffected and still folds to `count: 0`. A
  completed run with a non-empty `write_denials` is a signal to check whether the
  worker's scope was drawn correctly, not a defect in the worker. `bash_disabled`
  denials are excluded from the confession for the same reason they never strike:
  the shell being off is a property of the mode, not a scope drawn too small.
  They remain in the Log. The confession is scoped to terminal envelopes;
  dry-run plans, detached start acknowledgements, and `status`/`attach` liveness
  snapshots omit it rather than shipping a misleadingly empty one, as
  `docs/cli-contract.md` now records. The delegate envelope's additive schema
  revision is now `8`; the `pixir.delegate.envelope.v1` family name is unchanged.
- The bounded write policy's verify allowlist is operator-declared (#445): a
  policy's `bash` map accepts `verify_prefixes` alongside `verify`, so a writer
  in a pnpm, Python, Go, or Rust workspace can verify its own work instead of
  structurally finishing blind. A prefix is one or two literal tokens matched by
  token (`pnpm typecheck` never admits `pnpm typechecker`), and declaring an
  allowlist replaces the built-in `mix format` / `mix compile` default rather
  than extending it. Every existing per-entry filter still applies unchanged —
  no shell metacharacters, no parent-directory tokens, at most 8 entries,
  workspace confinement at authorization time — and rejections now report the
  allowlist actually in force so the operator can tell which one applied.
  Omitting `verify_prefixes` leaves behavior and the durable policy hash
  byte-identical, and `mix test` stays rejected under the default. On `resume`,
  the restored and requested allowlists intersect by tokenwise coverage — a
  prefix survives only when the durable side covers it, so `mix` against `mix
  format` keeps `mix format` — and the shell is disabled when the `verify`
  intersection is empty. The new `docs/bounded-write-policy.md` documents the
  config shape.

- The delegate envelope's schema revision derives from an append-only,
  feature-keyed registry (#461): two parallel envelope PRs now collide as a
  textual merge conflict instead of silently shipping several features under
  one revision number, and a parity pinning test guards the registry's
  contiguity, uniqueness, and the wave-elected 7/8/9 history. Consumers see no
  shape change — `schema_version` stays an additive integer. Every additive
  envelope change appends exactly one registry entry and one CHANGELOG line
  naming its feature; the convention is stated in `docs/cli-contract.md`.
- Monitor: each run-card copy slot names the fact it reports (#441), so a
  card's copy can no longer read as a claim about a different lifecycle stage.

### Fixed
- A terminal record can no longer out-crash the Turn it reports (#470). The
  three terminal finishers recorded `turn_failed` (and partial assistant text)
  with a bare call that exited the Turn Task when the Session was already gone
  — dying in the very path built to report the failure. Terminal writes now
  degrade with a bounded-class log line, the ORIGINAL error survives as the
  Turn's return value, and a record stalled past its call timeout classifies
  as Session unavailability instead of escaping as a crash.
- Cancelling a Turn mid-stream no longer poisons the Session (#462). A function
  call the provider had committed on the wire but Pixir had not yet persisted
  died with the killed Turn Task, and every later prompt on that Session was
  rejected in-band by the Responses API — `invalid_request_error` over HTTP 200,
  `param: "input"`, "No tool output found for function call `<id>`" — for an id
  that appeared in no Log event, so the Session was unusable for good. Two
  layers close it. **Drain to persistence:** each function call is now handed to
  the Session process the instant its output item completes on the wire, from
  inside the streaming path rather than after the stream returns, so a cancel
  landing mid-stream still finds the call in the hands of a process that
  survives the kill; the interrupt drains it to the Log as a `tool_call`, which
  the existing orphan reconciliation closes with its usual `orphan_tool_call` /
  `interrupt` result. Both transports inherit this — the seam is in the shared
  event reducer, not in a transport. The streaming runner outlives the Turn it
  belongs to on the default idle-watchdog topology, so declarations carry the
  identity of the Turn that made them — a monotonic generation issued at Turn
  start — rather than merely asserting that some Turn is running. A declaration
  whose generation is no longer the running one is drained on the spot: both when
  it lands with no Turn at all and when it lands while a *successor* Turn is
  already alive, where attributing it to that successor would have let the
  successor drop it at its own clean end. A Turn start drains whatever it finds
  instead of clearing it. A declaration that cannot be handed over — a
  Session that is gone or stalled — is logged and swallowed rather than killing
  the stream, and is never reported as a retryable transport error.
  **Build-time recovery:** a request rejected
  for a dangling call id absent from the Log is healed by synthesizing a
  cancelled output for exactly that id and retrying, which also repairs Sessions
  already poisoned by older binaries. Classification is gated structurally first
  — an `invalid_request_error` (or `bad_request`) on `param: "input"` — and only
  then is the rejected id parsed out of the message; prose alone never
  classifies, but a message rewording does silently disable the layer, so the
  parse is not incidental. Recovery is bounded once per id, by a total budget per
  Turn, and by a Session-lifetime ceiling counted off the synthesized markers
  already in the Log; it refuses to fire for an id the Log already carries (that
  remains the orphan reconciliation's job); and a second rejection surfaces the original
  provider error unchanged. Every synthesis appends durable Log evidence — a
  `tool_call` marked `synthesized` plus an `orphan_tool_call` result asserting
  the call did **not** run — before the retry is issued, so the Log never
  pretends a tool executed. A recovered Turn's envelope and exit code are those
  of a normal Turn. This is the first TURN-LEVEL recovery retry in Pixir: the
  first retry triggered by a structured `:dangling_tool_call` error that
  *modifies the rebuilt request*, appending synthesized evidence before
  re-sending it. Transport- and status-level retries of transient provider
  failures already existed via `Pixir.Provider.attempt/5`, which re-sends the
  request unchanged; ADR 0036 is amended to record this new class against that
  ADR's own retry conditions.
- Monitor: a launch handoff no longer ends `serve` (#437). The handoff is
  auxiliary to serving, so a reader that races the FIFO writer, closes it early,
  or never attaches now emits one `launch_degraded` frame and re-arms a fresh
  private directory, FIFO, and bounded writer — announcing the newly valid
  `fifo_path` in a new readiness frame — instead of exiting 1 with
  `{:writer_exit, 74}` while the listener and projection were healthy. Re-arm is
  bounded (16) and its exhaustion is a terminal `launch_surface_exhausted` frame,
  after which the monitor keeps serving without a FIFO. A successful handoff also
  re-arms, so a second browser session needs no restart; every handoff still
  issues its own fresh, one-use, TTL-bounded capability, and no capability byte
  reaches any frame, stdout, or stderr.
- Monitor: darwin mode reports its launch outcome and accepts re-entry (#437).
  The serving stdout frame now carries a bounded `launch` object distinguishing
  `succeeded`, `failed`, and `not_attempted` (including `unsupported_platform`
  off macOS), so a launcher failure is observable instead of fatal. `SIGUSR2`
  mints a fresh one-use capability and relaunches without restarting the monitor,
  replacing the previous one-shot token with no recovery path. SIGUSR1 is
  deliberately avoided: ERTS reserves it for its crash-dump handler.

## [0.1.12] - 2026-07-21

The contract-honesty cut: 11 pull requests since 0.1.11. A checked-in CLI
contract turns the real builders into pinned public evidence and catches three
product bugs in the process; delegate specification admission now fails closed
across every known surface; and Open Responses mode is proven live against a
local open endpoint.

### Added
- The checked-in CLI contract (#205, PR #423) records four surfaces and 87
  fields in `docs/cli-contract.md`, with 85 assertions pinned against the real
  builders. Those pins caught and fixed three product bugs in the same PR:
  `--json resume` no longer leaks streamed text to stdout before its envelope;
  pre-session failures in `--json` mode return an envelope instead of a bare
  human line on stderr; and `run_turn` no longer double-subscribes on a second
  in-process route and double-delivers output.
- The first live `mix pixir.smoke.open_responses` run against a local Ollama
  endpoint (#208, PR #424) proves Open Responses endpoint compatibility. A new
  `termination` evidence field tolerates and confesses a missing `data: [DONE]`
  sentinel while `done` remains strict; conformance probe v2 communicates its
  sentinel and pins its digest at compile time; and the honest claim level is
  `endpoint_compatibility_observed`.

### Changed
- Delegate specification admission fails closed (#422/#425, PR #426; #427,
  PR #429; #428, PR #430): unknown Workflow step keys are rejected with a
  nested `json_pointer` and a `depend_on` hint; root `steps` requires the
  Workflow strategy; and the `workflow` shell is a closed, accessor-backed
  object that rejects non-maps and the wrong strategy while making root and
  nested steps mutually exclusive. Workflow step `limits` accepts only the
  virtual-overlay limit keys with non-negative integer values and is rejected
  outright on non-overlay steps. The root `limits` knob bag accepts only
  `timeout_ms`, `delegate_timeout_ms`, `child_timeout_ms`, and
  `wait_horizon_ms`; the runner's nested-shell merge uses the same accessor;
  and attached-Workflow help now describes the admitted surface truthfully.

### Fixed
- Monitor hardening drains SSE streams and makes the API fail closed during
  shutdown (#405, PR #411). Rescue diagnostics serve fixed reasons rather than
  `Exception.message`, with a source-level boundary test (#414, PR #420). A
  dead bootstrap catch is replaced by an honest init-failure net, and the Runs
  list stale banner gains its Retry control with per-view copy (#416/#417,
  PR #421).
- Two diagnostics and metadata boundary fixes from the 0.1.11 mirror review
  harden the release without widening its claims.

## [0.1.11] - 2026-07-17

The Monitor cut: 42 pull requests since 0.1.10. Pixir Monitor — a read-only,
loopback-only web console over the append-only Log — goes from first
implementation to daily driver in one release, hardened by a maturity
gauntlet, a degradation suite, and browser evidence that is now mandatory in
CI. The provider gains the Open Responses conformance arc and truncation
honesty for successful output, and the post-0.1.10 security tranche lands
session-id and read-set confinement. The Monitor lives in `monitor/` as a
sibling escript project and ships in the repository, not in the Hex package;
Pixir core does not depend on Phoenix.

### Security
- Session-id and read-set confinement hardening (#323). `Pixir.SessionId` is
  the single 1..235-byte UTF-8 session-id grammar, and untrusted ids are
  validated before the Log, writer-lease, Registry, recovery-command,
  process, CLI, ACP, Delegate, Workflow, and Resource boundaries. Pixir-owned
  Session Log and writer-lease paths get a structured `lstat` preflight that
  refuses existing or dangling symlinks; evidence, doctor, and GC consumers
  are hardened; and leases are released on both failed `Session.init/1` and
  post-start rejection. Competing virtual-overlay `read_set` grammars are
  replaced by one shared structural classifier used by specification and
  execution callers, and lexical Workspace confinement is fixed for trusted
  root `/`. Documented boundary: this is a deterministic confinement
  tripwire, not a descriptor-relative POSIX sandbox — `openat`-style
  no-follow, hard-link, mount, and same-UID check/reopen race closure are
  explicitly not claimed, and Session Resource payload-path hardening below
  the validated session-id boundary is deferred.
- Responses and Anthropic body construction is hardened so hostile structs,
  improper lists, authority collisions, non-UTF-8 terms, and build or encode
  failures return redacted structured errors before credential assembly or
  transport (#317).
- Monitor 503 diagnostics no longer include the absolute workspace root;
  the error detail carries the workspace basename instead, and the full path
  stays observable only in the local server log (#369).

### Added
- **Pixir Monitor v1** (#324, ADR 0038): a local web presenter over the
  frozen `pixir.presenter.run.v1` contract for Workflow runs and Pixir
  Delegate fan-outs. The append-only Log remains canonical and the presenter
  stores no independent run state: authoritative HTTP snapshots plus bounded
  SSE invalidation hints, with disposable browser state that refetches after
  gaps, reconnects, or invalidation anomalies. The server is read-only and
  loopback-only with exact Host/Origin and Fetch Metadata checks, a one-use
  in-memory bootstrap token, strict CSP/Trusted Types, local assets only,
  and no mutation routes; model-authored hostile content renders literally.
  Surfaces: Runs inventory, Workflow Run Detail, Subagent Fan-out Detail,
  and Unit Inspector, keeping execution, dependency gates, advisory
  verdicts, liveness, and evidence source as independent dimensions, retry
  and resume attempts in one logical-unit lineage, and usage derived only
  from durable `provider_usage` events. A v1.1 operator repair pass (#329)
  followed: honest gate/advisory distributions, correct pagination totals, a
  truthful parent-Log-only attention lower bound, and actual-edge dependency
  captions.
- Monitor daily-driver train (#331, #332, #333, #334, #346, #347): launch
  against an explicit workspace resolved at invocation time; bounded search
  by title, Run id, or parent-observed child Session with the query in the
  route and the searched domain confessed; recency ordering over a frozen
  temporal schema with evidence-derived durations and confessed
  completeness; Follow as a refetch policy represented in the route, with
  refetch convergence later proven in a real browser (identity loss vs. a
  missing logical Unit are distinguished); list-scope activity honesty —
  the Runs list stopped offering liveness it cannot evidence, so list rows
  carry only "unobserved"/"not applicable", grouping is "Needs
  attention"/"Recent" over the parent Log only, and an "Active" state is
  pinned out by regression; and daily triage works at 390px narrow
  viewports.
- Monitor structure contracts, frozen then implemented: semantic-zoom v1
  (#336) — a bounded 100-unit Workflow zoom with wave:bucket clusters,
  six-plus-overflow windows, arc counts, and an exact edge ledger (#348) —
  and workspace-set v1 (#339) — a two-workspace read-only Workspace
  Overview keyed by operator-chosen workspace keys (#349). Large Delegate
  fan-outs group without inventing topology (#338), and the Overview stays
  useful when one workspace is stale or unavailable, with per-source
  degradation states and Retry (#340).
- Monitor honesty doctrine, adjudicated mid-release (#360, #403): the
  Builder normalizes out-of-vocabulary enums to `unknown` and unparseable
  timestamps to `null`, confessing every normalization
  (`unknown_enum:<field>:<raw>`, `malformed_timestamp:<field>:<raw>`);
  advisory classification stays the sole verdict authority; list and detail
  fail-close with the same execution vocabulary. The same sweep caught a
  real bug: a malformed event timestamp could win the lexicographic maximum
  into `source.last_durable_at`, so derived date-times now consider only
  parseable values and confess exclusions. The launch page reaches a
  terminal honest state in three categories (capability absent, capability
  rejected, generic failure) announced via a `role="status"` live region
  (#399), and the darwin launcher hands the launch capability to osascript
  via the environment, with the child actually reaped (#386).
- Monitor evidence and maturity gates: a 500-unit Workflow performance gate
  within DOM and render budgets, with scale growth measured against the
  100-unit baseline (#337); the maturity-gauntlet evidence package across
  security, accessibility, and envelope frontiers (#341), adjudicated
  operator-side with all three frontiers remaining Experimental (#360);
  scale cells exercised at magnitude — 512 logs, 50-row pages, 32 KiB
  fields (#397); a real 300-second SSE stream rotation — the page held open
  past the server's stream-lifetime timer, the stream required to end, and
  a second authenticated stream plus authoritative refetch required to
  follow — driven end to end (#400); four hostile-text vector classes
  (script, entities, RTL override, near-cap field) sealed per evidence
  source, eight source-qualified instances across both sources, plus
  keyboard deep-links into paginated cluster members (#402); and a named
  main landmark whose accessible-name gap fails closed (#390) with the
  variant-B redesign, a vertical per-source registry, across the Overview
  and zoom cluster views (#391, #392).
- Monitor test tiers: a real built-escript CDP browser harness drives the
  suites above; the default browser suites are mandatory in CI with an
  action-pinned Chrome and Node 22 (the missing gate was Node's global
  WebSocket, not Chrome) and a fail-loud toolchain assertion instead of
  silent skips — confessed exception: the five-minute lifecycle suite
  stays out of CI by design, opt-in via `PIXIR_MONITOR_LIFECYCLE=1`
  (#401); and a first tier executes the Presenter's frozen JavaScript seam
  in `node:vm`, fail-closed (#404).
- Monitor integration: a secure Codex sidecar handoff over a FIFO (#357),
  and detail projections restored in the built escript: schema loading had
  assumed a source layout (`:code.priv_dir/1`) that fails inside the
  escript, so the vendored Presenter schema is now embedded at compile
  time (#358).
- Open Responses conformance arc (#317, #318, #319, #320): an opaque,
  fail-closed, request-scoped Responses backend profile snapshots provider,
  model, capabilities, backend policy, and defaults once per request;
  request-scoped routing and auth enforce exact URL/transport capabilities
  with ephemeral policies for existing ChatGPT credentials, `bearer_env`,
  and `none` (strict token68, HTTPS or literal-loopback HTTP only, never
  stored or projected); open mode stays HTTP/SSE-only with `store: false`,
  a strict WHATWG SSE decoder, and 24 pinned event roots validated before
  any reducer effect. Conformance evidence is deterministic: a checked-in
  69-schema validator generated from a pinned OpenAPI commit with no
  runtime schema dependency or network, a 14,235-mutation differential
  corpus against an independent JSON Schema Draft 2020-12 oracle, and an
  offline smoke task. The default ChatGPT/Codex wire — request bytes,
  ordered headers, WebSocket/SSE policy — keeps exact regression coverage.
- Provider-neutral output-truncation evidence (#268, ADR 0039): a tri-state
  contract for successful OpenAI and Anthropic calls persists durable
  call-level evidence through Turn, Event, and Log, and surfaces bounded,
  deduplicated projections in CLI, ACP, diagnostics, replay, Subagents, and
  Delegate. Provider text is preserved exactly; successful truncation is
  distinguished from input overflow, error partials, and local channel
  bounds; tool execution stays gated on complete validated calls.

### Fixed
- Exact-cap error-body truncation provenance (#306): the binary-only error
  accumulator is replaced by an opaque capture that records whether any
  byte was actually discarded, so `err_body_truncated` is true byte-drop
  evidence rather than retained-length inference. At exactly 16,384
  received bytes the marker stays absent; a later nonempty byte makes it
  true and sticky for that capture; each retry starts fresh. OpenAI
  Responses, Anthropic Messages, and model-catalog refresh share the
  contract with retry and classification policy unchanged.

### Changed
- The public skills surface is pruned to the delegation trio plus
  diagnostics (#344): `pixir-audited-executor` folds into
  `pixir-delegate-codex` as its audited single-run mode, and the
  fork-maintenance skill family leaves the public mirror (the sync script
  gains fail-closed verify checks for the excluded paths).

## [0.1.10] - 2026-07-11

Hardening cut: the resume-sandbox security arc (#311) plus the five majors
from the public-mirror review adjudication wave, and explicit model-catalog
discovery.

### Security
- Resuming a delegated writer no longer discards its sandbox (#311). Spawn
  records a durable `permission_posture` event in the child Log before its
  first Turn (`permission_mode`, write-policy metadata with an integrity
  hash, `workspace_mode`), and `pixir resume` cold-folds that evidence and
  rehydrates the posture: the same `write_policy` gate that ran before the
  interruption denies out-of-policy writes after the resume. Resume flags
  may restrict but never widen (`read_only` wins, `bash: disabled` wins,
  a requested `write_policy` narrows to the intersection of the durable and
  requested allow sets); the no-widen matrix is pinned.
- Every new root session records a durable posture marker at sequence 0
  (`lineage=root`) at creation, through the single seam all product
  surfaces share (CLI one-shot, ACP `session/new`, delegate runner). A
  failed posture append stops the Session rather than delivering an
  unmarked one. The delegate runner records the run's real ceiling
  (read-only, or auto bounded by the spec's write policy), never an
  unbounded default.
- Fail closed on missing evidence: a history containing a successful
  mutating tool call with no readable, unambiguous posture refuses to
  resume write-capable (`resume_policy_unavailable`, with `next_actions`);
  mutation-free legacy logs still resume read-only. Unbounded `auto`
  without a write policy is restorable only when the root marker itself
  declared it.
- Legacy escape hatch, explicit and durable: `pixir resume
  --assume-legacy-root --legacy-root-reason <text>` recovers a pre-0.1.10
  write-capable root Log only when posture evidence is missing (unreadable
  or malformed shapes stay closed), only into read-only, ask, or
  policy-bounded auto (never unbounded `auto`), and records an
  `operator_attested_legacy_root` attestation so later plain resumes
  restore the attested ceiling without the flag.
- The trust rules survived five adversarial review rounds (seven confirmed
  majors from reviewers of different model families, two of them against
  intermediate versions of this fix): a root marker is trusted only at
  root position in physical append order (the first event that is not a
  `session_fork`, resolved from raw NDJSON line order rather than
  seq-sorted fold order, so neither a forged id nor a forged seq can move
  the boundary), only with source `root_session_start`, and never when it
  carries spawn fields. An unbounded `auto` ceiling with no write policy is
  refused for any non-root lineage even when the write evidence is deleted,
  so a bounded child cannot be surgically elevated. A forked root stays resumable, and a partially
  edited child Log does not elevate; the exact attack shapes are pinned as
  regressions. Accepted residue, documented: a same-UID rewrite of the
  entire session NDJSON can fabricate the trusted shape (local filesystem
  threat model, unchanged by this arc).
- ACP `session/load` and reattach restore the same posture, and the
  fail-closed paths stop the live Session (no lingering writer lease).
  Provider folds and `reconstruct` treat the posture marker as evidence
  only: it never reaches the model context and never fabricates a phantom
  child.

### Added
- `pixir models` and `pixir models refresh [--json]` (#288): the model
  catalog is operator-configurable and discovery is explicit, never
  implicit network. Refresh is per-provider fail-closed: OpenAI only with
  an API-key credential, Anthropic only with `ANTHROPIC_API_KEY`;
  subscription auth is confessed as unsupported for the models endpoint
  rather than guessed. The refresh path is the first config writer: atomic
  tmp+rename preserving foreign keys, owning exactly `models`,
  `anthropic_models`, and `models_refreshed_at`; if every provider skips
  or fails, `config.json` stays byte-identical.
  `config.json["anthropic_models"]` now overrides the static Anthropic
  list (mirroring the OpenAI pattern), doctor gains an informational
  `model_catalog` check with a 30-day stale hint, and the built-in catalog
  gains `gpt-5.6-sol` / `gpt-5.6`.

### Fixed
- Replay skill-view pairing no longer fabricates orphan outputs when
  unrelated tool calls are pending (a hole in the 0.1.9 pairing fix): both
  provider folds pair a skill activation iff exactly one pending candidate
  matches the activation name and a skills main-file path; zero or several
  candidates keep the conservative refusal, and an unrelated `tool_result`
  queues without disturbing a deferred activation. Provider parity is
  pinned with mirrored regressions; the original incident fixture is
  unchanged and green.
- Two crash classes in virtual/workflow execution: symlink resolution
  crashed on `Path.join([])` when a symlink was the final path segment;
  and virtual-step/apply-step tasks now run under a supervisor
  (`Task.Supervisor.async_nolink`) with an explicit `{:exit, reason}`
  clause, so an abnormal task exit returns a structured step failure
  instead of crashing the workflow (and an interrupted workflow no longer
  leaves a write-capable apply task running unsupervised). Also:
  unbounded-glob validation reports the original list position, and apply
  write-set validation runs once instead of twice.
- Completed delegate children keep their retry lineage across a cold
  Manager restore: the completed terminal event records the same terminal
  fields as every other terminal path (`retry_history`, `virtual_diff_ref`,
  `elapsed_ms`), and recovery guidance no longer treats a read-only role as
  write-capable.
- Virtual-overlay and workflow hardening from the public-mirror review of
  the 0.1.9 release diff: `run_virtual_commands` sanitizes the echoed
  command line like any other model-channel output; the canonical
  whole-workspace `read_set` spellings are rejected (robust normalized
  rejection of every equivalent spelling is tracked as follow-up hardening);
  an `apply` step serializes against
  readers with overlapping footprints in either argument order; and
  workflow validation errors emit real 0-based JSON pointers (the emitter
  interpolated 1-based indices).

### Changed
- New sessions carry the posture marker at sequence 0, so every subsequent
  event seq shifts by one; consumers that pin history shapes should expect
  the posture `subagent_event` first. Compaction excludes the posture
  marker from durable summaries.
- System-prompt construction reuses the per-Turn rendered skills index
  snapshot for cache-control providers instead of re-rendering it on every
  loop iteration (other providers keep their own render; public signatures
  unchanged; the cache-key timing design pass remains open).

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
