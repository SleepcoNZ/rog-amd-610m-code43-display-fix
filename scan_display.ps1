# ============================================================================
# Phase 2: Display-Specific Diagnostics
# ============================================================================
param([switch]$AsJob)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp = Get-Date -Format 'o'
    Phase     = 'Phase2_DisplayDiagnostics'
    Issues    = @()
    Data      = @{}
}

Write-DiagHeader "PHASE 2: Display-Specific Diagnostics"

# --- 2.1 Code 43 Deep Analysis ---
Write-DiagSection "2.1 Code 43 Deep Analysis - AMD Radeon 610M"
$code43 = Safe-Execute "Analyzing Code 43 device" {
    $amdDevice = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
    if (-not $amdDevice) {
        return @{ Found = $false; Message = "No AMD display device found" }
    }
    $inst = $amdDevice.InstanceId
    $allProps = Get-PnpDeviceProperty -InstanceId $inst -ErrorAction SilentlyContinue

    $propTable = @{}
    $keyProps = @(
        'DEVPKEY_Device_ProblemCode',
        'DEVPKEY_Device_ProblemStatus',
        'DEVPKEY_Device_ConfigFlags',
        'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverDate',
        'DEVPKEY_Device_DriverDesc',
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_DriverInfSection',
        'DEVPKEY_Device_LocationInfo',
        'DEVPKEY_Device_PDOName',
        'DEVPKEY_Device_Parent',
        'DEVPKEY_Device_Children',
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_CompatibleIds',
        'DEVPKEY_Device_InstallDate',
        'DEVPKEY_Device_FirstInstallDate',
        'DEVPKEY_Device_LastArrivalDate',
        'DEVPKEY_Device_LastRemovalDate',
        'DEVPKEY_Device_DevNodeStatus',
        'DEVPKEY_Device_IsPresent'
    )
    foreach ($kn in $keyProps) {
        $p = $allProps | Where-Object KeyName -eq $kn
        if ($p) { $propTable[$kn] = $p.Data }
    }

    @{
        Found        = $true
        DeviceName   = $amdDevice.FriendlyName
        InstanceId   = $inst
        Status       = $amdDevice.Status
        Present      = $amdDevice.Present
        Properties   = $propTable
    }
}
if ($code43.Success) {
    $results.Data.Code43Analysis = $code43.Data
    if ($code43.Data.Found) {
        $pc = $code43.Data.Properties['DEVPKEY_Device_ProblemCode']
        Write-DiagResult "AMD Device" $code43.Data.DeviceName $(if ($pc -eq 43) { 'CRITICAL' } else { 'INFO' })
        Write-DiagResult "Problem Code" "$pc" $(if ($pc -eq 43) { 'CRITICAL' } elseif ($pc -gt 0) { 'ERROR' } else { 'OK' })
        Write-DiagResult "Device Status" $code43.Data.Status $(if ($code43.Data.Status -eq 'Error') { 'ERROR' } else { 'OK' })
        Write-DiagResult "Driver" $code43.Data.Properties['DEVPKEY_Device_DriverVersion'] 'INFO'
        Write-DiagResult "INF Path" $code43.Data.Properties['DEVPKEY_Device_DriverInfPath'] 'INFO'
        Write-DiagResult "Location" $code43.Data.Properties['DEVPKEY_Device_LocationInfo'] 'INFO'
        Write-DiagResult "Hardware IDs" ($code43.Data.Properties['DEVPKEY_Device_HardwareIds'] -join '; ') 'INFO'
        Write-DiagResult "Last Arrival" $code43.Data.Properties['DEVPKEY_Device_LastArrivalDate'] 'INFO'

        if ($pc -eq 43) {
            $results.Issues += "CRITICAL: AMD Radeon 610M (Code 43) - Windows has disabled this device because it reported problems"
            $results.Issues += "CRITICAL: Code 43 on the iGPU means the internal panel has no active GPU driving it"
        }
    } else {
        Write-DiagResult "AMD GPU" "Not found in system" 'ERROR'
        $results.Issues += "ERROR: No AMD display device found - iGPU may be completely disabled in BIOS"
    }
}

# --- 2.2 eDP / Internal Panel Presence ---
Write-DiagSection "2.2 Internal Panel (eDP) Presence Check"
$panelCheck = Safe-Execute "Checking for internal panel" {
    # Check monitor devices
    $monitors = Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue
    $monitorInfo = $monitors | ForEach-Object {
        $props = Get-PnpDeviceProperty -InstanceId $_.InstanceId -ErrorAction SilentlyContinue
        $mfg = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_Manufacturer').Data
        $hwIds = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_HardwareIds').Data
        @{
            Name        = $_.FriendlyName
            InstanceId  = $_.InstanceId
            Status      = $_.Status
            Present     = $_.Present
            Manufacturer = $mfg
            HardwareIds = $hwIds
        }
    }

    # Check display configuration API via registry
    $displayConfig = @()
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
    if (Test-Path $regPath) {
        $configs = Get-ChildItem $regPath -ErrorAction SilentlyContinue
        foreach ($cfg in $configs) {
            $displayConfig += @{
                Name = $cfg.PSChildName
                Path = $cfg.PSPath
            }
        }
    }

    # Check for active video outputs
    $connectors = @()
    $connPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity'
    if (Test-Path $connPath) {
        $conn = Get-ChildItem $connPath -Recurse -ErrorAction SilentlyContinue
        foreach ($c in $conn) {
            $connectors += @{
                Name = $c.PSChildName
                Path = $c.PSPath
            }
        }
    }

    @{
        Monitors       = $monitorInfo
        MonitorCount   = @($monitorInfo).Count
        DisplayConfigs = $displayConfig
        Connectors     = $connectors
    }
}
if ($panelCheck.Success) {
    $results.Data.PanelCheck = $panelCheck.Data
    Write-DiagResult "Monitor Devices" "$($panelCheck.Data.MonitorCount) monitor(s) registered" $(if ($panelCheck.Data.MonitorCount -gt 0) { 'OK' } else { 'WARN' })
    foreach ($m in $panelCheck.Data.Monitors) {
        $s = if ($m.Status -eq 'OK') { 'OK' } else { 'WARN' }
        Write-DiagResult "  Monitor" "$($m.Name) Status=$($m.Status) Present=$($m.Present)" $s
        Write-DiagResult "  HW IDs" ($m.HardwareIds -join '; ') 'INFO'
    }
    Write-DiagResult "Display Configs" "$($panelCheck.Data.DisplayConfigs.Count) configuration(s)" 'INFO'
    if ($panelCheck.Data.MonitorCount -eq 0) {
        $results.Issues += "CRITICAL: No monitor devices registered - the internal panel is completely invisible to Windows"
    }
}

# --- 2.3 Backlight Detection ---
Write-DiagSection "2.3 Backlight / Brightness Detection"
$backlight = Safe-Execute "Querying backlight via WMI" {
    $brightnessInfo = @{ Available = $false }
    try {
        $bl = Get-CimInstance -Namespace root\WMI -ClassName WmiMonitorBrightness -ErrorAction Stop
        $brightnessInfo.Available = $true
        $brightnessInfo.CurrentBrightness = $bl.CurrentBrightness
        $brightnessInfo.Levels = $bl.Level
        $brightnessInfo.InstanceName = $bl.InstanceName
    }
    catch {
        $brightnessInfo.Error = $_.Exception.Message
    }

    # Also try the brightness methods
    try {
        $methods = Get-CimInstance -Namespace root\WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop
        $brightnessInfo.MethodsAvailable = $true
    }
    catch {
        $brightnessInfo.MethodsAvailable = $false
    }

    # Check ASUS backlight via registry
    $asusPath = 'HKLM:\SOFTWARE\ASUS\ASUS System Control Interface\AsusOptimization\ASUS Keyboard Hotkeys'
    if (Test-Path $asusPath) {
        $brightnessInfo.AsusHotkeyPath = $asusPath
    }

    $brightnessInfo
}
if ($backlight.Success) {
    $results.Data.Backlight = $backlight.Data
    if ($backlight.Data.Available) {
        Write-DiagResult "Backlight" "Available - Current brightness: $($backlight.Data.CurrentBrightness)%" 'OK'
        Write-DiagResult "Brightness Levels" ($backlight.Data.Levels -join ', ') 'INFO'
        $results.Issues += "INFO: Backlight WMI is responding - panel hardware may be connected but GPU not driving it"
    } else {
        Write-DiagResult "Backlight" "NOT available - $($backlight.Data.Error)" 'WARN'
        $results.Issues += "WARN: Backlight WMI not responding - panel may be disconnected or backlight circuit failed"
    }
}

# --- 2.4 MUX Switch / GPU Mode Detection ---
Write-DiagSection "2.4 MUX Switch / GPU Mode Detection"
$muxCheck = Safe-Execute "Checking ASUS MUX switch state" {
    $mux = @{}

    # Check ASUS GPU Switch registry
    $gpuSwitchPaths = @(
        'HKLM:\SOFTWARE\ASUS\ARMOURY CRATE Service',
        'HKLM:\SOFTWARE\ASUS\GPUSwitch',
        'HKLM:\SOFTWARE\ASUS\Armoury Crate Service\GPUSwitch',
        'HKLM:\SYSTEM\CurrentControlSet\Services\ArmouryCrateService',
        'HKLM:\SOFTWARE\ASUS\ASUS System Control Interface\GPUMux'
    )
    foreach ($p in $gpuSwitchPaths) {
        if (Test-Path $p) {
            $mux["Registry_$($p.Split('\')[-1])"] = Get-ItemProperty $p -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS*
        }
    }

    # Check for GPU MUX via ASUS ACPI
    $asusAcpiPaths = @(
        'HKLM:\SYSTEM\CurrentControlSet\Services\AsusSystemControlInterface',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    )
    foreach ($p in $asusAcpiPaths) {
        if (Test-Path $p) {
            $mux["ACPI_$($p.Split('\')[-1])"] = "Path exists"
            # Get subkeys for GPU class
            if ($p -match '4d36e968') {
                $subkeys = Get-ChildItem $p -ErrorAction SilentlyContinue
                foreach ($sk in $subkeys) {
                    if ($sk.PSChildName -match '^\d{4}$') {
                        $vals = Get-ItemProperty $sk.PSPath -ErrorAction SilentlyContinue
                        if ($vals.DriverDesc) {
                            $mux["GPU_$($sk.PSChildName)"] = @{
                                DriverDesc = $vals.DriverDesc
                                ProviderName = $vals.ProviderName
                                DriverVersion = $vals.DriverVersion
                                DriverDate = $vals.DriverDate
                                HardwareID = $vals.MatchingDeviceId
                            }
                        }
                    }
                }
            }
        }
    }

    # Check for Optimus / Hybrid mode
    $optimusPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\EnableHwidScheduling'
    if (Test-Path $optimusPath) {
        $mux['HwidScheduling'] = Get-ItemProperty $optimusPath -ErrorAction SilentlyContinue
    }

    # Check NVIDIA Optimus profiles
    $nvidiaOptimus = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak'
    if (Test-Path $nvidiaOptimus) {
        $mux['NVTweak'] = Get-ItemProperty $nvidiaOptimus -ErrorAction SilentlyContinue |
            Select-Object * -ExcludeProperty PS*
    }

    $mux
}
if ($muxCheck.Success) {
    $results.Data.MuxSwitch = $muxCheck.Data
    $muxKeys = $muxCheck.Data.Keys | Sort-Object
    foreach ($k in $muxKeys) {
        $val = $muxCheck.Data[$k]
        if ($val -is [hashtable]) {
            Write-DiagResult $k ($val | ConvertTo-Json -Compress) 'INFO'
        } else {
            Write-DiagResult $k "$val" 'INFO'
        }
    }
    if ($muxKeys.Count -eq 0) {
        $results.Issues += "WARN: Could not detect MUX switch state from registry - may need Armoury Crate GUI"
    }
}

# --- 2.5 NVIDIA Status ---
Write-DiagSection "2.5 NVIDIA GPU Status"
$nvidiaCheck = Safe-Execute "Running nvidia-smi" {
    $smiPath = "C:\Windows\System32\nvidia-smi.exe"
    if (-not (Test-Path $smiPath)) {
        $smiPath = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    }
    if ($smiPath) {
        $smiOutput = & $smiPath 2>&1
        $queryOutput = & $smiPath --query-gpu=name,driver_version,pstate,temperature.gpu,power.draw,display_mode,display_active --format=csv,noheader 2>&1
        @{
            Available   = $true
            FullOutput  = ($smiOutput -join "`n")
            QueryOutput = ($queryOutput -join "`n")
        }
    } else {
        @{ Available = $false; Error = "nvidia-smi not found" }
    }
}
if ($nvidiaCheck.Success) {
    $results.Data.NvidiaStatus = $nvidiaCheck.Data
    if ($nvidiaCheck.Data.Available) {
        Write-DiagResult "nvidia-smi" "Available" 'OK'
        Write-Host $nvidiaCheck.Data.FullOutput
        Write-DiagResult "GPU Query" $nvidiaCheck.Data.QueryOutput 'INFO'
    } else {
        Write-DiagResult "nvidia-smi" "Not available" 'WARN'
        $results.Issues += "WARN: nvidia-smi not found - NVIDIA driver may not be installed correctly"
    }
}

# --- 2.6 Display Output Topology ---
Write-DiagSection "2.6 Display Output Topology"
$topology = Safe-Execute "Checking display output paths" {
    # Use CIM to get display mode info
    $modes = @()
    try {
        $vc = Get-CimInstance Win32_VideoController
        foreach ($v in $vc) {
            $modes += @{
                GPU              = $v.Name
                CurrentMode      = $v.VideoModeDescription
                InfFilename      = $v.InfFilename
                InfSection       = $v.InfSection
                InstalledDrivers = $v.InstalledDisplayDrivers
                Status           = $v.Status
                StatusInfo       = $v.StatusInfo
                Availability     = $v.Availability
            }
        }
    }
    catch {}

    # Check for display paths in registry
    $displayPaths = @()
    $dpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
    if (Test-Path $dpPath) {
        Get-ChildItem $dpPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $displayPaths += $_.PSChildName
        }
    }

    @{
        VideoModes   = $modes
        DisplayPaths = $displayPaths
    }
}
if ($topology.Success) {
    $results.Data.DisplayTopology = $topology.Data
    foreach ($m in $topology.Data.VideoModes) {
        Write-DiagResult $m.GPU "Mode=$($m.CurrentMode) Status=$($m.Status)" 'INFO'
    }
}

# --- Summary ---
Write-DiagSection "Phase 2 Summary"
$severity = Get-Severity $results.Issues
Write-DiagResult "Overall Severity" $severity $severity
Write-DiagResult "Issues Found" "$($results.Issues.Count)" $(if ($results.Issues.Count -eq 0) { 'OK' } else { 'WARN' })
foreach ($issue in $results.Issues) {
    Write-Host "  ! $issue" -ForegroundColor $(if ($issue -match 'CRITICAL') { 'Magenta' } elseif ($issue -match 'ERROR') { 'Red' } else { 'Yellow' })
}

Save-Result "phase2_display.json" $results
Write-Host "`nPhase 2 Complete.`n" -ForegroundColor Cyan
return $results
