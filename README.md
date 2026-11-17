# Per-Assignee Test Runner Filter + Assignment & Execution Board (v18.4.4)

A **PTC Codebeamer 3.2.0.2** customization with two parts that share one authorization engine:

1. **A backend filter**, applied by AspectJ compile-time weaving, that restricts the native
   Test Runner's child-run list (and a "strict single-run" launch mode) to the runs the
   current user is actually authorized against — by direct assignment, by a project role they
   hold, or by a role inherited through group membership.
2. **The Assignment & Execution Board** — an external Codebeamer widget shown on a parent Test
   Run that gives testers and coordinators one operational view of the child executions a Test
   Set generates: searchable, filterable, with bulk assignment actions and a single "Run"
   button per row that launches only the authorized, correctly-scoped execution.

Both the native Test Runner and the widget's `Run` button are backed by the **same**
assignment-authorization logic (`EffectiveAssignmentAuthorizationService`) and the **same**
woven interception point (`TestRun.getTestCaseRunsRecursively()`) — the widget is a better user
experience in front of an authorization decision the backend already enforces; it is not a
second, independent security boundary.

> **Looking for the Codebeamer 3.0.0.5 / `TestRunnerEngine` version of this customization?**
> It has been superseded by this release and is kept for reference under
> [`legacy/3.0.0.5-testrunner-engine/`](legacy/3.0.0.5-testrunner-engine/).

> **v18.4.5 (widget-only patch):** `executeRunWidget.html` build bumped to
> `18.4.4-parent-guard-r5.2-20261117`. Fixes `enrichTestCase()`'s Test Case link/ID, which was
> built from `rev.commonItemId` (the logical item lineage) instead of `rev.id` (the physical,
> Stream-specific item this Test Run actually references) — could link to the wrong item in a
> Stream. See [`web/README.md`](web/README.md). No backend/`patches/` change.

---

## What's in this release

| Area | Files |
|---|---|
| Backend source | [`src/main/java/com/philips/cb/testrun/`](src/main/java/com/philips/cb/testrun/) — `AssignedRunFilterAspect.java`, `SingleRunFilterAspect.java`, `EffectiveAssignmentAuthorizationService.java` |
| Backend source (vendor package) | [`src/main/java/com/intland/codebeamer/controller/testmanagement/`](src/main/java/com/intland/codebeamer/controller/testmanagement/) — `PhilipsAuthorizedChildrenController.java`, `PhilipsCurrentUserController.java` |
| Deployable backend bundle | [`patches/woven/`](patches/woven/) — 10 `.class` files; see below |
| Deploy/rollback scripts | [`patches/apply-testrun-filter.ps1`](patches/apply-testrun-filter.ps1), [`patches/rollback-testrun-filter.ps1`](patches/rollback-testrun-filter.ps1) |
| Frontend | [`web/`](web/) — `executeRunWidget.html`, `extension.json`, plus pinned reference copies of the two Codebeamer-vendor files the HTML depends on |
| Deployment runbook | [`DEPLOYMENT-RUNBOOK.md`](DEPLOYMENT-RUNBOOK.md) |
| Architecture decisions | [`docs/adr/`](docs/adr/) |
| Full implementation guide | [`docs/Test_Run_-_Assignment_and_Execution_Board.docx`](docs/Test_Run_-_Assignment_and_Execution_Board.docx) |

## Why there are 10 class files, not a jar

This customization is deployed as **loose `.class` files under `WEB-INF/classes`**
("class-shadowing"), the same mechanism the 3.0.0.5 release used — not a jar:

- `TestRun.class` is Codebeamer's own vendor class, **binary-woven** with
  `AssignedRunFilterAspect`'s advice. It must shadow the stock class from `cb-3.2.0.2.jar` by
  classloader precedence — it cannot be packaged as a normal jar entry.
- `AssignedRunFilterAspect.class`, `SingleRunFilterAspect.class` (+2 inner classes), and
  `EffectiveAssignmentAuthorizationService.class` (+2 inner classes) are the compiled
  output of that same one-shot `ajc` build (see `DEPLOYMENT-RUNBOOK.md` §4) and are deployed
  alongside it for consistency, rather than split across a jar and a class-shadow.
- `PhilipsAuthorizedChildrenController.class` and `PhilipsCurrentUserController.class` back
  the widget's two REST calls. They're ordinary Spring `@Controller` classes with no weaving
  requirement, but they live in a vendor package (`com.intland.codebeamer.controller.testmanagement`)
  that Codebeamer's own internal classloading already scans — confirmed by `cb.txt`
  startup/request logs on a live install with **no customer Spring XML entry at all**. Since
  they need no Spring XML wiring either way, deploying them as loose class files alongside the
  other eight keeps the whole customization to one deployment mechanism instead of two.

`patches/apply-testrun-filter.ps1` deploys all ten as a single, hash-verified, idempotent
operation. See [`DEPLOYMENT-RUNBOOK.md`](DEPLOYMENT-RUNBOOK.md) for the full procedure,
pre-flight checklist, smoke tests, and rollback.

## What was deliberately left out

An earlier, more ambitious "Assignment Board" backend (a snapshot-style API —
`PhilipsAssignmentBoardController`, `AssignmentCommandService`, `AssignmentOptionsAdapter`,
and 14 supporting DTOs under `com.philips.cb.testrun.assignmentboard`) exists in the source
tree this release was built from, but is **not part of this release**: nothing outside that
cluster references it, and the current, deployed widget (`executeRunWidget.html`, build
18.4.4) talks to the simpler `currentUser`/`authorizedChildren` controllers plus Codebeamer's
own public v3 APIs directly — confirmed by reading the HTML and by live request logs. The
implementation guide documents that other design as a separate "V18.5" profile for future
reference; it was never the shipped backend and is intentionally not included here.

## Architecture

```
Native Test Runner                    Assignment & Execution Board widget
  |                                      |
  `-- TestRun.getTestCaseRunsRecursively()   `-- GET  /cb/api/testRun/philips/currentUser
        (woven)                             `-- GET  /cb/api/testRun/philips/authorizedChildren
        |                                   `-- (standard Codebeamer v3 APIs for everything else:
        v                                        item/relations query, field options, atomic field PUT)
  AssignedRunFilterAspect
        +-- EffectiveAssignmentAuthorizationService   (direct user / role / group-inherited role)
        `-- SingleRunFilterAspect                     (optional strict single-run narrowing)
```

See [`docs/adr/0005-forked-core-class-register-testrun.md`](docs/adr/0005-forked-core-class-register-testrun.md)
for the full forked-class register entry (hashes, weave point, regulatory scope) and
[`docs/adr/0006-aspectj-toolchain-3-2-0-2.md`](docs/adr/0006-aspectj-toolchain-3-2-0-2.md) for
the build-toolchain decision.

## Deployment

See [`DEPLOYMENT-RUNBOOK.md`](DEPLOYMENT-RUNBOOK.md) — pre-flight checklist, build procedure,
backend apply/rollback scripts, frontend deployment, post-restart smoke tests, upgrade SOP,
and known constraints.

## Repository layout

```
.
├── README.md                     This file
├── DEPLOYMENT-RUNBOOK.md         Full deployment/operations runbook for this release
├── src/main/java/
│   ├── com/philips/cb/testrun/                              The aspect + helper classes
│   └── com/intland/codebeamer/controller/testmanagement/    The two REST controllers
├── patches/
│   ├── woven/                    The 10 deployable .class files
│   ├── apply-testrun-filter.ps1
│   ├── rollback-testrun-filter.ps1
│   ├── source-hashes.txt         Pinned stock cb-3.2.0.2.jar hash
│   ├── expected-post-apply-hashes.txt
│   └── ajc-build.log             Proof of a successful weave
├── web/                          Widget HTML/JSON + pinned vendor JS/icon (see web/README.md)
├── docs/
│   ├── adr/                      Architecture decision records
│   └── Test_Run_-_Assignment_and_Execution_Board.docx   Full implementation guide
└── legacy/3.0.0.5-testrunner-engine/   Superseded Codebeamer 3.0.0.5 release (see its README)
```
