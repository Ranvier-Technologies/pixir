# 13. Skills can provide Workflow Templates as installed practices

Date: 2026-06-04
Status: Accepted
Implementation status: Implemented

## Context

ADR 0010 defines Skills as progressively disclosed instruction packages with durable
per-Turn activations. ADR 0011 defines Subagents as supervised child Sessions. ADR 0012
defines Workflows as deterministic structural orchestration over those Subagents.

The missing relationship is how a reusable agent practice becomes executable without
collapsing the concepts together. A Skill can teach judgment, priors, terminology,
examples, and failure modes. A Workflow can run an explicit dependency graph. A Tool or
script can perform deterministic operations. Treating any one of those as the whole
system creates bad coupling:

- a Skill that directly mutates files on activation violates ADR 0010;
- a Workflow that relies only on prose loses ADR 0012's structural edge guarantees;
- a script that secretly encodes orchestration becomes an unlogged second runtime;
- a Subagent role that tries to embody a whole practice pollutes prompts and makes reuse
  hard to audit.

The useful pattern from the hybrid Claude Code orchestrator is not its JS Workflow
runtime. It is the split between an installed practice and an executable shape: the
practice says how to reason, what evidence matters, and which failure modes are known;
the runtime executes a bounded graph.

## Decision

Pixir treats a **Workflow Template** as a reusable, parameterized Workflow shape that may
be supplied by a Skill or by Pixir itself.

A Skill may include Workflow Templates as progressively disclosed resources, usually
under a supporting path such as `workflows/<name>.json`. They are not listed eagerly by
`skills_list`; the model first discovers the Skill by bounded metadata, loads the Skill
or referenced supporting file through `skill_view`, and then asks `run_workflow` to
instantiate the referenced template. A template can define:

- optional schema `version`, defaulting to `1`;
- required and optional parameters;
- suggested Agent roles for steps;
- step dependency edges;
- read/write posture defaults;
- expected Checkpoint Bundle shape;
- verification or review conventions;
- known failure modes and safe next actions.

A Workflow Template is not running state, not a Tool, and not a Skill Activation by
itself. It becomes a concrete Workflow only when a Session instantiates it with
task-specific arguments and executes it through Pixir's normal permissioned Tool surface,
initially `run_workflow`.

Skill Activation remains per ADR 0010:

- loading `SKILL.md` records the activation snapshot;
- reading a template or supporting reference is progressive disclosure, not activation;
- scripts shipped with a Skill are never auto-run merely because the Skill was loaded;
- executing a script remains an ordinary Tool operation subject to permissions,
  dry-run, structured errors, and workspace confinement.

The runtime ownership stays unchanged:

- Skills teach the practice.
- Workflow Templates describe reusable orchestration shapes.
- Workflows execute structural graphs.
- Subagents do bounded stochastic work.
- Tools and scripts perform deterministic operations.
- The Log remains the source of truth for durable facts.

## Consequences

- Pixir can package practices such as visual QA, benchmark execution, high-rigor review,
  release preparation, and multi-agent implementation as reusable Skill-backed Workflow
  Templates instead of one-off prompts.
- The same practice can be used from terminal, ACP, or T3 Code because execution still
  goes through Pixir's Workflow and Tool surfaces.
- Skills become more powerful without becoming hidden executors.
- Workflow Template discoverability should stay Skill-shaped: bounded Skill metadata in
  `skills_list`, supporting file reads via `skill_view`, and validation at
  `run_workflow` instantiation time. This keeps the prompt and tool output compact while
  preserving ADR 0005 dry-run and structured-error behavior.
- Unsupported template versions fail during instantiation as structured
  `:invalid_args`; they do not run partially.
- If a future implementation persists template instantiations or workflow-level
  decisions, that is a deliberate Event/Log schema change under ADR 0004.

## Non-goals

- Do not import Claude Code's `Workflow({scriptPath, args})` mechanics.
- Do not auto-run templates on Skill Activation.
- Do not make Skills sticky Session state.
- Do not replace `run_workflow` with a second orchestration runtime.

## Verification Direction

The first implementation should be verifiable without network calls:

```bash
mix test test/pixir/skills_test.exs test/pixir/workflows_test.exs
mix pixir.smoke.workflows --dry-run --json
```

It should prove that a template can be discovered through the Skill's progressive
disclosure path, instantiated into a normal Workflow spec, dry-run, and executed through
the existing `Pixir.Workflows` path without bypassing permissions or Workspace
confinement.

## References

- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: tool ergonomics, dry-run, self-describing help, structured errors.
- ADR 0010: Agent Skills use progressive disclosure with durable activations.
- ADR 0011: BEAM-native Subagents as supervised child Sessions.
- ADR 0012: structural Workflows over Subagents.
