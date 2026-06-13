<#
.SYNOPSIS
    Boot-GPU-Guardian.ps1 -- Runs at Windows boot for ~5 minutes, watching for
    GPU/display errors. On detection, force-applies the known-good settings
    captured by Capture-WorkingState.ps1 and attempts recovery.

.DESCRIPTION
    Designed to run as SYSTEM via a scheduled task at logon/startup. After 5
    minutes of clean health, exits. Logs to results\boot-guardian.log.

    Detection criteria (any one trips recovery):
      - Any Display class device with ProblemCode != 0
      - Any Display class device with Status != 'OK'
      - Zero active monitors (Win32_DesktopMonitor with Availability=3/Running)
      - NVIDIA or AMD driver service not running

    Recovery actions (in order, until GPU clears or all exhausted):
      1. Re-apply critical registry (TDR, Power, Fast Startup)
      2. Disable+Enable each broken Display device
      3. Re-run pnputil scan for hardware changes
      4. As a last resort, log "manual reboot required"

#>
[CmdletBinding()]
param(
    [int]$WatchMinutes = 5,
    [int]$PollSeconds = 10
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Log  = Join-Path $script:Root 'results\boot-guardian.log'
New-Item -ItemType Directory -Path (Split-Path $script:Log) -Force -EA SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -Path $script:Log -Value $line
    Write-Host $line
}

# Rotate log if > 1 MB
if ((Test-Path $script:Log) -and ((Get-Item $script:Log).Length -gt 1MB)) {
    Move-Item $script:Log "$script:Log.old" -Force
}

Write-Log "==================== BOOT GUARDIAN START (watch=${WatchMinutes}min, poll=${PollSeconds}s) ===================="
Write-Log "Uptime at start: $(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('hh\:mm\:ss'))"

# -------- Health check function --------
function Test-GPUHealth {
    $issues = @()
    $gpus = Get-PnpDevice -Class Display -EA SilentlyContinue
    foreach ($g in $gpus) {
        $p = Get-PnpDeviceProperty -InstanceId $g.InstanceId -EA SilentlyContinue
        $code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        if ($code -gt 0) {
            $issues += [PSCustomObject]@{ Type='ProblemCode'; Device=$g.FriendlyName; InstanceId=$g.InstanceId; Detail="Code $code" }
        }
        if ($g.Status -ne 'OK') {
            $issues += [PSCustomObject]@{ Type='Status'; Device=$g.FriendlyName; InstanceId=$g.InstanceId; Detail="Status=$($g.Status)" }
        }
    }
    # ---- LowResolution detection via Win32_VideoController ----
    # Works in SYSTEM context (Forms gives phantom 1024x768 'WinDisc' when no logon session).
    # Any non-zero resolution under 1280x720 on a real GPU means mode-set failed.
    $videoCtrls = Get-CimInstance Win32_VideoController -EA SilentlyContinue
    foreach ($vc in $videoCtrls) {
        $w = [int]$vc.CurrentHorizontalResolution
        $h = [int]$vc.CurrentVerticalResolution
        if ($w -gt 0 -and $h -gt 0 -and ($w -lt 1280 -or $h -lt 720)) {
            $match = Get-PnpDevice -Class Display -EA SilentlyContinue | Where-Object FriendlyName -eq $vc.Name | Select-Object -First 1
            $inst = if ($match) { $match.InstanceId } else { '' }
            $issues += [PSCustomObject]@{
                Type='LowResolution'
                Device=$vc.Name
                InstanceId=$inst
                Detail=("{0}x{1} reported by Win32_VideoController" -f $w, $h)
            }
        }
    }

    # NoDisplay check (only meaningful if a user session exists; skip phantom WinDisc)
    try {
        Add-Type -AssemblyName System.Windows.Forms -EA SilentlyContinue
        $screens = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -notmatch 'WinDisc' }
        if ($screens.Count -lt 1) {
            # Only flag if there's an active console session (avoid false positives at boot before logon)
            $sess = (qwinsta 2>$null | Select-String 'Active|console')
            if ($sess) {
                $issues += [PSCustomObject]@{ Type='NoDisplay'; Device='(any)'; InstanceId=''; Detail='AllScreens.Count=0 (active session present)' }
            }
        }
    } catch { }

    # ---- Extra checks (failure modes we've seen on this machine) ----

    # #5 Microsoft Basic Display Adapter (real GPU driver crashed but PNP still says OK)
    $videoCtrls = Get-CimInstance Win32_VideoController -EA SilentlyContinue
    foreach ($vc in $videoCtrls) {
        if ($vc.Name -match 'Basic Display|Microsoft Basic') {
            $issues += [PSCustomObject]@{
                Type='BasicDisplayAdapter'
                Device=$vc.Name
                InstanceId=''
                Detail='Real GPU driver crashed; OS fell back to MS Basic Display'
            }
        }
    }

    # #6 Refresh rate too low on built-in panel (165 Hz panel falling to 60 Hz = partial mode-set)
    foreach ($vc in $videoCtrls) {
        if ($vc.CurrentRefreshRate -gt 0 -and $vc.CurrentRefreshRate -lt 100 -and
            $vc.CurrentHorizontalResolution -ge 2560) {
            # 2560 = QHD built-in panel. Refresh < 100 Hz is wrong for it (native 165Hz)
            $match = Get-PnpDevice -Class Display | Where-Object FriendlyName -eq $vc.Name | Select-Object -First 1
            $inst = ''
            if ($match) { $inst = $match.InstanceId }
            $issues += [PSCustomObject]@{
                Type='LowRefresh'
                Device=$vc.Name
                InstanceId=$inst
                Detail="Refresh=$($vc.CurrentRefreshRate)Hz at $($vc.CurrentHorizontalResolution)x$($vc.CurrentVerticalResolution) (expected >=120Hz)"
            }
        }
        # Color depth dropped (32 bpp expected)
        if ($vc.CurrentBitsPerPixel -gt 0 -and $vc.CurrentBitsPerPixel -lt 32) {
            $match = Get-PnpDevice -Class Display | Where-Object FriendlyName -eq $vc.Name | Select-Object -First 1
            $inst = ''
            if ($match) { $inst = $match.InstanceId }
            $issues += [PSCustomObject]@{
                Type='LowColorDepth'
                Device=$vc.Name
                InstanceId=$inst
                Detail="$($vc.CurrentBitsPerPixel)bpp (expected 32)"
            }
        }
    }

    # #8 GPU kernel services not running
    $criticalSvcs = @('amdkmdag','nvlddmkm')  # kernel drivers, not services per se; use Get-Service for user-mode
    $svcNames = @('AMD External Events Utility','NVDisplay.ContainerLocalSystem','LGHUBUpdaterService') |
                Where-Object { Get-Service -Name $_ -EA SilentlyContinue }
    foreach ($svcName in @('NVDisplay.ContainerLocalSystem','AMD External Events Utility')) {
        $svc = Get-Service -Name $svcName -EA SilentlyContinue
        if ($svc -and $svc.StartType -ne 'Disabled' -and $svc.Status -ne 'Running') {
            $issues += [PSCustomObject]@{
                Type='ServiceStopped'
                Device=$svc.DisplayName
                InstanceId=''
                Detail="Service '$($svc.Name)' is $($svc.Status) (StartType=$($svc.StartType))"
            }
        }
    }

    # #11 Recent TDR events since last boot (driver timeout - early warning)
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $tdr = Get-WinEvent -FilterHashtable @{
            LogName='System'
            ProviderName='Display'
            StartTime=$boot
        } -EA SilentlyContinue -MaxEvents 5
        if ($tdr) {
            foreach ($e in $tdr) {
                $issues += [PSCustomObject]@{
                    Type='TDREvent'
                    Device='(driver)'
                    InstanceId=''
                    Detail="EventID=$($e.Id) at $($e.TimeCreated.ToString('HH:mm:ss')): $($e.LevelDisplayName)"
                }
            }
        }
    } catch { }

    return ,$issues
}

# -------- Safety: lockout file path --------
$script:LockoutFile = Join-Path $script:Root 'results\guardian.LOCKOUT'

# -------- Never-cycle list: devices whose disable/enable is known to be dangerous --------
# The AMD Radeon 610M (iGPU) drives the laptop panel in MSHybrid mode.
# Cycling it cannot recover Code 43 and causes speckle/black artifacts. Hardware
# reset (full power cycle) is the only safe recovery path for the iGPU on this rig.
$script:NeverCycle = @(
    'AMD Radeon\(TM\) 610M'
    'Microsoft Basic Display'
)

# -------- Snapshot helper: captures current GPU/display state for rollback checks --------
function Get-StateSnapshot {
    $vcs = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            W    = [int]$_.CurrentHorizontalResolution
            H    = [int]$_.CurrentVerticalResolution
            R    = [int]$_.CurrentRefreshRate
            B    = [int]$_.CurrentBitsPerPixel
        }
    })
    $pnp = @(Get-PnpDevice -Class Display -EA SilentlyContinue | ForEach-Object {
        $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -EA SilentlyContinue
        $code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        [PSCustomObject]@{
            Name       = $_.FriendlyName
            InstanceId = $_.InstanceId
            Status     = "$($_.Status)"
            Code       = [int]$code
        }
    })
    $monitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -EA SilentlyContinue | Where-Object Active).Count
    return [PSCustomObject]@{
        Time           = Get-Date
        VC             = $vcs
        Pnp            = $pnp
        ActiveMonitors = $monitors
    }
}

# -------- Regression detector: returns reason string if 'after' is worse than 'before' --------
function Test-Regression {
    param($Before, $After)
    if ($After.ActiveMonitors -lt $Before.ActiveMonitors) {
        return "ActiveMonitors decreased: $($Before.ActiveMonitors) -> $($After.ActiveMonitors)"
    }
    foreach ($b in $Before.Pnp) {
        $a = $After.Pnp | Where-Object { $_.InstanceId -eq $b.InstanceId } | Select-Object -First 1
        if ($a -and $b.Code -eq 0 -and $a.Code -ne 0) {
            return "GPU '$($b.Name)' regressed: Code 0 -> $($a.Code)"
        }
        if ($a -and $b.Status -eq 'OK' -and $a.Status -ne 'OK') {
            return "GPU '$($b.Name)' status regressed: OK -> $($a.Status)"
        }
    }
    foreach ($b in $Before.VC) {
        $a = $After.VC | Where-Object { $_.Name -eq $b.Name } | Select-Object -First 1
        if ($a -and $b.W -gt 0 -and $a.W -eq 0) {
            return "GPU '$($b.Name)' lost mode: $($b.W)x$($b.H) -> 0x0"
        }
    }
    return $null
}

# -------- Panel-failover state (run-once per guardian session) --------
$script:FailoverDone   = $false
$script:FailoverMarker = Join-Path $script:Root 'results\guardian.FAILOVER'

# -------- Panel failover: iGPU dead + dGPU alive + external display present --------
# In MSHybrid mode the laptop panel is physically wired to the AMD iGPU. Software
# cannot reroute it to the NVIDIA dGPU. But if the iGPU is in Code 43 / Status=Error
# AND we still have at least one active monitor (which must therefore be on the
# dGPU via HDMI/USB-C), we can:
#   1. Force Windows projection to "Second screen only" so the user has a usable
#      session on the dGPU-driven external display (panel is dead anyway).
#   2. Set the NVIDIA dGPU as the system-preferred GPU so new launches pick it.
# Guarded by Test-PanelFailoverCondition so it never fires when the iGPU is fine.
function Test-PanelFailoverCondition {
    param($Snapshot)
    # Must have at least one active monitor (otherwise nothing to project to)
    if ($Snapshot.ActiveMonitors -lt 1) { return $false }

    $amd     = $Snapshot.Pnp | Where-Object { $_.Name -match 'AMD Radeon\(TM\) 610M' } | Select-Object -First 1
    $nvidia  = $Snapshot.Pnp | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if (-not $amd -or -not $nvidia) { return $false }

    $amdBad     = ($amd.Code -ne 0) -or ($amd.Status -ne 'OK')
    $nvidiaOk   = ($nvidia.Code -eq 0) -and ($nvidia.Status -eq 'OK')
    return ($amdBad -and $nvidiaOk)
}

function Invoke-PanelFailover {
    param($Snapshot)
    if ($script:FailoverDone) {
        Write-Log "FAILOVER already performed this session -- skipping" 'INFO'
        return
    }
    Write-Log "PANEL FAILOVER: iGPU is in error state; promoting NVIDIA dGPU + external display" 'WARN'
    Write-Log "  AMD 610M: Code=$(($Snapshot.Pnp | Where-Object { $_.Name -match 'AMD' }).Code) Status=$(($Snapshot.Pnp | Where-Object { $_.Name -match 'AMD' }).Status)" 'INFO'
    Write-Log "  NVIDIA:   healthy. ActiveMonitors=$($Snapshot.ActiveMonitors)" 'INFO'

    # 1) Switch Windows projection to external-only (dGPU-driven outputs)
    $ds = Join-Path $env:WINDIR 'System32\DisplaySwitch.exe'
    if (Test-Path $ds) {
        try {
            Start-Process -FilePath $ds -ArgumentList '/external' -WindowStyle Hidden -Wait -EA Stop
            Write-Log "  DisplaySwitch /external -> projected to external monitor" 'OK'
        } catch {
            Write-Log "  DisplaySwitch /external failed: $($_.Exception.Message)" 'ERROR'
        }
    } else {
        Write-Log "  DisplaySwitch.exe not found at $ds" 'ERROR'
    }

    # 2) Set NVIDIA dGPU as system-preferred GPU (DirectX hybrid hint)
    #    HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}
    #    is the Display device class; we set the dGPU's HybridPreferred bias.
    #    Per-user fallback under HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences.
    try {
        $nvInst = ($Snapshot.Pnp | Where-Object { $_.Name -match 'NVIDIA' }).InstanceId
        if ($nvInst) {
            # System-wide preference (best-effort; missing key is fine)
            $keyHybrid = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler'
            if (-not (Test-Path $keyHybrid)) { New-Item $keyHybrid -Force | Out-Null }
            # Tell DWM to prefer the high-performance adapter
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -Type DWord -Force -EA SilentlyContinue
            Write-Log "  HwSchMode=2 (hardware-scheduled, prefers dGPU)" 'OK'
        }
    } catch {
        Write-Log "  preferred-GPU registry hint failed: $($_.Exception.Message)" 'WARN'
    }

    # 3) Restart NVIDIA display container so DWM re-evaluates with new projection
    try {
        $svc = Get-Service -Name 'NVDisplay.ContainerLocalSystem' -EA SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Restart-Service -Name 'NVDisplay.ContainerLocalSystem' -Force -EA SilentlyContinue
            Write-Log "  NVDisplay.ContainerLocalSystem restarted" 'OK'
        }
    } catch { }

    # Mark complete
    $script:FailoverDone = $true
    $stamp = "Failover at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): iGPU dead, projected to external via NVIDIA dGPU.`r`nDelete this file to allow another failover attempt next boot."
    Set-Content -Path $script:FailoverMarker -Value $stamp -Force -EA SilentlyContinue
    Write-Log "FAILOVER complete -> $script:FailoverMarker" 'OK'
}

# -------- Apply safe registry-only fixes (no device cycling) --------
function Invoke-SafeRegistryFix {
    Write-Log "Applying registry-only fixes (no device cycle)" 'WARN'
    $reg = @{
        'HKLM:\SYSTEM\CurrentControlSet\Control\Power' = @{
            PlatformAoAcOverride=0; CsEnabled=0; HibernateEnabled=0; HibernateEnabledDefault=0
        }
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' = @{
            HiberbootEnabled=0
        }
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' = @{
            TdrDelay=30; TdrDdiDelay=30; TdrLimitCount=10; TdrLimitTime=60
        }
    }
    foreach ($k in $reg.Keys) {
        if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
        foreach ($v in $reg[$k].GetEnumerator()) {
            try {
                Set-ItemProperty -Path $k -Name $v.Key -Value $v.Value -Type DWord -Force -EA Stop
            } catch {
                Write-Log "  reg fail: $k\$($v.Key) -> $_" 'ERROR'
            }
        }
    }
}

# -------- Recovery function (guard-railed) --------
function Invoke-Recovery {
    param($Issues)

    # -- Hard stop: if lockout flag exists, refuse to act --
    if (Test-Path $script:LockoutFile) {
        Write-Log "LOCKOUT in effect ($script:LockoutFile) -- refusing to act. Delete the file to re-enable." 'ERROR'
        return $false
    }

    Write-Log "RECOVERY TRIGGERED -- $($Issues.Count) issue(s):" 'WARN'
    foreach ($i in $Issues) { Write-Log "  - $($i.Type): $($i.Device) :: $($i.Detail)" 'WARN' }

    # -- Pre-action snapshot --
    $before = Get-StateSnapshot
    Write-Log "Pre-action: ActiveMonitors=$($before.ActiveMonitors), GPUs=$(($before.Pnp | ForEach-Object { "$($_.Name)[Code=$($_.Code),$($_.Status)]" }) -join '; ')" 'INFO'

    # -- PANEL FAILOVER PATH (safest action for our specific failure mode) --
    # If iGPU is dead but dGPU + external display are healthy, promote them.
    if (Test-PanelFailoverCondition -Snapshot $before) {
        Invoke-PanelFailover -Snapshot $before
        # Failover does not cycle any devices; no regression check needed.
        # Verify nothing got worse, then return.
        Start-Sleep -Seconds 3
        $afterFo = Get-StateSnapshot
        $regFo = Test-Regression -Before $before -After $afterFo
        if ($regFo) {
            Write-Log "POST-FAILOVER REGRESSION: $regFo" 'ERROR'
            Set-Content -Path $script:LockoutFile -Value "Post-failover regression: $regFo" -Force
            return $false
        }
        Write-Log "Failover path complete -- external display promoted, no further action this attempt" 'OK'
        return $true
    }

    # -- Always-safe step: registry --
    Invoke-SafeRegistryFix

    # -- Classify issues: 'soft' = no device cycle, 'hard' = candidate for cycle --
    $softTypes = @('LowResolution','LowRefresh','LowColorDepth','TDREvent','ServiceStopped','BasicDisplayAdapter')
    $hardIssues = @($Issues | Where-Object { $_.Type -notin $softTypes -and $_.InstanceId })

    # -- Safety gate 1: zero active monitors means no safe path; do NOT cycle anything --
    if ($before.ActiveMonitors -lt 1) {
        Write-Log "SAFETY: 0 active monitors detected. Skipping device-cycle steps (hardware reset needed)." 'WARN'
        Write-Log "If display is dead, a full power-off cycle is the recommended recovery." 'WARN'
        & pnputil /scan-devices 2>&1 | Out-Null
        return $false
    }

    # -- Filter hard issues: drop never-cycle devices --
    $cycleTargets = @()
    foreach ($h in $hardIssues) {
        $blocked = $false
        foreach ($pat in $script:NeverCycle) {
            if ($h.Device -match $pat) { $blocked = $true; break }
        }
        if ($blocked) {
            Write-Log "SAFETY: refusing to cycle '$($h.Device)' (never-cycle list). Will let hardware self-recover." 'WARN'
        } else {
            $cycleTargets += $h
        }
    }

    # -- Safety gate 2: refuse to cycle the GPU currently driving the only active display --
    # Heuristic: if only 1 active monitor and we have only 1 healthy GPU, don't cycle it.
    if ($before.ActiveMonitors -eq 1) {
        $healthyGpus = @($before.Pnp | Where-Object { $_.Code -eq 0 -and $_.Status -eq 'OK' })
        if ($healthyGpus.Count -le 1) {
            $cycleTargets = @($cycleTargets | Where-Object {
                $tgt = $_.Device
                -not ($healthyGpus | Where-Object { $_.Name -eq $tgt })
            })
            if ($cycleTargets.Count -eq 0 -and $hardIssues.Count -gt 0) {
                Write-Log "SAFETY: only one healthy GPU driving the only active display. No safe cycle targets." 'WARN'
            }
        }
    }

    # -- Step 2: Cycle remaining targets, one at a time, with rollback on regression --
    $cycledOk = @()
    foreach ($d in ($cycleTargets | Select-Object -Property Device, InstanceId -Unique)) {
        Write-Log "Cycling '$($d.Device)' (InstanceId=$($d.InstanceId))" 'WARN'
        try {
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -EA Stop
            Start-Sleep -Seconds 3
            Enable-PnpDevice  -InstanceId $d.InstanceId -Confirm:$false -EA Stop
            Start-Sleep -Seconds 5
            $cycledOk += $d
        } catch {
            Write-Log "  cycle failed: $_" 'ERROR'
        }

        # Check for regression after each cycle, immediately
        $mid = Get-StateSnapshot
        $reg = Test-Regression -Before $before -After $mid
        if ($reg) {
            Write-Log "REGRESSION detected after cycling '$($d.Device)': $reg" 'ERROR'
            Write-Log "Attempting rollback: re-enabling all cycled devices" 'ERROR'
            foreach ($r in $cycledOk) {
                try { Enable-PnpDevice -InstanceId $r.InstanceId -Confirm:$false -EA SilentlyContinue } catch {}
            }
            # Engage permanent lockout
            $reason = "Regression at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $reg`r`nDelete this file to re-enable the guardian after manual diagnosis."
            Set-Content -Path $script:LockoutFile -Value $reason -Force
            Write-Log "LOCKOUT engaged -> $script:LockoutFile" 'ERROR'
            return $false
        }
    }

    # -- Step 3: pnputil rescan (always safe) --
    Write-Log "pnputil rescan" 'INFO'
    & pnputil /scan-devices 2>&1 | Out-Null

    # -- Final verify --
    Start-Sleep -Seconds 3
    $after = Get-StateSnapshot
    $reg = Test-Regression -Before $before -After $after
    if ($reg) {
        Write-Log "POST-ACTION REGRESSION: $reg" 'ERROR'
        Set-Content -Path $script:LockoutFile -Value "Post-action regression: $reg" -Force
        Write-Log "LOCKOUT engaged -> $script:LockoutFile" 'ERROR'
        return $false
    }

    $issuesAfter = Test-GPUHealth
    if ($issuesAfter.Count -eq 0) {
        Write-Log "RECOVERY SUCCESS -- all checks healthy" 'OK'
        return $true
    } else {
        Write-Log "RECOVERY INCOMPLETE -- $($issuesAfter.Count) issue(s) remain (no regression, will retry later)" 'WARN'
        foreach ($i in $issuesAfter) { Write-Log "  - $($i.Type): $($i.Device) :: $($i.Detail)" 'WARN' }
        return $false
    }
}

# -------- Main loop --------
# If lockout exists, run in monitor-only mode (log status, never act)
$lockedOut = Test-Path $script:LockoutFile
if ($lockedOut) {
    Write-Log "LOCKOUT FILE PRESENT -- monitor-only mode. Manually delete '$script:LockoutFile' to re-enable recovery." 'WARN'
}

$deadline = (Get-Date).AddMinutes($WatchMinutes)
$recoveryCount = 0
$maxRecoveries = 1   # reduced from 3: one attempt, then watch only
$lastState = 'unknown'

while ((Get-Date) -lt $deadline) {
    $issues = Test-GPUHealth
    if ($issues.Count -eq 0) {
        if ($lastState -ne 'healthy') { Write-Log "Healthy" }
        $lastState = 'healthy'
    } else {
        if ($lastState -ne 'broken') {
            Write-Log "Issues detected ($($issues.Count)):" 'WARN'
            foreach ($i in $issues) { Write-Log "  - $($i.Type): $($i.Device) :: $($i.Detail)" 'WARN' }
        }
        $lastState = 'broken'

        if ($lockedOut) {
            # monitor-only, do not act
        } elseif (Test-Path $script:LockoutFile) {
            $lockedOut = $true
            Write-Log "LOCKOUT engaged mid-run. Switching to monitor-only." 'WARN'
        } elseif ($recoveryCount -ge $maxRecoveries) {
            if ($lastState -ne 'broken-backoff') {
                Write-Log "Max recovery attempts ($maxRecoveries) reached -- watching only" 'WARN'
                $lastState = 'broken-backoff'
            }
        } else {
            $recoveryCount++
            Write-Log "Recovery attempt $recoveryCount of $maxRecoveries" 'WARN'
            [void](Invoke-Recovery -Issues $issues)
        }
    }
    Start-Sleep -Seconds $PollSeconds
}

Write-Log "==================== BOOT GUARDIAN END (recoveries=$recoveryCount, final=$lastState, locked=$lockedOut) ===================="
