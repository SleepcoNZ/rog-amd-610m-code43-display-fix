<#
.SYNOPSIS
    Restores Modern Standby + Hibernate + sleep on lid close, and provides
    proper fix path. Run as Administrator.
.DESCRIPTION
    Reverses our earlier overrides so the OS uses the firmware's actual sleep
    capability (Modern Standby S0ix on this Ryzen 7000 laptop). Re-enables
    hibernate as fallback. Restores lid/button defaults.
    
    The REAL fix for the AMD iGPU crash on resume is one of:
      A) Switch GPU MUX to "Ultimate" / dGPU-only mode (bypass iGPU)
      B) Update BIOS (current G713PV.336)
      C) Update AMD chipset drivers (GPIO, SMBus, PSP)
    These are listed at the end of the output.
#>

$outFile = "$PSScriptRoot\results\restore_sleep_output.txt"
$log = [System.Collections.ArrayList]::new()
function L($m) { $line = "$(Get-Date -Format 'HH:mm:ss') $m"; [void]$log.Add($line); Write-Host $line }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "ERROR: Run as Administrator" -ForegroundColor Red; exit 1 }

L "=========================================="
L "  RESTORE SLEEP / MODERN STANDBY"
L "=========================================="
L ""

# 1. Remove the Modern Standby overrides we set
L "--- 1. Restoring Modern Standby (S0 Low Power Idle) ---"
$pwrPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
try {
    # Removing forces firmware default. Setting to 1 explicitly enables.
    Remove-ItemProperty $pwrPath -Name 'PlatformAoAcOverride' -EA SilentlyContinue
    L "[OK] Removed PlatformAoAcOverride override (firmware default restored)"

    # CsEnabled = 1 to re-enable Connected Standby
    Set-ItemProperty $pwrPath -Name 'CsEnabled' -Value 1 -Type DWord -Force
    L "[OK] CsEnabled: -> 1 (Connected Standby enabled)"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 2. Re-enable hibernation
L ""
L "--- 2. Re-enabling Hibernation ---"
try {
    & powercfg /hibernate on
    L "[OK] Hibernation re-enabled"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 3. Restore power button / lid / sleep button to sensible defaults
L ""
L "--- 3. Restoring Button & Lid Defaults ---"
try {
    # Start menu power button: 0=Sleep
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS UIBUTTON_ACTION 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS UIBUTTON_ACTION 0
    L "[OK] Start menu power button: Sleep"

    # Physical power button: 1=Sleep (was 3=Shutdown)
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 1
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 1
    L "[OK] Physical power button: Sleep"

    # Lid close: 1=Sleep
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 1
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 1
    L "[OK] Lid close: Sleep"

    # Sleep button (Fn): 1=Sleep
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 1
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 1
    L "[OK] Fn sleep button: Sleep"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 4. Restore reasonable idle timeouts (sleep after 30 min on AC, 15 min on DC)
L ""
L "--- 4. Restoring Idle Sleep Timeouts ---"
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 1800   # 30 min AC
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 900    # 15 min DC
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0    # no auto-hibernate
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    L "[OK] Sleep idle: 30 min (AC) / 15 min (DC)"
    L "[OK] Auto-hibernate: Never"
} catch { L "[FAIL] $($_.Exception.Message)" }

# 5. PCI Express ASPM — keep OFF for stability with the buggy iGPU
L ""
L "--- 5. PCI-E ASPM kept OFF (stability with iGPU) ---"

# 6. Activate scheme
try { powercfg /SETACTIVE SCHEME_CURRENT; L "[OK] Power scheme activated" } catch {}

# 7. Try GPU recovery
L ""
L "--- 6. AMD iGPU Recovery Attempt ---"
$amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon' }
if ($amd -and $amd.Status -ne 'OK') {
    L "AMD: Status=$($amd.Status) - toggling..."
    Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA SilentlyContinue
    Start-Sleep 5
    Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA SilentlyContinue
    Start-Sleep 8
    $after = Get-PnpDevice -InstanceId $amd.InstanceId
    L "After toggle: $($after.Status)"
    if ($after.Status -ne 'OK') {
        L "[INFO] iGPU still Code 43 — needs a FULL SHUTDOWN (shutdown /s /t 0) then power on."
    }
} elseif ($amd) { L "AMD iGPU is OK" }

# 8. Verify sleep states now available
L ""
L "--- 7. Sleep States After Restore ---"
$states = (powercfg /a) -join "`n"
foreach ($line in ($states -split "`n")) { if ($line.Trim()) { L "  $line" } }

L ""
L "=========================================="
L "  REAL FIX PATH (must be done outside this script)"
L "=========================================="
L ""
L "OPTION A (RECOMMENDED) - Switch to dGPU-only via MUX switch:"
L "  This bypasses the broken AMD iGPU entirely. The display is wired"
L "  directly to the NVIDIA RTX 4060. iGPU resume bug becomes irrelevant."
L "  HOW: Open Armoury Crate -> System Configuration / GPU Mode ->"
L "       Select 'Ultimate' (also called 'Discrete GPU' or 'dGPU only')"
L "       -> Reboot when prompted."
L "  TRADE-OFF: ~10-15% more battery drain (RTX always on)."
L "             Reverting to MSHybrid is one click + reboot."
L ""
L "OPTION B - Update BIOS:"
L "  Current: G713PV.336 (October 2025)"
L "  Check for newer at: https://www.asus.com/supportonly/rog-strix-g17-g713pv/helpdesk_bios/"
L "  Newer BIOS may include AMD AGESA updates that fix the iGPU resume bug."
L ""
L "OPTION C - Update AMD chipset drivers:"
L "  Current AMD GPIO: 2.2.0.136 (Oct 2025)"
L "  Current AMD SMBus: 5.12.0.44 (Sep 2025)"
L "  Current AMD PSP:   5.43.0.0 (Feb 2026)"
L "  Download AMD Chipset Driver from:"
L "  https://www.amd.com/en/support/chipsets/amd-socket-am5/x670"
L "  (or use ASUS download page for matching package)"
L ""
L "Apply Option A for an immediate, bulletproof fix."
L "Options B + C are good hygiene but may not fix the root iGPU bug."

$log | Out-File $outFile -Encoding UTF8 -Force
"COMPLETE" | Out-File "$outFile.done" -Force
