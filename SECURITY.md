# Security Policy

Pixir is an Elixir/OTP runtime that runs coding-agent work — it executes shell
commands, reads and writes files, and spawns supervised child Sessions on behalf
of a caller. Because of that, we take reports about its confinement and evidence
guarantees seriously.

## Preview status — read this first

Pixir is a **developer preview**. Its workspace confinement is a conservative
**tripwire, not a full POSIX sandbox or a production security boundary**. It
rejects shell tokens that visibly resolve outside the workspace (parent-directory
references, absolute paths, home/env-home paths, and existing symlink-prefix
escapes) before crossing the host boundary, and it confines the `read`/`write`/
`edit` tools to the workspace. It does **not** claim to contain an adversary who
controls the model's output and computes escapes at runtime (for example, a path
assembled inside a shell subshell or an interpreter). The leading
environment-assignment exception is a documented residual of the same kind:
`VAR=/outside cmd $VAR` is accepted because the outside path is visible only as
the RHS of a leading assignment and may be expanded by the shell at runtime;
confinement is defense-in-depth, not a sandbox. Run Pixir against
workspaces and credentials you are willing to expose to the tasks you delegate.

## Pixir-owned state paths

Pixir applies a narrower static guarantee to its own Session state. Session ids are
validated before they become Registry keys, filename components, recovery-command
arguments, or durable references. Before operating on Session Logs, writer leases,
or lease-release diagnostics, Pixir walks each existing path component below the
trusted Workspace root with `lstat` and rejects regular or dangling symlinks,
non-directory ancestors, and unexpected final types. The caller-selected Workspace
root is the trusted anchor, including when the caller deliberately selected a symlink
alias as that root.

This is a **preflight-time guarantee**, not a race-free filesystem capability. A
process running as the same OS user may replace a checked component between the
`lstat` and the later open, rename, or remove operation. Operators who need protection
from a hostile same-UID process must add an OS-level isolation boundary.

Session Resource path hardening is intentionally incomplete in this preview. Resource
boundaries validate the Session id, but static symlink/race hardening of payload paths
under `.pixir/sessions/<session_id>/resources/` is deferred. Do not treat the Resource
store as a same-UID adversarial sandbox.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Use GitHub's private vulnerability reporting: go to the repository's **Security**
tab and choose **"Report a vulnerability"**. This opens a private advisory visible
only to you and the maintainers.

If private vulnerability reporting is unavailable to you, email
<opensource@ranvier-technologies.com> with the same details.

When you report, please include:

- the Pixir version (`pixir --version`) and how it was installed (source checkout
  or Hex);
- OS and Elixir/OTP versions;
- a minimal reproduction — ideally a delegate spec or command sequence;
- what you expected to be confined/denied and what actually happened;
- any relevant structured evidence (envelope JSON, `kind`, and the child
  `.pixir/sessions/<id>.ndjson` **with secrets removed**).

We will acknowledge your report, work with you on a fix and disclosure timeline,
and credit you in the advisory unless you prefer to remain anonymous.

## In scope

Reports that demonstrate a real weakening of Pixir's stated guarantees are most
valuable:

- **Workspace confinement escapes** — a delegated tool call reading or writing
  outside the workspace root when the mode should confine it.
- **Write policy bypass** — a bounded-write run applying a write outside its
  `allow_writes` allowlist, or a denied write reported as applied.
- **Evidence / Log corruption** — a tool call that can delete, truncate, or forge
  the append-only Session Log or the audit mirror while a run reports success.
- **Secret leakage** — Pixir writing credentials, tokens, or Provider secrets into
  logs, envelopes, or committed artifacts.
- **Dishonest envelopes** — a machine-readable result that claims an outcome the
  durable evidence contradicts (for example, `status: "completed"` over failed
  work, or a denial surfaced under a misleading `kind`).

## Out of scope

- The tripwire not catching a runtime-computed shell escape, including
  `VAR=/outside cmd $VAR` where the outside path is expanded at runtime
  (documented limitation above, not a full sandbox).
- Same-UID replacement races after a Pixir-owned state-path preflight, and
  payload-level Session Resource symlink hardening under the Resource container
  (documented limitations above).
- Vulnerabilities in the underlying Provider, model output, Erlang/OTP, or
  third-party dependencies — report those upstream.
- Anything requiring the operator to have already granted the task access to the
  target (Pixir confines by workspace, not by classifying task intent).
- Denial of service from a caller's own runaway spec on their own machine.

Thank you for helping keep Pixir's confinement and evidence honest.
