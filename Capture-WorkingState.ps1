<#
.SYNOPSIS
    Captures complete working-state snapshot of GPU/display/power configuration
    so we can compare future broken states against it and restore.
#>
$ErrorActionPreference = 'Continue'

$snapDir = "$PSScriptRoot\snapshots"
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$snap = Join-Path $snapDir "working_state_$ts"
New-Item $snap -ItemType Directory -Force | Out-Null
Write-Host "Snapshot dir: $snap" -ForegroundColor Cyan

# 1. GPU PnP state
$gpus = Get-PnpDevice -Class Display
$gpuData = foreach ($g in $gpus) {
    $props = Get-PnpDeviceProperty -InstanceId $g.InstanceId -EA SilentlyContinue
    $code = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    [PSCustomObject]@{
        Name = $g.FriendlyName
        Status = $g.Status
        ProblemCode = $code
        InstanceId = $g.InstanceId
    }
}
$gpuData | Format-List | Out-File "$snap\01_gpu_pnp.txt" -Encoding UTF8
Write-Host "[1] GPU PnP captured"

# 2. Video controller details
Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate, VideoModeDescription, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate, AdapterRAM, Status, PNPDeviceID | Format-List | Out-File "$snap\02_video_controllers.txt" -Encoding UTF8
Write-Host "[2] Video controllers captured"

# 3. Display monitors
Get-CimInstance Win32_DesktopMonitor | Select-Object Name, DeviceID, MonitorType, ScreenHeight, ScreenWidth, Status, Availability | Format-List | Out-File "$snap\03_monitors.txt" -Encoding UTF8
Get-CimInstance -Namespace 'root\wmi' -ClassName 'WmiMonitorID' -EA SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        InstanceName = $_.InstanceName
        ManufacturerName = -join ($_.ManufacturerName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
        UserFriendlyName = -join ($_.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
        ProductCodeID = -join ($_.ProductCodeID | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
        SerialNumberID = -join ($_.SerialNumberID | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
        YearOfManufacture = $_.YearOfManufacture
        Active = $_.Active
    }
} | Format-List | Out-File "$snap\03_monitors_wmi.txt" -Encoding UTF8
Write-Host "[3] Monitors captured"

# 4. Power state availability
powercfg /a 2>&1 | Out-File "$snap\04_powercfg_a.txt" -Encoding UTF8

# 5. Active power scheme - full dump
$scheme = (powercfg /getactivescheme) -replace '.*GUID: (\S+).*', '$1'
powercfg /q SCHEME_CURRENT 2>&1 | Out-File "$snap\05_powercfg_scheme.txt" -Encoding UTF8
"Active Scheme GUID: $scheme" | Out-File "$snap\05_active_scheme.txt" -Encoding UTF8

# 6. List of all power schemes
powercfg /list 2>&1 | Out-File "$snap\06_powercfg_list.txt" -Encoding UTF8
Write-Host "[4-6] Power config captured"

# 7. Critical registry — Power
$pwrReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -EA SilentlyContinue
$pwrReg | Format-List | Out-File "$snap\07_reg_power.txt" -Encoding UTF8

$sesPwr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -EA SilentlyContinue
$sesPwr | Format-List | Out-File "$snap\07_reg_sessionmgr_power.txt" -Encoding UTF8

# 8. Registry — GraphicsDrivers (TDR settings)
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -EA SilentlyContinue | Format-List | Out-File "$snap\08_reg_graphicsdrivers.txt" -Encoding UTF8

# 9. Registry — Class GUID for display adapters (per-GPU settings)
$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$adapters = Get-ChildItem $classKey -EA SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
foreach ($a in $adapters) {
    $desc = (Get-ItemProperty $a.PSPath -Name DriverDesc -EA SilentlyContinue).DriverDesc
    if ($desc) {
        $safeDesc = $desc -replace '[^\w]', '_'
        Get-ItemProperty $a.PSPath -EA SilentlyContinue | Format-List | Out-File "$snap\09_reg_classadapter_$($a.PSChildName)_$safeDesc.txt" -Encoding UTF8
    }
}
Write-Host "[7-9] Registry captured"

# 10. Display configuration (DisplaySwitch / current outputs)
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | Format-List | Out-File "$snap\10_screens.txt" -Encoding UTF8

# 11. Drivers
Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'DISPLAY','SYSTEM' -or $_.DeviceName -match 'AMD|NVIDIA|Radeon|GeForce|Chipset|GPIO|SMBus|I2C|PSP|MUX|Hybrid' } | Select-Object DeviceName, DriverVersion, DriverDate, DriverProviderName, InfName, Signer | Sort-Object DeviceName | Format-Table -AutoSize | Out-File "$snap\11_drivers.txt" -Encoding UTF8 -Width 250
Write-Host "[10-11] Display + drivers captured"

# 12. BIOS / system
Get-CimInstance Win32_BIOS | Format-List | Out-File "$snap\12_bios.txt" -Encoding UTF8
Get-CimInstance Win32_ComputerSystem | Format-List | Out-File "$snap\12_computer.txt" -Encoding UTF8
Get-CimInstance Win32_BaseBoard | Format-List | Out-File "$snap\12_baseboard.txt" -Encoding UTF8
Get-CimInstance Win32_Processor | Format-List | Out-File "$snap\12_processor.txt" -Encoding UTF8

# 13. ASUS / Armoury Crate state
$asusKey = 'HKLM:\SOFTWARE\ASUS'
if (Test-Path $asusKey) {
    Get-ChildItem $asusKey -Recurse -EA SilentlyContinue | Where-Object { $_.Name -match 'GPU|MUX|Hybrid|Mode|Optimization' } | ForEach-Object {
        "=== $($_.Name) ==="
        Get-ItemProperty $_.PSPath -EA SilentlyContinue | Format-List
    } | Out-File "$snap\13_asus_registry.txt" -Encoding UTF8
}

# Decode current GPU mode cycle report
$gpuModeKey = 'HKLM:\SOFTWARE\ASUS\Armoury Crate Service\CycleReport\{9EBAE211-6820-4E90-AFA6-292ADE3F9480}\GPUMode'
if (Test-Path $gpuModeKey) {
    $rec = (Get-ItemProperty $gpuModeKey).Record
    if ($rec) {
        [System.Text.Encoding]::UTF8.GetString($rec) | Out-File "$snap\13_gpu_mode_history.txt" -Encoding UTF8
    }
}
Write-Host "[12-13] BIOS + ASUS captured"

# 14. Services state (display/GPU related)
Get-Service | Where-Object { $_.Name -match 'AMD|NVIDIA|Display|Graphics|Asus|Armoury|GpuMon' } | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize | Out-File "$snap\14_services.txt" -Encoding UTF8

# 15. Scheduled tasks (watchdog)
schtasks /query /tn 'GPU_Watchdog_ROG' /fo LIST /v 2>&1 | Out-File "$snap\15_watchdog_task.txt" -Encoding UTF8

# 16. Recent watchdog log (last 30 lines)
if (Test-Path "$PSScriptRoot\results\watchdog.log") {
    Get-Content "$PSScriptRoot\results\watchdog.log" -Tail 30 | Out-File "$snap\16_watchdog_log_tail.txt" -Encoding UTF8
}

# 17. Boot info
$os = Get-CimInstance Win32_OperatingSystem
[PSCustomObject]@{
    LastBootUpTime = $os.LastBootUpTime
    Uptime = (Get-Date) - $os.LastBootUpTime
    BuildNumber = $os.BuildNumber
    Version = $os.Version
    Caption = $os.Caption
    OSArchitecture = $os.OSArchitecture
} | Format-List | Out-File "$snap\17_os.txt" -Encoding UTF8

# 18. nvidia-smi if available
if (Get-Command nvidia-smi -EA SilentlyContinue) {
    nvidia-smi 2>&1 | Out-File "$snap\18_nvidia_smi.txt" -Encoding UTF8
}

# 19. Current display mode (DPI/scaling/refresh) via dxdiag
Start-Process dxdiag -ArgumentList "/t `"$snap\19_dxdiag.txt`"" -Wait -WindowStyle Hidden
Write-Host "[14-19] Services, tasks, OS, dxdiag captured"

# 20. SUMMARY (one-page human-readable)
$summary = @"
================================================================
 WORKING STATE SNAPSHOT - $(Get-Date)
 Location: $snap
================================================================

GPU STATUS:
$(Get-PnpDevice -Class Display | ForEach-Object {
    $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -EA SilentlyContinue
    $c = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    "  $($_.FriendlyName) | Status=$($_.Status) | Code=$c"
})

VIDEO DRIVERS:
$(Get-CimInstance Win32_VideoController | ForEach-Object {
    "  $($_.Name) v$($_.DriverVersion) ($($_.DriverDate.ToString('yyyy-MM-dd')))"
})

KEY REGISTRY VALUES:
  PlatformAoAcOverride = $($pwrReg.PlatformAoAcOverride)  (Modern Standby: $(if($pwrReg.PlatformAoAcOverride -eq 0){'DISABLED'}elseif($null -eq $pwrReg.PlatformAoAcOverride){'firmware default'}else{$pwrReg.PlatformAoAcOverride}))
  CsEnabled            = $($pwrReg.CsEnabled)  (Connected Standby: $(if($pwrReg.CsEnabled -eq 0){'DISABLED'}else{'ENABLED'}))
  HiberbootEnabled     = $($sesPwr.HiberbootEnabled)  (Fast Startup: $(if($sesPwr.HiberbootEnabled -eq 0){'DISABLED'}else{'ENABLED'}))
  HibernateEnabled     = $($pwrReg.HibernateEnabled)
  TdrDelay             = $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -EA SilentlyContinue).TdrDelay)
  TdrDdiDelay          = $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -EA SilentlyContinue).TdrDdiDelay)
  TdrLimitCount        = $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -EA SilentlyContinue).TdrLimitCount)

POWER PLAN ACTIONS (current scheme):
$(@(
    @{Name='Lid close (AC)'; Sub='SUB_BUTTONS'; Set='LIDACTION'; Mode='AC'},
    @{Name='Lid close (DC)'; Sub='SUB_BUTTONS'; Set='LIDACTION'; Mode='DC'},
    @{Name='Power button (AC)'; Sub='SUB_BUTTONS'; Set='PBUTTONACTION'; Mode='AC'},
    @{Name='Sleep timeout AC'; Sub='SUB_SLEEP'; Set='STANDBYIDLE'; Mode='AC'}
) | ForEach-Object {
    "  $($_.Name) (see 05_powercfg_scheme.txt for full detail)"
})

SLEEP STATES AVAILABLE:
$((powercfg /a) -split "`n" | Where-Object { $_ -match 'Hibernate|Standby|Hybrid|Fast' -and $_ -notmatch 'firmware|disabled|hypervisor|policy|not been' } | ForEach-Object { "  $($_.Trim())" })

BIOS: $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion) ($((Get-CimInstance Win32_BIOS).ReleaseDate.ToString('yyyy-MM-dd')))
MODEL: $((Get-CimInstance Win32_ComputerSystem).Model)
OS: $((Get-CimInstance Win32_OperatingSystem).Caption) Build $((Get-CimInstance Win32_OperatingSystem).BuildNumber)

UPTIME: $(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('d\.hh\:mm'))
LAST BOOT: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime)

WATCHDOG TASK:
$(if ((schtasks /query /tn 'GPU_Watchdog_ROG' 2>&1) -match 'Ready|Running') { '  GPU_Watchdog_ROG: ACTIVE' } else { '  GPU_Watchdog_ROG: NOT FOUND' })

================================================================
 FILES IN THIS SNAPSHOT:
================================================================
$(Get-ChildItem $snap | Sort-Object Name | ForEach-Object { "  $($_.Name) ($([math]::Round($_.Length/1KB,1)) KB)" })
"@

$summary | Out-File "$snap\00_SUMMARY.txt" -Encoding UTF8
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " SNAPSHOT COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "Location: $snap"
Write-Host ""
Get-Content "$snap\00_SUMMARY.txt"
