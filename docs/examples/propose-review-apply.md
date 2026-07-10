# Example: a propose → review → apply workflow

This example shows the complete virtual-diff cycle inside one Workflow: a
`virtual_overlay` step **proposes** a change without touching the real
workspace, a read-only subagent step **reviews** the proposal, and an
`apply_from` step **applies** the artifact under an explicit write policy.
Nothing mutates the parent workspace until the apply step runs.

Provenance note: this document was added to the repository by the exact
workflow it describes — the apply step's first production run wrote this file.

## The spec

```json
{
  "contract_version": 1,
  "strategy": "workflow",
  "mode": "bounded_write",
  "write_policy": {
    "version": 1,
    "allow_writes": ["docs/examples/propose-review-apply.md"]
  },
  "steps": [
    {
      "id": "propose",
      "task": "Stage the new example document as a virtual diff",
      "workspace_mode": "virtual_overlay",
      "permission_mode": "read_only",
      "read_set": ["outputs/f4-propose-review-apply/proposed-doc.md"],
      "virtual_commands": [
        "mkdir -p docs/examples",
        "cp outputs/f4-propose-review-apply/proposed-doc.md docs/examples/propose-review-apply.md"
      ]
    },
    {
      "id": "review",
      "task": "Adversarially verify the proposed document against the live contract and reply with a strict JSON verdict.",
      "workspace_mode": "shared",
      "permission_mode": "read_only",
      "reasoning_effort": "xhigh",
      "depends_on": ["propose"],
      "timeout_ms": 900000
    },
    {
      "id": "apply",
      "apply_from": "propose",
      "workspace_mode": "shared",
      "depends_on": ["propose", "review"],
      "write_set": ["docs/examples/propose-review-apply.md"]
    }
  ]
}
```

The review `task` shown here is abbreviated for readability; the production
run carried the full review brief (claims to check, files to read, and the
strict-JSON verdict shape) inline in the `task` field. The verdict shape used
in production was
`{"claims": [{"claim", "verdict": "confirmed|refuted|unverifiable", "evidence"}], "majors": [], "minors": [], "mergeable": true|false}`
— nothing in the runtime parses it; it is advisory by design, as the
review-step notes below explain.

Run it with a rehearsal first — the dry-run validates through the same shared
path as the real run and plans apply steps without artifact content:

```bash
pixir delegate --spec spec.json --dry-run --json | jq .
pixir delegate --spec spec.json --json --timeout-ms 1200000 > envelope.json
```

## What each step may and may not do

**The propose step** runs its `virtual_commands` in an in-memory shell over a
bounded import of `read_set` — no child model session, no network, no host
binaries, and no writes to the real workspace. Its evidence is a
`virtual_diff` artifact with `apply.status: "not_applied"`: per-file
`add`/`modify`/`delete` changes carrying content hashes, and — for text
changes — a unified diff (binary or otherwise non-text changes carry an
`unsupported` caveat instead and are review-only evidence). Import and
output are bounded by `virtual_limits` (defaults include 20 commands max
and 50,000 diff bytes per change); a text diff that exceeds the byte budget
is flagged `truncated`, and the apply engine refuses truncated `add`/
`modify` changes — a `delete` needs no diff body, since its applicability
rests entirely on the `before` content hash.

**The review step** is an ordinary read-only subagent step. In a
`bounded_write` workflow every non-writer step must declare
`permission_mode: "read_only"`, and per-step `model` / `reasoning_effort` /
`timeout_ms` knobs let a review lens run heavier than the rest of the DAG.
Its verdict is advisory in this shape: a completed review reaches
`checkpoint_ready` regardless of what it concluded, so the apply can run even
when the review returned `mergeable: false` — the first production run of
this exact example did precisely that, and the reviewer's findings were folded
in afterward by the operator. The orchestrator (or a stricter gating design)
must read the verdict before trusting the applied result. What the DAG does
enforce is order and failure: the apply step stays held unless every
dependency reached `checkpoint_ready`, so a failed or timed-out review blocks
the apply.

**The apply step** is pure engine — it spawns no subagent. The contract is
deliberately narrow and fail-closed:

- `apply_from` must name a previous `virtual_overlay` step, and that producer
  must also be listed in `depends_on`.
- Like every writer step in a `bounded_write` workflow, the apply step must
  declare `workspace_mode: "shared"` explicitly in the spec: the delegate
  CLI's rehearsal gate rejects a missing mode rather than silently defaulting
  a writer to an isolated snapshot. (The workflow runtime itself always
  normalizes apply steps to `shared` — the explicit field is the CLI
  contract's honesty requirement, not a runtime knob.)
- The spec must run with `mode: "bounded_write"` and a `write_policy`;
  subagent-style knobs (`agent`, `model`, `reasoning_effort`, `attachments`,
  `virtual_commands`, `read_set`) are rejected on apply steps.
- `write_set` is required and non-empty. Every path in the artifact is checked
  against the step's `write_set` before the engine runs; any path outside it
  fails the step (`artifact_path_outside_step_write_set`).
- The engine stages before it commits: hash preconditions are checked first
  (an `add` requires the target to be absent, `modify`/`delete` require the
  current content to match the artifact's recorded `sha256`; a stale
  workspace fails the whole apply), and all new content is written to temp
  files before any target mutates — a staging failure leaves every target
  byte-identical. The rename/delete commit phase has a narrow residual
  window: its rollback is total and non-raising, and a failed apply confesses
  the recovery outcome (`recovery.rolled_back`, structured
  `restore_failures`) rather than claiming filesystem transactionality.
- The step result records the apply as `virtual_diff_apply` evidence with
  per-operation counts, and the step reaches `checkpoint_ready` only if the
  artifact was actually applied.

## Why this shape

The proposal is cheap and safe to regenerate, the review sees the exact bytes
that would land, and the mutation is a single explicit, policy-gated,
hash-checked event with durable evidence at every hop. See ADR 0028 (workspace
strategies and the virtual overlay), ADR 0029 (virtual-diff artifacts), and
ADR 0030 (explicit apply and merge-back) for the design lineage.
