# ADR-0003: Forked Core Class Register

**Status:** Accepted
**Date:** 2026-06-16
**Author:** cb-project-architect (with cb-senior-developer, cb-deployment-engineer)
**Supersedes:** none
**Related:** ADR-0002 (omit META-INF from customization JARs), ADR-0004 (AspectJ toolchain pinning)

## Context

Customization B (`AssignedRunFilterAspect`, the per-assignee test-runner filter) is the **first** customization in this codebase that **forks a Codebeamer-shipped Java class**. Specifically, it produces a binary-woven `com.intland.codebeamer.manager.testmanagement.TestRunnerEngine.class` deployed via `WEB-INF/classes/` shadowing.

Until now, every customization in `Philips_Customizations` has been either:
- A new class with a CB-mirror package name (e.g. `com.intland.codebeamer.philips.ParameterTableAction`) deployed as a new artefact, **or**
- A read-only / cosmetic edit to a shipped JSP / Velocity template (e.g. the test-run-window v1.0 customization)

Customization B is categorically different: the deployed `TestRunnerEngine.class` is a **modified copy** of vendor bytecode. The original ships in `tomcat/webapps/cb/WEB-INF/lib/cb-3.0.0.5.jar`; the fork sits in `tomcat/webapps/cb/WEB-INF/classes/` and wins the classloader race. Every Codebeamer patch release that ships a changed `cb-3.0.0.5.x.jar` therefore introduces a **silent forking divergence** that we cannot detect without a register.

Without a single source of truth listing every forked FQCN, its stock SHA-256, woven SHA-256, build toolchain, and regulatory scope, the team will:
- Miss the trigger for re-weaving when CB ships a patch
- Lack a defensible audit trail under IEC 62304 / 21 CFR Part 11
- Allow silent forking drift across multiple customizations as more aspects are added

## Decision

**Maintain a Forked Core Class Register as an appendix to this ADR.** Every customization that ships a `.class` file under `WEB-INF/classes/` whose FQCN belongs to `com.intland.codebeamer.*` (Codebeamer-vendor namespace) MUST append an entry before being deployed.

A register entry MUST contain:
1. **FQCN** of the forked class
2. **Stock SHA-256** of the class file (extracted from the original vendor JAR, version-pinned)
3. **Woven SHA-256** of the deployed shadow class
4. **Vendor JAR** the stock was extracted from, with its own SHA-256
5. **Build toolchain** (compiler, weaver, JDK version) — links to ADR-0004 if AspectJ is involved
6. **Customization owner** (the customization name + workspace path)
7. **Regulatory scope** statement (one paragraph; what the change does, what it does NOT touch, scope of re-validation required)
8. **Upgrade trigger criteria** (under what conditions a CB patch requires a re-weave + re-validation cycle)

## Register

### Entry #1 — `com.intland.codebeamer.manager.testmanagement.TestRunnerEngine` (Customization B)

| Field | Value |
|---|---|
| FQCN | `com.intland.codebeamer.manager.testmanagement.TestRunnerEngine` |
| Stock SHA-256 | `171dbe5a8cb8ac6f07701f82941700732adbc45305e6af13699da45418bcac7a` |
| Woven SHA-256 | `635cfd65b5fc72396667990cb08ce30481067d43b5a6374893080f44614e44a1` (v2.1; the weave is now **inlined** — see Companion class) |
| Vendor JAR | `cb-3.0.0.5.jar` SHA-256 `ee1db7af83626b9a751f73f72fd59da2dbb572d3258cd5aef22ced45b74539cd` |
| Companion class | **NONE in v2.1.** The v2.1 advice body has no lambda, so ajc inlines `proceed()` into the engine itself (`getTestCaseRunsRecursively_aroundBody*` methods) — **no `TestRunnerEngine$AjcClosure1.class` is produced**, and the woven engine does not reference one (verified via `javap -v`). v2.1 is a **2-file deploy** (engine + aspect). _v1.0/v2.0 emitted a 3rd closure class (`0a4a1e9e…`) because their advice used a stream/lambda; if a future rebuild reintroduces a lambda the closure can reappear — the rule is "deploy every `.class` the build emits."_ |
| Aspect class | `com.philips.cb.testrun.AssignedRunFilterAspect` SHA-256 `a84da6c3c5405f3cec595a805e90237fe7b76e32196ea66df05de77a74613768` (v2.1 — Option B + role-aware matching; independent, does NOT shadow vendor code). _Prior: v2.0 `bd9c20f0…` (user-only match), v1.0 `277329d7…` (had JVM-property switch)._ |
| Build toolchain | ajc 1.9.22-tools + aspectjrt 1.9.7-runtime + JDK 21 (target Java 11). See ADR-0004. |
| On/off model | **v2.0+ (Option B):** no runtime switch. Filter active whenever the woven classes are deployed; "off" = remove them. Rationale: a global class-shadow makes any switch application-wide anyway, and the prior JVM-property switch was error-prone (clobbered `--add-opens`). |
| Matching (v2.1) | Matches a child run to the current user by **direct user assignment OR a role the user holds in the run's project** (resolved via `ProjectManager.getProjectMemberRoles`, incl. group-derived roles). v2.0 matched only direct users, so role-assigned runs were wrongly hidden. ProjectManager bean is fetched from `ApplicationContextHolder` (the woven aspect is not a Spring bean). Fail-open if role resolution errors. |
| Customization owner | Customization B "Per-Assignee Test Runner Filter (CTW)" — `Codebeamer_Customizations\3_0_0_5\Philips_Customizations\test_run_assignee_filter\` |
| Regulatory scope | The fork modifies `TestRunnerEngine.getTestCaseRunsRecursively()` to return a per-user subset of the child test-case runs. It does **NOT** alter verdict calculation, result persistence, audit logging, electronic-signature capture, locking semantics, or End-Run gating (gating reads `TestRun.getNoOfNotEditableUnfinishedChildTestRuns()` on a different class). Under IEC 62304 the change is in the test-execution navigation surface; re-qualification scope is limited to runner navigation flows. Under 21 CFR Part 11 §11.10(e) audit trail behaviour is unchanged. |
| Upgrade trigger | Any CB upgrade that changes the `cb-3.0.0.5.jar` SHA-256 triggers a re-weave cycle: stock-class diff, re-build, re-validation per DEPLOYMENT-RUNBOOK.md §Upgrade-SOP. |

## Consequences

### Required
- Apply script (`patches/apply-testrun-filter.ps1`) MUST pin the stock vendor JAR SHA-256 and abort on mismatch.
- DEPLOYMENT-RUNBOOK.md MUST cite this ADR's Upgrade SOP section.
- Any new customization that adds an entry MUST be reviewed by the architect before deploy.

### Documented
- The Codebeamer Customization Environment Guide §10 (Deployment) gets a one-paragraph callout pointing at this ADR.

### Risks
- **Multiple forks of the same vendor class will not be detected by a simple register-row count.** Two customizations could both fork `TestRunnerEngine` and silently collide at runtime (the second-applied shadow wins). Apply scripts must check for pre-existing shadow files before writing, with an unambiguous "another customization already forks this class" failure path.
- **Vendor major version updates may break the woven bytecode.** A CB upgrade that recompiles `TestRunnerEngine` against a newer JDK (e.g. JDK 25 class file v69) will force a toolchain upgrade in lockstep — see ADR-0004 for the AspectJ version coupling.

### Operational
- On any CB upgrade: senior-developer agent runs `Get-FileHash cb-3.0.0.5.jar` against every register entry's Vendor JAR pin. Each mismatch triggers the entry's Upgrade SOP.
- The register is the **first artefact** a regulatory auditor will request when asking "what vendor code has Philips modified?". Keep it accurate.

## Open questions for follow-up

1. Should the register be a separate file (`docs/adr/forked-core-class-register.md`) referenced by ADRs, rather than appendix-style growth inside this ADR? Decide before entry #2.
2. Should we ship the woven `TestRunnerEngine.class` to source control alongside the source aspect, or only the build artefacts under `patches/woven/`? Today: only `patches/woven/` is checked in. Future: revisit if multiple operators need to deploy without re-running ajc.
3. Should each register entry produce a corresponding apply / rollback script pair, or is one pair per "customization" sufficient even if it shadows N classes? Today: one pair per customization (B has one pair, deploys 2 classes in v2.1 — was 3 before the advice was inlined).
