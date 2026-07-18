# Pixir Monitor Web Threat Model

Status: contract for the follow-up Goal  
Applies to: read-only local web presenter consuming `pixir.presenter.run.v1`

## Security objective

The monitor may render attacker-controlled or model-authored data from Pixir
Logs, child Logs, diffs, tool arguments/results, paths, summaries, recovery
commands, Provider errors, and artifacts. The browser must treat every projected
string as untrusted display data while preserving the Log as evidence.

The v1 monitor is read-only. It may display or copy structured safe actions,
including mutating guidance, but it cannot invoke cancel, retry, resume, apply,
shell, filesystem mutation, policy changes, or Provider calls.

## Trust boundaries

| Boundary | Trusted for | Not trusted for |
| --- | --- | --- |
| Parent/child Logs | Canonical event ordering and stored fields | Safe HTML, safe links, safe commands, complete redaction |
| Presenter projection | Schema-valid deterministic view | Authorization to mutate runtime or workspace |
| Manager/Owner diagnostics | Current-runtime liveness | Durable completion, historical truth |
| Terminal envelope | Structured recovery guidance and snapshot fields | Authority over contradictory Log facts |
| Model summary/advisory | Explicitly labeled advisory content | Runtime gate, executable markup, executable commands |
| Browser client | Display and local interaction | Direct filesystem/runtime authority |
| Local HTTP/WebSocket server | Serving projection data | Ambient trust merely because it binds to localhost |

## Threats and required mitigations

### 1. Stored and reflected XSS

Threats:

- summaries containing `<script>`, event handlers, SVG payloads, or malformed
  HTML;
- diff text containing tags or closing sequences;
- tool output containing ANSI/control characters or HTML;
- Provider errors or commands containing quotes and markup;
- JSON keys intended to trigger unsafe object merging.

Requirements:

- Render all projected strings through text nodes (`textContent` semantics),
  never `innerHTML`, `dangerouslySetInnerHTML`, template HTML interpolation, or
  DOM parsing.
- Render diffs as tokenized text spans produced by trusted code. Diff content
  itself never supplies markup or class names.
- Render structured JSON with a component that writes keys and values as text.
- Parse JSON into data-only structures and never merge untrusted objects into
  configuration or component props through prototype-bearing spread patterns.
- Reject or neutralize `__proto__`, `prototype`, and `constructor` during any
  object-to-map conversion not already protected by the JSON parser/runtime.
- Strip ANSI terminal control sequences for display while keeping the original
  bytes referenced as evidence. Represent remaining C0/C1 controls visibly.
- Do not Unicode-normalize evidence strings. Use `unicode-bidi: plaintext` and
  visibly mark bidi override/isolate controls in paths, commands, and ids so
  display order cannot spoof the copied evidence.

### 2. Markdown and link injection

v1 requirements:

- Markdown rendering is disabled. Model summaries are plain text or structured
  JSON only.
- Raw HTML is never interpreted.
- URLs found in text are not auto-linkified.
- Structured links, if added by a later schema version, must use an allowlist
  of `http:` and `https:` and open only after explicit operator action.
- Reject `javascript:`, `data:`, `file:`, custom application schemes, protocol-
  relative URLs, and embedded credentials.
- External navigation must show the destination and use
  `rel="noopener noreferrer"`; it remains outside the v1 core flow.

### 3. Command and path injection

- Recovery and diagnose commands are opaque text.
- `presentation: "copy_only"` authorizes only a clipboard affordance. It does
  not assert that text is safe to paste or that its effect is authorized.
- The UI never interpolates a path/session id into a command.
- Paths are display data. v1 does not open arbitrary host paths or translate
  them into `file:` URLs.
- A single-line command with no control/bidi codepoint and no leading/trailing
  whitespace may be copied exactly after an explicit click, without adding a
  newline.
- CR/LF, U+2028/U+2029, NUL, DEL, ESC/ANSI, C0/C1, bidi controls, or
  leading/trailing whitespace require a review modal before any clipboard
  write. The safe option copies escaped evidence; raw bytes require a second
  explicit confirmation. Mutating actions always require confirmation.
- Shell control syntax such as substitutions, backticks, pipes, redirects, or
  command separators is shown with a warning even when single-line.
- Cancelling or denied clipboard permission writes nothing. Never fall back to
  deprecated DOM `execCommand`, shell execution, terminal deep-linking, or
  command composition.
- A future editor/file-open integration needs a separate workspace-confined
  adapter and is not authorized by this projection.

### 4. Localhost exposure, DNS rebinding, and cross-site requests

Localhost is a network boundary, not an authentication mechanism.

Server requirements:

- Bind explicitly to loopback only: `127.0.0.1` and, if separately supported,
  `::1`. Never bind `0.0.0.0` or `::` by default.
- Use a random ephemeral port unless the operator configures one explicitly.
- Validate the `Host` header against the exact loopback host and active port to
  resist DNS rebinding.
- Generate a high-entropy, one-use launch token in process memory with a
  30-second expiry. The CLI hands it to the browser only as a URL fragment
  `#launch=<base64url>`; it never appears in path or query.
- A hash-pinned bootstrap script runs before any subresource. Its first
  synchronous operation reads the fragment and calls
  `history.replaceState(null, "", "/")`; only then may it render, fetch, or
  open a WebSocket.
- Exchange the token with `POST /bootstrap` after exact Host, Origin, and
  `Sec-Fetch-Site` validation. Consume/invalidate it and issue a new random
  `HttpOnly; SameSite=Strict; Path=/` session cookie with no Domain or
  persistence. Projection endpoints and WebSocket use that session, not the
  launch token.
- Do not persist either secret in repo, Logs, config, DOM, Referer, server
  access logs, Web Storage, IndexedDB, Cache API, service workers, history,
  diagnostics, or crash reporting. On bootstrap failure require relaunch; never
  restore the token.
- Deny CORS. Do not send `Access-Control-Allow-Origin: *`.
- Validate WebSocket `Origin` against the exact monitor origin and reject
  missing or foreign origins for browser clients.
- Reject state-changing HTTP methods in v1. No endpoint may mutate runtime,
  workspace, config, projection inputs, or evidence.
- Return `Cache-Control: no-store` for pages, projection JSON, and Logs.

### 5. Content Security Policy and browser isolation

The follow-up implementation must ship an equivalent policy with the actual
port/origin substituted safely:

```text
default-src 'none';
script-src 'self' 'sha256-{BASE64_OF_EXACT_INLINE_BOOTSTRAP_BYTES}';
style-src 'self';
img-src 'self' data:;
font-src 'self';
connect-src 'self';
object-src 'none';
base-uri 'none';
form-action 'none';
frame-ancestors 'none';
manifest-src 'self';
worker-src 'self';
require-trusted-types-for 'script'
```

- No CDN, analytics, remote font, remote icon, remote image, or remote script.
- The placeholder above is replaced at build time with the base64 SHA-256 of
  the immutable inline bootstrap bytes; the server sends that exact header and
  the HTML contains no other inline script. The bootstrap is the first script
  in the document, executes before any subresource declaration, and its first
  observable operation after reading `location.hash` is
  `history.replaceState(null, "", "/")`. Only after that operation may it
  attach DOM content or load the self-hosted application bundle.
- No inline style exception is permitted. A nonce instead of the hash requires
  a documented constraint and equivalent byte/order/history tests.
- Use self-hosted Pixir assets and local icon packages.
- Send `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
  `Cross-Origin-Opener-Policy: same-origin`,
  `Cross-Origin-Resource-Policy: same-origin`, and a restrictive
  `Permissions-Policy` disabling unused sensors/capabilities.

### 6. WebSocket and activity-stream confusion

- Validate every message against a dedicated schema before state reduction.
- Durable messages carry Session id and sequence. Reject impossible negative
  sequences and record duplicates, gaps, or out-of-order delivery.
- Ephemeral activity never advances `source.as_of_seq` and never changes
  canonical execution or gate state.
- A reconnect refetches a full projection and reconciles by evidence id/seq;
  it does not assume missed deltas were harmless.
- Bound message size, buffered messages, reconnect rate, and per-run event rate.
- A malformed or oversized activity message may be dropped with a visible
  presenter limitation; it must not crash the projection or hide durable state.

### 7. Resource exhaustion and pathological evidence

- Paginate and virtualize Logs, activity, diffs, attempts, evidence, and runs.
- Enforce bounded bytes/lines for initial summaries and diff previews. Provide
  an explicit continuation control rather than silent truncation.
- Preserve `truncated` and continuation metadata from Pixir tools.
- Put hard caps on JSON depth, string length, array length, decompressed asset
  size, syntax-highlighting work, and concurrent child-Log reads.
- Perform expensive parsing off the primary render path and make cancellation
  possible.
- Never load every child Log or artifact merely to render the Runs list.

### 8. Secret and privacy exposure

- The monitor is not a redaction boundary. It may display only fields included
  by the projection contract, not arbitrary environment, auth, Provider header,
  or config dumps.
- Do not expose OAuth/API keys, `.env` values, raw request headers, cookies,
  bearer tokens, or full home-directory paths.
- Prefer workspace-relative or sanitized path labels in presenter output.
- Clipboard copy is explicit and scoped to one field. Do not offer “copy all
  diagnostics” without a separate redaction contract.
- No telemetry, analytics, crash upload, remote error reporting, or remote asset
  requests in the follow-up Goal.

### 9. Filesystem boundary

- The server consumes the projection adapter, not arbitrary path parameters
  supplied by the browser.
- Browser requests identify a known run/unit/evidence id. Server-side lookup
  resolves those ids against the already-confined projection inventory.
- Reject `..`, absolute path substitution, symlink escape, and arbitrary glob
  parameters at the HTTP boundary.
- Evidence-mirror reads must follow Pixir's existing mirror contract and never
  expose unrelated project/user data.

### 10. Future mutating control plane

The projection is information, not authority. A future control plane requires
a separate contract and threat review. At minimum it must:

- re-read current runtime/Log state immediately before mutation;
- revalidate owner reachability, permission mode, write policy, workspace, and
  stale-handle status;
- use per-action CSRF protection and explicit operator confirmation;
- never execute a command string from the projection;
- call typed Pixir operations with structured arguments;
- record durable audit evidence of the request and outcome;
- fail closed on disagreement, stale evidence, ambiguous previous writes, or
  missing owner capability.

No v1 read-only component should contain dormant mutation endpoints or hidden
feature flags.

## Required hostile fixtures and tests for the follow-up Goal

1. Summary containing `<script>`, `<img onerror>`, broken tags, and SVG/event
   handler payloads renders as literal text.
2. Diff containing HTML, `</style>`, ANSI, NUL, and bidi controls cannot alter
   DOM structure or visual path truth.
3. JSON with `__proto__` and constructor keys cannot mutate application state.
4. `javascript:`, `data:`, `file:`, protocol-relative, credential-bearing, and
   custom-scheme links remain inert.
5. Safe single-line recovery command copies exactly without an added newline;
   dangerous commands require review, offer escaped evidence first, never
   write before confirmation, and are never executed.
6. Oversized summary/diff/activity message is bounded with visible continuation
   or limitation evidence.
7. Foreign Origin, invalid Host, missing/invalid launch token, cross-origin
   fetch, and cross-origin WebSocket are rejected.
8. CSP contains no unsafe wildcard or remote origin and blocks injected script.
9. WebSocket duplicate, gap, reorder, reconnect, and malformed-message cases do
   not rewrite canonical execution/gate state.
10. A durable terminal state wins over conflicting volatile running evidence.
11. A durable running state with no owner becomes stale, not completed/failed.
12. Mutating HTTP verbs and action endpoints are absent in the read-only build.
13. `copy_only` with a null/empty command fails schema validation; clipboard
    cancellation/denial leaves prior clipboard content unchanged.
14. Launch token never enters request URLs, Referer, access logs, DOM/storage,
    service workers, or recoverable history; invalid/expired/reused tokens fail
    with 401 and no cookie.
15. The first observable bootstrap operation is `replaceState`; reload,
    back/forward, clean close, and abrupt close do not recover the fragment.

## Acceptance boundary

The follow-up Goal cannot claim security from unit tests alone. Completion
requires:

- header/CSP assertions against the running server;
- hostile fixture rendering in a real browser;
- DOM inspection proving payloads remain text;
- network checks proving loopback-only bind and rejected foreign Origin/Host;
- source review confirming no mutation endpoint exists;
- dependency/build review confirming zero remote runtime assets;
- an evidence-backed completion audit.
