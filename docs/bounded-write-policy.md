# The bounded write policy config

A bounded write policy is a JSON object the **operator** supplies. It is the only
thing that grants a headless Pixir run the right to write, and it is never
proposed, widened, or edited by a model. Pass it with `--write-policy
<policy.json>` on a one-shot or `resume` run, or inline as `write_policy` in a
`pixir delegate --spec` whose `mode` is `bounded_write`.

```json
{
  "version": 1,
  "metadata": { "id": "task-c" },
  "allow_writes": ["src/**"],
  "deny_writes": ["src/secret.txt"],
  "bash": "disabled"
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Must be `1`. |
| `metadata` | no | Free-form object; `metadata.id` names the policy in denials. |
| `allow_writes` | yes | Path rules the run may write or edit. |
| `deny_writes` | no | Path rules subtracted from the allow set. |
| `bash` | no | `"disabled"` (default) or a verify map — see below. |

`.pixir/**`, `.git/**`, `**/.env*`, and `**/secrets/**` are always denied, and
the policy file itself is added to `deny_writes` so a run cannot rewrite its own
mandate. Unknown top-level fields are rejected rather than ignored.

## What a denial does: feedback once, fatal on the second strike

A denial is **recoverable feedback**, not an immediate execution. The contract is
fixed, and it is a contract rather than an implementation accident:

1. **The first denial in a Turn is recoverable.** The structured denial — denied
   tool, requested and normalized path, matched rule, policy identity
   (`policy_id`, `policy_hash`, `policy_version`), and `next_actions` — is
   delivered to the model as the tool output for that call on the next provider
   round-trip. The remaining tool calls of that same response still run. The
   model can then write inside the allowlist, fall back to read-only work, or
   finish with an honest report. The feedback is self-explanatory: no coordinator
   is needed to interpret it.
2. **The second denial in the same Turn is turn-fatal.** N = 2 is fixed. There is
   no flag, policy key, or environment variable to change it. A model that keeps
   pushing at the boundary after being told once does not get a third try. The
   Turn fails exactly as it did before: `turn_failed` with the terminal
   tool-error shape and the bounded-write denial exit code.
3. **Every denial is logged, both of them.** Recoverability does not reduce the
   audit record. Each denial — strike 1 and strike 2 alike — is a
   `permission_decision` Event with `decision: "deny"` and `gate:
   "write_policy"`, retaining the policy identity and the matched rule. The Log
   remains the proof that the boundary held.
4. **Every write denial is confessed.** Delegate envelopes carry `write_denials` at the
   top level and on each child entry; workflow step checkpoints carry it in their
   `workflow_checkpoint.v1` payload. It is present even when there were no
   denials, so its absence is a schema violation rather than an ambiguous
   silence. Each entry reports the tool, the target as the requested aim (falling back
   to the normalized path, else the denied command; never the walk-stop
   component, which travels in its own key), the matched rule, the policy
   identity, and a `disposition` of
   `recovered`, `fatal`, or `unresolved`. The confession is a *coordination*
   surface: it rides the envelopes a coordinator reads about work it delegated.
   A one-shot or `resume` run has no coordinator to report to and carries no
   such field — there, the Log is the record, foldable with
   `Pixir.Permissions.WriteDenials.from_session/2`.

Every rule that refuses a write raises the **same denial kind**,
`write_policy_denied` — an allowlist miss, a `deny_writes` match, a protected
path, the workspace root as a target, a child trying to broaden its own policy,
a bash command whose path reaches outside the workspace, and denials surfaced
through `apply_virtual_diff`. The specific rule survives in `matched_rule`
(`no_allow_match`, `outside_workspace`, …), so no information is lost; unifying
the kind is what lets the strike counter and the confession classify exactly the
same events without enumerating rules or tool names.

The strike counter is **Turn-scoped**. It resets when a new Turn starts,
including a resumed Turn — history is never recounted — and it is never shared
across sibling child Sessions.

### Reading `disposition`

`recovered` and `fatal` are claims about a Turn that finished: the Log holds
**that** Turn's terminal event, so the confession can say whether the denial was
survived or was the strike the Turn died on. `unresolved` is the honest third
answer for a denial whose own Turn never reached a terminal event in the Log — a
crash between the denial and the end of the Turn, an interrupt, a partially
copied Log, a fold taken while the Session is still running. Pixir does not infer
a disposition from an incomplete Log: calling such a denial `recovered` would be
a fail-open claim on evidence that is missing. Treat `unresolved` as "go read the
child's Log", not as a failure.

A Turn ends, for this purpose, at its terminal event **or** at the `user_message`
that opens the next Turn, whichever comes first. That second boundary is not a
technicality: an interrupted Turn records neither `assistant_message` nor
`turn_failed`, and neither does a Turn lost to a supervisor `DOWN`. Without it, a
resumed Session's next successful Turn would close the dead Turn's denial as
`recovered` on evidence belonging to a different Turn. A denial is only ever
resolved by its own Turn's ending.

### When the Log itself cannot be read

`count` and `denials` describe a Log that was read. A Log that **exists and could
not be read** — a corrupt child Log, an id the Log store rejects, a permission
error — yields a different shape: no `count` at all, plus
`"status": "unavailable"` and an `"error"` string. A missing Log is not this
case; a Session that never wrote a Log genuinely denied nothing and folds to
`count: 0`.

The distinction is load-bearing. Zero and unreadable are different facts and only
one of them says the worker never probed its boundary, so a coordinator that sums
counts cannot silently add a zero for evidence it never saw. Unavailability is
contagious upward: if any child's Log is unavailable, the aggregate confession on
the envelope is `unavailable` too, reporting the denials that *were* read and
withholding the total.

### What each denial names as its target

Every confessed denial carries a target, because an entry the coordinator cannot
reconcile to *something the worker aimed at* is not evidence. The target is
reported in `normalized_path`, and it is always the **aim** — the path or command
the call actually named — never where the refusal happened to stop:

| Denial shape (`matched_rule`) | Target reported | Also carries |
| --- | --- | --- |
| `no_allow_match`, `deny_match`, `protected_path` | the requested write path | — |
| `workspace_root_not_writable` | the requested path (normalizes to `.`) | — |
| `path_outside_workspace` | the requested path; there is no normalized form | — |
| `symlink_path_component` | the requested path, in full | `symlink_component` |
| `path_not_inspectable` | the requested path, in full | `uninspectable_component` |
| `outside_workspace` (bash) | the requested command | `token` |
| `child_policy_override_unsupported` | the **tool name**, `spawn_agent` | — |
| `unsupported_mutating_tool` | the **tool name** | — |

The two component rows are why the aim outranks the normalized form. A
confinement walk normalizes to the component it stopped at, so a write to
`link/deep/out.txt` refused at `link` would otherwise confess `link` as its
target — naming a write no call ever made, and leaving the coordinator unable to
tell which write under `link/` was refused. The component is not lost: it keeps
its own key beside the target, so both facts survive.

The last two rows are the deliberate choice for the two denials with no path and
no command: `spawn_agent` refused for trying to hand a child a different policy,
and an unknown mutating tool refused for being unknown. Neither aimed at a path,
so the tool itself is the honest answer — reporting no target at all would ship
an entry with nothing to reconcile. A tool name is ambiguous on its face (a file
could be named `spawn_agent`), and it is disambiguated by the keys that are
always present beside it: `matched_rule` — one of exactly those two rules — plus
`tool`. That pair is the contract; there is no separate target-kind field, so
read `matched_rule` rather than guessing from the string.

This matters for how you read a result. A completed run with a non-empty
`write_denials` is **not** a failure and **not** a boundary-free run: the worker
probed a path, was refused, and adapted. Reconcile `write_denials` before
accepting the work, and treat a non-empty confession as a signal to check whether
the worker's scope was drawn correctly.

A `bash_disabled` denial is a separate, always non-terminal kind: the model
adapts using the native read tools. It never counts as a strike, and it is not
reported in `write_denials`. The shell being off is a property of the mode, not
a scope drawn too small, so a worker that merely tried to shell out must not
raise a boundary-probe signal. It is still logged as a `permission_decision`
Event, so the audit record is complete either way.

## The verify map

Set `bash` to a map to let the writer run its own cheap checks instead of
finishing blind. `verify` lists the exact commands the run may execute:

```json
{
  "version": 1,
  "allow_writes": ["lib/**", "test/**"],
  "bash": {
    "verify": ["mix format --check-formatted", "mix compile --warnings-as-errors"]
  }
}
```

Authorization is **byte-equal** after trimming leading and trailing whitespace on
both sides — no substring match, no prefix match, no argument splicing. A
declared `mix format --check-formatted` does not authorize `mix format
--check-formatted --migrate`. Anything else still falls through to the read-only
safe-command list, and otherwise denies with `bash_disabled`.

## `verify_prefixes`: the operator-declared allowlist

Without a declaration, `verify` entries must begin with `mix format` or `mix
compile` — the built-in default. That default is an Elixir accident, not a
security boundary, so a policy may declare its own allowlist with
`verify_prefixes`:

```json
{
  "version": 1,
  "allow_writes": ["src/**"],
  "bash": {
    "verify_prefixes": ["pnpm typecheck", "pnpm lint"],
    "verify": ["pnpm typecheck", "pnpm lint --max-warnings 0"]
  }
}
```

- A prefix is one or two literal tokens. One token (`cargo`, `pytest`) admits
  every verify entry starting with that command; two tokens (`npm run`, `pnpm
  typecheck`) pin the subcommand as well. Matching is by token, so `pnpm
  typecheck` never admits `pnpm typechecker`.
- Declaring `verify_prefixes` **replaces** the default; it does not extend it.
  A pnpm policy that also wants `mix format` must list both.
- Omitting `verify_prefixes` keeps the exact pre-existing behavior, including
  the byte-identical policy hash, so no existing policy changes meaning.

The allowlist lives in the policy object. There is no CLI flag, no environment
variable, and no global setting for it; a `spawn_agent` call carrying a
`write_policy` is denied with `child_policy_override_unsupported`, and narrowing
a policy to a write set preserves the allowlist rather than widening it.

## Resuming: how two allowlists combine

A `resume` run may carry its own policy. The restored (durable) policy and the
requested one are intersected, and the result governs the resumed session.

- `verify` commands intersect by exact membership: a command survives only if
  both sides listed it. This is the authorization boundary — authorization
  matches `verify` byte-equal — so a command the durable side alone would have
  rejected can never become runnable after a resume.
- `verify_prefixes` intersect by **tokenwise coverage**, not as exact strings.
  A prefix survives only when it is covered by the durable side: some durable
  prefix must be a leading run of its tokens, which means it admits a subset of
  what durable already admitted. The same filter runs against the requested
  side, so every surviving prefix is covered by both. Durable `mix` against
  requested `mix format` therefore keeps `mix format`, the narrower of the two;
  requested `mix` against durable `mix format` also keeps `mix format`, because
  the bare `mix` is not covered by the durable declaration.
- When only one side declares an allowlist, that declaration survives: the
  other side was normalized under the built-in default, and every surviving
  command was admitted by both.
- The shell is disabled when the **`verify` intersection is empty** — there is
  nothing left to authorize. An empty prefix intersection is not the trigger and
  cannot occur on its own: a command both sides admitted was covered by a prefix
  on each side, and two prefixes covering the same command are leading runs of
  it, so one always covers the other.

Coverage is what keeps the restricted policy re-admissible. A restricted policy
is re-normalized before it takes effect, so surviving prefixes must still cover
every surviving command; comparing prefixes as exact strings would drop `mix`
and `mix format` as unrelated and strand a command both sides had authorized.

## Filters that always apply

Declaring a prefix relaxes **which command** may be listed. It relaxes nothing
else. Every one of these still rejects, under a declared allowlist exactly as
under the default:

- Empty or non-string `verify` entries.
- Any shell metacharacter: newline, carriage return, `&&`, `||`, `;`, `|`, `&`,
  `>`, `>>`, `<`, a backtick, or `$(`. There is no shell — the command is
  executed directly, so an entry cannot chain, pipe, or redirect.
- Any parent-directory token (`../`), in the entry or in the prefix.
- More than 8 `verify` entries, or more than 8 `verify_prefixes`.
- At authorization time, a command whose arguments reference a path outside the
  workspace, even when the command itself is allowlisted. Under a bounded write
  policy that denial is a boundary probe: it carries
  `matched_rule: "outside_workspace"` and the `write_policy_denied` kind, so it
  strikes and is confessed like any other write denial.

Rejections name the allowlist actually in force: a policy with
`verify_prefixes` reports the operator's prefixes in `accepted_prefixes`, and a
policy without one reports the `mix format` / `mix compile` default. That is how
you tell which of the two applied.

## Tests stay with the orchestrator

`mix test` is rejected under the built-in default with
`keep_test_execution_with_the_orchestrator`. The division of labor is
deliberate: the writer implements and runs cheap checks, the orchestrator runs
the suite and reads the result. An operator who declares their own allowlist is
declaring their own boundary and owns that choice.
