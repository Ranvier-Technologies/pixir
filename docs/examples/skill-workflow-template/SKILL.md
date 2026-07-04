---
name: readonly-review
description: Run a no-network read-only review practice with two explorer steps and one synthesis step.
---

# Read-Only Review

Use this Skill when the task needs a bounded read-only review with independent
perspectives before synthesis.

For a structural Workflow version of this practice, inspect:

```text
workflows/parallel_review.json
```

Then instantiate it through `run_workflow` with:

- `template_id`: `readonly-review/parallel_review`
- `template_args.topic`: the thing being reviewed
- `template_args.focus_a`: the first explorer focus
- `template_args.focus_b`: the second explorer focus

The template requests read-only explorer steps and contains no scripted side effects.
When using it as an example, inspect the instantiated workflow before execution.
