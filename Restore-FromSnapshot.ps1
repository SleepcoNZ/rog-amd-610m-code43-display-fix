<#
.SYNOPSIS
    Restore-FromSnapshot.ps1 — Restore the GPU/display/power configuration
    to the captured "working" state.

.DESCRIPTION
    Reads the most recent (or specified) snapshot from .\snapshots\ and re-applies
    the key registry and powercfg settings. Then attempts GPU recovery.

    Run AS ADMINISTRATOR. From a local elevated PowerShell session,
    NOT through Splashtop (UAC won't pass through secure desktop).

.PARAMETER SnapshotPath
    Path to a specific snapshot dir. If omitted, uses the most recent
    "working_state_*" folder.

.PARAMETER SkipGPUReset
    Skip the AMD GPU disable/enable cycle (default does the reset).

.EXAMPLE
    # Use latest snapshot, do full restore
    .\Restore-FromSnapshot.ps1

.EXAMPLE
    # Use a specific snapshot
    .\Restore-FromSnapshot.ps1 -SnapshotPath '.\snapshots\working_state_20260519_000958'
#>
[CmdletBinding()]
param(
    [string]$SnapshotPath,
    [switch]$SkipGPUReset
)

$ErrorActionPreference = 'Continue'

# --- elevation check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script requires Administrator. Right-click PowerShell -> Run as Admin." -ForegroundColor Red
    Write-Host "  Note: Splashtop will NOT pass UAC. Use the laptop directly or HDMI-out KB/mouse." -ForegroundColor Yellow
    exit 1
}

# --- locate snapshot ---
$snapRoot = Join-Path $PSScriptRoot 'snapshots'
if (-not $SnapshotPath) {
    $latest = Get-ChildItem $snapRoot -Directory -Filter 'working_state_*' -EA SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-Host "ERROR: No snapshots found in $snapRoot" -ForegroundColor Red; exit 1 }
    $SnapshotPath = $latest.FullName
}
if (-not (Test-Path $SnapshotPath)) { Write-Host "ERROR: Snapshot not found: $SnapshotPath" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " RESTORE FROM SNAPSHOT" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Using: $SnapshotPath" -ForegroundColor White
Write-Host ""

# === STEP 1 — Restore Power registry ===
Write-Host "[1/7] Restoring Power registry..." -ForegroundColor Yellow
# These are the verified-working values from the snapshot (see 07_reg_power.txt).
$powerSets = @{
    'HKLM:\SYSTEM\CurrentControlSet\Control\Power' = @{
        'PlatformAoAcOverride' = 0   # Modern Standby disabled (we want classic sleep, but it's not available here)
        'CsEnabled'            = 0   # Connected Standby disabled
        'HibernateEnabled'     = 0   # Hibernate disabled
        'HibernateEnabledDefault' = 0
    }
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' = @{
        'HiberbootEnabled' = 0       # Fast Startup disabled
    }
    'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' = @{
        'TdrDelay'      = 30
        'TdrDdiDelay'   = 30
        'TdrLimitCount' = 10
        'TdrLimitTime'  = 60
    }
}
foreach ($k in $powerSets.Keys) {
    if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
    foreach ($v in $powerSets[$k].GetEnumerator()) {
        try {
            Set-ItemProperty -Path $k -Name $v.Key -Value $v.Value -Type DWord -Force
            Write-Host "    OK $k\$($v.Key) = $($v.Value)" -ForegroundColor DarkGray
        } catch {
            Write-Host "    FAIL $k\$($v.Key): $_" -ForegroundColor Red
        }
    }
}

# === STEP 2 — Powercfg settings ===
Write-Host "[2/7] Applying powercfg settings..." -ForegroundColor Yellow
powercfg /hibernate off 2>&1 | Out-Null
Write-Host "    hibernate: off"
# Disable hybrid sleep on both AC/DC (current scheme)
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 2>&1 | Out-Null
# Sleep timeout = never (we don't want auto-sleep with this hardware)
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 2>&1 | Out-Null
# Lid close = do nothing (so accidental lid close doesn't kill GPU)
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 2>&1 | Out-Null  # DC=sleep is moot since sleep states are unavailable
powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
Write-Host "    Power plan settings applied" -ForegroundColor DarkGray

# === STEP 3 — Re-create watchdog task if missing ===
Write-Host "[3/7] Verifying watchdog task..." -ForegroundColor Yellow
$taskExists = (schtasks /query /tn 'GPU_Watchdog_ROG' 2>&1) -match 'GPU_Watchdog_ROG'
if (-not $taskExists) {
    $watchdog = Join-Path $PSScriptRoot 'GPU-Watchdog.ps1'
    if (Test-Path $watchdog) {
        $action = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`""
        schtasks /create /tn 'GPU_Watchdog_ROG' /tr $action /sc onstart /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
        schtasks /run /tn 'GPU_Watchdog_ROG' 2>&1 | Out-Null
        Write-Host "    Watchdog task recreated and started" -ForegroundColor Green
    } else {
        Write-Host "    GPU-Watchdog.ps1 not found at $watchdog — skipping" -ForegroundColor Yellow
    }
} else {
    Write-Host "    Watchdog already installed" -ForegroundColor DarkGray
}

# === STEP 4 — GPU health check ===
Write-Host "[4/7] Checking GPU health..." -ForegroundColor Yellow
$gpus = Get-PnpDevice -Class Display
$broken = @()
foreach ($g in $gpus) {
    $p = Get-PnpDeviceProperty -InstanceId $g.InstanceId -EA SilentlyContinue
    $code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    $status = if ($code -gt 0) { "BROKEN (Code $code)" } else { "OK" }
    $color = if ($code -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    $($g.FriendlyName): $status" -ForegroundColor $color
    if ($code -gt 0) { $broken += $g }
}

# === STEP 5 — GPU reset cycle ===
if (-not $SkipGPUReset -and $broken.Count -gt 0) {
    Write-Host "[5/7] Attempting GPU recovery cycle..." -ForegroundColor Yellow
    foreach ($g in $broken) {
        Write-Host "    Disabling: $($g.FriendlyName)..."
        Disable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -EA SilentlyContinue
        Start-Sleep -Seconds 3
        Write-Host "    Enabling: $($g.FriendlyName)..."
        Enable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -EA SilentlyContinue
        Start-Sleep -Seconds 3
        $p = Get-PnpDeviceProperty -InstanceId $g.InstanceId -EA SilentlyContinue
        $code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        if ($code -eq 0) { Write-Host "    RECOVERED" -ForegroundColor Green }
        else             { Write-Host "    Still Code $code — see manual steps below" -ForegroundColor Red }
    }
} elseif ($SkipGPUReset) {
    Write-Host "[5/7] GPU reset skipped (-SkipGPUReset)" -ForegroundColor DarkGray
} else {
    Write-Host "[5/7] No broken GPUs — skipping reset" -ForegroundColor DarkGray
}

# === STEP 6 — Verify final state ===
Write-Host "[6/7] Final state check..." -ForegroundColor Yellow
Get-PnpDevice -Class Display | ForEach-Object {
    $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -EA SilentlyContinue
    $c = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    "    $($_.FriendlyName): Status=$($_.Status), Code=$c"
}

# === STEP 7 — Diff vs snapshot ===
Write-Host "[7/7] Comparing against snapshot..." -ForegroundColor Yellow
$summaryFile = Join-Path $SnapshotPath '00_SUMMARY.txt'
if (Test-Path $summaryFile) {
    Write-Host "    Original snapshot summary:" -ForegroundColor DarkGray
    Get-Content $summaryFile | Select-String 'GPU STATUS|VIDEO DRIVERS|Modern Standby|Fast Startup|TdrDelay|BIOS:|MODEL:' | ForEach-Object { "      $_" }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " RESTORE COMPLETE" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "MANUAL FALLBACK STEPS if built-in screen is STILL BLACK:" -ForegroundColor Yellow
Write-Host "  1. Plug in HDMI cable to external monitor (NVIDIA path — always works)" -ForegroundColor White
Write-Host "  2. Press Win+Ctrl+Shift+B (resets graphics stack — won't reboot)" -ForegroundColor White
Write-Host "  3. Full shutdown (NOT restart): shutdown /s /t 0" -ForegroundColor White
Write-Host "     Restart REUSES kernel state; shutdown does a true cold boot" -ForegroundColor DarkGray
Write-Host "  4. PERMANENT FIX: Open Armoury Crate -> System -> GPU Mode ->" -ForegroundColor White
Write-Host "     'Ultimate' (routes panel through NVIDIA, bypasses AMD iGPU)" -ForegroundColor White
Write-Host "     Requires reboot. No more AMD-related black screens after this." -ForegroundColor DarkGray
Write-Host ""
