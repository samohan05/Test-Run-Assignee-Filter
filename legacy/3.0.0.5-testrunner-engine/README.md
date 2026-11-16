# Legacy: Codebeamer 3.0.0.5 / `TestRunnerEngine` weave (superseded)

This folder preserves the **original** Per-Assignee Test Runner Filter customization for
historical and regulatory-audit reference. It targets **Codebeamer 3.0.0.5** and has been
superseded by the v18.4.4 release documented in the [repository root](../../README.md), which
targets **Codebeamer 3.2.0.2** and adds the Assignment & Execution Board widget.

## Why this is superseded, not just upgraded

| | Legacy (this folder) | Current (repo root) |
|---|---|---|
| Codebeamer target | 3.0.0.5 | 3.2.0.2 |
| Weave target | `TestRunnerEngine.getTestCaseRunsRecursively()` | `TestRun.getTestCaseRunsRecursively()` — Codebeamer **removed the method from `TestRunnerEngine` and moved it onto `TestRun`** between these releases |
| Deployed shadow classes | 2 (`TestRunnerEngine.class` + `AssignedRunFilterAspect.class`) | 10 (adds `SingleRunFilterAspect`, `EffectiveAssignmentAuthorizationService`, and the two REST controllers — see repo root README) |
| Current-user source | `((TestRunnerEngine) pjp.getThis()).getUser()` | `TestRun` has no public `getUser()` — read the private `user` field reflectively |
| User-facing surface | None — filters the native Test Runner's side panel only | Full "Assignment & Execution Board" external widget (`executeRunWidget.html`), plus the `/testRun/philips/*` REST endpoints it calls |
| AspectJ toolchain | Build: ajc 1.9.22-tools; **Runtime: 1.9.7** (version-skew workaround, see `docs/adr/0004` in this folder) | Build and runtime both **1.9.22.1** — the skew that ADR-0004 worked around no longer exists on 3.2.0.2 |

Everything in this folder — the runbook, ADRs, apply/rollback scripts, source, and woven
bundle — describes the 3.0.0.5 state only. Do **not** apply these scripts against a 3.2.0.2
install; the vendor-jar hash pins, shadow class paths, and weave target are all wrong for it.
Keep this folder only if you still operate a 3.0.0.5 environment with this customization
deployed.
