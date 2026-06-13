# ============================================================================
# Phase 1: System & Hardware Inventory Scanner
# ============================================================================
param([switch]$AsJob)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp    = Get-Date -Format 'o'
    Phase        = 'Phase1_SystemInventory'
    Issues       = @()
    Data         = @{}
}

Write-DiagHeader "PHASE 1: System & Hardware Inventory"

# --- 1.1 Basic System Info ---
Write-DiagSection "1.1 System Information"
$sysInfo = Safe-Execute "Collecting system info" {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS
    $mb = Get-CimInstance Win32_BaseBoard
    @{
        ComputerName    = $cs.Name
        Model           = "$($cs.Manufacturer) $($cs.Model)"
        SystemType      = $cs.SystemType
        TotalRAM_GB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        OSName          = $os.Caption
        OSBuild         = $os.BuildNumber
        OSVersion       = $os.Version
        BIOSVersion     = $bios.SMBIOSBIOSVersion
        BIOSDate        = $bios.ReleaseDate
        BIOSManufacturer = $bios.Manufacturer
        Motherboard     = "$($mb.Manufacturer) $($mb.Product)"
        SerialNumber    = $bios.SerialNumber
    }
}
if ($sysInfo.Success) {
    $results.Data.System = $sysInfo.Data
    foreach ($k in $sysInfo.Data.Keys) {
        Write-DiagResult $k $sysInfo.Data[$k] 'INFO'
    }
}

# --- 1.2 Display Adapters ---
Write-DiagSection "1.2 Display Adapters (PnP Devices)"
$displayDevices = Safe-Execute "Enumerating display adapters" {
    Get-PnpDevice -Class Display | ForEach-Object {
        $props = Get-PnpDeviceProperty -InstanceId $_.InstanceId -ErrorAction SilentlyContinue
        $driverVersion = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion').Data
        $driverDate = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_DriverDate').Data
        $locationInfo = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
        $hwIds = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_HardwareIds').Data
        $problemCode = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        $problemStatus = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemStatus').Data
        @{
            Name           = $_.FriendlyName
            InstanceId     = $_.InstanceId
            Status         = $_.Status
            ProblemCode    = $problemCode
            ProblemStatus  = $problemStatus
            DriverVersion  = $driverVersion
            DriverDate     = $driverDate
            Location       = $locationInfo
            HardwareIds    = $hwIds
            Class          = $_.Class
            Present        = $_.Present
        }
    }
}
if ($displayDevices.Success) {
    $results.Data.DisplayAdapters = $displayDevices.Data
    foreach ($dev in $displayDevices.Data) {
        $status = if ($dev.Status -eq 'OK') { 'OK' }
                  elseif ($dev.ProblemCode -eq 43) { 'CRITICAL' }
                  else { 'ERROR' }
        Write-DiagResult $dev.Name "Status=$($dev.Status) ProblemCode=$($dev.ProblemCode) Driver=$($dev.DriverVersion)" $status
        if ($dev.ProblemCode -eq 43) {
            $results.Issues += "CRITICAL: $($dev.Name) has Code 43 - Windows has stopped this device"
        }
        elseif ($dev.Status -ne 'OK') {
            $results.Issues += "ERROR: $($dev.Name) status is $($dev.Status)"
        }
    }
}

# --- 1.3 Video Controllers (WMI detailed) ---
Write-DiagSection "1.3 Video Controllers (CIM Detailed)"
$videoCtrl = Safe-Execute "Querying video controllers" {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        @{
            Name               = $_.Name
            AdapterRAM_MB      = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1MB) } else { 'N/A' }
            DriverVersion      = $_.DriverVersion
            DriverDate         = $_.DriverDate
            VideoProcessor     = $_.VideoProcessor
            CurrentResolution  = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
            CurrentRefreshRate = $_.CurrentRefreshRate
            VideoMode          = $_.VideoModeDescription
            Status             = $_.Status
            Availability       = $_.Availability
            ConfigManagerErrorCode = $_.ConfigManagerErrorCode
        }
    }
}
if ($videoCtrl.Success) {
    $results.Data.VideoControllers = $videoCtrl.Data
    foreach ($vc in $videoCtrl.Data) {
        $status = if ($vc.ConfigManagerErrorCode -eq 0) { 'OK' } else { 'ERROR' }
        Write-DiagResult $vc.Name "Res=$($vc.CurrentResolution) Driver=$($vc.DriverVersion) ErrCode=$($vc.ConfigManagerErrorCode)" $status
        if ($vc.CurrentResolution -eq '640x480' -or $vc.CurrentResolution -eq 'x') {
            $results.Issues += "WARN: $($vc.Name) running at $($vc.CurrentResolution) - indicates no proper display driver active or no monitor connected"
        }
    }
}

# --- 1.4 Monitor Detection (EDID) ---
Write-DiagSection "1.4 Monitor / Panel Detection"
$monitors = Safe-Execute "Checking for connected monitors via EDID" {
    try {
        $edid = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
        $edid | ForEach-Object {
            $mfg = -join ($_.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
            $name = -join ($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
            $serial = -join ($_.SerialNumberID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
            @{
                InstanceName = $_.InstanceName
                Manufacturer = $mfg
                UserFriendlyName = $name
                SerialNumber = $serial
                ProductCodeID = $_.ProductCodeID
                Active = $_.Active
            }
        }
    }
    catch {
        @{ Error = "No monitors detected via WMI EDID: $($_.Exception.Message)" }
    }
}
if ($monitors.Success) {
    $results.Data.Monitors = $monitors.Data
    if ($monitors.Data.Error) {
        Write-DiagResult "Monitor EDID" $monitors.Data.Error 'WARN'
        $results.Issues += "WARN: No monitor EDID data available - panel may not be detected at all"
    } else {
        $monCount = @($monitors.Data).Count
        Write-DiagResult "Monitors Detected" "$monCount monitor(s) via EDID" $(if ($monCount -gt 0) { 'OK' } else { 'WARN' })
        foreach ($m in $monitors.Data) {
            Write-DiagResult "Monitor" "$($m.Manufacturer) $($m.UserFriendlyName) Active=$($m.Active)" 'INFO'
        }
        if ($monCount -eq 0) {
            $results.Issues += "CRITICAL: No monitors detected via EDID - built-in panel is not being recognized by Windows"
        }
    }
}

# --- 1.5 Desktop Monitors ---
Write-DiagSection "1.5 Desktop Monitor Instances"
$desktopMon = Safe-Execute "Querying desktop monitors" {
    Get-CimInstance Win32_DesktopMonitor | ForEach-Object {
        @{
            Name         = $_.Name
            MonitorType  = $_.MonitorType
            ScreenWidth  = $_.ScreenWidth
            ScreenHeight = $_.ScreenHeight
            Status       = $_.Status
            Availability = $_.Availability
            PNPDeviceID  = $_.PNPDeviceID
        }
    }
}
if ($desktopMon.Success) {
    $results.Data.DesktopMonitors = $desktopMon.Data
    foreach ($dm in $desktopMon.Data) {
        Write-DiagResult $dm.Name "Type=$($dm.MonitorType) Size=$($dm.ScreenWidth)x$($dm.ScreenHeight) Status=$($dm.Status)" 'INFO'
    }
}

# --- 1.6 Processor & Thermal ---
Write-DiagSection "1.6 Processor Info"
$cpu = Safe-Execute "Querying CPU" {
    Get-CimInstance Win32_Processor | ForEach-Object {
        @{
            Name            = $_.Name
            Cores           = $_.NumberOfCores
            LogicalProcs    = $_.NumberOfLogicalProcessors
            MaxClockMHz     = $_.MaxClockSpeed
            CurrentClockMHz = $_.CurrentClockSpeed
            Status          = $_.Status
            LoadPercentage  = $_.LoadPercentage
        }
    }
}
if ($cpu.Success) {
    $results.Data.Processor = $cpu.Data
    foreach ($c in $cpu.Data) {
        Write-DiagResult "CPU" "$($c.Name) Cores=$($c.Cores) Load=$($c.LoadPercentage)%" 'INFO'
    }
}

# --- Summary ---
Write-DiagSection "Phase 1 Summary"
$severity = Get-Severity $results.Issues
Write-DiagResult "Overall Severity" $severity $severity
Write-DiagResult "Issues Found" "$($results.Issues.Count)" $(if ($results.Issues.Count -eq 0) { 'OK' } else { 'WARN' })
foreach ($issue in $results.Issues) {
    Write-Host "  ! $issue" -ForegroundColor $(if ($issue -match 'CRITICAL') { 'Magenta' } elseif ($issue -match 'ERROR') { 'Red' } else { 'Yellow' })
}

Save-Result "phase1_system.json" $results
Write-Host "`nPhase 1 Complete.`n" -ForegroundColor Cyan
return $results
