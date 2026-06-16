# ADR-0004: AspectJ toolchain pinning — ajc 1.9.22-tools / aspectjrt 1.9.7-runtime split

**Status:** Accepted
**Date:** 2026-06-16
**Author:** cb-senior-developer (with cb-deployment-engineer, cb-project-architect)
**Supersedes:** none
**Related:** ADR-0003 (Forked Core Class Register)

## Context

Customization B (Per-Assignee Test Runner Filter) uses AspectJ compile-time weaving (CTW) to advise `TestRunnerEngine.getTestCaseRunsRecursively()`. The deploy doc (DEPLOY.md §2) initially mandated using AspectJ 1.9.7 tools to "match the version Codebeamer bundles" (`tomcat/webapps/cb/WEB-INF/lib/aspectjweaver-1.9.7.jar`).

**That mandate cannot be honoured** on the deployed Codebeamer 3.0.0.5 install. The reasons emerged in build-time evidence:

1. **`cb-3.0.0.5.jar` contains Java 21 class files** (class-file major version 65). Verified via `javap -v` on extracted classes: `TestRunnerEngine.class`, `PluggableCodeLoggingAspect.class`, `GlobalLockAspect.class` are all major 65.
2. **ajc 1.9.7 cannot read major version 65 bytecode.** Attempted build with `aspectjtools-1.9.7.jar` aborted with `java.lang.IllegalArgumentException: Unsupported class file major version 65` inside `org.aspectj.weaver.bcel.asm.StackMapAdder.addStackMaps`. The crash is structural — 1.9.7 predates Java 17/21 class-file support.
3. **The deployed runtime weaver IS 1.9.7.** Replacing `aspectjweaver-1.9.7.jar` in `WEB-INF/lib` with a newer version is **NOT** an option because the existing `PhilipsMergeModelEnricherAspect` (Spring AOP, in production) was built against and validated with 1.9.7. A runtime weaver upgrade widens the change scope from "shadow three classes" to "modify a shipped CB library used by another in-production aspect" and would itself be a validated change.

Therefore we have two incompatible constraints: **build needs newer ajc** to handle Java 21 class files; **runtime weaver must stay 1.9.7** to not perturb an already-validated aspect.

The empirically successful resolution: **use ajc 1.9.22-tools to build, and let the woven bytecode link against the deployed 1.9.7 runtime at load time.** This works because the AspectJ runtime contract (the public surface of `org.aspectj.runtime.internal.*` and `org.aspectj.lang.*`) is stable across the 1.9.x minor line.

## Evidence

### Verification that woven bytecode is 1.9.7-compatible

The ajc-emitted closure class (`TestRunnerEngine$AjcClosure1.class`) was inspected with `javap -v` and shown to reference only:
- `org.aspectj.runtime.internal.AroundClosure` (constructor + `run([Ljava/lang/Object;)Ljava/lang/Object;` method)
- `org.aspectj.lang.JoinPoint` (parameter type)

Both symbols exist in `aspectjweaver-1.9.7.jar` (verified by `jar tf aspectjweaver-1.9.7.jar | findstr AroundClosure`). The closure does **not** reference any symbol added in 1.9.x for `x > 7`. The single ajc warning emitted at build time — `bad version number found in aspectjrt-1.9.7.jar expected 1.9.22 found 1.9.7` — is informational; the woven build proceeds and produces runnable bytecode.

### Verification that the woven engine class loads at runtime

After deployment, the test environment served test-runner requests without `NoSuchMethodError`, `LinkageError`, `VerifyError`, or `IncompatibleClassChangeError`. The aspect's `@Around` is invoked as expected (verified by the customization functionality being active in manual smoke tests).

### Failed alternatives

- **ajc 1.9.7 tools** — `Unsupported class file major version 65` on first class read. Not viable.
- **Downgrade `cb-3.0.0.5.jar` to a pre-Java-21 build** — would require Codebeamer to ship a different binary. Out of scope.
- **Upgrade `aspectjweaver-1.9.7.jar` to 1.9.22 in `WEB-INF/lib`** — pulls `PhilipsMergeModelEnricherAspect` into the change scope. Defers the problem rather than solving it; we would need a separate ADR + validation cycle for that change.

## Decision

**Pin the build toolchain to AspectJ 1.9.22 tools (`aspectjtools-1.9.22.jar`). Pin the runtime weaver to AspectJ 1.9.7 (`aspectjweaver-1.9.7.jar` in `WEB-INF/lib`, as shipped by Codebeamer). Do not attempt to align the two within the current customization B release cycle.**

Specifically:
1. Build with `aspectjtools-1.9.22.jar` on the classpath of `java -cp <tools> org.aspectj.tools.ajc.Main ...`.
2. Reference `aspectjrt-1.9.7.jar` on the ajc `-classpath` so the compiler emits 1.9.7-compatible runtime references.
3. Do **not** replace `aspectjweaver-1.9.7.jar` in `tomcat/webapps/cb/WEB-INF/lib/`.
4. Do not ship the `aspectjtools-1.9.22.jar` to the production CB install — it is a build-time-only artefact, stored under `Philips_Customizations/libs/` for the build pipeline.

## Why we don't know the long-term mechanism

AspectJ 1.9.x is officially "Java 17+ support is in 1.9.10+; Java 21 support is in 1.9.20+" — the version-skew is therefore a documented capability gap of 1.9.7. What is **less** documented is that ajc-emitted closures stay backward-compatible with older AspectJ runtime jars. That backward compatibility is empirically verified for our specific weave but is not contractually guaranteed across all weave patterns the AspectJ team might introduce in future minor releases.

We cannot assert that all weaves will remain 1.9.7-runtime-compatible. We can only assert that this weave does.

## Consequences

### Required
- DEPLOYMENT-RUNBOOK.md §Build references ajc 1.9.22-tools explicitly; the older Deploy.md §2 mandate for ajc 1.9.7 is recorded as DEPRECATED in the runbook, not corrected in Deploy.md per the customer's wish to keep Deploy.md unmodified.
- The apply script (`patches/apply-testrun-filter.ps1`) pre-flight gate already enforces stock `cb-3.0.0.5.jar` SHA-256 — any change to the vendor jar triggers ADR-0003's Upgrade SOP, which is the right moment to re-evaluate the toolchain skew.

### Documented
- `Philips_Customizations/libs/` carries TWO `aspectjweaver-*.jar` artefacts:
  - `aspectjweaver-1.9.7.jar` — the **deployed runtime** copy (mirrors what's in `WEB-INF/lib`)
  - `aspectjweaver-1.9.22.jar` — historical, **leftover from the failed LTW attempt earlier in the spike**. Not used in the CTW build path. Candidate for cleanup.
- `aspectjtools-1.9.22.jar` (15 MB) is the BUILD artefact added 2026-06-16. NOT deployed to the CB install.
- `aspectjrt-1.9.7.jar` (122 KB) on the build classpath. The runtime symbols match the deployed weaver. NOT deployed to the CB install (already present transitively via `aspectjweaver-1.9.7.jar`).

### Risks
- **Future AspectJ tool release breaks the compatibility.** If ajc 1.9.30+ emits closures that reference 1.9.20-only runtime symbols, our build pipeline will produce class files that throw `NoSuchMethodError` at first invocation under the deployed 1.9.7. Mitigation: re-run the closure javap audit on every toolchain bump. Pin ajc to a specific minor (don't auto-upgrade).
- **Codebeamer ships a newer aspectjweaver in a patch release** (e.g., a hypothetical CB 3.0.0.6 with `aspectjweaver-1.9.20.jar`). Our existing woven classes may still load (forward compatibility usually holds) but the regulatory weight of *not* re-weaving against the new runtime is non-trivial. Trigger ADR-0003's Upgrade SOP on this case explicitly.
- **A developer "fixes" the version skew without reading this ADR** — symptom would be: someone changes the build pipeline to use ajc 1.9.7 to "match the bundled version," which would silently fail to build, or someone replaces the runtime weaver in `WEB-INF/lib`, which would silently break `PhilipsMergeModelEnricherAspect`. Mitigation: this ADR is referenced from DEPLOYMENT-RUNBOOK §Build and is the first ADR shown to anyone touching the AspectJ pipeline.

### Operational
- On every CB upgrade: senior-developer agent re-runs `javap -v` on the new `TestRunnerEngine$AjcClosure1.class` after re-weave, and confirms the new closure still references only 1.9.7-stable runtime symbols. Capture the javap output as evidence in the upgrade artefact bundle.

## Verification post-build

For each new ajc build, run:

```bash
# 1. Closure must only reference 1.9.7-available AspectJ runtime symbols
javap -v target/woven-out/com/intland/codebeamer/manager/testmanagement/TestRunnerEngine\$AjcClosure1.class \
  | grep -E "org/aspectj/(runtime|lang)" | sort -u
# Expected: org/aspectj/lang/JoinPoint and org/aspectj/runtime/internal/AroundClosure ONLY.
# Any other org/aspectj symbol = STOP, runtime compatibility is not certain.

# 2. Closure references must be present in the deployed weaver jar
jar tf C:/Codebeamer/CB-3.0.0.5/tomcat/webapps/cb/WEB-INF/lib/aspectjweaver-1.9.7.jar \
  | grep -E "AroundClosure.class|JoinPoint.class"
# Expected: both class names present.
```

## Open questions for follow-up

1. Is there a Codebeamer-vendor-published statement of what AspectJ runtime version is shipped with each CB release? If so, register it in the upgrade SOP to anticipate runtime version drift.
2. When does the AspectJ project officially deprecate 1.9.7? At that point, this ADR's "do not touch the runtime" decision becomes a security risk and must be revisited (the runtime weaver upgrade then becomes mandatory regardless of `PhilipsMergeModelEnricherAspect` impact).
3. Should `libs/aspectjweaver-1.9.22.jar` (the leftover from the LTW spike) be deleted to avoid confusion? Yes — recommend deleting in the next housekeeping pass.
