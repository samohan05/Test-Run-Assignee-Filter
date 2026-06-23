# Developer Onboarding — Customization B: Per-Assignee Test Runner Filter (CB 3.0.0.5)

**Audience:** A developer who is new to Codebeamer customization AND to AspectJ / aspect-oriented programming. No prior knowledge assumed.
**What this document is:** the "how it was built and why" companion to `DEPLOYMENT-RUNBOOK.md` (which is the "how to deploy" doc). Read this to understand and extend the customization, not just deploy it.
**Customization version:** v2.1 (role-aware matching; two-file deploy)
**Last revised:** 2026-06-23

---

## Part 0 — What this customization does, in plain terms

A **Test Run** in Codebeamer can contain many child test cases, and different cases can be assigned to different testers. Out of the box, when tester A opens the runner for a shared Test Run, they step through *all* the cases — including ones assigned to tester B.

Customization B makes the runner show **each tester only their own assigned cases**. Tester A sees A's cases; tester B sees B's. The parent run stays open until everyone finishes.

It does this by **intercepting one method** deep inside Codebeamer's runner engine and filtering its return value to the current user's cases.

---

## Part 1 — The concept you must understand first: weaving

### 1.1 The problem

The method we need to change lives inside Codebeamer's shipped code — a compiled Java class called `TestRunnerEngine`, inside `cb-3.0.0.5.jar`. **We do not have its source code, and we cannot edit the jar** (it's the vendor's signed product; editing it breaks upgrades and support).

We need `TestRunnerEngine.getTestCaseRunsRecursively()` — the method that returns the list of test cases the runner steps through — to return a *filtered* list. But we can't open the class and add an `if`.

### 1.2 Three ways to change behaviour you don't own — and why two failed

| Approach | Idea | Why it didn't work here |
|---|---|---|
| **Event Listener** (what Customization C would use) | CB fires "item created/updated" events; you write a listener. | The runner engine doesn't fire a listener event for "give me the case list." Listeners hook entity lifecycle events, not arbitrary method calls. |
| **Spring AOP** | Spring can wrap beans in proxies that run your code before/after methods. | Only works on **Spring-managed beans**. `TestRunnerEngine` is created with plain `new TestRunnerEngine(...)`, not by Spring — so Spring can't proxy it. |
| **AspectJ weaving** ✅ | Rewrite the compiled bytecode of the class itself to insert your code at the chosen method. | Works on *any* class, Spring-managed or not, because it changes the actual `.class` file. **This is what we used.** |

### 1.3 What "weaving" actually means

**Aspect-Oriented Programming (AOP)** lets you inject code ("advice") at chosen points ("join points") in existing code, without editing that code's source. The injection is done by a tool called a **weaver**.

- A **join point** is a place in the running program — here, "the moment `getTestCaseRunsRecursively()` is called."
- An **aspect** is a class holding your advice. Ours is `AssignedRunFilterAspect.java`.
- **Advice** is the code that runs at the join point. Ours is `@Around` advice — it wraps the original method, so it can run the original, inspect the result, and return a modified result.
- The **weaver** stitches the advice into the target class's bytecode.

There are two *times* weaving can happen:

| | **Load-Time Weaving (LTW)** | **Compile-Time / Binary Weaving (CTW)** ✅ |
|---|---|---|
| When | The JVM rewrites classes as they load, via a `-javaagent` | At build time, on the dev machine, producing an already-rewritten `.class` |
| Server needs | A `-javaagent:aspectjweaver.jar` JVM flag + an `aop.xml` | Nothing extra — just drop the rewritten `.class` file |
| What we tried first | **LTW — and it crashed Codebeamer's boot** (`java.lang.InternalError: platform encoding not initialized`). The agent instruments classes too early in JVM startup. | **CTW — works.** No agent, no boot perturbation; the JVM just loads a normal (pre-woven) class. |

**We use CTW.** The decision and the LTW failure are recorded in `CTW-OPTION.md` and `ADR-0004`.

### 1.4 How the woven class gets loaded instead of the original

Codebeamer's `cb-3.0.0.5.jar` (containing the original `TestRunnerEngine.class`) sits in `tomcat/webapps/cb/WEB-INF/lib/`. Tomcat's classloader has a rule: **`WEB-INF/classes/` is searched BEFORE `WEB-INF/lib/*.jar`.**

So we place our woven `TestRunnerEngine.class` in `WEB-INF/classes/com/intland/codebeamer/manager/testmanagement/`. The classloader finds it first and never loads the jar's copy. This is called **class shadowing**. The vendor jar is never touched.

Two `.class` files get deployed:
```
WEB-INF/classes/com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class         ← woven (the rewritten engine)
WEB-INF/classes/com/philips/cb/testrun/AssignedRunFilterAspect.class                         ← our aspect
```
> **v2.1 note:** v1.0/v2.0 also deployed a generated `TestRunnerEngine$AjcClosure1.class`. v2.1's advice body has no lambda, so `ajc` inlines `proceed()` into the engine and emits no closure — see Part 3 Step 4.

---

## Part 2 — The aspect, line by line (`AssignedRunFilterAspect.java`, 248 lines)

This is the **only source file we wrote**. Everything else (the woven engine) is generated by the weaver from this plus the vendor jar. (v2.1's advice has no lambda, so the weaver emits no `$AjcClosure1` companion — see Part 3 Step 4.)

### Block 1 — header and imports (lines 1–26)

```java
/*
 * Copyright (c) 2026 PTC Inc. - Customization for Philips.
 * ...
 * Mechanism: Compile-Time Weaving (CTW) via AspectJ, deployed as
 *            class-shadow in tomcat/webapps/cb/WEB-INF/classes/.
 */
package com.philips.cb.testrun;
```
Standard copyright header (matches the team's other customizations) and the package. The package `com.philips.cb.testrun` is *ours* — it does not shadow any vendor class, so it's safe.

```java
import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.manager.testmanagement.TestRunnerEngine;
import com.intland.codebeamer.persistence.dto.TrackerItemDto;
import com.intland.codebeamer.persistence.dto.UserDto;
import com.intland.codebeamer.persistence.dto.RoleDto;
import com.intland.codebeamer.persistence.dto.NamedDto;
```
The CB types we touch: `TestRun` (a child run in the list), `TestRunnerEngine` (the class we weave), `TrackerItemDto` (the underlying tracker item that holds assignee info), `UserDto` (a user), and — new in v2.1 — `RoleDto` / `NamedDto` (an "Assigned to" entry can be a user *or* a role; both are `NamedDto`).

```java
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;
import java.util.ArrayList;
import java.util.List;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.HashSet;
```
- `log4j` — the team's logging API (same as `VetoEditOnOpenReview.java`).
- `org.aspectj.lang.*` — the AspectJ annotations and the `ProceedingJoinPoint` type. **These classes are provided at runtime by `aspectjweaver-1.9.7.jar`, which is already on CB's classpath** — we don't ship them.
- `java.util.*` — list handling plus the per-call `Map<Integer,Set<Integer>>` role cache (v2.1). Note v2.1's filter loop is a plain `for` loop, not a stream — see Block 5.

### Block 2 — the class declaration (lines 88–89)

```java
@Aspect
public class AssignedRunFilterAspect {
```
`@Aspect` marks this class as an AspectJ aspect. The weaver looks for this annotation to know "this class contains advice to weave."

### Block 3 — logger + load breadcrumb (v2.0: no master switch)

```java
private static final Logger log = LogManager.getLogger(AssignedRunFilterAspect.class);

static {
    log.info("AssignedRunFilterAspect v2.1 loaded - per-assignee filtering is ACTIVE "
            + "(matches direct-user AND role assignments; active whenever these woven classes are deployed).");
}
```
- A logger (writes to `cb.txt`).
- A `static { }` block runs **once, when the class is first loaded** (at CB startup). It logs that the filter is active. This is the breadcrumb support greps for to confirm "is this customization on this server?"

> **v1.0 → v2.0 change — the master switch was removed.** v1.0 had a `SYSTEM_PROPERTY_KEY = "philips.testrun.assigneeFilter"` and an `isEnabled()` method that read a JVM system property; the filter defaulted to OFF and was turned on by adding `-Dphilips.testrun.assigneeFilter=true` to the procrun service's JVM options.
>
> That switch was **deleted in v2.0** because it caused a production incident. Setting the JVM property meant editing the procrun service options, and a wrong edit (replace instead of append) **wiped Codebeamer's required `--add-opens` flags**, which broke the project admin page and SSO. More fundamentally, the switch added no real control: CTW class-shadowing replaces the engine for the *whole webapp*, so an on/off property is application-wide anyway — identical in effect to deploying vs. removing the class files.
>
> **v2.0 model:** ON = the classes are deployed; OFF = remove them (the rollback). No JVM property, no `isEnabled()`, nothing in the registry. See ADR-0003 (v2.0 entry) and `DEPLOYMENT-RUNBOOK.md` §5.4.

### Block 4 — the pointcut: WHERE to inject (lines 117–119)

```java
@Pointcut("execution(java.util.List "
        + "com.intland.codebeamer.manager.testmanagement.TestRunnerEngine.getTestCaseRunsRecursively())")
public void testCaseRunsRecursively() {}
```
A **pointcut** names a join point with a pattern. Read the string inside `execution(...)` as:

> "the **execution** of a method that returns `java.util.List`, named `getTestCaseRunsRecursively`, declared on class `TestRunnerEngine`, taking no arguments."

The empty method `testCaseRunsRecursively()` is just a *name* to attach the pattern to (AspectJ convention — the method body is never called; its name labels the pointcut).

**Why this specific method?** It's the "backbone" of the runner. Every navigation and counting method in the engine (current case, "X of N", next/previous) funnels through `getTestCaseRunsRecursively()`. Filtering this one method filters everything the tester sees — verified by reading the engine's bytecode. (The original blueprint targeted a different method, `getTestCasesWaitingForRun()`, which the runner UI never actually calls — that would have been a silent no-op. Corrected during the evidence pass.)

### Block 5 — the advice: WHAT to inject (lines 121–165)

```java
@Around("testCaseRunsRecursively()")
public Object filterRecursiveRuns(ProceedingJoinPoint pjp) throws Throwable {
    Object result = pjp.proceed();
```
- `@Around("testCaseRunsRecursively()")` — this method *wraps* the pointcut. `@Around` is the most powerful advice type: it can run the original method, see its result, and decide what to return.
- `ProceedingJoinPoint pjp` — the handle to the wrapped call. `pjp.proceed()` runs the **original** `getTestCaseRunsRecursively()` and gives us its result (the full, unfiltered list). We call it first so the engine's own logic (and its internal cache) runs normally.

```java
    try {
        if (!isEnabled() || !(result instanceof List)) {
            return result;
        }
```
The whole filter is wrapped in `try { } catch (Throwable) { }` — **fail-open** (explained below). First guard: if the result isn't a `List` for some reason, return the original untouched. (In v1.0 there was also a master-switch check here; removed in v2.0 — see Block 3.)

```java
        @SuppressWarnings("unchecked")
        List<TestRun> all = (List<TestRun>) result;

        UserDto currentUser = null;
        Object target = pjp.getThis();
        if (target instanceof TestRunnerEngine) {
            currentUser = ((TestRunnerEngine) target).getUser();
        }
```
- Cast the result to `List<TestRun>`.
- `pjp.getThis()` — the actual `TestRunnerEngine` *instance* whose method we wrapped. The engine was constructed for one specific user and holds that user in a field; `getUser()` returns them. **This is the key insight that made the design simple** — we don't need a thread-local or the HTTP session; the user is right there on the engine instance.

```java
        if (currentUser == null) {
            log.warn("...currentUser is null on engine [{}] - returning unfiltered list (fail-open)", target);
            return all;
        }
```
If we somehow can't determine the user, return the full list (fail-open — never hide a tester's work due to a resolution miss).

```java
        // per-call cache of the user's role ids, keyed by project id
        final Map<Integer, Set<Integer>> roleIdsByProject = new HashMap<>();
        List<TestRun> mine = new ArrayList<>(all.size());
        for (TestRun run : all) {
            if (isAssignedToUser(run, currentUser, roleIdsByProject)) mine.add(run);
        }
```
**The filter itself (v2.1).** A plain `for` loop that builds a new `ArrayList`, keeping only the runs where `isAssignedToUser(run, currentUser, roleIdsByProject)` is true. `roleIdsByProject` is a per-call cache (built fresh each advice invocation, keyed by project id) so we resolve each project's roles for this user at most once per click — see Block 6. **Because this loop has no lambda, the weaver has nothing to package into a closure — see Part 3 Step 4** (this is why v2.1 emits no `$AjcClosure1`). (v2.0 used a Java stream with a `.filter(lambda)` here, which is exactly why it *did* emit a closure.)

```java
        if (log.isDebugEnabled()) {
            log.debug("...user [{}] filtered {} -> {} runs", currentUser.getId(), all.size(), mine.size());
        }
        if (mine.isEmpty() && !all.isEmpty()) {
            log.warn("...filter produced empty set from {} runs for user [{}] - tester sees 'no work' UI", all.size(), currentUser.getId());
        }
        return mine;
```
- DEBUG line: "filtered 8 → 3 runs" (only if DEBUG logging is on — cheap when off).
- WARN line: if the filter emptied a non-empty list (the tester is assigned nothing in this run) — a notable but legitimate state, logged so support can see it.
- Return the filtered list. **This is the value the runner now uses everywhere.**

```java
    } catch (Throwable t) {
        log.warn("...filter logic threw [{}] - returning unfiltered list (fail-open)", t.toString(), t);
        return result;
    }
}
```
**Fail-open.** If *anything* in the filter throws, log a warning and return the original unfiltered list. The advice runs inside the runner's request — an uncaught exception here would break the runner for the user. Fail-open means a bug in our filter degrades to "shows all cases" (stock behaviour), never "runner is broken."

### Block 6 — the assignee check (v2.1: role-aware, two passes)

```java
private boolean isAssignedToUser(TestRun run, UserDto user, Map<Integer,Set<Integer>> roleIdsByProject) {
    if (run == null) return false;
    TrackerItemDto item = run.getDelegate();
    if (item == null) return true;                       // structural row -> keep visible
    List<? extends NamedDto> assignedTo = item.getAssignedTo();
    if (assignedTo == null || assignedTo.isEmpty()) return true;  // unassigned -> keep visible
    // Pass 1: direct user assignment (and note whether any role is assigned)
    boolean hasRoleAssignee = false;
    for (NamedDto a : assignedTo) {
        if (a == null) continue;
        if (a instanceof UserDto) { if (user.equals(a)) return true; }
        else if (a instanceof RoleDto) { hasRoleAssignee = true; }
    }
    // Pass 2: role assignment -- does the user hold any assigned role in this project?
    if (hasRoleAssignee) {
        Set<Integer> userRoleIds = userRoleIdsInProject(item, user, roleIdsByProject); // may be null
        if (userRoleIds == null) return true;            // role resolution failed -> fail-open, keep visible
        for (NamedDto a : assignedTo) {
            if (a instanceof RoleDto) {
                Integer roleId = ((RoleDto) a).getId();
                if (roleId != null && userRoleIds.contains(roleId)) return true;
            }
        }
    }
    return false;
}
```
"Is this run assigned to this user?" In v2.1 an "Assigned to" entry can be a **user** *or* a **role**, so the check runs in two passes:
- `run.getDelegate()` — the underlying `TrackerItemDto` (where assignee lives).
- **`if (item == null) return true;`** and **empty `assignedTo` → return true** — these keep *structural/folder rows* visible. A folder row in a nested test set has no assignee but must stay visible or the tree rendering breaks. Keeping a no-assignee row doesn't expose another user's *work* (folders carry none).
- **Pass 1 (direct user):** walk the assignees; if any is a `UserDto` that equals the current user, match immediately. `UserDto.equals()` compares by user **id** (verified — not object identity, not version-sensitive), so the same user loaded in different requests still matches. While walking, we also set `hasRoleAssignee` if any entry is a `RoleDto`, so Pass 2 only runs when it can matter.
- **Pass 2 (role):** if a role is assigned, resolve the set of role ids this user holds *in this run's project* (`userRoleIdsInProject(...)`, below — using the per-call cache), then match if any assigned `RoleDto.getId()` is in that set. If role resolution returns `null` (project or bean unavailable), we **fail open** and keep the row visible rather than risk hiding a tester's work.

#### The role resolver — `userRoleIdsInProject(item, user, cache)`

```java
ProjectManager pm = ApplicationContextHolder.getInstance()
        .getApplicationContext().getBean(ProjectManager.class);
List<RoleDto> roles = pm.getProjectMemberRoles(project, user, true); // true = fold in group-derived roles
```
It reads `item.getProject()`, then (caching per project id for the lifetime of one advice call) collects each `RoleDto.getId()` into a `Set<Integer>`. The `true` argument tells CB to **fold in roles the user inherits via group membership**, not just directly-granted roles. It returns `null` if the project or the `ProjectManager` bean can't be resolved — and the caller then fails open (keeps role-assigned runs visible).

> **KEY POINT — why `ApplicationContextHolder` and not `@Autowired`:** the aspect is **not a Spring bean**. It's woven into a `TestRunnerEngine` that CB constructs with `new`, so Spring never instantiates the aspect and there is nothing to autowire into. To reach a managed bean like `ProjectManager`, the aspect must pull it from `ApplicationContextHolder.getInstance().getApplicationContext().getBean(...)` at runtime.

> **Why role resolution (v2.1).** v2.0 matched only direct *user* assignment. A child run whose "Assigned to" was a **role** (not an individual) was hidden from *everyone* — including a tester who actually holds that role. That was a defect; v2.1's Pass 2 fixes it.

---

## Part 3 — The build chain (this is where the real complexity lives)

The source above is straightforward. Turning it into deployable `.class` files was the hard part, with three traps. The full procedure is in `DEPLOYMENT-RUNBOOK.md §4`; here's the *why* behind each step.

### Step 1 — extract just the one class to weave into

```bash
jar xf cb-3.0.0.5.jar com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class
```
We weave into a directory holding **only** `TestRunnerEngine.class`, not the whole jar. **Why:** the weaver's "inpath" is what it rewrites. If we point it at the whole jar, it tries to re-weave CB's *own* existing aspects (CB ships some), which are Java-21 bytecode, and the weaver aborts. Narrowing to one class avoids that.

### Step 2 — compile + weave in ONE command

```bash
java -cp aspectjtools-1.9.22.jar org.aspectj.tools.ajc.Main \
   -inpath <dir with TestRunnerEngine.class> \
   -classpath <aspectjrt + cb jars + spring + log4j> \
   -source 11 -target 11 -g -showWeaveInfo \
   -d target/woven-out \
   AssignedRunFilterAspect.java
```
`ajc` is the AspectJ compiler. In one invocation it (a) compiles our `.java` aspect and (b) weaves its advice into `TestRunnerEngine.class` from the inpath. Output (v2.1): the woven engine + our compiled aspect — **no `$AjcClosure1` is generated, because the advice has no lambda** (ajc inlines `proceed()` directly into the engine; see Step 4).

**Three traps, all learned the hard way:**

1. **`aspectjtools-1.9.22`, NOT 1.9.7.** The deployment doc originally said use 1.9.7 (to "match" the runtime weaver CB ships). But `cb-3.0.0.5.jar` contains **Java 21** bytecode, and ajc 1.9.7 can't read Java 21 (`Unsupported class file major version 65`). We must build with 1.9.22. The *runtime* weaver stays 1.9.7 — and that's fine, because the woven code only references stable AspectJ runtime classes present in both versions (verified; recorded in `ADR-0004`).

2. **`-source 11 -target 11`, NOT `-1.11`.** The doc had a typo: `-1.11` is not a valid ajc flag (the legacy `-1.x` form stops at `-1.8`; Java 9+ uses bare numbers). Correct is `-source 11 -target 11`.

3. **Deploy every `.class` the build emits.** Don't hardcode a file count — deploy whatever lands in the output dir. v2.1 = **two** (woven engine + aspect). If a future rebuild ever reintroduces a lambda in the advice (e.g. someone rewrites the loop as a stream), ajc will again emit a **third** `TestRunnerEngine$AjcClosure1.class` — and that one must be deployed too (see Step 4). Shipping a partial set gives runtime `NoClassDefFoundError` at the first runner click.

> **Also critical — one command, not two — the `aspectOf()` saga.** The doc once said: compile the aspect with plain `javac`, then weave with `ajc -aspectpath`. That path produced an aspect `.class` **missing a method called `aspectOf()`**. The woven engine calls `AssignedRunFilterAspect.aspectOf()` to get the aspect singleton — so at the first runner click, it threw `java.lang.NoSuchMethodError: aspectOf()`. **`aspectOf()` is a method the AspectJ compiler synthesizes** — plain `javac` doesn't add it. The fix: compile the aspect *with ajc in the same weave command* (above), so the aspect class carries `aspectOf()`. This is the single most important build fact in this customization.

### Step 3 — gate the build

Two checks before trusting the output:
- The build log must contain a "weave info" line: `... TestRunnerEngine.getTestCaseRunsRecursively() ... advised by around advice from ... AssignedRunFilterAspect`. If absent, the weave didn't apply — STOP.
- `javap -p AssignedRunFilterAspect.class` must list `aspectOf()`. If absent, you hit the `aspectOf()` trap (the "Also critical" note above) — STOP.

### Step 4 — why there's no `$AjcClosure1` in v2.1 (and when it would reappear)

When `@Around` advice calls `pjp.proceed()`, the weaver needs a way to invoke the *original* method body. **How it does that depends on the advice body:**
- If the advice body **captures a lambda or anonymous class** (as v1.0/v2.0 did — their filter used a Java stream `.filter(lambda)`), ajc can't inline `proceed()` cleanly, so it packages the original method body into a small generated helper class — `TestRunnerEngine$AjcClosure1`. Those versions therefore emitted a **third** class that had to be deployed alongside the engine.
- v2.1's advice body is a plain `for` loop with **no lambda**, so ajc **inlines** `proceed()` directly into the engine (as synthetic `getTestCaseRunsRecursively_aroundBody*` methods) and emits **no closure**. That's why v2.1 is a **two-file** deploy: woven engine + aspect.

**The durable rule: deploy every `.class` the build emits** — don't hardcode "two" any more than the old doc should have hardcoded "three." If a future rebuild reintroduces a lambda in the advice, the `$AjcClosure1` companion reappears in the output dir and must be deployed too; otherwise the first runner click throws `NoClassDefFoundError: TestRunnerEngine$AjcClosure1`.

---

## Part 4 — How it was built (the journey)

1. **Spike + blueprint.** A `SPIKE.md` established the approach after Spring AOP and LTW were ruled out (LTW actually crashed CB boot — see `CTW-OPTION.md`).
2. **Deployment-engineer review** before any deploy — produced the pre-flight checklist now in `DEPLOYMENT-RUNBOOK.md`.
3. **First deploy hit the 3 build traps** (1.9.7-vs-1.9.22, `-1.11` typo, `aspectOf()` missing). Each was diagnosed from the runtime error and fixed. The corrected build chain is the runbook's §4.
4. **Senior-dev code review** then hardened the aspect: added the fail-open `try/catch`, the null-assignee filter, the default-OFF switch, structured logging, and deleted a dead `CurrentUser.java` helper.
5. **ADRs written** — `ADR-0003` (this is the first "forked core class" in the codebase; it needs an upgrade-re-weave register) and `ADR-0004` (the 1.9.22-build / 1.9.7-runtime version split).

**Lesson for you:** the *code* was easy; the *toolchain* was the hard part. If you ever re-build this (e.g. after a CB upgrade), follow `DEPLOYMENT-RUNBOOK.md §4` exactly and watch for the same three traps.

---

## Part 5 — How to extend it

### Change which cases are filtered (the filter logic)
Edit `isAssignedToUser(...)` in the aspect. (Note: matching the user's *role* is **already done** in v2.1 — see Block 6, Pass 2 — so you don't need to add that.) A genuinely new change might be, e.g., honouring direct **user-group** assignment (treat a run assigned to a group the user belongs to as theirs), or scoping the filter to a **per-project allowlist** so it only applies in chosen projects. Add the new branch in `isAssignedToUser` (and a helper if it needs to resolve more CB data, following the `userRoleIdsInProject` / `ApplicationContextHolder` pattern), then **re-build** (Part 3) and re-deploy. **Watch the advice body:** if your change introduces a lambda/stream, ajc will start emitting a `$AjcClosure1` again — deploy it too (Part 3 Step 4).

### Filter additional engine methods
If you find a runner path that bypasses `getTestCaseRunsRecursively()` (a navigation method reading a different list), add a second `@Pointcut` + `@Around` for that method in the same aspect. Re-build, re-deploy. (Today, one pointcut covers everything — verified.)

### After a Codebeamer upgrade (critical)
A CB upgrade ships a new `cb-3.0.0.5.x.jar` with a possibly-changed `TestRunnerEngine`. Your woven class is built against the *old* engine and may not match the new one. You **must re-weave**:
1. `DEPLOYMENT-RUNBOOK.md §Upgrade-SOP` is the step-by-step.
2. In short: diff the new stock `TestRunnerEngine.class` against the pinned hash in `ADR-0003`; if it changed, repeat the Part 3 build against the new jar; re-deploy; re-run the smoke tests.
3. The apply script (`patches/apply-testrun-filter.ps1`) refuses to deploy if the live `cb-3.0.0.5.jar` SHA-256 doesn't match `patches/source-hashes.txt` — that's the automatic tripwire that tells you an upgrade happened and a re-weave is needed.

### Turn the filter on / off (v2.0 — no switch)
- **On:** deploy the class files the build emits (v2.1 = two), restart.
- **Off:** remove those class files (the rollback), restart.
- There is no JVM property and no `enable`/`disable` script anymore — those were retired in v2.0 because editing the procrun JVM options is the step that broke the admin page + SSO. Disabling == rollback.

### Things to NOT do
- **Don't** edit `cb-3.0.0.5.jar` directly. Ever. The whole point of class-shadowing is to leave it untouched.
- **Don't** replace the runtime `aspectjweaver-1.9.7.jar` in `WEB-INF/lib/` with 1.9.22. Another in-production aspect (`PhilipsMergeModelEnricherAspect`) depends on 1.9.7. The build uses 1.9.22; the runtime stays 1.9.7. (Full reasoning in `ADR-0004`.)
- **Don't** deploy a partial set — deploy every `.class` the build emits. v2.1 has no companion closure (two files), but a future lambda-bearing rebuild would add a `$AjcClosure1` that must ship too (Part 3 Step 4).
- **Don't** ship the aspect compiled by plain `javac` — it'll be missing `aspectOf()`. Always build with the one-shot `ajc` command.

---

## Part 6 — Where everything lives

| What | Path |
|---|---|
| The only source file | `src/com/philips/cb/testrun/AssignedRunFilterAspect.java` |
| Built artefacts (deploy these) | `patches/woven/com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class`, `patches/woven/com/philips/cb/testrun/AssignedRunFilterAspect.class` (v2.1 = these two; deploy whatever the build emits — a future lambda would add a `$AjcClosure1`) |
| Deploy target | `tomcat/webapps/cb/WEB-INF/classes/...` (same package paths) |
| Deploy / build / rollback doc | `DEPLOYMENT-RUNBOOK.md` (authoritative) |
| Enable / disable | No scripts (v2.0). On = deploy the class files the build emits (v2.1 = 2); off = remove them. The v1.0 `enable`/`disable` scripts were retired. |
| Apply / rollback scripts | `patches/apply-testrun-filter.ps1`, `patches/rollback-testrun-filter.ps1` |
| Why CTW not LTW; why this method | `CTW-OPTION.md`, `SPIKE.md` |
| Forked-class register + version-skew decisions | `../../3_0_0_5/Philips_Customizations/docs/adr/0003-...`, `0004-...` |
| Source-of-truth repo | https://github.com/samohan05/Test-Run-Assignee-Filter |

**Read next:** `DEPLOYMENT-RUNBOOK.md` for the exact build/deploy commands, then open `AssignedRunFilterAspect.java` side-by-side with Part 2 of this doc. If you only remember one thing: **the aspect must be compiled with `ajc` (one-shot), and `ajc` must be 1.9.22, and you deploy every `.class` the build emits (v2.1 = two).**
