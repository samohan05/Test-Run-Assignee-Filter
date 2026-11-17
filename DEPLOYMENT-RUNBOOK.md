# DEPLOYMENT RUNBOOK — Per-Assignee Test Runner Filter + Assignment & Execution Board (CTW)

**Customization:** Per-Assignee Test Runner Filter (backend) + Assignment & Execution Board (widget frontend)
**Codebeamer target:** 3.2.0.2 (Jakarta/Tomcat 10, Windows, procrun service)
**Mechanism:** AspectJ Compile-Time Weaving (CTW) for the backend filter, deployed as class-shadowing under `WEB-INF/classes`; a static external widget (HTML + JSON) for the frontend
**Status:** v18.4.4 — ported from the 3.0.0.5 / `TestRunnerEngine` release (see `legacy/3.0.0.5-testrunner-engine/`)
**Last update:** 2026-11-16

This runbook supersedes the 3.0.0.5 runbook for this Codebeamer target. The prior runbook,
ADRs, and scripts remain under `legacy/3.0.0.5-testrunner-engine/` for environments still
running that version — **do not run those scripts against this install**, and do not run
*this* runbook's scripts against a 3.0.0.5 install (wrong weave target, wrong jar hash pin).

---

## 0. TL;DR — the 60-second view

1. **Backend build:** one-shot `ajc 1.9.22` invocation compiles `AssignedRunFilterAspect.java`
   and `SingleRunFilterAspect.java` and binary-weaves the former into a single-class inpath
   containing only `TestRun.class` (extracted from `cb-3.2.0.2.jar`). `EffectiveAssignmentAuthorizationService.java`
   is picked up implicitly (same source directory) because the aspect references it. This
   build emits 8 `.class` files (`TestRun`, `AssignedRunFilterAspect`, `SingleRunFilterAspect`
   + 2 inner classes, `EffectiveAssignmentAuthorizationService` + 2 inner classes). Gate: the
   build log must contain `Join point ... TestRun.getTestCaseRunsRecursively() ... advised by
   ... AssignedRunFilterAspect`, and `javap -p AssignedRunFilterAspect.class` must show
   `aspectOf()`.
2. **Two more classes, plain `javac`, no weaving:** `PhilipsAuthorizedChildrenController.java`
   and `PhilipsCurrentUserController.java` (under the vendor package
   `com.intland.codebeamer.controller.testmanagement`) — these back the widget's REST calls.
   **10 class files total** to deploy.
3. **Deploy backend:** `.\patches\apply-testrun-filter.ps1`. Service must be stopped
   (`net stop codebeamer`) first; script's pre-flight refuses otherwise.
4. **Deploy frontend:** copy `web/executeRunWidget.html`, `web/cb-widget-api.js`, and
   `web/menuitem_submenuindicator.png` to `<CB_WEBAPP>/custom/`, publish `web/extension.json`
   through your configured `externalWidgetExtensions` mechanism, clear
   `externalWidgetExtensionConfigCache`. No restart required for a frontend-only change.
5. **No enable step:** the backend filter is active as soon as the ten class files are
   deployed and the service restarts. There is no JVM property and no config switch.
6. **Start:** `net start codebeamer`. Smoke per §7. Run the Assignment Board functional
   checklist in the implementation guide (`docs/Test_Run_-_Assignment_and_Execution_Board.docx`,
   section "Validation Checklist").
7. **Rollback / disable:** `.\patches\rollback-testrun-filter.ps1` deletes the ten backend
   shadow classes and restarts; restore the previous `executeRunWidget.html` /
   `extension.json` pair for a frontend rollback.

---

## 1. What changed from the 3.0.0.5 runbook

| Area | 3.0.0.5 (`legacy/`) | 3.2.0.2 (this runbook) |
|---|---|---|
| Codebeamer install | `C:\Codebeamer\CB-3.0.0.5` | `C:\Codebeamer\CB-3.2.0.2` |
| Weave target | `TestRunnerEngine.getTestCaseRunsRecursively()` | `TestRun.getTestCaseRunsRecursively()` (method moved vendor-side) |
| Shadow class count | 2 (engine + aspect) | **10** (see §0.1–0.2) |
| Current-user source | `((TestRunnerEngine) pjp.getThis()).getUser()` | `TestRun` has no public `getUser()` → reflective read of the private `user` field |
| AspectJ toolchain | Build 1.9.22-tools / **runtime 1.9.7** (version-skew workaround, ADR-0004) | Build **and** runtime 1.9.22.x — no skew; see ADR-0006 |
| User-facing surface | None | Assignment & Execution Board external widget |
| ADR register entries | ADR-0003 Entry #1, ADR-0004 | ADR-0005 Entry #2/#3, ADR-0006 |

Per customer direction, the 3.0.0.5 artefacts are retained unmodified under `legacy/` rather
than deleted — see `legacy/3.0.0.5-testrunner-engine/README.md`.

---

## 2. Pre-flight checklist (BLOCKERs)

Before triggering deployment, confirm ALL of the following.

| # | Pre-flight item |
|---|---|
| 1 | `cb-3.2.0.2.jar` SHA-256 matches `patches/source-hashes.txt` (`ba85f2c1…`). If mismatch → Codebeamer has been patched; trigger §9 Upgrade-SOP, do NOT proceed. |
| 2 | Stock `TestRun.class` SHA-256 matches the pin in ADR-0005 Entry #2 (`e7126216…`). |
| 3 | `aspectjweaver-1.9.22.1.jar` is at `tomcat/webapps/cb/WEB-INF/lib/` and unchanged. |
| 4 | All ten class files exist at `patches/woven/...` and their SHA-256s match ADR-0005 Entry #2/#3. Rule: deploy every `.class` the build emits. |
| 5 | `patches/expected-post-apply-hashes.txt` is in its stub form, or carries hashes from a prior successful apply you intend to overwrite. |
| 6 | No other customization currently shadows `com.intland.codebeamer.manager.testmanagement.TestRun` or either `Philips*` controller. Check `tomcat/webapps/cb/WEB-INF/classes/com/intland/codebeamer/...` for pre-existing files with the same names from a different source. |
| 7 | The `codebeamer` Windows service is stopped (`Get-Service codebeamer` → `Status: Stopped`) OR you accept the `-IgnoreService` deferred-takeover model. |
| 8 | A pre-apply snapshot of `cb-3.2.0.2.jar` and the current customization jar (`philips-cb-customization-3.2.0.2.jar`) is preserved for upgrade-diff use. |
| 9 | The Assignment Board functional validation dataset (standard runs, parameterized runs, direct-user/role/group assignment, unassigned, completed) is either captured or explicitly waived in writing. |

**If any of 1–7 is ✗ → STOP.** 8–9 are pre-customer-touch, not pre-deploy.

---

## 3. Prerequisites — environment

### 3.1 Target install
- Codebeamer 3.2.0.2 at `C:\Codebeamer\CB-3.2.0.2\`
- Tomcat 10 inside that install: `tomcat\webapps\cb\WEB-INF\`
- Procrun Windows service registered as `codebeamer`. Verify: `Get-Service codebeamer`.
- JDK 21 (Adoptium) for the running JVM and for `javac`/`javap`/`jar` during build —
  `cb-3.2.0.2.jar` itself is Java 21 bytecode (class-file major version 65); an older JDK/ajc
  fails to read it (`cannot access ... bad class file ... wrong version`).

### 3.2 Build host requirements
- `Philips_Customizations` Maven project containing all `cb-*` dependency jars under `libs/`,
  plus `aspectjtools-1.9.22.jar` (compiler tools).
- The source files from `src/main/java/` in this repository, staged at
  `src/main/java/com/philips/cb/testrun/` and `src/main/java/com/intland/codebeamer/controller/testmanagement/`
  in that build project.

### 3.3 Operator role
The deploy itself runs from PowerShell with admin rights (procrun service control requires
it). The build can run from any account; bash (Git for Windows) is fine for the build steps
below.

---

## 4. Backend build — one-shot ajc 1.9.22 binary weave

### 4.1 Stage the inpath (single-class)

```bash
PROJ="C:/path/to/Philips_Customizations"   # the companion build project, not this repo
CB_JAR="$PROJ/libs/cb-3.2.0.2.jar"
JAR="<JDK21>/bin/jar.exe"

cd "$PROJ"
rm -rf target/cb-inpath target/woven-out
mkdir -p target/cb-inpath target/woven-out
cd target/cb-inpath
"$JAR" xf "$CB_JAR" com/intland/codebeamer/manager/testmanagement/TestRun.class
cd "$PROJ"
```

Narrowing the inpath to a single class avoids ajc scanning every class in `cb-3.2.0.2.jar`
(some of which are themselves already-woven aspects at Java 21 bytecode and can abort a
full-jar scan).

### 4.2 Compile + weave in one ajc invocation

```bash
JAVA="<JDK21>/bin/java.exe"
CP="$(ls $PROJ/libs/*.jar | tr '\n' ';')"

"$JAVA" -Xmx2g -cp "$PROJ/libs/aspectjtools-1.9.22.jar" org.aspectj.tools.ajc.Main \
    -inpath target/cb-inpath \
    -classpath "$CP" \
    -source 11 -target 11 -g -showWeaveInfo \
    -d target/woven-out \
    src/main/java/com/philips/cb/testrun/AssignedRunFilterAspect.java \
    src/main/java/com/philips/cb/testrun/SingleRunFilterAspect.java \
    2>&1 | tee target/woven-out/ajc-build.log
```

**Do not** split this into `javac` + `ajc -aspectpath`; plain `javac` does not synthesize
`aspectOf()` and the woven class throws `NoSuchMethodError` at first invocation.

### 4.3 Build-time gates (must pass before proceeding)

```bash
# Gate 1 — weave-info line (proves the around-advice landed on TestRun, not TestRunnerEngine)
grep -E "Join point .*TestRun\.getTestCaseRunsRecursively.* advised by .*AssignedRunFilterAspect" \
     target/woven-out/ajc-build.log

# Gate 2 — aspectOf() synthesized on the aspect class
<JDK21>/bin/javap.exe -p target/woven-out/com/philips/cb/testrun/AssignedRunFilterAspect.class \
  | grep aspectOf

# Gate 3 — single-run helper compiled with its entry point
<JDK21>/bin/javap.exe -p target/woven-out/com/philips/cb/testrun/SingleRunFilterAspect.class \
  | grep applyToAuthorizedRuns

# Gate 4 — the assigned aspect delegates to the single-run helper
<JDK21>/bin/javap.exe -p -c target/woven-out/com/philips/cb/testrun/AssignedRunFilterAspect.class \
  | grep "SingleRunFilterAspect.applyToAuthorizedRuns"
```

If any gate's grep returns empty → **STOP. Do not deploy.**

### 4.4 Compile the two plain controller classes (no weaving)

```bash
JAVAC="<JDK21>/bin/javac.exe"
"$JAVAC" -source 11 -target 11 -cp "$CP" -d target/woven-out \
    src/main/java/com/intland/codebeamer/controller/testmanagement/PhilipsAuthorizedChildrenController.java \
    src/main/java/com/intland/codebeamer/controller/testmanagement/PhilipsCurrentUserController.java
```

### 4.5 Capture artefact hashes and bundle

```bash
find target/woven-out -name "*.class" | sort | while read f; do
    sha256sum "$f"
done
```

Compare against ADR-0005 Entry #2/#3. A mismatch requires architect sign-off before the new
hashes are recorded. Bundle every emitted `.class` file under `patches/woven/` in this
repository, preserving the package directory structure — the apply script reads from there.

---

## 5. Backend deploy — apply script

### 5.1 Dry-run first

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\patches\apply-testrun-filter.ps1 -DryRun
```

Expected: "Stock cb-3.2.0.2.jar SHA-256 verified", "Bundle integrity check passed (10 class
files present)", a hash inventory, and "DRY-RUN: would copy …" lines for each of the ten
paths.

If the dry-run logs `Stock cb-3.2.0.2.jar SHA-256 MISMATCH` → **STOP**, follow §9 Upgrade-SOP.

### 5.2 Stop the service

```powershell
net stop codebeamer
```

### 5.3 Real apply

```powershell
.\patches\apply-testrun-filter.ps1
```

Expected: exit code `0` and a success banner. The script prints the rollback one-liner.

### 5.4 Activation model — no switch

There is no enable step and no JVM property. The filter is active the moment the ten class
files are present and the service restarts. Turning it off = remove them (§10) and restart.
Deployment never touches JVM options (the prior 3.0.0.5 JVM-property switch was retired for
exactly this reason — see `legacy/3.0.0.5-testrunner-engine/DEPLOYMENT-RUNBOOK.md §5.4`).

### 5.5 Start the service

```powershell
net start codebeamer
```

---

## 6. Frontend deploy — widget assets

The widget frontend is independent of the backend class files and does not require a
Codebeamer restart on its own.

1. Back up the current `executeRunWidget.html`, `extension.json`, `cb-widget-api.js`, and icon
   (record size, timestamp, SHA-256).
2. Copy `web/executeRunWidget.html` to `<CB_WEBAPP>/custom/`.
3. Copy `web/cb-widget-api.js` to the same folder — treat it as a vendor/runtime dependency,
   not business logic; do not modify the minified bundle (see `web/README.md` for its hash).
4. Copy `web/menuitem_submenuindicator.png`, or remove `iconUrl` from the descriptor if you
   don't want an icon.
5. Publish `web/extension.json` through your site's configured `externalWidgetExtensions`
   mechanism. **Increment the `?v=` query string on `viewUrl` whenever the HTML changes** —
   browsers and Codebeamer's own widget cache otherwise keep serving the old build.
6. Clear `externalWidgetExtensionConfigCache` using your site's approved mechanism.
7. Hard-refresh the browser (or open a private window) and confirm the toolbar shows the
   intended build marker (`VER` in the HTML, currently `18.4.4-parent-guard-r5.2-20261117`).

---

## 7. Post-restart smoke

### 7.1 Service health (within 60s of `net start`)

```powershell
Get-Service codebeamer            # Status: Running
Invoke-WebRequest -Uri 'http://localhost:<port>/cb/' -UseBasicParsing -TimeoutSec 10 |
    Select-Object StatusCode
```

### 7.2 Boot log scan — `tomcat\logs\cb.txt`

```powershell
Get-Content 'C:\Codebeamer\CB-3.2.0.2\tomcat\logs\cb.txt' -Tail 300 |
   Select-String -Pattern 'Server startup','NoSuchMethodError','NoClassDefFoundError',
       'LinkageError','VerifyError','PhilipsAuthorizedChildrenController',
       'PhilipsCurrentUserController','BeanCreationException'
```

**GREEN signals:**
- `Server startup in NNNN ms`.
- `PhilipsAuthorizedChildrenController v17.2 class loaded` (the static-init log line this
  controller emits — confirms the class was loaded by the classloader; absence means the
  class is missing or the JVM is serving a cached/old version).

**RED signals (any ⇒ STOP, follow §10):**
- `NoSuchMethodError ... aspectOf` — rebuild per §4.2, do not deploy a class compiled with
  plain `javac`.
- `NoClassDefFoundError ... TestRun$AjcClosure1` — a build that reintroduced a lambda was
  deployed without its closure class; redeploy every `.class` the build emitted.
- `LinkageError` / `VerifyError` mentioning `TestRun` — AspectJ toolchain mismatch; re-check
  ADR-0006 (should not occur on this target, since build/runtime are both 1.9.22.x).

### 7.3 Functional smoke

- Open a parent Test Run with the widget deployed; confirm it loads child rows (not stuck on
  "Initializing").
- `GET /cb/api/testRun/philips/currentUser` returns your user as JSON.
- `GET /cb/api/testRun/philips/authorizedChildren?parentId=<id>` returns an
  `authorizedChildIds` array for a Test Run you have access to.
- Assign a run to yourself, confirm the board updates and `Run` enables for that row.
- Run the full dataset matrix in the implementation guide (standard, parameterized,
  direct-user, role, group-inherited role, unassigned, completed/skipped, 500+ children
  pagination).

---

## 8. Observability

- Daily: `findstr /R "PhilipsAuthorizedChildrenController" C:\Codebeamer\CB-3.2.0.2\tomcat\logs\cb.txt`
  — at least one INFO line per business day during regular hours confirms the controller is
  live and being called.
- Watch for `AssignedRunFilterAspect` `ERROR`/exception lines — the aspect fails open (returns
  an empty list) on internal errors; any such line means a tester saw zero runs when they
  should have seen some. Investigate promptly.
- Watch for recurring "currentUser is null" / reflective-access warnings from
  `AssignedRunFilterAspect.currentUserOf(...)` — indicates the fail-open path is being hit;
  the `user` field's name or accessibility changed on a Codebeamer patch.

---

## 9. Upgrade SOP — when Codebeamer ships a patch

1. **Detect:** the apply script's pre-flight gate (`Stock cb-3.2.0.2.jar SHA-256 MISMATCH`) is
   the automatic trigger.
2. **Diff `TestRun.class`:** extract it from the new jar and from the pinned stock copy
   (ADR-0005 Entry #2), `javap -p -c` both, `Compare-Object`.
   - Diff empty or confined to methods not woven here → proceed.
   - Diff touches `getTestCaseRunsRecursively()`, its signature, or `areAllEditableTestCasesComplete()`
     → escalate to architect; a full re-validation cycle is triggered.
3. **Re-weave:** repeat §4 against the new jar. Capture the new `ajc-build.log` and SHA-256s.
4. **Update ADR-0005** Entry #2 with the new vendor jar hash, stock/woven `TestRun.class`
   hashes.
5. **Update `patches/source-hashes.txt`** with the new `cb-3.2.0.2.jar` hash.
6. **Bundle the new artefacts** at `patches/woven/` (overwrites the prior bundle).
7. **Re-validate:** stop service, apply, start service, run §7 smoke + the full functional
   matrix. Capture old/new hashes, javap diff, new `ajc-build.log`, and functional results as
   evidence.
8. **Sign-off** before promoting to any further environment.

---

## 10. Rollback

### 10.1 Disable (no soft switch)
Same as §5.4: the only way to turn the backend filter off is to remove the shadow classes —
"disable" and "rollback" are the same operation.

### 10.2 Backend hard rollback

```powershell
net stop codebeamer
.\patches\rollback-testrun-filter.ps1
net start codebeamer
```

The script takes optional `.preRollback-<DATE>.bak` backups of the ten class files before
deleting them, verifies the target paths are empty afterward, and resets
`expected-post-apply-hashes.txt`.

### 10.3 Frontend rollback

1. Restore the previous `executeRunWidget.html` and `extension.json` pair — **never mix a new
   HTML build with an older descriptor, or vice versa.**
2. Restore the previous `cb-widget-api.js` only if it changed.
3. Clear `externalWidgetExtensionConfigCache`.
4. Hard-refresh and confirm the prior build marker.

### 10.4 Catastrophic recovery (scripts themselves fail)

```powershell
Remove-Item -Force `
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\intland\codebeamer\manager\testmanagement\TestRun.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\AssignedRunFilterAspect.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\SingleRunFilterAspect.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\SingleRunFilterAspect$StrictRunScope.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\SingleRunFilterAspect$StrictRunSelection.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\EffectiveAssignmentAuthorizationService.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\EffectiveAssignmentAuthorizationService$AssignmentAuthorizationContext.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\philips\cb\testrun\EffectiveAssignmentAuthorizationService$RoleMembershipKey.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\intland\codebeamer\controller\testmanagement\PhilipsAuthorizedChildrenController.class',
    'C:\Codebeamer\CB-3.2.0.2\tomcat\webapps\cb\WEB-INF\classes\com\intland\codebeamer\controller\testmanagement\PhilipsCurrentUserController.class' `
    -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force 'C:\Codebeamer\CB-3.2.0.2\tomcat\work\Catalina\localhost\cb' -ErrorAction SilentlyContinue
net start codebeamer
```

---

## 11. Known constraints & open items

| # | Constraint | Mitigation / acceptance |
|---|---|---|
| 1 | Forked core class — every CB upgrade triggers re-validation if `TestRun` changes | ADR-0005 + §9 Upgrade SOP |
| 2 | `TestRun.getTestCaseRunsRecursively()` is now also in the completion-gating call path (unlike 3.0.0.5's separate `TestRunnerEngine`/`TestRun` methods) | See ADR-0005's behavioral-change note; validate End-Run gating explicitly |
| 3 | `AssignedRunFilterAspect`'s engine/aspect state is set up per call; no cross-request cache | Not a correctness issue, just a performance note for very high-traffic installs |
| 4 | Operation/authorization state has no persistence of its own beyond Codebeamer's own `assignedTo` field | N/A — this customization reads/writes only standard Codebeamer fields |
| 5 | Nested/parameterized test-case variants inherit parent assignee | Documented in the implementation guide; works by inheritance |

## 12. References

- ADRs: `docs/adr/0005-forked-core-class-register-testrun.md`, `docs/adr/0006-aspectj-toolchain-3-2-0-2.md`
- Implementation guide: `docs/Test_Run_-_Assignment_and_Execution_Board.docx` (Executive Summary through Appendix B — business scenario, UX, architecture, endpoint contracts, validation, troubleshooting, known Test Runner lifecycle behaviors)
- Source: `src/main/java/com/philips/cb/testrun/`, `src/main/java/com/intland/codebeamer/controller/testmanagement/`
- Deployable bundle: `patches/woven/`
- Build log: `patches/ajc-build.log`
- Scripts: `patches/apply-testrun-filter.ps1`, `patches/rollback-testrun-filter.ps1`
- Hash pins: `patches/source-hashes.txt`, `patches/expected-post-apply-hashes.txt`
- Legacy (3.0.0.5): `legacy/3.0.0.5-testrunner-engine/`

---

**End of runbook.**
