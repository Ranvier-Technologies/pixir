# 1. Single-process Session; Agent is configuration

Date: 2026-05-29
Status: Accepted

## Context

Pixir needs a unit that owns a conversation: its history, its current role, and the
running LLM tool-loop. The Kimojo reference splits this into **two** long-lived
processes per conversation — a `Sessions.Session` GenServer (state/history) and an
`Agents.*` GenServer (the loop + permission profile) — and coordinates them.

A turn is long-running and streaming, so it must run in a supervised `Task` in *any*
design (running it inline in a GenServer callback would block the mailbox and kill
interruptibility). That observation removes "non-blocking" as a reason to split.

## Decision

For v0.1 there is **one** long-lived process per conversation: the **Session**.
**Agent** is a named role/configuration (system prompt + allowed tools + permission
profile), not a process. A Turn runs in a `Task` the Session supervises and can kill.
A **Sub-agent** is a child Session running a different Agent role.

## Consequences

- **Single source of truth for history.** No write-back protocol between two
  processes, avoiding the partial-vs-final message duplication Kimojo documents.
- **Trivial role/model switching** — mutate a field; the next Turn uses it.
- **Clean sub-agent recursion** — a sub-agent is just another Session.
- **Load-bearing invariant:** the Turn MUST run in a monitored `Task`; "interrupt"
  means the Session kills that Task. Running the loop inline is forbidden.
- **What we give up:** an Agent cannot (yet) outlive a Session, be shared across
  Sessions, or run headless/autonomously. Those map to scope Pixir is dropping.
- **Reversible-ish:** because Turns already run in Tasks and tools take an explicit
  `context`, promoting Agent to its own process later is a contained refactor.
