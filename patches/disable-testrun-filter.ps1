<#
=================================================================
 Philips per-assignee test-runner filter (CTW) - DISABLE script
 Target: Codebeamer 3.0.0.5 procrun service 'codebeamer'
 Owner : cb-deployment-engineer (agent-owned)

 BEHAVIOUR
   * Edits the procrun service's JVM Options REG_MULTI_SZ at
       HKLM:\SOFTWARE\WOW6432Node\Apache Software Foundation\
         Procrun 2.0\codebeamer\Parameters\Java\Options
   * Removes any line starting with
     -Dphilips.testrun.assigneeFilter= from the options array.
     This returns the procrun config to its pre-enable state.
   * Idempotent: re-running has no further effect.
   * Does NOT restart the service. The change takes effect on the
     next 'net stop codebeamer' / 'net start codebeamer' cycle.
   * Note: this is a SOFT disable (rollback Tier 1). The shadow
     class files at WEB-INF/classes/ remain in place. The aspect
     is still woven into TestRunnerEngine and is still called on
     every recursive-list invocation - but isEnabled() returns
     false (default), so the around-advice returns the unfiltered
     list immediately with no further behaviour change.
     For a hard rollback (remove the class files), use
     patches\rollback-testrun-filter.ps1 instead.

 USAGE
   PS> .\patches\disable-testrun-filter.ps1
   PS> .\patches\disable-testrun-filter.ps1 -DryRun

 PRE-REQ
   * PowerShell session must be elevated (Administrator). Writing
     to HKLM requires admin rights.

 EXIT CODES
   0  Success (or already disabled - no change required)
   1  Procrun registry key not found
   5  Not running as Administrator
   9  Internal error
=================================================================
#>
[CmdletBinding()]
param(
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$regKey           = 'HKLM:\SOFTWARE\WOW6432Node\Apache Software Foundation\Procrun 2.0\codebeamer\Parameters\Java'
$valueName        = 'Options'
$philipsKeyPrefix = '-Dphilips.testrun.assigneeFilter='

function Write-Info  ($m) { Write-Host "[disable] $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "[disable] $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "[disable] $m" -ForegroundColor Yellow }
function Write-Err   ($m) { Write-Host "[disable] $m" -ForegroundColor Red }

# ---------- admin check (skipped on -DryRun so logic can be validated) -----
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Err "This script must run from an ELEVATED PowerShell session (writes to HKLM)."
    Write-Err "Right-click PowerShell -> 'Run as administrator' and retry."
    Write-Err "Tip: re-run with -DryRun to validate the planned change without admin."
    exit 5
}
if (-not $isAdmin -and $DryRun) {
    Write-Warn2 "Not running as Administrator. Continuing in DRY-RUN (read-only) mode."
}

# ---------- registry presence check -------------------------------
if (-not (Test-Path -LiteralPath $regKey)) {
    Write-Err "Procrun registry key not found: $regKey"
    Write-Err "Has the codebeamer service been installed via cbservice.bat?"
    exit 1
}

# ---------- read current options ----------------------------------
$current = (Get-ItemProperty -LiteralPath $regKey -Name $valueName -ErrorAction Stop).$valueName
if ($null -eq $current) { $current = @() }
if ($current -isnot [array]) { $current = @($current) }

Write-Info "Procrun key: $regKey"
Write-Info "Current JVM Options ($($current.Count) lines):"
$current | ForEach-Object {
    if ($_.StartsWith($philipsKeyPrefix)) {
        Write-Host "[disable]    $_   <-- will be removed by this script" -ForegroundColor Yellow
    } else {
        Write-Info "   $_"
    }
}

# ---------- compute new options (remove philips lines) -----------
$new = @($current | Where-Object { -not ($_.StartsWith($philipsKeyPrefix)) })

# Idempotency check
if (($current -join "`n") -eq ($new -join "`n")) {
    Write-Ok "Already disabled (no philips.testrun.assigneeFilter line present)."
    Write-Info "No registry change. The aspect's default behaviour is OFF, so the filter is inactive."
    exit 0
}

Write-Host ""
Write-Info "Computed new JVM Options ($($new.Count) lines):"
$new | ForEach-Object { Write-Info "   $_" }

# ---------- write -------------------------------------------------
Write-Host ""
if ($DryRun) {
    Write-Warn2 "DRY-RUN MODE - no registry change will be made."
} else {
    try {
        Set-ItemProperty -LiteralPath $regKey -Name $valueName -Value $new -Type MultiString -ErrorAction Stop
    } catch {
        Write-Err "Registry write FAILED: $($_.Exception.Message)"
        exit 9
    }
    Write-Ok "Registry updated."
}

Write-Host ""
Write-Ok "================================================================="
Write-Ok " Philips per-assignee test-runner filter is now DISABLED in registry."
Write-Ok "================================================================="
Write-Warn2 "The codebeamer service must be RESTARTED for the change to take effect:"
Write-Warn2 "    net stop codebeamer"
Write-Warn2 "    net start codebeamer"
Write-Host ""
Write-Info "Verify after restart - cb.txt should show:"
Write-Info "    'AssignedRunFilterAspect loaded. ... (resolved enabled=false)'"
Write-Host ""
Write-Info "The shadow class files at WEB-INF/classes/ remain deployed (this is a soft disable)."
Write-Info "For a hard rollback (delete the class files): .\patches\rollback-testrun-filter.ps1"
Write-Info "To re-enable: .\patches\enable-testrun-filter.ps1"
exit 0
