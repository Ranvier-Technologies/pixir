# Skill Workflow Template Example

This is a no-network example of a Skill that ships a Workflow Template as a supporting
resource.

The important shape is:

- `SKILL.md` describes the practice and points to a supporting template file.
- `workflows/parallel_review.json` is loaded only when the agent needs that template.
- `run_workflow` instantiates the template with `template_id: "readonly-review/parallel_review"`
  and `template_args`.

To try it manually, copy this directory to `.agents/skills/readonly-review/` in a
scratch workspace, inspect `SKILL.md` and `workflows/parallel_review.json`, then
instantiate the template through `run_workflow`.

Example `run_workflow` arguments:

```json
{
  "template_id": "readonly-review/parallel_review",
  "template_args": {
    "topic": "repository onboarding",
    "focus_a": "architecture",
    "focus_b": "tests"
  }
}
```
