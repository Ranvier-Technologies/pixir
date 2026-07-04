# AGENTS.md - Pixir Examples

This directory holds source examples, not runtime state.

- Keep examples deterministic and offline unless the file name and README say otherwise.
- Do not place examples under repo `.agents/skills/` unless the intent is to activate
  them as real repo Skills.
- Skill examples should be copyable into `.agents/skills/<name>/` and should document
  which supporting files are loaded through `skill_view`.
- Workflow Template examples must instantiate through `run_workflow`; they must not
  encode script execution or hidden side effects.
