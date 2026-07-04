# Classification Rubric

Patch classification is Skill-led judgment recorded by the Patch CLI.

For every donor change and every target surface that constrains the port, choose exactly one canonical classification.

## Labels

- `Port`: Bring this donor change into the target.
- `Preserve`: Protect this target surface from donor assumptions.
- `Adapt`: Carry the donor intent without directly copying the donor implementation.
- `Reject`: Explicitly do not bring this donor change into the target.
- `Defer`: Possibly useful later, but outside the current patch stop condition.

Do not invent softer labels such as `maybe`, `related`, `review_later`, or `partial`. Map them to one of the five labels.

## Decision Rules

- Use `Port` only when the donor implementation fits the target boundary and the patch stop condition.
- Use `Preserve` when a target invariant, public seam, repo law, or local fork behavior must not be overwritten.
- Use `Adapt` when donor intent is valid but target architecture, names, dependencies, or public seams differ.
- Use `Reject` when the donor change is unwanted for this target or contradicts the fork.
- Use `Defer` when the change is plausible but needs a future patch, prerequisite, or explicit scope expansion.

## Conflict Clusters

Create a conflict cluster when a `Port` or `Adapt` decision collides with one or more `Preserve` decisions. A cluster is not a random topic group; it is a focused judgment surface.

## Autonomy

The Skill may write evidence and narrow scope. Ask before widening scope, changing preserve paths, deleting evidence, rewriting repo law, or running external side-effecting tools.
