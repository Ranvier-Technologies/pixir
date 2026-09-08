# Model-aware reasoning effort

Issue #617 makes reasoning effort a shared vocabulary with a separate capability
check, owned by `Pixir.ReasoningEffort`. A recognized value is not automatically a
capability of every model or backend.

## Effective behavior

| Selection | `max` |
| --- | --- |
| Exact `gpt-6-astra`, `Pixir.Provider`, ChatGPT/Codex Responses backend | Admitted |
| Other or unknown model IDs, including guessed Astra aliases/snapshots | Refused |
| Custom Provider, Anthropic, or nonstandard legacy route | Refused |
| Strict `open_responses`, including an official OpenAI endpoint | Refused; existing reasoning-free policy remains |

The ChatGPT/Codex path supports its existing HTTP/SSE and WebSocket transport choices
and authentication policy. An explicitly configured `chatgpt_codex` backend has the
same capability as the default backend. A legacy route override must be the exact
canonical ChatGPT backend base, Codex base, or Responses URL (optional trailing slash).
No endpoint hostname, model prefix, or custom catalog entry is used to infer support.
This is a local compatibility policy, not proof that a live backend/account accepts
any given request. No live acceptance probe is part of this change.

The default model remains `gpt-5.5`. Effort remains unset by default. Existing
`low`, `medium`, `high`, and `xhigh` behavior is preserved, including Anthropic's
existing wire mapping. This change does not redefine those providers' non-max
capabilities or change Anthropic wire semantics.

## Config and Provider

```json
{
  "model": "gpt-6-astra",
  "reasoning": {"effort": "max"}
}
```

Config recognizes and retains `max` intent. An incompatible effective Config
model/backend produces an `unsupported_reasoning_effort` compatibility warning,
not a silent reset to nil or `high`. The warning is separate from invalid-value
warnings: malformed or unknown values retain established ignore-with-warning
behavior. Programmatic effort and model precedence is unchanged.

`Config.valid_reasoning_efforts/0` is the established bare-list **intent vocabulary**
API used by legacy parsers. It is not an admission check. Consumers needing capability
must use the shared definition with the effective resolved Provider selection.

The immutable request snapshot validates defaults as known intent, independently of
capability. A retained `max` default remains structurally valid even when an explicit
request overrides it with `high`; neither validation nor attachment rewrites the
frozen defaults.

Provider stream and body preview validate the same effective model/backend and
emit exactly `"reasoning": {"effort": "max"}` when admitted. Request values win over
Provider option defaults; explicit nil or `default` omits effort. Both string-keyed
and atom-keyed request efforts are handled consistently; duplicate normalized keys
are refused. Model/backend overrides are checked after resolution, so an Astra Config
cannot grant max to a later incompatible override, and a compatible override can
honor retained intent from an otherwise incompatible Config. Invalid max is refused
before authentication or transport, not omitted from the body. Request body preview
is offline and uses the same policy.

## ACP

- `session/set_config_option` with `configId: "model"` or `"reasoning_effort"`
  remains canonical. `session/set_model` remains a compatibility extension.
- The effort selector advertises `max` only for the effective compatible
  model/backend, including server-level Provider/backend overrides.
- An incompatible model change with sticky max is a JSON-RPC `-32602` refusal.
  Both session model and effort stay unchanged. Select `high` or `default` first
  if changing to an incompatible model.
- Per-turn `_meta.model`/`_meta.reasoning_effort` cannot bypass the check and do not
  mutate sticky state. An incompatible combination is rejected before the Turn.
- Runtime-driven model/effort changes are checked as one proposed combination.
  An incompatible combination is rejected atomically with a fixed stderr warning;
  no partial model/effort update is advertised. A combined model change plus explicit
  supported effort remains possible.
- `default` explicitly suppresses Config fallback and lets the selected Provider
  omit effort. ACP stdout remains JSON-RPC only.

## Delegate and native runtime admission

The Delegate CLI validates max against effective subagent model and runtime
Provider/backend options before dry-run acceptance or attached runner dispatch.
Native Subagents.Manager admission also checks the shared capability policy before
creating or queueing a child, including when max comes only from Provider options
or Config. The child-Turn start boundary rechecks defaults for queued children and
same-Session follow-ups; a rejected follow-up leaves the previous child state intact.
Queued starts revalidate before workspace or child Session allocation. If a later
setup check rejects an already-created child, its Log records a self-scoped
`child_start_failed` subagent Event before Session/lease cleanup. It does not invent
a user Turn or a descendant in SessionTree; the parent's failure remains recorded.
If the child Log cannot be written, cleanup still proceeds with parent-side evidence.
Direct Workflow dry-run and run entry points check each effective child
selection during normalization; direct Delegate Runner execution reaches these same
runtime checks rather than relying on the CLI parser.

Explicit spec model and effort win over inherited Provider options and Config, as
on the child Turn path. Workflow admission follows its existing spawning precedence:
step knobs override Provider options, while unrelated top-level `model` and
`reasoning_effort` Workflow opts are ignored. Workflow `default` remains invalid;
Provider and ACP explicit-omission behavior is unchanged. Local virtual-overlay and
artifact-apply steps make no Provider calls.

CLI admission errors remain structured `invalid_spec` results. Direct native
capability refusals use `invalid_config`; malformed step/spec values retain their
structured parser errors, and Workflow capability errors identify the step. A
known `max` in a legacy parser never authorizes a custom Provider callback or an
incompatible model/backend. These are admission checks, not a new configuration
snapshot lifetime or a claim of live acceptance.

Runtime admission honors the caller's `config_path`, `raw_config`, and
`request_snapshot_loader`; explicit Provider options still win. The Turn also
validates max against its own final frozen selection before invoking any Provider,
including custom callbacks. This closes the gap when Config changes after an
earlier admission check, without a second Config read inside the Turn or a new
snapshot lifetime. Invalid final selections record a normal configuration failure.

## Verification scope

Offline tests cover Config intent/warnings, shared capability definitions, Provider
body-preview and injected-transport parity, pre-auth refusal, model/backend overrides,
ACP selectors and sticky/per-turn/runtime switching, and Delegate admission. They
neither establish live-model acceptance nor change model discovery, Events, replay,
transport/cache/history architecture, or permission/privacy policy.
