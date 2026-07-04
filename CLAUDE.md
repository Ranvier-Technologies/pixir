# Pixir Harness - legacy agent guide

`AGENTS.md` is the canonical instruction file for coding agents in this repo. Start
there, then read `CONTEXT.md` for vocabulary and the relevant ADR in `docs/adr/`.

This file remains only as a compatibility pointer for harnesses that still look for
`CLAUDE.md`.

## Current map

- Runtime spine: `Session -> Turn -> Provider -> Tools`.
- Source of truth: append-only local Log under `.pixir/sessions/`.
- Presenters: terminal CLI and ACP over stdio.
- Provider path: OpenAI Responses, `store: false`, provider usage as durable evidence,
  WebSocket-preferred transport with HTTP/SSE fallback.
- Growth surfaces: Skills, Subagents, Workflows, Session Resources/Image Attachments,
  Provider-hosted Web Search, and future Skill Context Hydration.

## Commands

```bash
mix deps.get
mix check
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix escript.build
./pixir doctor --json
```

Run Python helpers, if any, with:

```bash
uv run python file_name.py
```
