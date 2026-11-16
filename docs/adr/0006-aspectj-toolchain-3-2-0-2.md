# ADR-0006: AspectJ toolchain on Codebeamer 3.2.0.2 — the 3.0.0.5 version-skew no longer applies

**Status:** Accepted
**Date:** 2026-11-16
**Related:** ADR-0005 (Forked Core Class Register, `TestRun`); supersedes the *applicability* of
[legacy/3.0.0.5-testrunner-engine/docs/adr/0004-aspectj-toolchain-pinning.md](../../legacy/3.0.0.5-testrunner-engine/docs/adr/0004-aspectj-toolchain-pinning.md) for this target (that ADR is retained, unmodified, as historical record)

## Context

ADR-0004 (3.0.0.5) documented a hard constraint: `cb-3.0.0.5.jar` shipped Java 21 class files
(major version 65), which only `ajc 1.9.22`-tools could read, but the *deployed runtime
weaver* in that install's `WEB-INF/lib` was `aspectjweaver-1.9.7.jar` — far older, and not
safe to upgrade because an already-validated Spring-AOP aspect
(`PhilipsMergeModelEnricherAspect`) depended on it. The accepted workaround was to build with
1.9.22-tools and rely on the empirically-verified fact that the specific woven closure only
referenced AspectJ runtime symbols stable since 1.9.7.

## What changed on 3.2.0.2

This install's own `tomcat/webapps/cb/WEB-INF/lib/` ships **`aspectjweaver-1.9.22.1.jar`** —
not 1.9.7. Build tools (`aspectjtools-1.9.22.jar`) and the deployed runtime weaver are now in
the same minor line. The entire version-skew workaround ADR-0004 existed to justify is **moot
for this target**.

## Decision

**Build and weave with `ajc 1.9.22`-tools, as before — but there is no longer a
build/runtime split to justify or verify.** Concretely:

1. Continue building with `aspectjtools-1.9.22.jar` on the `java -cp <tools>
   org.aspectj.tools.ajc.Main ...` classpath (see `build-testrun-filters-3.2.0.2.ps1` in the
   companion `Philips_Customizations` project, not shipped in this repository).
2. The deployed `aspectjweaver-1.9.22.1.jar` in `WEB-INF/lib` does not need to be touched,
   audited for symbol compatibility, or pinned against a different version — it already
   matches the build tools' minor line.
3. ADR-0004's closure-symbol verification step (`javap -v ... | grep org/aspectj`) is no
   longer a required gate for this target. It remains good practice if a future weave
   reintroduces a lambda (producing a `TestRun$AjcClosure1.class`), simply to confirm the
   closure loads — not because of a version mismatch, but as ordinary build verification.

## Consequences

### Required
- `DEPLOYMENT-RUNBOOK.md` does not carry forward ADR-0004's "do not touch the runtime weaver"
  constraint as a hard blocker for 3.2.0.2 — there is nothing to protect it from, since build
  and runtime already agree.

### Documented
- Do not assume this alignment holds on every future Codebeamer release. If a later version
  reintroduces a runtime/tools split (e.g. by shipping an older or newer
  `aspectjweaver-*.jar` than whatever `ajc`-tools version is current when this customization
  is next rebuilt), re-open the ADR-0004 verification procedure rather than assuming
  compatibility.

### Risks
- None specific to this release beyond the general forked-core-class risks already tracked in
  ADR-0005.
