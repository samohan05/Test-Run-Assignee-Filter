<#
=================================================================
 Philips per-assignee test-runner filter (CTW) - apply script
 Target: Codebeamer 3.0.0.5 at C:\Codebeamer\CB-3.0.0.5
 Mode  : binary class-shadowing via WEB-INF/classes
 Owner : cb-deployment-engineer (agent-owned)

 BEHAVIOUR
   * Pre-flight gate A: codebeamer Windows service must be STOPPED.
     -IgnoreService bypasses (operator accepts the risk that the JVM
     will not see new class files until next restart).
   * Pre-flight gate B: SHA-256 of the deployed cb-3.0.0.5.jar is
     verified against patches\source-hashes.txt. A mismatch means
     the Codebeamer install has been upgraded since this bundle was
     woven - apply MUST stop and the upgrade SOP in
     DEPLOYMENT-RUNBOOK.md §Upgrade-SOP must be followed instead.
   * Idempotency: if all three shadow class files exist with the
     hashes recorded in patches\expected-post-apply-hashes.txt, the
     script exits 0 with "Already applied".
   * Partial-apply detection: if some (not all) of the three files
     exist, OR any hash differs from the bundled SHA-256s, the
     script refuses and recommends running rollback first.
   * Copies the three woven .class files from patches\woven\ into
     tomcat\webapps\cb\WEB-INF\classes\, creating intermediate
     directories if needed.
   * Clears Jasper compile cache at
     tomcat\work\Catalina\localhost\cb (retry up to 5 times if
     handles aren't released immediately - see DEPLOYMENT-RUNBOOK §Service-control).
   * Writes the three post-apply SHA-256s into
     patches\expected-post-apply-hashes.txt for the next idempotency
     check.
   * Prints the rollback one-liner and a reminder to start the
     service.

 USAGE
   PS> .\patches\apply-testrun-filter.ps1
   PS> .\patches\apply-testrun-filter.ps1 -DryRun
   PS> .\patches\apply-testrun-filter.ps1 -IgnoreService   # if service refuses to stop

 EXIT CODES
   0  Success or already applied
   1  Source-hash mismatch (CB upgraded, must re-weave)
   2  Partial deploy detected (rollback first)
   3  Bundled class file missing
   5  codebeamer service is running (use -IgnoreService to override)
   9  Internal error
=================================================================
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $IgnoreService
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------- paths --------------------------------------------------
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace   = Split-Path -Parent $scriptDir
$bundleRoot  = Join-Path $scriptDir 'woven'
$srcHashFile = Join-Path $scriptDir 'source-hashes.txt'
$postHashFile= Join-Path $scriptDir 'expected-post-apply-hashes.txt'

$cbRoot      = 'C:\Codebeamer\CB-3.0.0.5'
$cbWebapp    = Join-Path $cbRoot 'tomcat\webapps\cb'
$cbClasses   = Join-Path $cbWebapp 'WEB-INF\classes'
$liveCbJar   = Join-Path $cbWebapp 'WEB-INF\lib\cb-3.0.0.5.jar'
$jasperDir   = Join-Path $cbRoot 'tomcat\work\Catalina\localhost\cb'

# The woven artefacts (v2.1: two -- engine + aspect). The v2.1 advice body has
# no lambda, so ajc inlines proceed() and produces NO TestRunnerEngine$AjcClosure1.class.
# If a future rebuild reintroduces a lambda and emits a closure class, add it back here.
# Relative path inside both bundle and live tree.
$shadowFiles = @(
    'com\intland\codebeamer\manager\testmanagement\TestRunnerEngine.class',
    'com\philips\cb\testrun\AssignedRunFilterAspect.class'
)

# ---------- helpers ------------------------------------------------
function Write-Info  ($m) { Write-Host "[apply] $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "[apply] $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "[apply] $m" -ForegroundColor Yellow }
function Write-Err   ($m) { Write-Host "[apply] $m" -ForegroundColor Red }

function Get-Sha256 ([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-HashFile ([string] $Path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2) {
            $map[$parts[0]] = $parts[1].ToLowerInvariant()
        }
    }
    return $map
}

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
                Write-Warn2 ("Jasper cache could NOT be cleared after 5 attempts. Continuing - Tomcat will re-compile JSPs lazily.")
            }
        }
    }
}

# ---------- start --------------------------------------------------
Write-Info "Philips per-assignee test-runner filter apply script"
Write-Info "Workspace : $workspace"
Write-Info "CB root   : $cbRoot"
if ($DryRun) { Write-Warn2 "DRY-RUN MODE - no files will be written." }

# ---------- pre-flight A: service must be stopped ------------------
$svc = Get-Service -Name 'codebeamer' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    if ($IgnoreService) {
        Write-Warn2 ("codebeamer service is Running but -IgnoreService passed. Continuing. New classes will only take effect after the next service restart.")
    } else {
        Write-Err "codebeamer service is RUNNING. Stop it first: 'net stop codebeamer'."
        Write-Err "Pass -IgnoreService to override (only if you accept the deferred-takeover risk)."
        exit 5
    }
} else {
    Write-Ok ("codebeamer service status: " + ($(if ($svc) { $svc.Status } else { 'not registered' })) + " - proceeding.")
}

# ---------- pre-flight B: stock cb-3.0.0.5.jar SHA-256 -------------
if (-not (Test-Path -LiteralPath $liveCbJar)) {
    Write-Err "Deployed cb-3.0.0.5.jar not found at $liveCbJar"
    exit 1
}
$srcHashes = Read-HashFile $srcHashFile
if (-not $srcHashes.ContainsKey('cb-3.0.0.5.jar')) {
    Write-Err "source-hashes.txt has no entry for cb-3.0.0.5.jar."
    exit 9
}
$expectedJarHash = $srcHashes['cb-3.0.0.5.jar']
$actualJarHash   = Get-Sha256 $liveCbJar
if ($actualJarHash -ne $expectedJarHash) {
    Write-Err "Stock cb-3.0.0.5.jar SHA-256 MISMATCH:"
    Write-Err "  expected (pinned)  : $expectedJarHash"
    Write-Err "  actual   (deployed): $actualJarHash"
    Write-Err "Codebeamer has been upgraded since this bundle was woven."
    Write-Err "STOP. Follow DEPLOYMENT-RUNBOOK.md §Upgrade-SOP to re-weave against the new jar."
    exit 1
}
Write-Ok ("Stock cb-3.0.0.5.jar SHA-256 verified: $actualJarHash")

# ---------- bundle integrity check --------------------------------
$bundleHashes = @{}
foreach ($rel in $shadowFiles) {
    $bp = Join-Path $bundleRoot $rel
    if (-not (Test-Path -LiteralPath $bp)) {
        Write-Err "Bundled class file missing: $bp"
        exit 3
    }
    $bundleHashes[$rel] = Get-Sha256 $bp
}
Write-Ok "Bundle integrity check passed ($($shadowFiles.Count) class files present)."

# ---------- idempotency / partial-apply detection -----------------
$postHashes = Read-HashFile $postHashFile
$liveState  = @{}
foreach ($rel in $shadowFiles) {
    $lp = Join-Path $cbClasses $rel
    if (Test-Path -LiteralPath $lp) {
        $liveState[$rel] = Get-Sha256 $lp
    } else {
        $liveState[$rel] = $null
    }
}

$liveCount    = ($liveState.Values | Where-Object { $_ } | Measure-Object).Count
$allPresent   = ($liveCount -eq $shadowFiles.Count)
$nonePresent  = ($liveCount -eq 0)
$matchesPost  = $true
foreach ($rel in $shadowFiles) {
    $basename = Split-Path -Leaf $rel
    if (-not $postHashes.ContainsKey($basename)) { $matchesPost = $false; break }
    if ($liveState[$rel] -ne $postHashes[$basename]) { $matchesPost = $false; break }
}

if ($allPresent -and $matchesPost) {
    Write-Ok "Already applied (all $($shadowFiles.Count) class files match expected-post-apply hashes). Nothing to do."
    exit 0
}
if (-not $nonePresent -and -not $allPresent) {
    Write-Err "Partial deploy detected ($liveCount of $($shadowFiles.Count) class files present)."
    Write-Err "Run patches\rollback-testrun-filter.ps1 first to return to a clean baseline."
    exit 2
}
if ($allPresent -and -not $matchesPost) {
    Write-Warn2 "All $($shadowFiles.Count) class files present but hashes do not match the bundle. This is an OVERWRITE deploy."
    foreach ($rel in $shadowFiles) {
        $basename = Split-Path -Leaf $rel
        Write-Warn2 ("   {0}" -f $basename)
        Write-Warn2 ("      live  : {0}" -f $liveState[$rel])
        Write-Warn2 ("      bundle: {0}" -f $bundleHashes[$rel])
    }
}

# ---------- copy the woven class files ----------------------------
Write-Info "Copying woven class files into WEB-INF/classes ..."
foreach ($rel in $shadowFiles) {
    $src = Join-Path $bundleRoot $rel
    $dst = Join-Path $cbClasses  $rel
    $dstDir = Split-Path -Parent $dst
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    Write-Info ("   {0}" -f $dst)
}

# ---------- clear Jasper cache (retry pattern) --------------------
Write-Info "Clearing Jasper work directory ..."
if (-not $DryRun) { Clear-JasperWithRetry } else { Write-Info "(DRY-RUN) would clear $jasperDir" }

# ---------- write expected-post-apply-hashes.txt -----------------
Write-Info "Writing expected-post-apply-hashes.txt ..."
$hashLines = @(
    '# Philips per-assignee test-runner filter (CTW) - expected post-apply SHA-256',
    '# Written by apply-testrun-filter.ps1. The next apply uses this file to detect',
    '# half-applied deploys and to enable idempotency.',
    '# Format: <basename> <sha256>',
    '# Algorithm: SHA-256'
)
foreach ($rel in $shadowFiles) {
    $basename = Split-Path -Leaf $rel
    $dst = Join-Path $cbClasses $rel
    if ((Test-Path -LiteralPath $dst) -and -not $DryRun) {
        $h = Get-Sha256 $dst
    } else {
        $h = $bundleHashes[$rel]
    }
    $hashLines += ("{0} {1}" -f $basename, $h)
}
if (-not $DryRun) {
    Set-Content -LiteralPath $postHashFile -Value $hashLines -Encoding utf8
    Write-Ok "Post-apply hashes recorded."
} else {
    Write-Info "(DRY-RUN) would write:"
    $hashLines | ForEach-Object { Write-Info "   $_" }
}

# ---------- success summary --------------------------------------
Write-Host ""
Write-Ok "================================================================="
Write-Ok " Philips per-assignee test-runner filter applied successfully."
Write-Ok "================================================================="
Write-Host ""
Write-Warn2 "The codebeamer service must be (re)started for the classes to load:"
Write-Warn2 "    net start codebeamer"
Write-Host ""
Write-Warn2 "The filter is ACTIVE as soon as the classes load (Option B - no switch)."
Write-Warn2 "There is NO JVM property and NO config toggle. To turn it OFF, run the"
Write-Warn2 "rollback below (removes the shadow classes) and restart."
Write-Host ""
Write-Info "Rollback (delete shadow classes, return to stock):"
Write-Info "    .\patches\rollback-testrun-filter.ps1"
Write-Host ""
Write-Info "Smoke checklist: DEPLOYMENT-RUNBOOK.md §Post-restart-smoke"
exit 0
