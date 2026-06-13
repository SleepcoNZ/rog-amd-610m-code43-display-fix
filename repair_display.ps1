# ============================================================================
# Phase 7: Automated Repair Actions
# Each repair is opt-in. Pass -RepairId to run a specific repair, or
# -RunAll to attempt all in order. Requires admin for most repairs.
# ============================================================================
param(
    [int]$RepairId = 0,
    [switch]$RunAll,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp = Get-Date -Format 'o'
    Phase     = 'Phase7_Repairs'
    Repairs   = @()
    Data      = @{}
}

$isAdmin = Test-IsAdmin

Write-DiagHeader "PHASE 7: Automated Display Repair Actions"

if (-not $isAdmin) {
    Write-Host @"

  WARNING: Most repairs require admin privileges.
  This script should be run elevated. The orchestrator handles this.
  Non-admin repairs will still be attempted where possible.

"@ -ForegroundColor Yellow
}

function Confirm-Repair {
    param([string]$Description, [string]$Risk)
    if ($NonInteractive) { return $true }
    Write-Host "`n  REPAIR: $Description" -ForegroundColor Cyan
    Write-Host "  RISK:   $Risk" -ForegroundColor Yellow
    $response = Read-Host "  Proceed? (Y/N)"
    return $response -match '^[Yy]'
}

function Log-Repair {
    param([int]$Id, [string]$Name, [string]$Status, [string]$Detail)
    $entry = @{ Id = $Id; Name = $Name; Status = $Status; Detail = $Detail; Time = (Get-Date -Format 'o') }
    $results.Repairs += $entry
    $color = switch ($Status) { 'SUCCESS' { 'Green' } 'FAILED' { 'Red' } 'SKIPPED' { 'DarkGray' } default { 'Yellow' } }
    Write-Host "  [$Status] Repair $Id - $Name : $Detail" -ForegroundColor $color
}

# ============================================================================
# REPAIR 1: Re-enable AMD iGPU
# ============================================================================
function Repair-1-ReenableAMD {
    Write-DiagSection "Repair 1: Re-enable AMD Radeon 610M iGPU"

    if (-not (Confirm-Repair "Disable then re-enable the AMD Radeon 610M (Code 43 device)" "LOW - standard device manager operation")) {
        Log-Repair 1 "Re-enable AMD iGPU" "SKIPPED" "User declined"
        return
    }

    $amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
    if (-not $amd) {
        Log-Repair 1 "Re-enable AMD iGPU" "FAILED" "AMD device not found"
        return
    }

    try {
        Write-Host "  Disabling $($amd.FriendlyName)..." -ForegroundColor DarkGray
        Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3

        Write-Host "  Re-enabling $($amd.FriendlyName)..." -ForegroundColor DarkGray
        Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 5

        $amdAfter = Get-PnpDevice -InstanceId $amd.InstanceId
        $props = Get-PnpDeviceProperty -InstanceId $amd.InstanceId
        $newProblemCode = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data

        if ($amdAfter.Status -eq 'OK' -and $newProblemCode -eq 0) {
            Log-Repair 1 "Re-enable AMD iGPU" "SUCCESS" "Device now OK, Code 43 cleared!"
        } else {
            Log-Repair 1 "Re-enable AMD iGPU" "FAILED" "Device still has ProblemCode=$newProblemCode Status=$($amdAfter.Status)"
        }
    }
    catch {
        Log-Repair 1 "Re-enable AMD iGPU" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 2: Uninstall & Rescan AMD Driver
# ============================================================================
function Repair-2-ReinstallAMDDriver {
    Write-DiagSection "Repair 2: Remove AMD Driver & Rescan"

    if (-not (Confirm-Repair "Uninstall AMD display driver and let Windows re-detect/install" "MEDIUM - will temporarily lose AMD GPU. Windows should auto-reinstall.")) {
        Log-Repair 2 "Reinstall AMD Driver" "SKIPPED" "User declined"
        return
    }

    $amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
    if (-not $amd) {
        Log-Repair 2 "Reinstall AMD Driver" "FAILED" "AMD device not found"
        return
    }

    try {
        # Get the driver INF
        $props = Get-PnpDeviceProperty -InstanceId $amd.InstanceId
        $infPath = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data

        Write-Host "  Uninstalling device $($amd.InstanceId)..." -ForegroundColor DarkGray
        & pnputil /remove-device "$($amd.InstanceId)" 2>&1 | Write-Host

        Start-Sleep -Seconds 3

        Write-Host "  Scanning for hardware changes..." -ForegroundColor DarkGray
        & pnputil /scan-devices 2>&1 | Write-Host

        Start-Sleep -Seconds 10

        $amdAfter = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
        if ($amdAfter -and $amdAfter.Status -eq 'OK') {
            Log-Repair 2 "Reinstall AMD Driver" "SUCCESS" "AMD device reinstalled and working"
        } elseif ($amdAfter) {
            $newProps = Get-PnpDeviceProperty -InstanceId $amdAfter.InstanceId
            $pc = ($newProps | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
            Log-Repair 2 "Reinstall AMD Driver" "PARTIAL" "Device found but Status=$($amdAfter.Status) ProblemCode=$pc"
        } else {
            Log-Repair 2 "Reinstall AMD Driver" "FAILED" "AMD device not found after rescan"
        }
    }
    catch {
        Log-Repair 2 "Reinstall AMD Driver" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 3: Force MUX Switch to dGPU Mode
# ============================================================================
function Repair-3-ToggleMUX {
    Write-DiagSection "Repair 3: Toggle MUX Switch / GPU Mode"

    if (-not (Confirm-Repair "Attempt to toggle ASUS MUX switch between iGPU/dGPU/auto modes via registry and Armoury Crate" "MEDIUM - changes GPU routing. May require reboot to take effect.")) {
        Log-Repair 3 "Toggle MUX Switch" "SKIPPED" "User declined"
        return
    }

    try {
        # Try multiple approaches to toggle MUX

        # Approach 1: ASUS System Control Interface WMI
        Write-Host "  Attempting MUX toggle via ASUS WMI..." -ForegroundColor DarkGray
        $asusWmi = $null
        try {
            $asusWmi = Get-CimInstance -Namespace root\WMI -ClassName AsusAtkWmi_WMNB -ErrorAction Stop
        } catch {
            Write-Host "  ASUS WMI not available: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Approach 2: Registry-based GPU mode switch
        Write-Host "  Checking ASUS GPU Switch registry keys..." -ForegroundColor DarkGray
        $gpuMuxPaths = @(
            'HKLM:\SOFTWARE\ASUS\ASUS System Control Interface\GPUMux',
            'HKLM:\SOFTWARE\ASUS\Armoury Crate Service\GPUSwitch',
            'HKLM:\SOFTWARE\ASUS\GPUSwitch'
        )

        $muxFound = $false
        foreach ($path in $gpuMuxPaths) {
            if (Test-Path $path) {
                $current = Get-ItemProperty $path -ErrorAction SilentlyContinue
                Write-Host "  Found MUX registry at: $path" -ForegroundColor Green
                Write-Host "  Current values: $($current | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                $muxFound = $true

                # Try to read and toggle the GPU mode value
                $modeValue = $current.GPUMuxMode
                if ($null -eq $modeValue) { $modeValue = $current.Mode }
                if ($null -eq $modeValue) { $modeValue = $current.SwitchMode }

                if ($null -ne $modeValue) {
                    # Common values: 0 = dGPU/discrete, 1 = Optimus/hybrid, 2 = iGPU/eco
                    # We want to try discrete mode (0) to bypass the broken iGPU
                    $newMode = 0  # discrete/dGPU
                    Write-Host "  Current GPU mode: $modeValue -> Setting to $newMode (discrete/dGPU)" -ForegroundColor Yellow
                    Set-ItemProperty $path -Name 'GPUMuxMode' -Value $newMode -ErrorAction SilentlyContinue
                    Set-ItemProperty $path -Name 'Mode' -Value $newMode -ErrorAction SilentlyContinue
                }
                $results.Data.MUXRegistryBefore = $current
            }
        }

        # Approach 3: Try GPUSwitchDialog.exe from Armoury Crate
        $gpuSwitchExe = "C:\Program Files\ASUS\Armoury Crate Service\GPUSwitch\GPUSwitchDialog.exe"
        if (Test-Path $gpuSwitchExe) {
            Write-Host "  Found ASUS GPUSwitchDialog at: $gpuSwitchExe" -ForegroundColor Green
            $results.Data.GPUSwitchExePath = $gpuSwitchExe
        }

        # Approach 4: Try NVIDIA control panel to force dGPU as primary
        Write-Host "  Checking NVIDIA settings..." -ForegroundColor DarkGray
        $nvRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        if (Test-Path $nvRegPath) {
            $subkeys = Get-ChildItem $nvRegPath -ErrorAction SilentlyContinue
            foreach ($sk in $subkeys) {
                $vals = Get-ItemProperty $sk.PSPath -ErrorAction SilentlyContinue
                if ($vals.DriverDesc -match 'NVIDIA') {
                    Write-Host "  NVIDIA GPU found at registry: $($sk.PSPath)" -ForegroundColor DarkGray
                    # Check/set EnableMsHybrid
                    if ($null -ne $vals.EnableMsHybrid) {
                        Write-Host "  EnableMsHybrid = $($vals.EnableMsHybrid)" -ForegroundColor DarkGray
                    }
                }
            }
        }

        if ($muxFound) {
            Log-Repair 3 "Toggle MUX Switch" "ATTEMPTED" "Registry keys modified. REBOOT REQUIRED for MUX change to take effect."
        } else {
            Log-Repair 3 "Toggle MUX Switch" "PARTIAL" "MUX registry keys not found. Try Armoury Crate GUI or BIOS settings."
        }
    }
    catch {
        Log-Repair 3 "Toggle MUX Switch" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 4: Force Backlight On
# ============================================================================
function Repair-4-ForceBacklight {
    Write-DiagSection "Repair 4: Force Backlight / Brightness"

    if (-not (Confirm-Repair "Attempt to force the screen backlight on via WMI brightness controls and ASUS hotkey simulation" "LOW - only adjusts brightness values")) {
        Log-Repair 4 "Force Backlight" "SKIPPED" "User declined"
        return
    }

    try {
        # Attempt 1: WMI Brightness
        Write-Host "  Attempting WMI brightness set..." -ForegroundColor DarkGray
        try {
            $methods = Get-CimInstance -Namespace root\WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop
            Invoke-CimMethod -InputObject $methods -MethodName WmiSetBrightness -Arguments @{ Brightness = 100; Timeout = 0 } -ErrorAction Stop
            Write-Host "  WMI brightness set to 100%" -ForegroundColor Green
            Log-Repair 4 "Force Backlight" "SUCCESS" "WMI brightness set to 100%"
            return
        }
        catch {
            Write-Host "  WMI brightness method failed: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Attempt 2: PowerShell display brightness via registry
        Write-Host "  Attempting registry brightness override..." -ForegroundColor DarkGray
        $brightPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ScreenBrightness'
        if (Test-Path $brightPath) {
            Set-ItemProperty $brightPath -Name 'ScreenBrightness' -Value 100 -ErrorAction SilentlyContinue
        }

        # Attempt 3: Send brightness key via ASUS hotkey
        Write-Host "  Attempting ASUS keyboard brightness hotkey simulation..." -ForegroundColor DarkGray
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        # Brightness Up is typically VK_BRIGHTNESS_UP = 0xA9
        for ($i = 0; $i -lt 20; $i++) {
            [System.Windows.Forms.SendKeys]::SendWait('{F7}')  # Common ASUS brightness up
            Start-Sleep -Milliseconds 100
        }

        Log-Repair 4 "Force Backlight" "ATTEMPTED" "Tried WMI, registry, and hotkey methods. Check if screen shows anything."
    }
    catch {
        Log-Repair 4 "Force Backlight" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 5: SFC + DISM Repair
# ============================================================================
function Repair-5-SFCDism {
    Write-DiagSection "Repair 5: SFC + DISM System Repair"

    if (-not $isAdmin) {
        Log-Repair 5 "SFC + DISM" "SKIPPED" "Requires admin"
        return
    }

    if (-not (Confirm-Repair "Run DISM /RestoreHealth then SFC /scannow to repair corrupted system files" "LOW - standard Windows repair operation, but takes 10-20 minutes")) {
        Log-Repair 5 "SFC + DISM" "SKIPPED" "User declined"
        return
    }

    try {
        Write-Host "  Running DISM /RestoreHealth (may take 10+ minutes)..." -ForegroundColor Yellow
        $dismOutput = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
        $dismText = $dismOutput -join "`n"
        Write-Host ($dismOutput | Select-Object -Last 5) -ForegroundColor DarkGray

        Write-Host "  Running SFC /scannow..." -ForegroundColor Yellow
        $sfcOutput = & sfc /scannow 2>&1
        $sfcText = $sfcOutput -join "`n"
        Write-Host ($sfcOutput | Select-Object -Last 5) -ForegroundColor DarkGray

        $results.Data.DISMRepair = $dismText
        $results.Data.SFCRepair = $sfcText

        if ($sfcText -match 'successfully repaired' -or $dismText -match 'successfully') {
            Log-Repair 5 "SFC + DISM" "SUCCESS" "System files repaired"
        } elseif ($sfcText -match 'did not find any integrity violations') {
            Log-Repair 5 "SFC + DISM" "SUCCESS" "No corruption found - system files are clean"
        } else {
            Log-Repair 5 "SFC + DISM" "PARTIAL" "Completed but check output for details"
        }
    }
    catch {
        Log-Repair 5 "SFC + DISM" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 6: Driver Rollback via pnputil
# ============================================================================
function Repair-6-DriverRollback {
    Write-DiagSection "Repair 6: AMD Driver Rollback"

    if (-not $isAdmin) {
        Log-Repair 6 "Driver Rollback" "SKIPPED" "Requires admin"
        return
    }

    if (-not (Confirm-Repair "Attempt to roll back the AMD display driver to a previous version" "MEDIUM - will uninstall current and try previous driver")) {
        Log-Repair 6 "Driver Rollback" "SKIPPED" "User declined"
        return
    }

    try {
        # List AMD driver packages
        Write-Host "  Listing AMD driver packages..." -ForegroundColor DarkGray
        $drivers = pnputil /enum-drivers /class Display 2>&1
        Write-Host ($drivers -join "`n") -ForegroundColor DarkGray

        # Try rolling back via device manager method
        $amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
        if ($amd) {
            Write-Host "  Attempting driver rollback for $($amd.FriendlyName)..." -ForegroundColor DarkGray
            # Use devcon-like approach: remove current driver, scan for older
            $props = Get-PnpDeviceProperty -InstanceId $amd.InstanceId
            $infPath = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data

            if ($infPath) {
                Write-Host "  Current INF: $infPath" -ForegroundColor DarkGray
                # Delete current driver package
                & pnputil /delete-driver $infPath /force 2>&1 | Write-Host
                Start-Sleep -Seconds 3
                # Rescan
                & pnputil /scan-devices 2>&1 | Write-Host
                Start-Sleep -Seconds 10

                $amdAfter = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
                if ($amdAfter -and $amdAfter.Status -eq 'OK') {
                    Log-Repair 6 "Driver Rollback" "SUCCESS" "Older driver active, device OK"
                } else {
                    Log-Repair 6 "Driver Rollback" "PARTIAL" "Driver removed; device may need manual driver install"
                }
            } else {
                Log-Repair 6 "Driver Rollback" "FAILED" "Could not determine current INF path"
            }
        } else {
            Log-Repair 6 "Driver Rollback" "FAILED" "AMD device not found"
        }
    }
    catch {
        Log-Repair 6 "Driver Rollback" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 7: Power Cycle Both Display Adapters
# ============================================================================
function Repair-7-PowerCycleGPUs {
    Write-DiagSection "Repair 7: Power-Cycle All Display Adapters"

    if (-not (Confirm-Repair "Disable then re-enable ALL display adapters (AMD and NVIDIA) to force re-initialization" "MEDIUM - screen may flicker/go black temporarily via Splashtop")) {
        Log-Repair 7 "Power Cycle GPUs" "SKIPPED" "User declined"
        return
    }

    try {
        $gpus = Get-PnpDevice -Class Display | Where-Object { $_.Status -ne $null }

        foreach ($gpu in $gpus) {
            Write-Host "  Disabling $($gpu.FriendlyName)..." -ForegroundColor DarkGray
            Disable-PnpDevice -InstanceId $gpu.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }

        Write-Host "  Waiting 5 seconds..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5

        foreach ($gpu in $gpus) {
            Write-Host "  Enabling $($gpu.FriendlyName)..." -ForegroundColor DarkGray
            Enable-PnpDevice -InstanceId $gpu.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 10

        $gpusAfter = Get-PnpDevice -Class Display
        $allOk = $true
        foreach ($g in $gpusAfter) {
            $props = Get-PnpDeviceProperty -InstanceId $g.InstanceId -ErrorAction SilentlyContinue
            $pc = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
            Write-DiagResult $g.FriendlyName "Status=$($g.Status) ProblemCode=$pc" $(if ($g.Status -eq 'OK') { 'OK' } else { 'ERROR' })
            if ($g.Status -ne 'OK') { $allOk = $false }
        }

        if ($allOk) {
            Log-Repair 7 "Power Cycle GPUs" "SUCCESS" "All display adapters are now OK"
        } else {
            Log-Repair 7 "Power Cycle GPUs" "PARTIAL" "Some adapters still have issues after power cycle"
        }
    }
    catch {
        Log-Repair 7 "Power Cycle GPUs" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# REPAIR 8: Disable Fast Startup
# ============================================================================
function Repair-8-DisableFastStartup {
    Write-DiagSection "Repair 8: Disable Fast Startup"

    if (-not (Confirm-Repair "Disable Windows Fast Startup (hiberboot) which can prevent display hardware from reinitializing on boot" "LOW - only changes a power setting")) {
        Log-Repair 8 "Disable Fast Startup" "SKIPPED" "User declined"
        return
    }

    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        $current = (Get-ItemProperty $regPath -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
        Write-Host "  Current Fast Startup state: $current (1=enabled, 0=disabled)" -ForegroundColor DarkGray

        if ($current -eq 1) {
            Set-ItemProperty $regPath -Name HiberbootEnabled -Value 0
            $after = (Get-ItemProperty $regPath -Name HiberbootEnabled).HiberbootEnabled
            if ($after -eq 0) {
                Log-Repair 8 "Disable Fast Startup" "SUCCESS" "Fast Startup disabled. Next full shutdown + boot will reinitialize display hardware."
            } else {
                Log-Repair 8 "Disable Fast Startup" "FAILED" "Registry write did not take effect"
            }
        } else {
            Log-Repair 8 "Disable Fast Startup" "SKIPPED" "Fast Startup already disabled"
        }
    }
    catch {
        Log-Repair 8 "Disable Fast Startup" "FAILED" $_.Exception.Message
    }
}

# ============================================================================
# Run Selected or All Repairs
# ============================================================================

$repairFunctions = @{
    1 = { Repair-1-ReenableAMD }
    2 = { Repair-2-ReinstallAMDDriver }
    3 = { Repair-3-ToggleMUX }
    4 = { Repair-4-ForceBacklight }
    5 = { Repair-5-SFCDism }
    6 = { Repair-6-DriverRollback }
    7 = { Repair-7-PowerCycleGPUs }
    8 = { Repair-8-DisableFastStartup }
}

if ($RunAll) {
    Write-Host "`n  Running ALL repairs in order (least to most invasive)...`n" -ForegroundColor Yellow
    foreach ($id in 1..8) {
        & $repairFunctions[$id]
    }
} elseif ($RepairId -gt 0 -and $RepairId -le 8) {
    & $repairFunctions[$RepairId]
} else {
    Write-Host @"

  Available Repairs:
    1. Re-enable AMD iGPU (disable/enable cycle)
    2. Remove & rescan AMD driver
    3. Toggle MUX switch to dGPU mode
    4. Force backlight on
    5. SFC + DISM system file repair
    6. AMD driver rollback
    7. Power-cycle all display adapters
    8. Disable Fast Startup

  Usage:
    .\repair_display.ps1 -RepairId 1      # Run specific repair
    .\repair_display.ps1 -RunAll           # Run all repairs in order
    .\repair_display.ps1 -RunAll -NonInteractive  # No confirmations

"@ -ForegroundColor Cyan
}

# --- Summary ---
Write-DiagSection "Repair Summary"
foreach ($r in $results.Repairs) {
    $color = switch ($r.Status) { 'SUCCESS' { 'Green' } 'FAILED' { 'Red' } 'SKIPPED' { 'DarkGray' } 'PARTIAL' { 'Yellow' } default { 'White' } }
    Write-Host "  Repair $($r.Id): [$($r.Status)] $($r.Name) - $($r.Detail)" -ForegroundColor $color
}

Save-Result "phase7_repairs.json" $results
Write-Host "`nPhase 7 Complete.`n" -ForegroundColor Cyan
return $results
