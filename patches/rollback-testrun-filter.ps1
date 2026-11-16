<#
=================================================================
 Philips Per-Assignee Test Runner Filter + Assignment Board (CTW) - rollback script
 Target: Codebeamer 3.2.0.2 at C:\Codebeamer\CB-3.2.0.2
 Owner : cb-deployment-engineer (agent-owned)

 BEHAVIOUR
   * Pre-flight: codebeamer Windows service should be stopped.
     -IgnoreService bypasses (operator accepts that the JVM keeps
     using the in-memory woven classes until next restart).
   * Optional safety backup (default ON, disable with -NoSafetyBackup):
     copies the deployed class files to
       <basename>.preRollback-<YYYY-MM-DD>.bak
     next to them, so an accidental rollback is undoable without
     a rebuild.
   * Deletes the ten shadow/compiled class files from
     tomcat\webapps\cb\WEB-INF\classes\ (see $shadowFiles below).
   * Removes the now-empty com\philips\cb\testrun\ directory tree.
     Does NOT remove com\intland\... directories (they host other
     Philips customizations' classes, including other packages under
     com\intland\codebeamer\controller\testmanagement\ that are NOT
     part of this release - see docs/adr/0003 Consequences/Risks).
   * Clears Jasper compile cache at
     tomcat\work\Catalina\localhost\cb (with retry pattern matching
     the apply script).
   * Resets patches\expected-post-apply-hashes.txt to its stub state.
   * Verifies the ten target paths are gone, then prints the
     start-service reminder.
   * Does NOT touch the widget frontend (web/) - roll that back
     separately per DEPLOYMENT-RUNBOOK.md Rollback-Procedure.

 ROLLBACK BASELINE
   These shadow paths did not exist before this customization was first
   deployed. Their absence IS the baseline; no .bak of an earlier state
   is required to restore stock CB. The webapp classloader will resolve
   TestRun from cb-3.2.0.2.jar again, and PhilipsAuthorizedChildrenController
   / PhilipsCurrentUserController will no longer be registered, as soon as
   Tomcat restarts.

 USAGE
   PS> .\patches\rollback-testrun-filter.ps1
   PS> .\patches\rollback-testrun-filter.ps1 -DryRun
   PS> .\patches\rollback-testrun-filter.ps1 -NoSafetyBackup
   PS> .\patches\rollback-testrun-filter.ps1 -IgnoreService

 EXIT CODES
   0  Success (or already-rolled-back: no files to remove)
   2  Target path verification FAILED after delete (manual inspection required)
   5  codebeamer service is running (use -IgnoreService to override)
   9  Internal error
=================================================================
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $NoSafetyBackup,
    [switch] $IgnoreService
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------- paths --------------------------------------------------
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$postHashFile = Join-Path $scriptDir 'expected-post-apply-hashes.txt'

$cbRoot      = 'C:\Codebeamer\CB-3.2.0.2'
$cbWebapp    = Join-Path $cbRoot 'tomcat\webapps\cb'
$cbClasses   = Join-Path $cbWebapp 'WEB-INF\classes'
$jasperDir   = Join-Path $cbRoot 'tomcat\work\Catalina\localhost\cb'
$today       = Get-Date -Format 'yyyy-MM-dd'

$shadowFiles = @(
    'com\intland\codebeamer\manager\testmanagement\TestRun.class',
    'com\philips\cb\testrun\AssignedRunFilterAspect.class',
    'com\philips\cb\testrun\SingleRunFilterAspect.class',
    'com\philips\cb\testrun\SingleRunFilterAspect$StrictRunScope.class',
    'com\philips\cb\testrun\SingleRunFilterAspect$StrictRunSelection.class',
    'com\philips\cb\testrun\EffectiveAssignmentAuthorizationService.class',
    'com\philips\cb\testrun\EffectiveAssignmentAuthorizationService$AssignmentAuthorizationContext.class',
    'com\philips\cb\testrun\EffectiveAssignmentAuthorizationService$RoleMembershipKey.class',
    'com\intland\codebeamer\controller\testmanagement\PhilipsAuthorizedChildrenController.class',
    'com\intland\codebeamer\controller\testmanagement\PhilipsCurrentUserController.class'
)
# We only own these specific files. Removing the shared com\intland\... package
# directories would be presumptuous - other Philips customizations (and the
# unused "Phase 1 Assignment Board" classes, intentionally not part of this
# release) may place other classes in the same directories.
$philipsOwnedDirs = @(
    'com\philips\cb\testrun',
    'com\philips\cb',
    'com\philips'
)

# ---------- helpers ------------------------------------------------
function Write-Info  ($m) { Write-Host "[rollback] $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "[rollback] $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "[rollback] $m" -ForegroundColor Yellow }
function Write-Err   ($m) { Write-Host "[rollback] $m" -ForegroundColor Red }

function Clear-JasperWithRetry {
    if (-not (Test-Path -LiteralPath $jasperDir)) { Write-Info "Jasper dir already absent."; return }
    for ($i = 1; $i -le 5; $i++) {
        try {
            Remove-Item -LiteralPath $jasperDir -Recurse -Force -ErrorAction Stop
            Write-Ok ("Jasper cache cleared (attempt {0})." -f $i)
            return
        } catch {
            if ($i -lt 5) {
                Write-Warn2 ("Jasper cache delete attempt {0} failed - waiting 5s and retrying..." -f $i)
                Start-Sleep -Seconds 5
            } else {
                Write-Warn2 ("Jasper cache could NOT be cleared after 5 attempts. Continuing - Tomcat will re-compile JSPs lazily on next request.")
            }
        }
    }
}

# ---------- start --------------------------------------------------
Write-Info "Philips Per-Assignee Test Runner Filter + Assignment Board rollback script (v18.4.4)"
if ($DryRun) { Write-Warn2 "DRY-RUN MODE - no files will be modified." }

# ---------- pre-flight: service must be stopped --------------------
$svc = Get-Service -Name 'codebeamer' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    if ($IgnoreService) {
        Write-Warn2 "codebeamer service is Running but -IgnoreService passed. Continuing - file deletion is safe while JVM holds the loaded classes; effect only on next restart."
    } else {
        Write-Err "codebeamer service is RUNNING. Stop it first: 'net stop codebeamer'."
        Write-Err "Pass -IgnoreService to override (deletion is safe; load-effect is on next restart)."
        exit 5
    }
} else {
    Write-Ok ("codebeamer service status: " + ($(if ($svc) { $svc.Status } else { 'not registered' })) + " - proceeding.")
}

# ---------- count what's actually present -------------------------
$present = @()
foreach ($rel in $shadowFiles) {
    $lp = Join-Path $cbClasses $rel
    if (Test-Path -LiteralPath $lp) { $present += $lp }
}
if ($present.Count -eq 0) {
    Write-Ok "All shadow paths are already absent. Nothing to roll back."
    if ((Test-Path -LiteralPath $postHashFile) -and -not $DryRun) {
        $stub = @(
            '# Philips Per-Assignee Test Runner Filter + Assignment Board (CTW) - expected post-apply SHA-256',
            '# Populated by patches\apply-testrun-filter.ps1 on first successful run.',
            '# Format: <basename> <sha256>',
            '# Algorithm: SHA-256'
        )
        Set-Content -LiteralPath $postHashFile -Value $stub -Encoding utf8
        Write-Ok "Reset expected-post-apply-hashes.txt to stub."
    }
    exit 0
}
Write-Info ("Found {0} of {1} shadow class file(s) to remove." -f $present.Count, $shadowFiles.Count)

# ---------- optional safety backup --------------------------------
if (-not $NoSafetyBackup) {
    Write-Info "Taking pre-rollback safety backups (<file>.preRollback-$today.bak) ..."
    foreach ($lp in $present) {
        $bak = "$lp.preRollback-$today.bak"
        if (-not $DryRun) {
            Copy-Item -LiteralPath $lp -Destination $bak -Force
        }
        Write-Info ("   $bak")
    }
} else {
    Write-Warn2 "Skipping safety backup (per -NoSafetyBackup)."
}

# ---------- delete the shadow class files -------------------------
Write-Info "Removing shadow class files ..."
foreach ($rel in $shadowFiles) {
    $lp = Join-Path $cbClasses $rel
    if (Test-Path -LiteralPath $lp) {
        if (-not $DryRun) { Remove-Item -LiteralPath $lp -Force }
        Write-Info ("   removed $lp")
    } else {
        Write-Info ("   (already absent) $lp")
    }
}

# ---------- prune the Philips-owned empty package directories -----
Write-Info "Pruning empty Philips-owned package dirs ..."
foreach ($pkg in $philipsOwnedDirs) {
    $pd = Join-Path $cbClasses $pkg
    if (Test-Path -LiteralPath $pd) {
        $remaining = (Get-ChildItem -LiteralPath $pd -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($remaining -eq 0) {
            if (-not $DryRun) { Remove-Item -LiteralPath $pd -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Info ("   removed empty dir $pd")
        } else {
            Write-Info ("   keeping non-empty $pd ($remaining file(s) remain)")
        }
    }
}

# ---------- clear Jasper cache (retry pattern) --------------------
Write-Info "Clearing Jasper work directory ..."
if (-not $DryRun) { Clear-JasperWithRetry } else { Write-Info "(DRY-RUN) would clear $jasperDir" }

# ---------- verify clean state ------------------------------------
$still = @()
foreach ($rel in $shadowFiles) {
    $lp = Join-Path $cbClasses $rel
    if (Test-Path -LiteralPath $lp) { $still += $lp }
}
if (-not $DryRun -and $still.Count -gt 0) {
    Write-Err "FAIL: target paths still present after delete:"
    $still | ForEach-Object { Write-Err "   $_" }
    exit 2
}
Write-Ok "Verified: all shadow paths absent."

# ---------- reset expected-post-apply-hashes.txt stub -------------
if (-not $DryRun) {
    $stub = @(
        '# Philips Per-Assignee Test Runner Filter + Assignment Board (CTW) - expected post-apply SHA-256',
        '# Populated by patches\apply-testrun-filter.ps1 on first successful run.',
        '# Format: <basename> <sha256>',
        '# Algorithm: SHA-256'
    )
    Set-Content -LiteralPath $postHashFile -Value $stub -Encoding utf8
    Write-Ok "Reset expected-post-apply-hashes.txt to stub."
}

# ---------- final notes -------------------------------------------
Write-Host ""
Write-Ok "================================================================="
Write-Ok " Rollback complete. Stock TestRun will resume from cb-3.2.0.2.jar;"
Write-Ok " PhilipsAuthorizedChildrenController/PhilipsCurrentUserController"
Write-Ok " will no longer be registered."
Write-Ok "================================================================="
Write-Host ""
Write-Warn2 "Start the service to load stock behaviour:"
Write-Warn2 "    net start codebeamer"
Write-Host ""
Write-Warn2 "This script does NOT roll back the widget frontend (web/). See"
Write-Warn2 "DEPLOYMENT-RUNBOOK.md Rollback-Procedure if the HTML/descriptor changed too."
Write-Host ""
exit 0
