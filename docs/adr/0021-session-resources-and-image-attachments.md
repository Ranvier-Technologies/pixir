# 21. Session Resources and Image Attachments

Date: 2026-06-10
Status: Accepted
Implementation status: Initial image-attachment slice implemented; ACP
`resource_link` local-file ingestion is supported for Session Resource descriptors.
Subagent inheritance and non-image Provider projection remain out of scope

## Context

Presenters can present image attachments, but Pixir must keep the Harness boundary
clear: Presenter state and Pixir Session truth are not the same thing. Long-running
coding agents also cannot treat attached images as ambient prompt forever without losing
cache discipline and making compaction misleading.

## Decision

Pixir treats user-provided attachments and ACP `resource_link` blocks as durable
**Session Resources**, not as Presenter-local blobs or ambient prompt context. The first
concrete Provider-projected resource kind is an **Image Attachment**: Pixir preserves the
original local payload as canonical, references it from the Log by `resource_id`,
identifies exact bytes with `content_sha256`, projects the original image to the Provider
on the Turn where it is attached, then replays only a descriptor or digest on later Turns
unless a Tool-mediated **Resource View** explicitly rehydrates it.

ACP `resource_link` is a baseline prompt block. Pixir accepts it as a resource
descriptor. When the `uri` is a readable local `file://` target, Pixir copies the bytes
into its Session Resource store even if the source file is outside the workspace: the
Presenter/user supplied the link explicitly, while `read`/`write`/`edit` remain
workspace-confined Tool operations. Remote links are recorded as descriptor-only
references; Pixir does not fetch them automatically.

The key boundary is the **Leakage Boundary**: local persistence inside Pixir is not
leakage, because Pixir is local-first; projecting a resource to the Provider is where
upload policy, cache behavior, and user intent matter. A Presenter may present and
upload images, but Pixir must ingest the resource and own the canonical Log reference.
OpenAI `input_image` is a Provider projection of a Session Resource, not the resource
itself.

## Non-goals

- Subagent access to Session Resources is deliberately out of scope for the first slice;
  it needs its own permission and inheritance decision.
- The MVP implementation supports the current image attachment contract and ACP
  `resource_link` descriptors. Documents, PDFs, audio, and other binary resources may be
  stored or described as Session Resources, but Provider projection beyond images
  remains a future decision.

## Considered Options

- Store only Presenter attachment ids: rejected because Pixir could not resume, fork,
  compact, or run as a CLI Harness without a Presenter projection database.
- Always replay original images: rejected because long-running sessions would become
  expensive, cache-hostile, and misleading after compaction.
- Sanitize or mutate local originals by default: rejected because Pixir is a power-user,
  local-first engineering Harness. The exact local artifact is the canonical evidence;
  sanitized/downsampled/provider-optimized variants may be explicit future projections.
- Use an image-specific rehydration tool: rejected for the architecture boundary. Pixir
  uses a resource-general **Resource View** concept, with image rehydration as the first
  supported kind.

## Consequences

- Compaction may summarize Image Attachments, but the summary must state its limitations:
  a visual digest is not the original image.
- Missing resource payloads must fail or degrade honestly; Pixir must not pretend the
  Provider saw an image when only a descriptor or digest was available.
- Remote `resource_link` descriptors must not imply that Pixir fetched or inspected the
  linked bytes.
- Forks may share `content_sha256` while keeping distinct `resource_id` references and
  distinct visual observations in each fork's History.

## Verification Direction

The first implementation Goal should prove:

- `CONTEXT.md` and this ADR define the boundary terms.
- Pixir can ingest an Image Attachment from ACP without storing raw base64 in the
  NDJSON Log.
- The Log records a resource descriptor with `resource_id` and `content_sha256`.
- Provider input includes `input_image` on the Turn where the image is attached.
- Later replay uses descriptor/digest by default.
- `resource_view` rehydrates the original image explicitly and records that action.
- Presenter adapter tests show image attachments are forwarded as attachments, not
  `_meta.pixir.presenter_context`.
- An end-to-end Presenter -> Pixir -> Provider smoke can attach an image, receive a
  vision-grounded answer, and leave `provider_usage` evidence.

## References

- CONTEXT.md: Session Resource, Image Attachment, Resource View, Leakage Boundary,
  Presenter, Presenter Projection, Compaction, Prompt Contract.
- ADR 0003: stateless Turns and local Log as source of truth.
- ADR 0004: unified Event envelope and canonical vs ephemeral Events.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0018: durable History compaction and replay repair.
- ADR 0019: provider usage and prompt-cache observability.
- ADR 0020: versioned Prompt Contract and cache-key families.
