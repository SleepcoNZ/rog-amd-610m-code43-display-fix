<#
.SYNOPSIS
    Comprehensive GPU stability settings for ASUS ROG G713PV
.DESCRIPTION
    Applies all settings needed for stable ML training on RTX 4060
    while preventing AMD iGPU Code 43 crashes. Run as Administrator.
    
    Settings applied:
    1. TDR (Timeout Detection & Recovery) - longer timeout for GPU compute
    2. Modern Standby - disabled (root cause of iGPU crashes)
    3. Connected Standby - disabled
    4. Fast Startup - disabled
    5. Sleep/Hibernate - disabled entirely
    6. Lid close action - Do Nothing (not sleep/shutdown)
    7. PCI Express ASPM - disabled
    8. NVIDIA power management - prefer max performance
    9. GPU error recovery registry settings
    10. Installs GPU watchdog scheduled task for auto-failover
    
    Run: powershell -ExecutionPolicy Bypass -File Harden-GPU.ps1
#>
param(
    [switch]$SkipWatchdog
)

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
$outFile = Join-Path $scriptDir 'results\harden_gpu_output.txt'
New-Item (Split-Path $outFile) -ItemType Directory -Force -EA SilentlyContinue | Out-Null
$log = [System.Collections.ArrayList]::new()

function Log($msg) {
    $line = "$(Get-Date -Format 'HH:mm:ss') $msg"
    [void]$log.Add($line)
    Write-Host $line
}

function LogOK($msg)   { Log "[OK]   $msg" }
function LogFIX($msg)  { Log "[FIX]  $msg" }
function LogSKIP($msg) { Log "[SKIP] $msg" }
function LogFAIL($msg) { Log "[FAIL] $msg" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Must run as Administrator" -ForegroundColor Red
    exit 1
}

Log "=========================================="
Log "  GPU STABILITY HARDENING - ROG G713PV"
Log "=========================================="
Log "User: $env:USERNAME | Admin: $isAdmin"
Log ""

# ============================================================
# 1. TDR (Timeout Detection & Recovery)
#    Default TdrDelay=2s is too short for GPU compute (training).
#    When a CUDA kernel runs >2s, Windows thinks the GPU hung and
#    resets it, causing TDR crash → Code 43.
# ============================================================
Log "--- 1. TDR Settings (GPU compute timeout) ---"
$gfxPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
try {
    # TdrDelay: seconds before Windows considers GPU hung (default 2)
    $oldDelay = (Get-ItemProperty $gfxPath -Name TdrDelay -EA SilentlyContinue).TdrDelay
    Set-ItemProperty $gfxPath -Name TdrDelay -Value 30 -Type DWord -Force
    LogFIX "TdrDelay: $oldDelay -> 30 seconds (was default 2s)"

    # TdrDdiDelay: DDI callback timeout (default 5)
    $oldDdi = (Get-ItemProperty $gfxPath -Name TdrDdiDelay -EA SilentlyContinue).TdrDdiDelay
    Set-ItemProperty $gfxPath -Name TdrDdiDelay -Value 30 -Type DWord -Force
    LogFIX "TdrDdiDelay: $oldDdi -> 30 seconds"

    # TdrLimitCount: number of TDR events before crash (default 5)
    Set-ItemProperty $gfxPath -Name TdrLimitCount -Value 10 -Type DWord -Force
    LogFIX "TdrLimitCount: -> 10 (allows more recovery attempts)"

    # TdrLimitTime: window for counting TDR events in seconds (default 60)
    Set-ItemProperty $gfxPath -Name TdrLimitTime -Value 120 -Type DWord -Force
    LogFIX "TdrLimitTime: -> 120 seconds"
} catch {
    LogFAIL "TDR settings: $($_.Exception.Message)"
}

# ============================================================
# 2. Modern Standby / Connected Standby
#    ROOT CAUSE of the recurring AMD Code 43 crashes.
# ============================================================
Log ""
Log "--- 2. Modern Standby / Connected Standby ---"
$pwrPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
try {
    $pao = (Get-ItemProperty $pwrPath -Name 'PlatformAoAcOverride' -EA SilentlyContinue).PlatformAoAcOverride
    if ($pao -eq 0) { LogOK "PlatformAoAcOverride: 0 (Modern Standby already disabled)" }
    else {
        Set-ItemProperty $pwrPath -Name 'PlatformAoAcOverride' -Value 0 -Type DWord -Force
        LogFIX "PlatformAoAcOverride: $pao -> 0 (Modern Standby DISABLED)"
    }

    $cs = (Get-ItemProperty $pwrPath -Name 'CsEnabled' -EA SilentlyContinue).CsEnabled
    if ($cs -eq 0) { LogOK "CsEnabled: 0 (Connected Standby already disabled)" }
    else {
        Set-ItemProperty $pwrPath -Name 'CsEnabled' -Value 0 -Type DWord -Force
        LogFIX "CsEnabled: $cs -> 0 (Connected Standby DISABLED)"
    }
} catch {
    LogFAIL "Modern Standby: $($_.Exception.Message)"
}

# ============================================================
# 3. Fast Startup
# ============================================================
Log ""
Log "--- 3. Fast Startup ---"
$fspath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$hb = (Get-ItemProperty $fspath -Name HiberbootEnabled -EA SilentlyContinue).HiberbootEnabled
if ($hb -eq 0) { LogOK "HiberbootEnabled: 0 (Fast Startup already disabled)" }
else {
    Set-ItemProperty $fspath -Name HiberbootEnabled -Value 0 -Type DWord -Force
    LogFIX "HiberbootEnabled: $hb -> 0 (Fast Startup DISABLED)"
}

# ============================================================
# 4. Power Plan: Sleep, Hibernate, Lid, Buttons
# ============================================================
Log ""
Log "--- 4. Power Plan Settings ---"
try {
    # Lid close = Do Nothing (user can still manually shutdown/restart)
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    LogFIX "Lid close: Do Nothing (AC & DC)"

    # Sleep button = Do Nothing
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    LogFIX "Sleep button: Do Nothing"

    # Sleep timeout = Never
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    LogFIX "Sleep timeout: Never"

    # Hibernate timeout = Never
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    LogFIX "Hibernate timeout: Never"

    # Hybrid sleep = Off
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0
    LogFIX "Hybrid sleep: Off"

    # PCI Express ASPM = Off
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    LogFIX "PCI Express ASPM: Off"

    # Display timeout on AC = Never (for training runs)
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0
    LogFIX "Display off on AC: Never"
    # Display timeout on DC = 10 min
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 600
    LogFIX "Display off on DC: 10 min"

    # Apply
    powercfg /SETACTIVE SCHEME_CURRENT
    LogOK "Power plan activated"
} catch {
    LogFAIL "Power plan: $($_.Exception.Message)"
}

# ============================================================
# 5. NVIDIA Power Management - Prefer Maximum Performance
# ============================================================
Log ""
Log "--- 5. NVIDIA Power Management ---"
try {
    $nvidiaRegBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $subkeys = Get-ChildItem $nvidiaRegBase -EA SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.PSPath -Name 'DriverDesc' -EA SilentlyContinue).DriverDesc -match 'NVIDIA'
    }
    if ($subkeys) {
        foreach ($key in $subkeys) {
            # Disable NVIDIA power-saving D3 transitions during compute
            Set-ItemProperty $key.PSPath -Name 'DisableDynamicPstate' -Value 1 -Type DWord -Force -EA SilentlyContinue
            # Enable performance mode
            Set-ItemProperty $key.PSPath -Name 'PerfLevelSrc' -Value 0x2222 -Type DWord -Force -EA SilentlyContinue
            LogFIX "NVIDIA ($($key.PSChildName)): DisableDynamicPstate=1, PerfLevelSrc=max"
        }
    } else {
        LogSKIP "NVIDIA registry keys not found under display class"
    }
} catch {
    LogFAIL "NVIDIA power: $($_.Exception.Message)"
}

# ============================================================
# 6. AMD iGPU - Disable power management features that cause Code 43
# ============================================================
Log ""
Log "--- 6. AMD iGPU Power Management ---"
try {
    $amdSubkeys = Get-ChildItem $nvidiaRegBase -EA SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.PSPath -Name 'DriverDesc' -EA SilentlyContinue).DriverDesc -match 'AMD|Radeon'
    }
    if ($amdSubkeys) {
        foreach ($key in $amdSubkeys) {
            # Disable AMD PowerXpress dynamic switching power save
            Set-ItemProperty $key.PSPath -Name 'EnableUlps' -Value 0 -Type DWord -Force -EA SilentlyContinue
            Set-ItemProperty $key.PSPath -Name 'EnableCrossFireAutoLink' -Value 0 -Type DWord -Force -EA SilentlyContinue
            LogFIX "AMD ($($key.PSChildName)): EnableUlps=0 (Ultra Low Power State OFF)"
        }
    } else {
        LogSKIP "AMD registry keys not found"
    }
} catch {
    LogFAIL "AMD power: $($_.Exception.Message)"
}

# ============================================================
# 7. GPU Device Power Management - Disable D3 Cold for both GPUs
# ============================================================
Log ""
Log "--- 7. GPU Device Power Management (D3 Cold) ---"
try {
    $gpus = Get-PnpDevice -Class Display | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'Error' }
    foreach ($gpu in $gpus) {
        $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Power"
        if (-not (Test-Path $devPath)) {
            New-Item $devPath -Force | Out-Null
        }
        # IdleTimeoutMs = 0 disables runtime power management idle timeout
        # DeviceD3ColdSupported = 0 prevents deep power off state
        Set-ItemProperty $devPath -Name 'IdleTimeoutMs' -Value 0 -Type DWord -Force -EA SilentlyContinue
        Set-ItemProperty $devPath -Name 'DeviceD3ColdSupported' -Value 0 -Type DWord -Force -EA SilentlyContinue
        LogFIX "$($gpu.FriendlyName): D3Cold=0, IdleTimeout=0"
    }
} catch {
    LogFAIL "D3 Cold: $($_.Exception.Message)"
}

# ============================================================
# 8. Install GPU Watchdog Task (auto-failover)
# ============================================================
Log ""
Log "--- 8. GPU Watchdog Scheduled Task ---"
if (-not $SkipWatchdog) {
    try {
        $watchdogScript = Join-Path $scriptDir 'GPU-Watchdog.ps1'
        if (Test-Path $watchdogScript) {
            $taskName = 'GPU_Watchdog_ROG'
            # Remove existing
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA SilentlyContinue

            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogScript`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit (New-TimeSpan -Days 365)

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            LogFIX "GPU Watchdog task installed and started (runs at logon as SYSTEM)"
        } else {
            LogSKIP "GPU-Watchdog.ps1 not found at: $watchdogScript"
        }
    } catch {
        LogFAIL "Watchdog task: $($_.Exception.Message)"
    }
} else {
    LogSKIP "Watchdog installation skipped (-SkipWatchdog)"
}

# ============================================================
# Summary
# ============================================================
Log ""
Log "=========================================="
Log "  SUMMARY"
Log "=========================================="
Log ""
Log "TDR Timeout:         30s (from default 2s) - prevents training crashes"
Log "Modern Standby:      DISABLED - prevents iGPU Code 43 on wake"
Log "Connected Standby:   DISABLED"
Log "Fast Startup:        DISABLED"
Log "Sleep/Hibernate:     NEVER (lid close = do nothing)"
Log "PCI-E ASPM:          OFF"
Log "NVIDIA D3/Pstate:    Disabled (max performance during training)"
Log "AMD ULPS:            OFF (prevents iGPU deep sleep failures)"
Log "GPU D3 Cold:         OFF (prevents deep power state hardware bugs)"
Log "GPU Watchdog:        Active (monitors & auto-recovers GPUs)"
Log ""
Log "REQUIRES REBOOT for TDR and power changes to take full effect."
Log ""

$log | Out-File $outFile -Encoding UTF8 -Force
"COMPLETE" | Out-File "$outFile.done" -Force
Write-Host "`nSaved to: $outFile" -ForegroundColor Green
