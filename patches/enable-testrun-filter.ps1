<#
=================================================================
 Philips per-assignee test-runner filter (CTW) - ENABLE script
 Target: Codebeamer 3.0.0.5 procrun service 'codebeamer'
 Owner : cb-deployment-engineer (agent-owned)

 BEHAVIOUR
   * Edits the procrun service's JVM Options REG_MULTI_SZ at
       HKLM:\SOFTWARE\WOW6432Node\Apache Software Foundation\
         Procrun 2.0\codebeamer\Parameters\Java\Options
   * Ensures -Dphilips.testrun.assigneeFilter=true is present
     EXACTLY ONCE in the options array. Any existing line
     starting with -Dphilips.testrun.assigneeFilter= (true OR
     false) is removed before appending the canonical =true.
   * Idempotent: re-running has no further effect.
   * Does NOT restart the service. The change takes effect on
     the next 'net start codebeamer' / services.msc restart.

 USAGE
   PS> .\patches\enable-testrun-filter.ps1
   PS> .\patches\enable-testrun-filter.ps1 -DryRun

 PRE-REQ
   * PowerShell session must be elevated (Administrator). Writing
     to HKLM requires admin rights. Script self-checks and exits 5
     if not elevated.

 EXIT CODES
   0  Success (or already enabled - no change required)
   1  Procrun registry key not found (service not installed?)
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

$regKey      = 'HKLM:\SOFTWARE\WOW6432Node\Apache Software Foundation\Procrun 2.0\codebeamer\Parameters\Java'
$valueName   = 'Options'
$philipsLine = '-Dphilips.testrun.assigneeFilter=true'
$philipsKeyPrefix = '-Dphilips.testrun.assigneeFilter='

function Write-Info  ($m) { Write-Host "[enable] $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "[enable] $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "[enable] $m" -ForegroundColor Yellow }
function Write-Err   ($m) { Write-Host "[enable] $m" -ForegroundColor Red }

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
# Normalize to an array regardless of whether registry returned a string or array
if ($current -isnot [array]) { $current = @($current) }

Write-Info "Procrun key: $regKey"
Write-Info "Current JVM Options ($($current.Count) lines):"
$current | ForEach-Object { Write-Info "   $_" }

# ---------- compute new options (idempotent) ----------------------
$kept = @($current | Where-Object { -not ($_.StartsWith($philipsKeyPrefix)) })
$new  = $kept + $philipsLine

# Detect a no-op (already correctly enabled)
if (($current -join "`n") -eq ($new -join "`n")) {
    Write-Ok "Already enabled (philips.testrun.assigneeFilter=true is already the only entry)."
    Write-Info "No registry change. Service restart not required for this script's effect."
    exit 0
}

Write-Host ""
Write-Info "Computed new JVM Options ($($new.Count) lines):"
$new | ForEach-Object {
    if ($_ -eq $philipsLine) {
        Write-Host "[enable]    $_   <-- added/updated by this script" -ForegroundColor Green
    } else {
        Write-Info "   $_"
    }
}

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
Write-Ok " Philips per-assignee test-runner filter is now ENABLED in registry."
Write-Ok "================================================================="
Write-Warn2 "The codebeamer service must be RESTARTED for the change to load:"
Write-Warn2 "    net stop codebeamer"
Write-Warn2 "    net start codebeamer"
Write-Host ""
Write-Info "Verify after restart:"
Write-Info "    Get-Content 'C:\Codebeamer\CB-3.0.0.5\tomcat\logs\cb.txt' -Tail 500 |"
Write-Info "        Select-String -Pattern 'AssignedRunFilterAspect loaded'"
Write-Info "Expected line: 'AssignedRunFilterAspect loaded. ... (resolved enabled=true)'"
Write-Host ""
Write-Info "To revert: .\patches\disable-testrun-filter.ps1"
exit 0
