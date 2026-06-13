<#
.SYNOPSIS
    Disables hibernation entirely - the ONLY sleep state this hardware supports
    is Hibernate, and it crashes the AMD iGPU on wake.
.DESCRIPTION
    Root cause analysis (May 2026):
    - Modern Standby (S0) disabled by previous fix
    - S1/S2/S3 not supported by firmware
    - Only hibernate was left → user kept hitting it manually
    - AMD Radeon 610M driver (even updated to March 2026 v32.0.21043.5001)
      cannot survive hibernate -> wake transition
    
    Fix: Disable hibernation, set ALL sleep-like buttons to Shut down.
    Trade-off: User must use full shutdown each time (no resume work).
    
    Run as Administrator.
#>

$outFile = "$PSScriptRoot\results\disable_hibernate_output.txt"
$log = [System.Collections.ArrayList]::new()
function L($m) { $line = "$(Get-Date -Format 'HH:mm:ss') $m"; [void]$log.Add($line); Write-Host $line }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "ERROR: Run as Administrator" -ForegroundColor Red; exit 1 }

L "=========================================="
L "  DISABLE HIBERNATE - PREVENT GPU CRASH"
L "=========================================="

# 1. Disable hibernation entirely
L ""
L "--- 1. Disable Hibernation ---"
try {
    & powercfg /hibernate off
    L "[OK] powercfg /hibernate off executed"
    Start-Sleep 1
    $hib = (powercfg /a) -join "`n"
    if ($hib -match 'Hibernation has not been enabled' -or $hib -notmatch 'Hibernate$') {
        L "[OK] Hibernate now disabled"
    }
    L ""
    L "Current sleep state availability:"
    powercfg /a 2>&1 | ForEach-Object { L "  $_" }
} catch { L "[FAIL] $($_.Exception.Message)" }

# 2. Force Start menu power button to Shut down (was Sleep)
L ""
L "--- 2. Set Start Menu Power Button = Shut down ---"
try {
    # UIBUTTON_ACTION: 0=Sleep, 1=Hibernate, 2=Shut down
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS UIBUTTON_ACTION 2
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS UIBUTTON_ACTION 2
    L "[OK] Start menu power button: 0(Sleep) -> 2(Shut down) for AC and DC"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 3. Lid close = Do Nothing (user can manually shutdown)
L ""
L "--- 3. Lid Close Action ---"
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    L "[OK] Lid close: Do Nothing (AC and DC)"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 4. Power button = Shut down
L ""
L "--- 4. Physical Power Button ---"
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
    L "[OK] Physical power button: Shut down (AC and DC)"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 5. Sleep button (Fn+F1 etc.) = Do Nothing
L ""
L "--- 5. Sleep Button (Fn key) ---"
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    L "[OK] Fn sleep button: Do Nothing (AC and DC)"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 6. Sleep/Hibernate idle timeouts = Never
L ""
L "--- 6. Auto-Sleep Timeouts ---"
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    L "[OK] Sleep timeout: Never | Hibernate timeout: Never"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 7. Activate the scheme
try { powercfg /SETACTIVE SCHEME_CURRENT; L "[OK] Power scheme activated" } catch {}

# 8. Try to recover the AMD iGPU via disable/enable
L ""
L "--- 7. Recover AMD iGPU (Code 43) ---"
$amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon' }
if ($amd -and $amd.Status -ne 'OK') {
    L "AMD: $($amd.FriendlyName) Status=$($amd.Status) - toggling..."
    Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA SilentlyContinue
    Start-Sleep 5
    Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA SilentlyContinue
    Start-Sleep 8
    $after = Get-PnpDevice -InstanceId $amd.InstanceId
    L "After toggle: Status=$($after.Status)"
    if ($after.Status -ne 'OK') {
        L "[INFO] iGPU still broken - requires FULL SHUTDOWN (not restart) to clear."
        L "[INFO] Run: shutdown /s /t 0  then power on."
    }
} elseif ($amd) { L "AMD iGPU already OK" }

L ""
L "=========================================="
L "  SUMMARY"
L "=========================================="
L "Hibernation:           DISABLED (no longer triggerable)"
L "Start menu power btn:  Shut down"
L "Lid close:             Do Nothing"
L "Physical power button: Shut down"
L "Fn sleep button:       Do Nothing"
L "Sleep/Hibernate idle:  Never"
L ""
L "BEHAVIOR CHANGE: When you would have hit 'Sleep' or closed the lid,"
L "  the system will now stay ON or shut down. No more hibernate -> black screen."
L ""
L "If AMD iGPU still Code 43 - do FULL SHUTDOWN (shutdown /s /t 0) then power on."

$log | Out-File $outFile -Encoding UTF8 -Force
"COMPLETE" | Out-File "$outFile.done" -Force
