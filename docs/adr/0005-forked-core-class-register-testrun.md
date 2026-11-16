# ADR-0005: Forked Core Class Register — v18.4.4 (`TestRun`, Codebeamer 3.2.0.2)

**Status:** Accepted
**Date:** 2026-11-16
**Supersedes:** Entry #1 of [legacy/3.0.0.5-testrunner-engine/docs/adr/0003-forked-core-class-register.md](../../legacy/3.0.0.5-testrunner-engine/docs/adr/0003-forked-core-class-register.md) for the Codebeamer 3.2.0.2 target
**Related:** ADR-0006 (AspectJ toolchain, 3.2.0.2)

## Context

Codebeamer 3.2.0.2 **removed `getTestCaseRunsRecursively()` from
`com.intland.codebeamer.manager.testmanagement.TestRunnerEngine` and moved it onto
`com.intland.codebeamer.manager.testmanagement.TestRun`**. The 3.0.0.5-era fork (ADR-0003
Entry #1, now archived under `legacy/3.0.0.5-testrunner-engine/`) therefore no longer applies:
there is nothing left to weave on `TestRunnerEngine`, and the method it must now advise lives
on a different vendor class with a different shape (no public `getUser()`; the acting user
must be read from the private `user` field reflectively).

This release also adds a user-facing surface (the Assignment & Execution Board widget) that
did not exist when ADR-0003 was written, calling two new REST endpoints
(`/testRun/philips/authorizedChildren`, `/testRun/philips/currentUser`) backed by two plain
`@Controller` classes. Those two classes do **not** fork vendor bytecode — they are new
classes under the vendor's own `com.intland.codebeamer.controller.testmanagement` package,
listed here for completeness of the deployed-artifact inventory, not because they fork
anything.

Per the process established in ADR-0003, this is a new register entry, not an edit to the
historical one.

## Register

### Entry #2 — `com.intland.codebeamer.manager.testmanagement.TestRun`

| Field | Value |
|---|---|
| FQCN | `com.intland.codebeamer.manager.testmanagement.TestRun` |
| Stock SHA-256 | `e7126216c643c67edfe6fa593b9923da17bb7f946ec0e7fdadbc48740b0562bd` (extracted from `cb-3.2.0.2.jar`) |
| Woven SHA-256 | `522a1325c3d3e6872b75c4137974040ea5fcb10772eefc739836d8f13b999885` |
| Vendor JAR | `cb-3.2.0.2.jar` SHA-256 `ba85f2c182bd3a175ab457791c5f2f212c617b22d70dc1643531bc85f36e76a8` |
| Woven join point | `TestRun.getTestCaseRunsRecursively()` — confirmed via `ajc -showWeaveInfo` (`patches/ajc-build.log`): `TestRun.java:1259 ... advised by around advice from 'com.philips.cb.testrun.AssignedRunFilterAspect' (AssignedRunFilterAspect.java:36)` |
| Companion class | **None.** The advice body has no lambda, so ajc inlines `proceed()` into `TestRun` itself — no `TestRun$AjcClosure1.class` is produced. If a future rebuild reintroduces a lambda, the closure can reappear; the rule remains "deploy every `.class` the build emits." |
| Aspect class | `com.philips.cb.testrun.AssignedRunFilterAspect` — delegates authorization to `EffectiveAssignmentAuthorizationService` and single-run scoping to `SingleRunFilterAspect.applyToAuthorizedRuns(...)` (the latter is a plain static helper, **not** itself an AspectJ aspect, despite its name) |
| Build toolchain | ajc 1.9.22-tools + JDK 21. See ADR-0006 — the 1.9.22-tools / 1.9.7-runtime skew that drove ADR-0004 (3.0.0.5) **no longer applies**; 3.2.0.2 ships `aspectjweaver-1.9.22.1.jar` as its runtime weaver, matching the build tools. |
| Current-user resolution | `TestRun` has no public `getUser()`. `AssignedRunFilterAspect.currentUserOf(...)` reads the private `user` field via reflection (`Field.setAccessible(true)`), fail-open (returns `null` → empty result) on any reflective-access failure. |
| Matching | Direct user assignment OR a project role the user holds (including group-derived roles, resolved via `ProjectManager.getProjectMemberRoles(...)` with a fallback role-user lookup), OR an empty `assignedTo` per the approved unassigned-run policy. Fail-closed (returns no runs) on any `RuntimeException` during authorization. |
| Single-run scoping | `SingleRunFilterAspect` additionally narrows the authorized collection to one run when the request carries `strictSingleRunId` (via request parameter, URL, Referer, or a 30-minute session-scoped continuation keyed by `task_id`, for the native Test Runner's internal Save/Next requests that may drop the query parameter). Never adds a run outside the already-authorized collection. |
| Customization owner | Per-Assignee Test Runner Filter + Assignment Board (CTW) — this repository, `src/main/java/com/philips/cb/testrun/` |
| Regulatory scope | The fork modifies `TestRun.getTestCaseRunsRecursively()` to return a per-user, assignment-authorized subset, optionally narrowed to one run. It does **not** alter verdict calculation, result persistence, audit logging, electronic-signature capture, or locking semantics. Per the 3.2.0.2 behavioral-change note below, this method is now also called from completion-gating code (`TestRun.areAllEditableTestCasesComplete()`), which was not the case in the 3.0.0.5 fork — see Known Constraints. |
| Upgrade trigger | Any CB upgrade that changes the `cb-3.2.0.2.jar` SHA-256 triggers a re-weave cycle: stock-class diff, re-build, re-validation per `DEPLOYMENT-RUNBOOK.md` Upgrade-SOP. |

### Entry #3 — non-forking additions (listed for completeness)

| FQCN | Nature |
|---|---|
| `com.intland.codebeamer.controller.testmanagement.PhilipsAuthorizedChildrenController` | New class, vendor package, no fork — plain `@Controller` |
| `com.intland.codebeamer.controller.testmanagement.PhilipsCurrentUserController` | New class, vendor package, no fork — plain `@Controller` |

Both rely on Codebeamer's own internal classpath scanning of `com.intland.codebeamer.*`
already picking up classes dropped into this package — confirmed live in `cb.txt` server logs
without any customer Spring XML `<context:component-scan>` entry.

## Consequences

### Required
- `patches/apply-testrun-filter.ps1` pins the stock `cb-3.2.0.2.jar` SHA-256 and aborts on
  mismatch (same mechanism as the 3.0.0.5 script).
- `DEPLOYMENT-RUNBOOK.md` cites this ADR's Upgrade SOP section.
- Any new entry must be reviewed before deploy.

### Risks (carried over from ADR-0003, still applicable)
- Multiple forks of `TestRun` would not be detected by a simple register-row count; apply
  scripts must check for pre-existing shadow files before writing.
- A future Codebeamer upgrade that recompiles `TestRun` against a newer JDK will force a
  toolchain re-validation — see ADR-0006.

### ⚠ Behavioral change vs the 3.0.0.5 fork — validate before trusting in production
In 3.0.0.5, `TestRunnerEngine.getTestCaseRunsRecursively()` (woven) and
`TestRun.getTestCaseRunsRecursively()` (not woven) were **distinct methods** — anything that
called the `TestRun` version directly saw an *unfiltered* list. In 3.2.0.2 there is only one
method, on `TestRun`, so weaving it filters **everything** that calls it:
- The native Test Runner stepper / "X of N" / Next-Prev paths are filtered — intended.
- `TestRun.areAllEditableTestCasesComplete()` **does** call the woven method. Confirm this
  does not gate End-Run enablement in a way that disagrees with the Known Test Runner
  Behaviors documented in the Assignment Board implementation guide.
- Anything that previously relied on an unfiltered `TestRun.getTestCaseRunsRecursively()` call
  will now see the filtered result too — likely an improvement, but call it out to the
  customer if a regression surfaces.

**Mitigation if validation regresses:** narrow the pointcut to exclude completion control-flow
(no logic change):

```java
@Pointcut("execution(java.util.List com.intland.codebeamer.manager.testmanagement.TestRun.getTestCaseRunsRecursively()) "
        + "&& !cflowbelow(execution(* com.intland.codebeamer.manager.testmanagement.TestRun.areAllEditableTestCasesComplete()))")
public void testCaseRunsRecursively() {}
```

## Open questions carried over from ADR-0003
Same three open questions as ADR-0003 remain unresolved (register file location, whether to
ship woven classes to source control, one apply/rollback pair per customization vs per forked
class). This release continues the ADR-0003 precedent: woven classes ARE checked into
`patches/woven/`, and one apply/rollback pair covers the whole customization (now ten files).
