# DEPLOYMENT RUNBOOK — Per-Assignee Test Runner Filter (CTW)

**Customization:** B — Per-Assignee Test Runner Filter
**Codebeamer target:** 3.0.0.5 (classic, Windows, procrun service)
**Mechanism:** AspectJ Compile-Time Weaving (CTW), deployed as class-shadowing under `WEB-INF/classes`
**Status:** v1.0 — ready for formal deployment after BLOCKERs in §Pre-flight-checklist are met
**Owners:** `cb-project-architect`, `cb-senior-developer`, `cb-deployment-engineer` (agent-owned; this runbook is the authoritative deployment doc — it does NOT modify the customer-supplied `DEPLOY.md` in the same folder, which is kept as historical reference)
**Last update:** 2026-06-16

---

## 0. TL;DR — the 60-second view

1. **Build:** one-shot `ajc 1.9.22` invocation that compiles `AssignedRunFilterAspect.java` AND binary-weaves it into a single-class inpath containing only `TestRunnerEngine.class`. Output: 3 `.class` files in `target/woven-out/` (engine, `$AjcClosure1`, aspect). Gate: build log must contain the `Join point ... advised by around advice from AssignedRunFilterAspect` weave-info line, AND `javap -p AssignedRunFilterAspect.class` must show `aspectOf()`.
2. **Deploy:** `.\patches\apply-testrun-filter.ps1`. Service must be stopped (`net stop codebeamer`) first; script's pre-flight refuses otherwise.
3. **Enable:** add `-Dphilips.testrun.assigneeFilter=true` to the procrun service JVM options. The aspect defaults to OFF — class drop alone changes no behaviour.
4. **Start:** `net start codebeamer`. Smoke per §Post-restart-smoke. Two-user functional matrix per `DEPLOY.md §6b`.
5. **Rollback:** `.\patches\rollback-testrun-filter.ps1`. Deletes the three shadow classes, JVM resolves stock `TestRunnerEngine` from `cb-3.0.0.5.jar`.

---

## 1. Why this runbook exists separately from `DEPLOY.md`

The customer-supplied `DEPLOY.md` (same folder) contains three documented bugs (cross-referenced in the architect's pre-deploy review):

- §2 mandates `ajc 1.9.7` tools. The deployed `cb-3.0.0.5.jar` contains Java 21 class files (major version 65); `ajc 1.9.7` crashes on them with `Unsupported class file major version 65`.
- §4b step 2 uses `-1.11` — not a valid `ajc` flag (legacy `-1.X` form stops at `-1.8`; Java 9+ uses bare `-11` or `-source 11 -target 11`).
- §4b step 1 compiles the aspect with `javac` and then passes via `-aspectpath`. Plain `javac` does **not** synthesize `aspectOf()`, so the woven engine throws `java.lang.NoSuchMethodError: AssignedRunFilterAspect.aspectOf()` on first runner click.

Per customer direction (2026-06-16): **do NOT modify `DEPLOY.md`.** This runbook is the authoritative agent-owned deployment doc; `DEPLOY.md` is retained as historical reference. When the two disagree, **this runbook wins.**

---

## 2. Pre-flight checklist (BLOCKERs)

Before triggering deployment, confirm ALL of the following. Each blocker must close (✓) or have a documented waiver.

| # | Pre-flight item | Status owner |
|---|---|---|
| 1 | `cb-3.0.0.5.jar` SHA-256 matches `patches/source-hashes.txt` (`ee1db7af…`). If mismatch → Codebeamer has been patched; trigger §Upgrade-SOP, do NOT proceed. | deployment-engineer |
| 2 | Stock `TestRunnerEngine.class` SHA-256 matches the pin in `ADR-0003` (`171dbe5a…`). | deployment-engineer |
| 3 | `aspectjweaver-1.9.7.jar` is at `tomcat/webapps/cb/WEB-INF/lib/` AND unchanged (do **not** replace it — see `ADR-0004`). | deployment-engineer |
| 4 | The three woven `.class` files exist at `patches/woven/...` and their SHA-256s match the architect's record in `ADR-0003 §Register Entry #1`. | senior-developer |
| 5 | `patches/expected-post-apply-hashes.txt` is in its stub form (or carries hashes from a prior successful apply that you intend to overwrite). | deployment-engineer |
| 6 | No other customization currently shadows `com.intland.codebeamer.manager.testmanagement.TestRunnerEngine`. Check `tomcat/webapps/cb/WEB-INF/classes/com/intland/codebeamer/manager/testmanagement/` for pre-existing files — see `ADR-0003 §Consequences/Risks` ("Multiple forks of the same vendor class…"). | architect |
| 7 | The codebeamer Windows service is stopped (`Get-Service codebeamer` → Status `Stopped`) OR you accept the `-IgnoreService` deferred-takeover model. | deployment-engineer |
| 8 | A pre-apply snapshot of `cb-3.0.0.5.jar` is preserved at `cb_testrun_backups/<timestamp>/WEB-INF-lib/` for upgrade-diff use (the rollback baseline for the shadow classes themselves is "files do not exist" — no `.bak` required). | deployment-engineer |
| 9 | The QA evidence pack for premature-completion and cursor-coverage tests is either captured (recommended) or explicitly waived in writing. See QA review's §B and §C. | QA lead |

**If any of 1–7 is ✗ → STOP.** 8–9 are pre-customer-touch, not pre-deploy.

---

## 3. Prerequisites — environment

### 3.1 Target install

- Codebeamer 3.0.0.5 at `C:\Codebeamer\CB-3.0.0.5\`
- Tomcat 9 inside that install: `tomcat\webapps\cb\WEB-INF\`
- Procrun Windows service registered as `codebeamer` (also visible as `Codebeamer`). Verify: `sc query codebeamer` → name + STATE line.
- JDK 21 (Adoptium) for the running JVM. Bundled JDK at `C:\Codebeamer\CB-3.0.0.5\jdk\` is used for `javac` / `javap` / `jar` during build.

### 3.2 Build host requirements

- `Philips_Customizations` Maven project at `C:\Users\samohan\Learning\Customization\3_0_0_5\Philips_Customizations\`
  - Contains all the cb-* dependency JARs under `libs/`
  - Contains `aspectjrt-1.9.7.jar` (runtime ref), `aspectjtools-1.9.22.jar` (compiler tools), `aspectjweaver-1.9.7.jar` (mirror of deployed runtime, NOT used in CTW build path)
- Python 3.x on PATH (used by ADR-0002's no-META-INF packaging pattern — not used in CTW, but kept for parity with other Philips customizations)
- The aspect source at `C:\Users\samohan\Learning\Customization\Codebeamer_Customizations\3_0_0_5\Philips_Customizations\test_run_assignee_filter\src\com\philips\cb\testrun\AssignedRunFilterAspect.java` (canonical) and a staged copy under `Philips_Customizations\src\main\java\com\philips\cb\testrun\` (build location)

### 3.3 Operator role

The deploy itself runs from PowerShell with admin rights (procrun service control requires it). The build can run from any account; bash (Git for Windows) is fine and the chain below assumes it.

---

## 4. Build — one-shot ajc 1.9.22 binary weave

### 4.1 Stage the inpath (single-class)

Narrow the ajc `-inpath` to a directory containing **only** `TestRunnerEngine.class`. A full-jar inpath causes ajc to scan all 7,000+ classes in `cb-3.0.0.5.jar`; some of those (notably `PluggableCodeLoggingAspect` and `GlobalLockAspect`) are already woven aspects at Java 21 major-65 bytecode, and re-weaving them aborts even with `ajc 1.9.22` (`Unsupported class file major version 65` on the `StackMapAdder`).

```bash
PROJ="C:/Users/samohan/Learning/Customization/3_0_0_5/Philips_Customizations"
DEPLOYED_CB_JAR="C:/Codebeamer/CB-3.0.0.5/tomcat/webapps/cb/WEB-INF/lib/cb-3.0.0.5.jar"
JAR="C:/Codebeamer/CB-3.0.0.5/jdk/bin/jar.exe"

cd "$PROJ"
rm -rf target/cb-inpath target/woven-out
mkdir -p target/cb-inpath target/woven-out
cd target/cb-inpath
"$JAR" xf "$DEPLOYED_CB_JAR" com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class
cd "$PROJ"
```

### 4.2 Compile + weave in one ajc invocation

The compile-and-weave must be a single ajc call so the aspect class carries `aspectOf()`. **Do not** split into `javac` + `ajc -aspectpath`; plain `javac` produces a class missing `aspectOf()` and the woven engine throws `NoSuchMethodError` at first invocation.

```bash
JAVA="C:/Codebeamer/CB-3.0.0.5/jdk/bin/java.exe"
CP="libs/aspectjrt-1.9.7.jar;$DEPLOYED_CB_JAR"
for j in libs/cb-common-3.0.0.5.jar libs/cb-jsp-wiki-3.0.0.5.jar \
         libs/spring-beans-5.3.39.jar libs/spring-context-5.3.36.jar libs/spring-core-5.3.39.jar \
         libs/servlet-api-tomcat-9.0.jar libs/commons-collections4-4.4.jar libs/guava-33.0.0-jre.jar \
         libs/log4j-api-2.23.1.jar libs/log4j-core-2.23.1.jar; do
    [ -f "$j" ] && CP="$CP;$j"
done

"$JAVA" -cp "libs/aspectjtools-1.9.22.jar" org.aspectj.tools.ajc.Main \
    -inpath target/cb-inpath \
    -classpath "$CP" \
    -source 11 -target 11 -g -showWeaveInfo \
    -d target/woven-out \
    src/main/java/com/philips/cb/testrun/AssignedRunFilterAspect.java \
    2>&1 | tee target/woven-out/ajc-build.log
```

### 4.3 Build-time gates (must BOTH pass before proceeding)

```bash
# Gate 1 — weave-info line (proves the around-advice landed)
grep -E "Join point .*TestRunnerEngine\.getTestCaseRunsRecursively.* advised by .*AssignedRunFilterAspect" \
     target/woven-out/ajc-build.log

# Gate 2 — aspectOf() synthesized on the aspect class
"C:/Codebeamer/CB-3.0.0.5/jdk/bin/javap.exe" -p \
    target/woven-out/com/philips/cb/testrun/AssignedRunFilterAspect.class \
  | grep "aspectOf"
```

If either grep returns empty → **STOP. Do not deploy an unwoven class.**

### 4.4 Capture artefact hashes

The three woven `.class` files are the deployable bundle.

```bash
find target/woven-out -name "*.class" -type f | sort | while read f; do
    size=$(stat -c%s "$f"); hash=$(sha256sum "$f" | awk '{print $1}')
    echo "$size B  $hash  $f"
done
```

Compare against `docs/adr/0003-forked-core-class-register.md` §Register Entry #1. Mismatch (any class differs from the recorded hash) is **not** automatically a failure — the recorded hashes are pinned to a specific source revision and toolchain. **A mismatch requires architect sign-off** before the new hashes are recorded into ADR-0003.

### 4.5 Bundle the artefacts

```bash
CANONICAL="C:/Users/samohan/Learning/Customization/Codebeamer_Customizations/3_0_0_5/Philips_Customizations/test_run_assignee_filter"
mkdir -p "$CANONICAL/patches/woven/com/intland/codebeamer/manager/testmanagement"
mkdir -p "$CANONICAL/patches/woven/com/philips/cb/testrun"
cp "target/woven-out/com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class" \
   "$CANONICAL/patches/woven/com/intland/codebeamer/manager/testmanagement/"
cp 'target/woven-out/com/intland/codebeamer/manager/testmanagement/TestRunnerEngine$AjcClosure1.class' \
   "$CANONICAL/patches/woven/com/intland/codebeamer/manager/testmanagement/"
cp "target/woven-out/com/philips/cb/testrun/AssignedRunFilterAspect.class" \
   "$CANONICAL/patches/woven/com/philips/cb/testrun/"
```

The bundle at `patches/woven/` is what the apply script reads.

---

## 5. Deploy — apply script

The `patches/apply-testrun-filter.ps1` script enforces all pre-flight gates programmatically.

### 5.1 Dry-run first

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\patches\apply-testrun-filter.ps1 -DryRun
```

Expected output:
- "Stock cb-3.0.0.5.jar SHA-256 verified" (no mismatch)
- "Bundle integrity check passed (3 class files present)"
- Hash inventory of the three live class files vs. the bundle
- "DRY-RUN: would copy …" lines for each of the three paths
- "DRY-RUN: would clear …" for the Jasper work dir
- "DRY-RUN: would write …" for `expected-post-apply-hashes.txt`

If the dry-run logs `Stock cb-3.0.0.5.jar SHA-256 MISMATCH` → **STOP**, follow §Upgrade-SOP.

### 5.2 Stop the service

```powershell
net stop codebeamer
# wait until 'sc query codebeamer' shows STATE: 1 STOPPED
```

See §Service-control for shutdown timing and file-handle release behaviour.

### 5.3 Real apply

```powershell
.\patches\apply-testrun-filter.ps1
```

Expected: exit code `0` and a "Philips per-assignee test-runner filter applied successfully" success banner. The script prints the rollback one-liner on success.

### 5.4 Enable the filter

The deployed aspect is **disabled by default** (`SYSTEM_PROPERTY_DEFAULT = false` in source; see `AssignedRunFilterAspect.java`). The class-drop alone does NOT activate the filter — this is deliberate per the aspect's class Javadoc, so a fresh deploy can be smoke-tested for structural cleanliness BEFORE any behaviour change.

To activate, use the agent-owned helper from an **elevated** PowerShell session (writing to HKLM requires admin):

```powershell
.\patches\enable-testrun-filter.ps1
```

The script:
- Edits `HKLM:\SOFTWARE\WOW6432Node\Apache Software Foundation\Procrun 2.0\codebeamer\Parameters\Java\Options` (the procrun service's `REG_MULTI_SZ` JVM-arg array)
- Removes any existing `-Dphilips.testrun.assigneeFilter=…` line (with any value) and appends the canonical `=true`
- Is idempotent — re-runs are no-ops
- Prints the before/after Options array and the verification command
- Does NOT touch the customer-supplied `cbservice.bat` (which uses `--JvmOptions` overwrite-mode and would clobber our entry if re-run)

> **Caveat:** if anyone ever re-runs `cbservice.bat` later (e.g., during a CB upgrade reinstall), it uses `--JvmOptions "<long-string>"` (overwrite) and our enable-line is wiped. Re-run `enable-testrun-filter.ps1` after any `cbservice.bat` invocation. The upgrade SOP in §9 is the canonical sequence.

Once the registry change is in place, restart the service for the change to load:

```powershell
net stop codebeamer
net start codebeamer
```

Equivalent low-level command (wrapped by the script — do NOT use directly, it lacks idempotency):

```cmd
"C:\Codebeamer\CB-3.0.0.5\bin\codebeameramd64.exe" //US//codebeamer ++JvmOptions=-Dphilips.testrun.assigneeFilter=true
```

### 5.5 Start the service

```powershell
net start codebeamer
```

Proceed to §Post-restart-smoke.

---

## 6. Service control — procrun nuances

### 6.1 Stop

`net stop codebeamer` returns once the service control manager has signalled the stop. The actual JVM teardown is asynchronous — file handles on `tomcat\work\Catalina\localhost\cb` are released **after** `net stop` returns. The apply script's Jasper-clear handles this with a 5-attempt retry pattern at 5-second intervals.

If `net stop` returns success but the JVM does not exit within 180 seconds:
1. Do **NOT** `taskkill /F` immediately. Force-kill of a regulated environment must be logged as a regulatory event.
2. Check `sc queryex codebeamer` for the PID; check `handle.exe` (Sysinternals) for what's held.
3. If genuinely wedged: `taskkill /PID <pid> /F` and document the forced kill in the deploy log with the reason.

### 6.2 Start

`net start codebeamer` returns once the service entry-point method returns — but Codebeamer's Spring + webapp init continues in background for 2–4 minutes. The cb webapp does not respond to HTTP until `cb.txt` shows the "Server startup in NNNN ms" line. See §Post-restart-smoke.

### 6.3 Does NOT honour `cb.bat` or `setenv.bat`

The procrun service launches the JVM directly via prunsrv.exe; it does **not** run `cb.bat`, `startup.bat`, or `setenv.bat`. JVM options must be configured via prunmgr (or `prunsrv //US//codebeamer ++JvmOptions=…`). The customer-supplied `DEPLOY.md` had a brief moment of confusion on this — `setenv.bat` is dead code under procrun.

---

## 7. Post-restart smoke (formal-deploy)

### 7.1 Service health (within 60 s of `net start`)

```powershell
sc query codebeamer   # STATE: 4 RUNNING
netstat -an | findstr ":8001"   # LISTENING line on HTTP port
# (HTTPS may also be exposed on :8444 depending on this install's server.xml)
Invoke-WebRequest -Uri 'http://localhost:8001/cb/' -UseBasicParsing -TimeoutSec 10 |
    Select-Object StatusCode
# Expect 200 or 302 — anything else (404, 503, timeout) = STOP and read cb.txt
```

### 7.2 Boot log scan — `tomcat\logs\cb.txt`

```powershell
Get-Content 'C:\Codebeamer\CB-3.0.0.5\tomcat\logs\cb.txt' -Tail 300 |
   Select-String -Pattern 'Server startup','platform encoding not initialized',
       'NoSuchMethodError','NoClassDefFoundError','LinkageError','VerifyError',
       'AssignedRunFilterAspect','BeanCreationException','TestRunnerEngine'
```

**GREEN signals (must be present):**
- `Server startup in NNNN ms` (cb webapp loaded successfully)
- A line from `AssignedRunFilterAspect` at INFO level: "AssignedRunFilterAspect loaded. Master switch philips.testrun.assigneeFilter=<...> (resolved enabled=<true|false>)" — this is the static-init log line that records the master-switch state. **If absent: the aspect class was not loaded.** Tomcat may be using the stock `TestRunnerEngine`; deployment did NOT take effect.

**RED signals (ANY one ⇒ STOP, follow §Rollback):**
- `platform encoding not initialized` — the LTW failure mode. Should be impossible under CTW (no `-javaagent`). If seen, an LTW residue was missed; restore from `cb_testrun_backups`.
- `NoSuchMethodError ... aspectOf` — the aspect class was compiled without `aspectOf()`. Re-build via §Build §4.2 (one-shot ajc).
- `NoClassDefFoundError: ...TestRunnerEngine$AjcClosure1` — the closure class wasn't deployed. Verify all three class files copied.
- `LinkageError` or `VerifyError` mentioning `TestRunnerEngine` — runtime/tools AspectJ version skew bit us. Re-validate per `ADR-0004`.
- `BeanCreationException ... PhilipsMergeModelEnricherAspect` — the Spring-AOP aspect is broken; the runtime weaver may have been accidentally altered. Verify `aspectjweaver-1.9.7.jar` is untouched.

### 7.3 Aspect activation proof (after first runner load)

After a test user opens a test runner page:

```powershell
Get-Content 'C:\Codebeamer\CB-3.0.0.5\tomcat\logs\cb.txt' -Tail 1000 |
    Select-String -Pattern 'AssignedRunFilterAspect:'
```

Expected at DEBUG level (only if `log4j2.xml` enables DEBUG for `com.philips.cb.testrun`):
- `AssignedRunFilterAspect: user [<id>] filtered N -> M runs`

Expected at WARN level (notable, but expected in narrow edge cases):
- `AssignedRunFilterAspect: filter produced empty set from N runs for user [<id>]` — the tester has zero assigned cases in this run. Visible signal to support, not an error.
- `AssignedRunFilterAspect: currentUser is null on engine [...]` — fail-open path triggered; the runner shows the full list. Investigate the session-state edge case that produced a null user.

### 7.4 Functional matrix

Run `DEPLOY.md §6b` (5 functional checks) with a two-user, multi-assignee parent Test Run. The QA reviewer's §B (premature completion) and §C (cursor coverage with A-B-A-B interleaved data) are STRONGLY recommended additions — see the QA review at the architect's filing point.

---

## 8. Observability — what to watch in production

### 8.1 Daily log scan

```powershell
findstr /R "AssignedRunFilterAspect" C:\Codebeamer\CB-3.0.0.5\tomcat\logs\cb.txt
# At least one INFO line per business day during regular hours = aspect is live.
findstr "AssignedRunFilterAspect.*ERROR\|Exception\|threw" C:\Codebeamer\CB-3.0.0.5\tomcat\logs\cb.txt
# Should be empty under normal operation. Any line = fail-open triggered; investigate.
```

### 8.2 Weekly health check

- Confirm presence of at least one `AssignedRunFilterAspect loaded` INFO line per JVM start
- Confirm at least one `filtering N -> M` line per business day (presence check — silent absence may indicate the JVM restarted without the customization loading)

### 8.3 Anomaly patterns

| Log content | Means | Action |
|---|---|---|
| `AssignedRunFilterAspect: filter produced empty set from N>0 runs for user [...]` for the same user across multiple requests | That user is genuinely assigned to no cases in the parent run, OR a configuration error has assigned cases to the wrong user, OR the filter has a defect | Inspect the parent run's `assignedTo` lists for the affected cases against the user identity |
| `AssignedRunFilterAspect: currentUser is null` recurring | Fail-open path is being hit; the runner is silently showing unfiltered data. The aspect is functioning safely, but the user-resolution path has a bug. | Capture the engine-instance hash from the log line; correlate with the request URL; reproduce in test env |
| `AssignedRunFilterAspect: filter logic threw [...]` | Internal exception caught by fail-open wrapper. Original list returned; tester sees unfiltered data; no functional failure. | Investigate the stack trace in the same log entry; the most likely causes are null elements in `assignedTo` (already guarded) or session-state edge cases on `getDelegate()` |
| Total absence of `AssignedRunFilterAspect` log lines for > 24h | The aspect class is not being loaded — either because the shadow files are missing, the JVM was restarted without picking them up, or a Codebeamer patch silently rolled them back | Run `Get-FileHash` on the three live class files vs `expected-post-apply-hashes.txt`; if mismatch, re-apply |

---

## 9. Upgrade SOP — when Codebeamer ships a patch

When PTC delivery receives a new `cb-3.0.0.5.x.jar` (e.g. `3.0.0.5.1`):

1. **Detect:** the apply script's pre-flight gate (`Stock cb-3.0.0.5.jar SHA-256 MISMATCH`) is the automatic trigger. Manual confirmation: `Get-FileHash <new-jar>` vs `patches/source-hashes.txt`.
2. **Diff the engine class:** extract `com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class` from the new jar (call it `TRE-new.class`) and from the pristine snapshot at `cb_testrun_backups/20260616-070211/WEB-INF-lib/cb-3.0.0.5.jar` (call it `TRE-old.class`). Then:
   ```powershell
   "C:\Codebeamer\CB-3.0.0.5\jdk\bin\javap.exe" -p -c TRE-old.class > TRE-old.javap
   "C:\Codebeamer\CB-3.0.0.5\jdk\bin\javap.exe" -p -c TRE-new.class > TRE-new.javap
   Compare-Object (Get-Content TRE-old.javap) (Get-Content TRE-new.javap)
   ```
   - **If the diff is empty** (same bytecode): proceed to step 3 with no risk.
   - **If the diff is confined to methods we do NOT weave** (e.g. `getTestCasesWaitingForRun`, `moveToNext`, `isAt*`, constructor): proceed to step 3; the woven `getTestCaseRunsRecursively()` advice still applies cleanly to the new shape.
   - **If the diff is in `getTestCaseRunsRecursively()` itself, its return type, or the methods it calls (lazy-cache, `LoadingCache`)**: escalate to architect. The advice may no longer apply correctly. A full re-validation cycle is triggered.
3. **Re-weave:** repeat §Build §4.1–§4.5 against the NEW jar. Capture the new `ajc-build.log` (proof of weave) and the new SHA-256s.
4. **Update ADR-0003 Entry #1:** record the new Vendor JAR SHA-256, the new stock TRE SHA-256, and the new woven SHA-256.
5. **Update `patches/source-hashes.txt`:** replace the old `cb-3.0.0.5.jar` hash with the new one.
6. **Bundle the new artefacts** at `patches/woven/` (overwrites the prior bundle).
7. **Re-validate in test env:** stop service, run apply, start service, run §Post-restart-smoke + DEPLOY.md §6b functional matrix. Capture evidence into `cb_testrun_backups/upgrade-<old>-to-<new>-<date>/`:
   - old jar hash, new jar hash
   - old TRE.class hash, new TRE.class hash, woven TRE.class hash
   - javap diff output (the `Compare-Object` result)
   - new `ajc-build.log` with weave-info line
   - DEPLOY.md §6b functional results (screenshots + DB queries)
8. **QA sign-off** on the evidence pack before any further environment (UAT, production) gets the upgrade.

---

## 10. Rollback

### 10.1 Soft-disable (no rollback, instant)

The aspect's master switch is `-Dphilips.testrun.assigneeFilter`. To neutralise the filter without removing the shadow classes, use the agent-owned helper from an **elevated** PowerShell session:

```powershell
.\patches\disable-testrun-filter.ps1
net stop codebeamer
net start codebeamer
```

The script removes the `-Dphilips.testrun.assigneeFilter=…` line entirely from the procrun JVM Options array (returning the registry to its pre-enable state). It's idempotent — re-runs are no-ops. After restart, `isEnabled()` falls back to `SYSTEM_PROPERTY_DEFAULT = false` and the around-advice returns the unfiltered list immediately. **Zero runtime cost beyond one property read per call.**

The shadow class files at `WEB-INF/classes/` remain deployed — the aspect is still woven into `TestRunnerEngine`, just behaviourally inactive. This is the correct rollback tier when the customer says "turn this off for now" but you want to leave the deploy in place for a fast re-enable later.

To re-enable: `.\patches\enable-testrun-filter.ps1` + restart.

### 10.2 Hard rollback (remove shadow classes)

```powershell
net stop codebeamer
.\patches\rollback-testrun-filter.ps1
net start codebeamer
```

The script takes optional `*.preRollback-<DATE>.bak` of the three class files before deleting them (skip with `-NoSafetyBackup`), verifies the target paths are empty after deletion, and resets `expected-post-apply-hashes.txt` to its stub. The webapp classloader resumes loading stock `TestRunnerEngine` from `cb-3.0.0.5.jar`.

### 10.3 Catastrophic recovery (rollback script itself fails)

The three shadow class paths are file-system paths under your control. If the rollback script fails for any reason:

```powershell
Remove-Item -Force `
    'C:\Codebeamer\CB-3.0.0.5\tomcat\webapps\cb\WEB-INF\classes\com\intland\codebeamer\manager\testmanagement\TestRunnerEngine.class',
    'C:\Codebeamer\CB-3.0.0.5\tomcat\webapps\cb\WEB-INF\classes\com\intland\codebeamer\manager\testmanagement\TestRunnerEngine$AjcClosure1.class',
    'C:\Codebeamer\CB-3.0.0.5\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\AssignedRunFilterAspect.class' `
    -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force 'C:\Codebeamer\CB-3.0.0.5\tomcat\work\Catalina\localhost\cb' -ErrorAction SilentlyContinue
net start codebeamer
```

These are simple file deletes — no scripting required.

---

## 11. Known constraints & open items

These constraints are inherent to the chosen mechanism and ARE accepted for this release. They are not deferrable defects.

| # | Constraint | Mitigation / acceptance reasoning |
|---|---|---|
| 1 | Forked core class — every CB upgrade triggers re-validation if `TestRunnerEngine` changes | `ADR-0003` Forked Core Class Register + §Upgrade-SOP |
| 2 | AspectJ tools / runtime version skew (1.9.22 build, 1.9.7 runtime) | `ADR-0004` — empirically verified compatible for this weave; closure references audited |
| 3 | Side panel from Customization A shows unfiltered cases; stepper from Customization B shows filtered cases | Confirmed by-design — Customization A calls `TestRun.getTestCaseRunsRecursively()` (different class). Documented as a customer-facing UX note in the v1.0 release. |
| 4 | The aspect's engine `index` is set against the unfiltered list at construction; cursor may land on null when filtered list is shorter | UX layer handles null cursor gracefully (existing behaviour); tester uses `#jumpTo` to reset |
| 5 | Nested test sets — structural rows are kept visible (returned `true`) even with no assignee | Documented in aspect class Javadoc + this runbook §Known-constraints |
| 6 | Parameterised test-case variants inherit parent assignee | Documented; works correctly by inheritance, no special handling needed |

---

## 12. References

### 12.1 ADRs
- `docs/adr/0003-forked-core-class-register.md` — the forked-class register (Entry #1 = our customization)
- `docs/adr/0004-aspectj-toolchain-pinning.md` — the toolchain version-skew decision

### 12.2 Source artefacts
- Aspect source: `Codebeamer_Customizations/3_0_0_5/Philips_Customizations/test_run_assignee_filter/src/com/philips/cb/testrun/AssignedRunFilterAspect.java`
- Staged build copy: `Learning/Customization/3_0_0_5/Philips_Customizations/src/main/java/com/philips/cb/testrun/AssignedRunFilterAspect.java`
- Bundled deploy artefacts: `test_run_assignee_filter/patches/woven/`
- Build log: `Learning/Customization/3_0_0_5/Philips_Customizations/target/woven-out/ajc-build.log`

### 12.3 Deployment scripts
- Apply: `test_run_assignee_filter/patches/apply-testrun-filter.ps1`
- Rollback: `test_run_assignee_filter/patches/rollback-testrun-filter.ps1`
- Source SHA pin: `test_run_assignee_filter/patches/source-hashes.txt`
- Expected post-apply SHA: `test_run_assignee_filter/patches/expected-post-apply-hashes.txt` (populated by apply on first run)

### 12.4 Reviews captured during this customization's development
- Senior-developer code review (warnings list) — see session transcript dated 2026-06-16
- Project-architect tactical pre-deploy review (ADRs, validation footprint) — same date
- Deployment-engineer formal-deploy readiness review (scripts, runbooks, observability) — same date
- QA test-strategy review (premature-completion test §B, cursor-coverage test §C) — same date

### 12.5 Customer-supplied DEPLOY.md
- `test_run_assignee_filter/DEPLOY.md` — retained as historical reference. **NOT** authoritative; see §1 of this runbook for the three bugs that disagree with reality.

---

**End of runbook.** Updates to this document must go through the architect agent; the three deployment scripts and ADRs referenced above are the operational primitives.
