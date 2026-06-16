# Compile-Time Weaving (CTW) — the per-assignee runner filter without a runtime agent

**Status:** design write-up for completeness · **Target:** CB 3.0.0.5 (classic, procrun service) · **Companion to:** SPIKE.md

This documents the *only* remaining way to weave `TestRunnerEngine` after the other two failed:
- Spring AOP can't reach it (engine is `new`-constructed, not a Spring bean).
- Load-time weaving (`-javaagent:aspectjweaver`) **broke Codebeamer boot** — `java.lang.InternalError: platform encoding not initialized` in `CodeBeamerContextListener.<clinit>`, because the agent instruments classes before the JVM platform encoding is ready. The `cb` context fails to deploy → 404.

CTW removes the runtime agent entirely. **It does not change the functional design** — same aspect, same join point. It only changes *when* and *how* the advice is injected.

---

## 1. How CTW works (vs. LTW)

| | Load-Time Weaving (failed) | Compile-Time / Binary Weaving (this doc) |
|---|---|---|
| When weaving happens | At class-load, in the running JVM | At **build time**, on the developer/CI box |
| What's on the server | A `-javaagent` that rewrites bytecode during boot | A pre-woven `.class` file. **No agent.** |
| Boot perturbation | Yes — instruments early classes → "platform encoding not initialized" | None — JVM boots exactly as stock; it just loads an already-woven class |
| `aop.xml` | Required (read by the agent) | Not used |
| Runtime dependency | aspectjweaver agent + aspectjrt | aspectjrt only (already in `WEB-INF/lib/aspectjweaver-1.9.7.jar`) |

**Binary weaving** is the relevant flavour: `ajc` (the AspectJ compiler) takes our already-compiled aspect **plus the compiled `cb-3.0.0.5.jar`** as an *inpath*, applies the pointcut, and emits a **modified `TestRunnerEngine.class`** with the advice inlined at the join point. That woven class is a normal Java class — at runtime it just calls into the aspect, which calls `org.aspectj.runtime.*`. No instrumentation, no agent, no early-boot hook. That is precisely why it avoids the crash.

---

## 2. Runtime prerequisites — already satisfied here (verified)

- Woven code references `org.aspectj.lang.*` / `org.aspectj.runtime.*`. Those classes are present in `WEB-INF/lib/aspectjweaver-1.9.7.jar` (verified). So **no new runtime jar is needed**; do NOT add the `-javaagent` line back.
- `WEB-INF/classes/` exists and `TestRunnerEngine` currently lives only in `cb-3.0.0.5.jar` (verified) — so the deployment in §4 is a clean shadow, not a conflict.

---

## 3. Build — `ajc` binary weaving via Maven

Add an AspectJ build to the `test_run_assignee_filter` module (separate from the existing `philips-cb-customization` jar so the woven core class is isolated and easy to roll back).

```xml
<build>
  <plugins>
    <plugin>
      <groupId>dev.aspectj</groupId>
      <artifactId>aspectj-maven-plugin</artifactId>
      <version>1.14</version>          <!-- pin to match the AspectJ line CB ships (1.9.7) -->
      <configuration>
        <complianceLevel>11</complianceLevel>
        <source>11</source>
        <target>11</target>
        <!-- weave OUR aspect INTO the codebeamer classes -->
        <weaveDependencies>
          <weaveDependency>
            <groupId>com.codebeamer</groupId>
            <artifactId>cb</artifactId>     <!-- the 3.0.0.5 jar, see note -->
          </weaveDependency>
        </weaveDependencies>
        <showWeaveInfo>true</showWeaveInfo>
        <verbose>true</verbose>
        <Xlint>warning</Xlint>
      </configuration>
      <executions>
        <execution><goals><goal>compile</goal></goals></execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

Critical: weave against **`cb-3.0.0.5.jar`**, not the `cb-3.0.0.1.jar` the current `pom.xml` references — the woven class must be binary-identical to the deployed engine or it won't load. Update the `cb` system-scope dependency to the 3.0.0.5 jar before building.

`aspectjweaver`/`aspectjrt` (1.9.7) must be a `provided` dependency so `ajc` can compile the aspect; it is NOT shipped (CB already has it at runtime).

Build output: `target/classes/` will contain the woven
`com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class`
and `com/philips/cb/testrun/AssignedRunFilterAspect.class`. `showWeaveInfo=true` prints a line confirming `getTestCasesWaitingForRun()` was advised — that is your build-time proof the weave took.

CLI equivalent (no Maven), for reference:
```
ajc -inpath cb-3.0.0.5.jar -aspectpath philips-testrun-filter.jar \
    -classpath aspectjrt-1.9.7.jar -1.11 -showWeaveInfo -d woven-out
```

---

## 4. Deployment — class shadowing (no agent, no jar edit)

Tomcat's webapp classloader loads `WEB-INF/classes/` **before** `WEB-INF/lib/*.jar`. So drop ONLY the two woven classes here:

```
tomcat/webapps/cb/WEB-INF/classes/com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class
tomcat/webapps/cb/WEB-INF/classes/com/philips/cb/testrun/AssignedRunFilterAspect.class
```

They shadow the jar copy. The signed `cb-3.0.0.5.jar` is **never modified**. No `-javaagent`, no `aop.xml`, no `setenv`/`cbservice.bat` JVM-option change — so the boot path is exactly stock and the 404 cannot recur from this.

Activation = a normal `net stop` / `net start` (no `cbservice.bat` re-register needed, since JVM options don't change). Clear the Jasper/work cache as your existing README already prescribes.

> Alternative deployment: replace just `TestRunnerEngine.class` inside a copy of the jar. More invasive (touches the jar) — prefer the `WEB-INF/classes` shadow.

---

## 5. Rollback

Delete the two `.class` files from `WEB-INF/classes/...` and restart. The jar's original `TestRunnerEngine` resumes immediately — no other change to undo. (Contrast with LTW, where rollback meant editing the service registration.)

---

## 6. What CTW does NOT fix — read before committing

1. **It's still a forked core class.** You now ship a Philips-modified `TestRunnerEngine`. Every CB upgrade that changes that class requires **re-weaving against the new jar**. Pin the SHA-256 of the stock `TestRunnerEngine.class` you wove against; on upgrade, diff and re-weave.
2. **Validation scope is unchanged.** You are altering the behaviour of a core execution class. Under IEC 62304 / 21 CFR Part 11 this is in re-qualification scope — CTW changes the *mechanism*, not the regulatory weight. (The only thing it removes is the runtime-agent risk.)
3. **The §2 functional question is still open.** We wove `getTestCasesWaitingForRun()`. The runner's executable sequence is driven by the cursor (`moveToNext` / `totalNumberOfRunsTillFinished`). If filtering that one method doesn't narrow what the tester can execute, CTW will faithfully reproduce that *non-result* — you'd then re-weave with `moveToNext` + the `isAt*PendingTestWithoutWrapping` methods included. CTW vs LTW makes no difference to which methods must be woven.
4. **Premature-completion risk is unchanged** — still must be tested: does finishing one user's subset leave the parent open or auto-finalise it?

---

## 7. Honest recommendation

CTW is the *correct* way to do engine weaving on this stack, and it removes the boot-crash risk that sank LTW. But it is still: a forked core class, re-woven every upgrade, in full validation scope, with the same unproven functional coverage (§6.3) we never got to confirm. Three mechanisms have now been needed to even attempt this, and two failed outright.

Weigh that against **Path A (one parent run per tester)**: no weaving, no agent, no core-class fork, no boot risk — a generation-side Groovy action plus the native runner, squarely inside the customization and validation flow you already operate. Given the cost trajectory here, Path A remains the lower-risk route to the same functional outcome; CTW is the answer only if a single shared parent run is a hard requirement.
