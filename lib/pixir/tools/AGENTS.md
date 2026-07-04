# AGENTS.md - Pixir Tools

This directory is the model's hands: Tool behaviour, Executor, concrete tools, Workspace
confinement, Skills disclosure tools, `resource_view`, and `run_workflow`.

- Prefer this file plus ADR 0005/0006/0010/0021 before changing Tool behaviour.
- ADR 0005 is the contract: dry-run, self-describing schema, structured errors, bounded
  model output.
- ADR 0006 owns permissions. Do not bypass `Pixir.Tools.Executor` or
  `Pixir.Tools.Workspace` for reads, writes, shell, Skills, or Workflow execution.
- `skills_list` stays bounded metadata only. Supporting Skill resources, including
  Workflow Templates, are loaded deliberately through `skill_view`.
- `resource_view` is explicit Session Resource rehydration. It is not a generic file read
  and should record honest missing-resource or limitation states.
- OpenAI hosted Web Search is not a local Pixir Tool; its request/evidence shape belongs
  under `lib/pixir/provider/`.
- Future Skill Context Hydration should call bounded Pixir surfaces explicitly; do not
  add hidden shell interpolation to `SKILL.md`.
- Invalid specs are Tool errors; expected agentic partial/failure states from Workflows
  are Workflow data.
- Add every new Tool to `test/support/tool_contract.ex`.

Fast checks:

```bash
mix test test/pixir/tools_test.exs test/pixir/permissions_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
```
