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
assembled inside a shell subshell or an interpreter). Run Pixir against
workspaces and credentials you are willing to expose to the tasks you delegate.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Use GitHub's private vulnerability reporting: go to the repository's **Security**
tab and choose **"Report a vulnerability"**. This opens a private advisory visible
only to you and the maintainers.

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

- The tripwire not catching a runtime-computed shell escape (documented limitation
  above, not a full sandbox).
- Vulnerabilities in the underlying Provider, model output, Erlang/OTP, or
  third-party dependencies — report those upstream.
- Anything requiring the operator to have already granted the task access to the
  target (Pixir confines by workspace, not by classifying task intent).
- Denial of service from a caller's own runaway spec on their own machine.

Thank you for helping keep Pixir's confinement and evidence honest.
