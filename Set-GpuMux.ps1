<#
.SYNOPSIS
    Switch the ASUS ROG hardware GPU MUX between Ultimate (dGPU-only) and Optimus (MSHybrid).

.DESCRIPTION
    On the ROG Strix G713PV the internal panel is wired through the AMD 610M iGPU in
    Optimus/MSHybrid mode. When the iGPU faults (Code 43) the panel goes dark and no
    software GPU reset can recover it. Switching the hardware MUX to "Ultimate" physically
    re-routes the internal panel directly to the NVIDIA dGPU and powers the iGPU off,
    bypassing the broken device entirely.

    The switch is staged in firmware and only takes physical effect after a reboot.
    It is fully reversible: run with -Mode Optimus to switch back.

    ASUS ATK WMI contract (verified on this machine via ID qualifiers):
        DSTS(Device_ID)                 -> device_status   (read)
        DEVS(Device_ID, Control_status) -> result          (write)
    GPU_MUX device id = 0x00090016 ; Control_status 0 = Ultimate/dGPU, 1 = Optimus.

.PARAMETER Mode
    Ultimate (default) routes the panel to the NVIDIA dGPU. Optimus routes it back to the AMD iGPU.

.PARAMETER Reboot
    If set, restart the machine after a successful switch (required to commit the change).

.PARAMETER RebootDelaySeconds
    Grace period before the restart. Default 20.
#>
[CmdletBinding()]
param(
    [ValidateSet('Ultimate','Optimus')]
    [string]$Mode = 'Ultimate',
    [switch]$Reboot,
    [int]$RebootDelaySeconds = 20
)

$ErrorActionPreference = 'Stop'
$LogDir = "$PSScriptRoot\logs"
$null = New-Item -ItemType Directory -Path $LogDir -Force
$Log = Join-Path $LogDir 'gpu-mux.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line | Tee-Object -FilePath $Log -Append
}

# --- elevation gate ---
$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Log 'Not elevated; relaunching with admin rights...' 'WARN'
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Mode',$Mode)
    if ($Reboot) { $argList += '-Reboot'; $argList += '-RebootDelaySeconds'; $argList += $RebootDelaySeconds }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    return
}

$ns      = 'root\wmi'
$class   = 'AsusAtkWmi_WMNB'
$MUX_ID  = 0x00090016
$target  = if ($Mode -eq 'Ultimate') { 0 } else { 1 }
$targetName = if ($target -eq 0) { 'Ultimate/dGPU (panel -> NVIDIA)' } else { 'Optimus/MSHybrid (panel -> AMD iGPU)' }

Write-Log "=== GPU MUX switch requested: $Mode (Control_status=$target) ==="

# ASUS ATK methods live on the WMI *instance* (verified), not the class.
$atk = Get-WmiObject -Namespace $ns -Class $class
if (-not $atk) { Write-Log 'AsusAtkWmi_WMNB instance not found; ATK interface unavailable.' 'ERROR'; exit 2 }

# --- read current MUX state ---
$cur = [uint32]($atk.DSTS($MUX_ID)).device_status
$present = [bool]($cur -band 0x00010000)
$curState = $cur -band 0xFF
Write-Log ("Current GPU_MUX DSTS=0x{0:X8} present={1} state={2}" -f $cur, $present, $curState)
if (-not $present) { Write-Log 'GPU_MUX device id not reported present; aborting (will not blind-write).' 'ERROR'; exit 3 }

if ($curState -eq $target) {
    Write-Log "MUX already in target mode ($Mode). No write needed."
    if ($Reboot) { Write-Log 'Reboot requested but no change made; skipping reboot.' 'WARN' }
    exit 0
}

# --- write: DEVS(Device_ID, Control_status) — Device_ID first per ID qualifiers ---
Write-Log "Setting MUX -> $targetName"
$res = [uint32]($atk.DEVS($MUX_ID, [uint32]$target)).result
Write-Log ("DEVS result=0x{0:X8}" -f $res)

# ASUS DEVS returns 1 (0x1) on success on this family. Treat 0 as failure.
if ($res -eq 0) {
    Write-Log 'DEVS returned 0 (failure). MUX not changed.' 'ERROR'
    exit 4
}

# Re-read (note: many firmwares keep reporting the OLD state until the commit reboot).
Start-Sleep -Milliseconds 500
$after = [uint32]($atk.DSTS($MUX_ID)).device_status
Write-Log ("Post-write DSTS=0x{0:X8} (may still show old state until reboot)" -f $after)

Write-Log "MUX switch staged successfully. A REBOOT is required to physically re-route the panel."

if ($Reboot) {
    Write-Log "Restarting in $RebootDelaySeconds s to commit the MUX switch..."
    # /g = restart and re-open apps after sign-in; /t = delay; /c = comment
    & shutdown.exe /g /t $RebootDelaySeconds /c "ASUS GPU MUX -> $Mode. Restarting to route the laptop panel to the RTX 4060."
} else {
    Write-Log 'Run a manual restart to apply. To revert: Set-GpuMux.ps1 -Mode Optimus' 'INFO'
}
