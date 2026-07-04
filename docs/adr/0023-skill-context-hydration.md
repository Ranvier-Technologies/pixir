# 23. Skill Context Hydration is explicit, canonical, and late-bound

Date: 2026-06-13
Status: Accepted
Implementation status: Design accepted; implementation is a follow-up slice.

## Context

Claude-style dynamic context injection is useful: a Skill can ask for current facts such
as `git diff HEAD` and receive them alongside the instructions. Pixir should support the
underlying practice, but not by copying the exact shape blindly.

Three existing Pixir decisions constrain the design:

- ADR 0010 says Skills are installed practices with progressive disclosure. Viewing or
  activating a Skill does not auto-run scripts or Workflow Templates.
- ADR 0017 says behavior that affects Provider input, replay, resume, fork, or
  compaction belongs in Pixir's Harness boundary, not in a Presenter projection.
- ADR 0020 says the Prompt Contract separates a stable cacheable prefix from late
  dynamic context. Splicing current workspace output into the Skill body would make the
  Skill unstable and cause avoidable cache breaks.

So the thing we want is not "SKILL.md interpolation". It is a runtime operation that
materializes dynamic facts for a specific Skill-guided Turn while keeping the Skill
package itself stable.

## Decision

Pixir introduces **Skill Context Hydration** as an explicit, permissioned operation.

A Skill package may declare or document allowed context sources. A **Skill Activation**
or Turn may choose to hydrate one of those sources. The resulting snapshot is recorded as
a canonical `skill_context_hydration` Event with enough provenance to replay and audit
what the model saw.

The event should include, at minimum:

- the Skill identity and activation/Turn relationship;
- `context_source_id` for the hydrated source;
- the Pixir Tool, command, Resource View, or other bounded surface used to produce it;
- permission posture and whether execution was explicit or future-safe automatic;
- bounded output or a resource pointer;
- hash, truncation, and limitation metadata.

Hydrated context enters the Provider request as a **late developer/context input item**
for the current Turn. It is not appended as a user message, not rendered as normal
assistant/user History, and not spliced into the stable Skill body. The Provider may see
the hydrated facts for the Turn, but the Prompt Contract remains cache-friendly:

- stable prefix: Pixir runtime rules, Tool schemas, Skill routing metadata;
- dynamic tail: user request, current workspace facts, hydrated Skill context.

Pixir does not auto-run arbitrary shell snippets embedded in `SKILL.md`. The default is
explicit hydration. A future `auto: true` mode is allowed only for read-only, bounded,
permission-safe sources and must still record the exact `skill_context_hydration` Event.

Avoid naming the source field `provider_id`; in Pixir, **Provider** means the model
backend. Use `context_source_id` for hydration sources.

## Consequences

- Pixir gets the practical benefit of dynamic Skill context without hidden command
  execution.
- The Skill body remains stable, which preserves prompt-cache discipline and makes
  Prompt Contract changes explicit.
- Replay, resume, fork, compaction, and future eval/training traces can see exactly
  which dynamic facts shaped the Turn.
- Hydration has more ceremony than terse inline `!cmd` syntax. That is intentional:
  the ceremony buys permissioning, bounded output, provenance, and clean replay.
- Log size can grow if hydration output is too large. Implementations must bound output,
  sanitize invalid bytes, and record truncation/limitations honestly.

## Non-goals

- Do not implement Skill Context Hydration in this ADR slice.
- Do not run arbitrary shell from `SKILL.md`.
- Do not make Skill Activations sticky session state or introduce Pinned Skills.
- Do not make T3 Code or any Presenter own hydration semantics.
- Do not treat hydrated context as conversational History.

## Verification Direction

The implementation slice should prove:

- `skill_context_hydration` is a canonical, string-keyed Event.
- Hydration can be invoked explicitly from a Skill-guided Turn.
- Unsafe or mutating hydration sources respect permission mode and fail with structured
  errors.
- Hydrated output is bounded, UTF-8 safe, and records hash/truncation metadata.
- Provider input places hydrated context in the late dynamic request portion, not inside
  `SKILL.md` content and not as a user message.
- History replay and compaction preserve the hydration evidence without replaying it as
  ambient context forever.
- Presenter-provided facts, if any, remain Presenter Context until Pixir explicitly
  records them as hydration evidence.

## References

- CONTEXT.md: Skill, Skill Activation, Skill Context Hydration, Prompt Contract, Log,
  History, Presenter, Presenter Context.
- ADR 0010: Agent Skills with progressive disclosure.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0020: versioned Prompt Contract, cache-key family, and compaction triggers.
