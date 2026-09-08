# Public PR #18 review dispositions — 0.1.17

This records maintainer adjudication of the original forty review comments, not
blanket agreement with an aggregate review score. Comment links refer to the
[public review](https://github.com/Ranvier-Technologies/pixir/pull/18).
The first hardening increment fixed four comments; the final contract pass fixes
two more. **Six fixed, sixteen accepted non-blocking follow-ups, thirteen rejected,
four deferred and one requiring reproduction.**

The remaining accepted work is not silently dropped. It is explicitly retained
below as follow-up scope, with the reason it does not establish a release blocker.
No critical runtime blocker was demonstrated by the adjudication. This is a
bounded evidence assessment, not an assertion that untested failures cannot exist.

Local acceptance, CI success, review disposition and publication are separate
decisions ([ADR 0005](../adr/0005-agent-ergonomics-dry-run-help-structured-errors-io-discipline.md)).
Monitor remains a read-only projection over canonical Logs
([ADR 0038](../adr/0038-pixir-monitor-sibling-spa-sse.md)).

## Fixed in the candidate

| Comment | Disposition and evidence |
|---|---|
| [3960614351](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614351) | Version-probe failure now stops wrappers before rehearsal/delegate/resume, even when the failed probe prints a version. Evidence: `.agents/skills/pixir-delegate/scripts/resolve-binary.sh:45-47`. |
| [3960614393](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614393) | Unresolved caller configuration rejects before dispatch without a second ambient/source read. Evidence: `lib/pixir/delegate/cli_contract.ex:1371-1429`. |
| [3960614439](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614439) | Shared manifest renderer limits appended text to 16,000 bytes, preserving caller summary/directive and structured evidence. Evidence: `lib/pixir/tools/wait_agent.ex:65-69`. |
| [3960614461](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614461) | Parent partiality no longer claims child evidence is missing; child completeness follows actual child selections. Evidence: `monitor/lib/pixir_monitor/projection/source.ex:238-282`. |
| [3960623278](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623278) | Reasoning-key collision uses the wrapped error at stream and preview boundaries, before auth/transport. Evidence: `lib/pixir/provider.ex:134-156`. |
| [3960623285](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623285) | Same shared renderer correction covers run_workflow; existing twenty-path cap is preserved. Evidence: `lib/pixir/tools/run_workflow.ex:133-157`. |

## Accepted, non-blocking follow-ups

| Comment | Disposition and evidence |
|---|---|
| [3960614422](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614422) | Read atom/string detail keys without losing the diagnostic reason. A durable degraded event requires a transient write failure; do not claim permanent unsafe paths reproduce it. Evidence: `lib/pixir/paths.ex:396-411`. |
| [3960614452](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614452) | Replace byte-bound prose for non-byte errors with accurate or neutral messages; structured kinds and confinement already work. Evidence: `monitor/lib/pixir_monitor/projection/bounded_log.ex:63-95`. |
| [3960614467](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614467) | Skip child I/O whose result is overwritten with undetermined in limited list rows; preserve output semantics. Evidence: `monitor/lib/pixir_monitor/projection/source.ex:132-144`. |
| [3960614490](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614490) | Use complete_through_observed_at rather than the legacy/unknown complete label in the mirror fixture; explicitly_missing is a different aggregate claim. Evidence: `monitor/test/projection/partial_child_evidence_test.exs:230-247`. |
| [3960614497](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614497) | Pin an expected refusal kind per malformed shape rather than accepting any of nine unrelated kinds. Evidence: `monitor/test/projection/partial_lifecycle_test.exs:81-103`. |
| [3960614520](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614520) | Commit the Git fixture and add a positive control before removing PATH, so unknown metadata has a discriminating cause. Evidence: `test/pixir/build_info_test.exs:79-99`. |
| [3960614526](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614526) | Isolate and restore Application reasoning_effort in affected tests; HomeIsolation only isolates PIXIR_HOME. Global mutators must not be async. Evidence: `lib/pixir/config.ex:621-635`. |
| [3960623251](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623251) | Add scoped ADR links to bounded-log-reader and context-pressure-honesty; ADR0038 does not specify the entire Core bounded-reader API. Evidence: `docs/AGENTS.md:15-16`. |
| [3960623264](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623264) | Let benchmark cleanup continue after detached-child close errors so remaining owned Sessions are stopped. Evidence: `lib/mix/tasks/pixir.bench.subagents.ex:523-557`. |
| [3960623309](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623309) | Update the explanatory comment from eighteen to nineteen families; checker and assertion already agree. Evidence: `monitor/test/presenter_ui_seam_test.exs:163-181`. |
| [3960623330](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623330) | Resolve Node explicitly using the neighboring local/CI dependency policy to improve missing-dependency diagnostics. Evidence: `monitor/test/ui/bounded_log_contract_test.exs:1-9`. |
| [3960623345](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623345) | Use synchronous mailbox inspection for synchronous admission rejection, avoiding unnecessary receive timeouts. Evidence: `test/pixir/delegate/cli_contract_test.exs:12-24`. |
| [3960623354](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623354) | Make test workspace cleanup independent of earlier fallible cleanup; the review's not_found examples are inaccurate, but detached close can fail. Evidence: `test/pixir/delegate/runner_test.exs:247-277`. |
| [3960623371](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623371) | Isolate GenServer.call exits in test teardown and continue cleanup of owned Sessions; no ordinary Manager outage was demonstrated. Evidence: `test/pixir/delegate/transport_forwarding_test.exs:48-64`. |
| [3960623386](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623386) | Wait for a new live connection identity after killing a transient child; do not require observing an empty Registry because restart can race that observation. Evidence: `test/pixir/provider_transport_policy_test.exs:1583-1626`. |
| [3960623407](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623407) | Replace the queue test's timer gate with its existing provider-start signal while retaining running/queued state and durable ordering checks. Evidence: `test/pixir/subagents_test.exs:126-140`. |

## Rejected claims

| Comment | Disposition and evidence |
|---|---|
| [3960614356](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614356) | Actual pnpm 11.5.0 accepted --config.verifyDepsBeforeRun=error --version, printed 11.5.0 and exited 0. This refutes the version-probe failure, not every flag behavior. Evidence: `bin/verify:60-74`. |
| [3960614387](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614387) | CHANGELOG already contains separate build-identity/revision-11 and landing-manifest/revision-10 entries; their cross-reference does not combine them. Evidence: `CHANGELOG.md:23-40`. |
| [3960614434](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614434) | BusyBox 1.36 kill records the invalid -- argument but continues to the following PGID and delivers the signal; nonzero exit does not establish no delivery. Other variants were not all executed. Evidence: `lib/pixir/tools/bash.ex:180-197`. |
| [3960614474](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614474) | The global guard validates structural WorkspaceSet configuration, not per-Log projection. Global refusal is intentional and Bootstrap.shell independently rejects it. Evidence: `monitor/lib/pixir_monitor/router.ex:17-25`. |
| [3960614486](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614486) | Actual READY/ARMED handshakes and external secret/EOF reads prevent the alleged no-writer success; watchdog liveness is covered in neighboring cases. Evidence: `monitor/test/fifo_handoff_test.exs:7-31`. |
| [3960614505](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614505) | Builder canonical_parent sorts by seq before validation/folding; the test still exercises prefix-only completion rather than an ordering failure. Evidence: `monitor/test/projection/source_test.exs:253-260`. |
| [3960614514](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614514) | Current scenarios do not navigate to a unit with pending scroll. Add requestAnimationFrame to the sandbox when such a scenario is added, not for a hypothetical current failure. Evidence: `monitor/test/support/child_resolution_acquisition_check.mjs:160-210`. |
| [3960614544](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614544) | Raw-log helpers have different return and timestamp contracts. The local helper returns bytes for immutable-Log assertions; changing the shared return is not a necessary fix. Evidence: `test/support/raw_log_helpers.ex:6-28`. |
| [3960623270](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623270) | Unknown Astra capacity is intentional and tested. Documented context_windows overrides require justified values; do not invent a ceiling. Overflow recovery remains independent. Evidence: `lib/pixir/provider/context_window.ex:10-26`. |
| [3960623315](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623315) | The captured node is the fully constructed renderer root, not an empty mount target. The served-renderer harness passed; it intentionally does not test DOM mounting. Evidence: `monitor/test/support/bounded_log_harness.mjs:5-19`. |
| [3960623379](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623379) | ExUnit.start enables autorun before normal VM exit; the parent checks cleanup after System.cmd returns. The two behavior tests passed without explicit ExUnit.run. Evidence: `test/test_helper.exs:1-2`. |
| [3960623400](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623400) | I/O-budget tests write real NDJSON and count folds; constructor fixtures are appropriate there. Raw cold-fold/lifecycle coverage already exists elsewhere. Evidence: `test/AGENTS.md:5-8`. |
| [3960623417](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623417) | Suite bootstrap installs HomeIsolation and replaces ambient PIXIR_HOME with a fresh temporary directory. The alleged operator-home dependency is already isolated. Evidence: `test/pixir/workflows_test.exs:831-849`. |

## Deferred changes

| Comment | Disposition and evidence |
|---|---|
| [3960614402](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614402) | Opaque tag matching is encapsulation/static-analysis debt, not a demonstrated runtime capability error. No Dialyzer warning reproduced. Evidence: `lib/pixir/reasoning_effort.ex:49-72`. |
| [3960614409](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614409) | Profile manifest I/O and consider sharing child reads. Taking the first eight completed children before determining integrability changes selection/counts; the alleged two folds per child is not unconditional. Evidence: `lib/pixir/subagents.ex:94-108`. |
| [3960614448](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614448) | Mixed error detail key types are real, but no broken consumer/collision was demonstrated. Normalize coherently as interface maintenance. Evidence: `lib/pixir/workflows.ex:428-447`. |
| [3960623300](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960623300) | Profile redundant/superlinear Builder lookups before broader indexing; preserve binding precedence and partial-evidence behavior. Evidence: `monitor/lib/pixir_monitor/projection/builder.ex:1280-1305`. |

## Requires reproduction

| Comment | Disposition and evidence |
|---|---|
| [3960614535](https://github.com/Ranvier-Technologies/pixir/pull/18#discussion_r3960614535) | Late events can restart the idle deadline, but such an event was not demonstrated in this fixture. Eleven local runs passed; keep the possible flake unproven. Evidence: `test/pixir/conversation_test.exs:522-603`. |

## Evidence limits

- Reproduced before correction: binary version-probe masking, Provider collision
  error shape, caller-config fallback, manifest byte growth, and false child absence.
- Both wrapper entrypoints now have failed-version regressions. Provider regressions
  cover atom/string collisions (including nil and equal values), matching stream and
  preview errors, and refusal before authentication/transport.
- The pnpm version probe, ExUnit cleanup and renderer harness were executed during
  adjudication. The Conversation test passed eleven runs; this does not prove the
  hypothetical race impossible.
- BusyBox disposition is grounded in the [1.36 kill implementation](https://raw.githubusercontent.com/mirror/busybox/1_36_stable/procps/kill.c),
  whose argument loop continues after recording an invalid numeric argument.
  This is not an all-platform runtime certification.
- The remaining test-strengthening, diagnostic and performance findings are mostly
  static conclusions; every future patch needs its own focused regression/proof.
- A successful incremental review does not retroactively resolve every earlier
  thread. The aggregate High-risk narrative includes both accepted residual issues
  and rejected claims; this per-comment record is the intended release decision input.
