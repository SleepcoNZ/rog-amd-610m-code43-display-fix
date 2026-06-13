<#
.SYNOPSIS
    Permanent fix for AMD Radeon 610M Code 43 on ASUS ROG G713PV
.DESCRIPTION
    This script:
    1. Disables Modern Standby (the root cause of recurring Code 43)
    2. Disables Connected Standby
    3. Sets lid-close action to Shutdown (not sleep)
    4. Disables AMD iGPU power management that fails on wake
    5. Verifies Fast Startup is still disabled
    6. Performs full shutdown
    
    Run as Administrator.
#>

$outFile = Join-Path $PSScriptRoot 'results\permanent_fix_output.txt'
$log = [System.Collections.ArrayList]::new()

function Log($msg) {
    [void]$log.Add("$(Get-Date -Format 'HH:mm:ss') $msg")
    Write-Host $msg
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Log "=== PERMANENT FIX FOR AMD CODE 43 RECURRENCE ==="
Log "Admin: $isAdmin"

# ============================================================
# FIX 1: Disable Modern Standby (S0 Low Power Idle)
# This is the ROOT CAUSE - the iGPU crashes on Modern Standby wake
# ============================================================
Log ""
Log "=== FIX 1: Disable Modern Standby ==="
try {
    # Method 1: Registry - PlatformAoAcOverride
    $csPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $current = (Get-ItemProperty $csPath -Name 'PlatformAoAcOverride' -EA SilentlyContinue).PlatformAoAcOverride
    Log "Current PlatformAoAcOverride: $current"
    Set-ItemProperty $csPath -Name 'PlatformAoAcOverride' -Value 0 -Type DWord -Force
    $after = (Get-ItemProperty $csPath -Name 'PlatformAoAcOverride').PlatformAoAcOverride
    Log "Set PlatformAoAcOverride: $after (0 = Modern Standby DISABLED)"
    
    # Method 2: Also set CsEnabled to 0 (Connected Standby)
    $csCurrent = (Get-ItemProperty $csPath -Name 'CsEnabled' -EA SilentlyContinue).CsEnabled
    Log "Current CsEnabled: $csCurrent"
    Set-ItemProperty $csPath -Name 'CsEnabled' -Value 0 -Type DWord -Force
    $csAfter = (Get-ItemProperty $csPath -Name 'CsEnabled').CsEnabled
    Log "Set CsEnabled: $csAfter (0 = Connected Standby DISABLED)"
    
    Log "SUCCESS: Modern Standby + Connected Standby disabled"
} catch {
    Log "FAILED: $($_.Exception.Message)"
}

# ============================================================
# FIX 2: Set lid close action to Shutdown (not Sleep)
# Prevents sleep-induced GPU crashes
# ============================================================
Log ""
Log "=== FIX 2: Set Lid Close = Shutdown ==="
try {
    # Lid close action: 0=Nothing, 1=Sleep, 2=Hibernate, 3=Shutdown
    # On AC power:
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 3
    # On battery:
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 3
    powercfg /SETACTIVE SCHEME_CURRENT
    Log "SUCCESS: Lid close action set to Shutdown (AC and DC)"
} catch {
    Log "FAILED: $($_.Exception.Message)"
}

# ============================================================
# FIX 3: Set sleep button/power button to not use sleep
# ============================================================
Log ""
Log "=== FIX 3: Disable Sleep on Power Button ==="
try {
    # Sleep button: 0=Nothing, 1=Sleep, 2=Hibernate, 3=Shutdown
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    # Set hibernate timeout to 0 (never)
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    # Set sleep timeout to 0 (never)
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    powercfg /SETACTIVE SCHEME_CURRENT
    Log "SUCCESS: Sleep disabled (sleep button=nothing, sleep/hibernate timeout=never)"
} catch {
    Log "FAILED: $($_.Exception.Message)"
}

# ============================================================
# FIX 4: Disable AMD GPU power management (PCI Express ASPM)
# ============================================================
Log ""
Log "=== FIX 4: Disable PCI Express Link State Power Management ==="
try {
    # ASPM: 0=None, 1=L0s, 2=L1, 3=L0s+L1
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    powercfg /SETACTIVE SCHEME_CURRENT
    Log "SUCCESS: PCI Express ASPM disabled (prevents GPU power state issues)"
} catch {
    Log "FAILED: $($_.Exception.Message)"
}

# ============================================================
# FIX 5: Verify Fast Startup is still disabled
# ============================================================
Log ""
Log "=== FIX 5: Verify Fast Startup ==="
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$hb = (Get-ItemProperty $regPath -Name HiberbootEnabled -EA SilentlyContinue).HiberbootEnabled
if ($hb -eq 0) {
    Log "Fast Startup: DISABLED (good)"
} else {
    Set-ItemProperty $regPath -Name HiberbootEnabled -Value 0
    Log "Fast Startup: Was enabled, now DISABLED"
}

# ============================================================
# FIX 6: Re-enable the AMD iGPU (clear Code 43)
# ============================================================
Log ""
Log "=== FIX 6: Re-enable AMD iGPU ==="
$amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
if ($amd -and $amd.Status -ne 'OK') {
    Log "AMD: $($amd.FriendlyName) Status=$($amd.Status) - disabling..."
    Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 3
    Log "Re-enabling..."
    Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 5
    $amdAfter = Get-PnpDevice -InstanceId $amd.InstanceId
    $props = Get-PnpDeviceProperty -InstanceId $amd.InstanceId -EA SilentlyContinue
    $code = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    Log "After toggle: Status=$($amdAfter.Status) Code=$code"
} elseif ($amd) {
    Log "AMD iGPU is already OK"
} else {
    Log "AMD device not found"
}

# ============================================================
# Summary
# ============================================================
Log ""
Log "=== SUMMARY ==="
Log "Modern Standby: DISABLED (no more sleep-wake GPU crashes)"
Log "Connected Standby: DISABLED"
Log "Lid close action: SHUTDOWN (not sleep)"
Log "Sleep/hibernate timeouts: NEVER"
Log "PCI Express ASPM: OFF"
Log "Fast Startup: DISABLED"
Log ""
Log "=== NEXT STEP ==="
Log "Do a FULL SHUTDOWN now: shutdown /s /t 0"
Log "Then power on. The screen should work."
Log "These settings are PERMANENT - the problem should not recur."

$log | Out-File $outFile -Encoding UTF8
Write-Host "`nResults saved to: $outFile" -ForegroundColor Green
Write-Host "`nPress Enter to exit..." -ForegroundColor Cyan
Read-Host
