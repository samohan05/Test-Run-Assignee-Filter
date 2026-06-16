# Spike — Per-Assignee Filtering of the Test Runner Execution Window (CB 3.0.0.5)

**Owner:** Sail Mohan · **Target:** Codebeamer 3.0.0.5 (classic) · **Status:** SPIKE / test-env only — NOT for production, NOT validated.

Goal of the spike: prove (or disprove) that the native Test Runner can be made to step a
logged-in user through **only the child test-case runs assigned to them**, when a single
parent run holds children assigned to multiple users — *without* rebuilding the execution UI.

---

## 1. What the code review established (evidence)

All findings are from the deployed `cb-3.0.0.5.jar` and the live `testmanagement/` JSPs.

| Finding | Evidence | Consequence |
|---|---|---|
| Runner is a server-side **stateful stepper** | `TestRunnerEngine` exposes `moveToNext(boolean)`, `getTestCasesWaitingForRun()`, `isAtFirstPendingTestWithoutWrapping()`, `isAtLastPendingTestWithoutWrapping()`, `getCurrentTestCaseRun()` | "Which case is shown next" is computed in Java, not the JSP. A JSP/JS-only change cannot re-scope execution. |
| Engine **derives its own** child-run list | Constructors take `(UserDto, TestRun, ApplicationContext, HttpServletRequest)` — no list param. Internal Guava `LoadingCache` + `TestRunManager`. | No controller-assembled list to pre-filter cheaply. |
| Engine is **not a Spring bean** | Built with `new` inside `TestRunnerControllerSupport.createTestRunnerEngine(...)` | **Spring AOP cannot advise engine methods.** Philips' existing aspect (`PhilipsMergeModelEnricherAspect`) is Spring-AOP and works only because its target is a Spring bean. |
| No AspectJ weaving present | No `aspectjweaver` javaagent in `tomcat/bin/*`, no `META-INF/aop.xml` anywhere | True weaving of the engine requires **new LTW infrastructure**. |
| No scope/filter setter on the engine | Method surface dump shows getters/navigation only | Can't constrain the engine after construction; must intercept its internal navigation. |
| Assignee is reachable per child run | `TestRun.getDelegate() : TrackerItemDto` → standard `getAssignedTo()` | Filter predicate is expressible. |
| Completion / lock gating is **separate** from per-user navigation | `TestRun.getNoOfNotEditableUnfinishedChildTestRuns()`, `isCompleted()`, per-`TestCaseLock` | "End Run" stays globally gated even if one user's pending set empties — supports pause-per-tester / lead-ends model. **Must be confirmed by the spike.** |
| Rerun-from-result is native | `TestRun.hasResultPredicate(TestRunResult)`, `getLeafChildTestRuns(TestRunResult)`, `selectTestsRunsForRerun.jsp` | Maria's "restart from failed" needs no execution-surface change. |

### Honest correction vs. earlier framing
Earlier this was described as "a surgical predicate tweak reusing your existing aspect tooling."
That was wrong on the **mechanism**: the existing tooling is Spring AOP and cannot reach a
`new`-constructed engine. The filter *concept* is valid, but delivering it requires standing up
**AspectJ load-time weaving** and weaving **several coordinated navigation methods** — more than a
one-line predicate, though still far less than a full custom-runner rebuild.

---

## 2. Verified join points (exact JVM descriptors)

`com.intland.codebeamer.manager.testmanagement.TestRunnerEngine`
```
getTestCasesWaitingForRun()Ljava/util/List;            // pending set the stepper draws from
moveToNext(Z)Z                                         // advances the cursor
isAtFirstPendingTestWithoutWrapping()Z
isAtLastPendingTestWithoutWrapping()Z
getCurrentTestCaseRun()Lcom/intland/codebeamer/manager/testmanagement/TestRun;
getTestCaseRunsRecursively()Ljava/util/List;           // full list (side-panel/counts)
```
`com.intland.codebeamer.manager.testmanagement.TestRun`
```
getDelegate()Lcom/intland/codebeamer/persistence/dto/TrackerItemDto;   // → getAssignedTo()
```

**Primary weave target:** `getTestCasesWaitingForRun()` (narrow the pending set to current user).
**Secondary (consistency):** `moveToNext(boolean)` + `isAtLast/FirstPendingTestWithoutWrapping()`
so the cursor never lands on another user's case. These must be woven *as a set* — weaving the
pending getter alone will leave `moveToNext` walking the unfiltered underlying list.

---

## 3. Spike design (smallest experiment that answers the question)

1. Add AspectJ LTW to the **test** Tomcat only (javaagent + `aop.xml`, see sibling files).
2. Weave `getTestCasesWaitingForRun()` with `@Around` returning only runs where
   `run.getDelegate().getAssignedTo()` contains the current user.
3. Generate ONE parent run with, say, 6 children split 3/3 across two test users.
4. Observe and record:

   - [ ] **Isolation:** User A's runner steps through only A's 3 cases; B sees only B's 3.
   - [ ] **Cursor integrity:** `moveToNext` / Next / Previous never lands on the other user's case
         (this is why the secondary methods may also need weaving).
   - [ ] **Premature completion (TOP RISK):** when A finishes A's 3, does the engine merely show
         "done for you," or does it **finalize/auto-close the parent**? The parent must remain open
         until all 6 are done and the lead ends it.
   - [ ] **Lock behavior:** concurrent A+B execution on the same parent — no cross-locking.
   - [ ] **End Run gating:** lead's "End Run" stays disabled until all 6 complete
         (`getNoOfNotEditableUnfinishedChildTestRuns() == 0`).
   - [ ] **Side panel / counts:** acceptable if it still shows the full count (cosmetic), or also
         needs `getTestCaseRunsRecursively()` weaving.
   - [ ] **Audit trail:** verdicts recorded against the correct child run and user.

**Decision rule:** if isolation + cursor integrity hold AND the parent does NOT prematurely close,
the approach is viable → proceed to a productionized aspect + formal validation. If the parent
auto-closes on per-user completion, the weave must also intercept the completion check, which
raises the validation cost materially — re-evaluate against Path A (separate parent per tester).

---

## 4. Why this stays *out* of the 62304 / Part 11 calc-audit scope (claim to verify, not assume)

The weave changes **which cases are presented for execution** (navigation/visibility), not
verdict calculation, result persistence, locking, or audit logging — those remain 100% native.
That *should* keep it outside the calc/audit re-qualification triggers your blueprint names.
**However**, it is still a change to execution behavior and a QA/validation lead must scope test
evidence for it. Do not represent it to the customer as "no validation impact."

---

## 5. Rollback

Backups taken 2026-06-16 07:02:11 at
`Philips/cb_testrun_backups/20260616-070211/` (jar + JSPs + custom/ + MANIFEST + REVERT.sh).
The spike adds only NEW files (aspect jar, `aop.xml`, a `setenv.sh` javaagent line). To roll back:
1. Stop test Tomcat.
2. Remove: `WEB-INF/lib/aspectjweaver-*.jar`, `WEB-INF/lib/philips-testrun-filter-*.jar`,
   `WEB-INF/classes/META-INF/aop.xml`, and the `-javaagent` line in `tomcat/bin/setenv.sh`.
3. `bash REVERT.sh --apply` (restores jar/JSPs to checksummed baseline), then start Tomcat.
