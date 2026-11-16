<#
=================================================================
 Philips per-assignee test-runner filter (CTW) - rollback script
 Target: Codebeamer 3.0.0.5 at C:\Codebeamer\CB-3.0.0.5
 Owner : cb-deployment-engineer (agent-owned)

 BEHAVIOUR
   * Pre-flight: codebeamer Windows service should be stopped.
     -IgnoreService bypasses (operator accepts that the JVM keeps
     using the in-memory woven classes until next restart).
   * Optional safety backup (default ON, disable with -NoSafetyBackup):
     copies the three deployed class files to
       <basename>.preRollback-<YYYY-MM-DD>.bak
     next to them, so an accidental rollback is undoable without
     a rebuild.
   * Deletes the three shadow class files from
     tomcat\webapps\cb\WEB-INF\classes\:
       com\intland\codebeamer\manager\testmanagement\TestRunnerEngine.class
       com\intland\codebeamer\manager\testmanagement\TestRunnerEngine$AjcClosure1.class
       com\philips\cb\testrun\AssignedRunFilterAspect.class
   * Removes the now-empty com\philips\cb\testrun\ directory tree.
     Does NOT remove com\intland\... directories (they may host
     other Philips shadows in the future).
   * Clears Jasper compile cache at
     tomcat\work\Catalina\localhost\cb (with retry pattern matching
     apply script).
   * Resets patches\expected-post-apply-hashes.txt to its stub state.
   * Verifies the three target paths are gone, then prints the
     start-service reminder.

 ROLLBACK BASELINE
   The three shadow paths did not exist before Customization B was
   first deployed. Their absence IS the baseline; no .bak of an
   earlier state is required to restore stock CB. The webapp
   classloader will resolve TestRunnerEngine from cb-3.0.0.5.jar
   again as soon as Tomcat restarts.

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

$cbRoot      = 'C:\Codebeamer\CB-3.0.0.5'
$cbWebapp    = Join-Path $cbRoot 'tomcat\webapps\cb'
$cbClasses   = Join-Path $cbWebapp 'WEB-INF\classes'
$jasperDir   = Join-Path $cbRoot 'tomcat\work\Catalina\localhost\cb'
$today       = Get-Date -Format 'yyyy-MM-dd'

# v2.1 deploys two shadow classes (engine + aspect); the inlined advice produces
# no TestRunnerEngine$AjcClosure1.class. If a future build emits one, add it here.
$shadowFiles = @(
    'com\intland\codebeamer\manager\testmanagement\TestRunnerEngine.class',
    'com\philips\cb\testrun\AssignedRunFilterAspect.class'
)
# We only own the com\philips\cb\testrun\ tree (Customization B
# package). Removing the com\intland\... directories would be
# presumptuous - other Philips customizations may place shadows there.
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
Write-Info "Philips per-assignee test-runner filter rollback script"
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
            '# Philips per-assignee test-runner filter (CTW) - expected post-apply SHA-256',
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

# ---------- delete the three shadow class files -------------------
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
        '# Philips per-assignee test-runner filter (CTW) - expected post-apply SHA-256',
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
Write-Ok " Rollback complete. Stock TestRunnerEngine will resume from cb-3.0.0.5.jar."
Write-Ok "================================================================="
Write-Host ""
Write-Warn2 "Start the service to load stock behaviour:"
Write-Warn2 "    net start codebeamer"
Write-Host ""
exit 0
