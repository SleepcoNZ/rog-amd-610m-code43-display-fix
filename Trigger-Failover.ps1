<#
.SYNOPSIS
    Trigger-Failover.ps1 -- Manually trigger the panel failover.
.DESCRIPTION
    Run any time the laptop panel is black/dead but an external monitor (HDMI/USB-C)
    is connected via the NVIDIA dGPU. Performs the same actions as
    Boot-GPU-Guardian.ps1's Invoke-PanelFailover:
      1. DisplaySwitch.exe /external  -- project to external display only
      2. HwSchMode=2 (requires admin)  -- bias DWM toward dGPU
      3. Restart NVDisplay.ContainerLocalSystem (requires admin)
    Safe to run when things are healthy: it just switches to "external only"
    projection and you can switch back with Win+P.
#>
[CmdletBinding()]
param(
    [switch]$SkipAdminSteps
)

$ErrorActionPreference = 'Continue'
$logDir = "$PSScriptRoot\results"
New-Item -ItemType Directory -Path $logDir -Force -EA SilentlyContinue | Out-Null
$log = Join-Path $logDir 'trigger-failover.log'

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -Path $log -Value $line
    Write-Host $line
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Log "==================== TRIGGER FAILOVER ===================="

# Snapshot
$vc = Get-CimInstance Win32_VideoController -EA SilentlyContinue
$mons = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -EA SilentlyContinue | Where-Object Active).Count
Write-Log "Active monitors: $mons"
foreach ($v in $vc) {
    Write-Log "  $($v.Name): $($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)@$($v.CurrentRefreshRate) Status=$($v.Status)"
}

if ($mons -lt 1) {
    Write-Log "0 active monitors -- failover has nothing to project to. Aborting." 'ERROR'
    Write-Host ""
    Write-Host "No display detected at all. You need a full power-off cycle."
    Write-Host "  shutdown /s /t 0   (then wait 30s, power on)"
    Read-Host "Press Enter to exit"
    exit 1
}

# Step 1: DisplaySwitch /external (no admin needed)
$ds = Join-Path $env:WINDIR 'System32\DisplaySwitch.exe'
if (Test-Path $ds) {
    try {
        Start-Process -FilePath $ds -ArgumentList '/external' -WindowStyle Hidden -Wait -EA Stop
        Write-Log "DisplaySwitch /external -> OK" 'OK'
    } catch {
        Write-Log "DisplaySwitch /external failed: $($_.Exception.Message)" 'ERROR'
    }
} else {
    Write-Log "DisplaySwitch.exe not found" 'ERROR'
}

# Steps 2/3 require admin
if ($SkipAdminSteps) {
    Write-Log "SkipAdminSteps set -- skipping HwSchMode + service restart" 'INFO'
} elseif (Test-IsAdmin) {
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -Type DWord -Force -EA Stop
        Write-Log "HwSchMode=2 set (takes effect on next reboot)" 'OK'
    } catch {
        Write-Log "HwSchMode set failed: $($_.Exception.Message)" 'WARN'
    }
    try {
        $svc = Get-Service -Name 'NVDisplay.ContainerLocalSystem' -EA SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Restart-Service -Name 'NVDisplay.ContainerLocalSystem' -Force -EA Stop
            Write-Log "NVDisplay.ContainerLocalSystem restarted" 'OK'
        }
    } catch {
        Write-Log "NVDisplay restart failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log "Not elevated -- HwSchMode + NVDisplay restart skipped. (DisplaySwitch /external already done.)" 'WARN'
    Write-Host ""
    Write-Host "Note: re-run as admin to also apply HwSchMode + restart NVDisplay container."
}

Write-Log "Failover complete."
Write-Host ""
Write-Host "Tip: press Win+P to change projection mode (Extend / PC only / Second only / Duplicate)."
Read-Host "Press Enter to close"
