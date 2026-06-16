<#
.SYNOPSIS
    Recover-Display.ps1 -- Escalating display-recovery engine for the ASUS ROG
    Strix G713PV (AMD Radeon 610M iGPU + NVIDIA RTX 4060 Laptop).

    Goal: get the built-in laptop panel lit "one way or another", then STOP.

.DESCRIPTION
    The built-in panel is MUXed to the NVIDIA RTX 4060 (Ultimate GPU mode), so
    it no longer depends on the AMD 610M iGPU. Two failure modes remain after a
    boot:
      A) Panel stuck at a generic 640x480 fallback (driver loaded but the native
         mode table wasn't bound). FIX: force native resolution -- instant, safe.
      B) Panel black (firmware/MUX init fault). FIX: a full COLD boot.
      C) Panel lit but stuck at a blind low resolution (e.g. 1024x768) with NO
         native mode table, because the NVIDIA dGPU trained the eDP link on a
         cold boot WITHOUT reading the panel's EDID. Step 1 has nothing native to
         switch to. FIX: recycle the NVIDIA adapter (disable -> rescan -> enable)
         to force a fresh EDID read, then bind native resolution -- instant, safe.

    This engine runs a single escalating ladder and re-checks panel health after
    every step. "Healthy" now means the internal panel is active AND at a usable
    (near-native) resolution -- a panel that is merely "on" at 640x480 is treated
    as not-yet-recovered. It exits the instant the panel is healthy. Cheap/safe
    software fixes run first; a reboot (restart, then a full cold shutdown if the
    restart did not clear it) is the LAST resort, with loop protection so it can
    never reboot endlessly.

    Ladder (stops at the first step that makes the panel usable):
      1. Force native resolution     ChangeDisplaySettingsEx (no admin)
      2. NVIDIA adapter recycle      EDID re-read            (admin)
      3. GPU stack reset             Win+Ctrl+Shift+B        (interactive)
      4. pnputil rescan + service    restart GPU svcs        (admin)
      5. AMD iGPU disable/enable     pnp cycle               (admin)
      6. DisplaySwitch mode-set      /extend,/clone          (interactive)
      7. Re-apply known-good registry TDR/power harden       (admin)
      8. Reboot ladder               restart -> cold off     (admin, last resort)

.PARAMETER NoReboot
    Run the software ladder only; never reboot. Use for live / manual recovery
    while you are mid-session.

.PARAMETER MaxRebootAttempts
    Automatic reboots allowed before giving up (loop protection). Default 2:
    one warm restart, then one full cold shutdown.

.PARAMETER StepSettleSeconds
    Seconds to let the graphics stack settle and re-enumerate after each step
    before re-checking panel health.

.NOTES
    Designed to run either:
      - interactively (manual recovery), or
      - from the Display_AutoRecover_ROG scheduled task, which runs as the
        logged-in user with Highest privileges (elevated, no UAC) so it can both
        inject the Win+Ctrl+Shift+B keystroke in the user session AND cycle
        devices / reboot.
#>
[CmdletBinding()]
param(
    [switch]$NoReboot,
    [int]$MaxRebootAttempts = 2,
    [int]$StepSettleSeconds = 8
)

$ErrorActionPreference = 'Continue'
$script:Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ResultsDir = Join-Path $script:Root 'results'
$script:Log        = Join-Path $script:ResultsDir 'recover-display.log'
$script:RebootState = Join-Path $script:ResultsDir 'reboot-state.json'
$script:AlertFile  = Join-Path $script:ResultsDir 'DISPLAY_ALERT.txt'
New-Item -ItemType Directory -Path $script:ResultsDir -Force -EA SilentlyContinue | Out-Null

# ---------------------------------------------------------------- logging ----
function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -Path $script:Log -Value $line -EA SilentlyContinue
    $color = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
    Write-Host $line -ForegroundColor $color
}

# Rotate log if > 1 MB
if ((Test-Path $script:Log) -and ((Get-Item $script:Log).Length -gt 1MB)) {
    Move-Item $script:Log "$script:Log.old" -Force -EA SilentlyContinue
}

function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ---------------------------------------------- resolution P/Invoke helpers ----
# In Ultimate (MUX -> NVIDIA) mode the most common boot failure is NOT a dead
# panel but the panel coming up stuck at a generic 640x480 fallback because the
# NVIDIA driver loaded without binding the panel's native mode table. This is
# fixed instantly and non-destructively with ChangeDisplaySettingsEx.
if (-not ('DisplayApi' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DisplayApi {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
        public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel;
        public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
        public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll")]
    public static extern bool EnumDisplaySettings(string dev, int n, ref DEVMODE dm);
    [DllImport("user32.dll")]
    public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
}
"@
}

# Enumerate every mode available on a device (default: primary \\.\DISPLAY1).
function Get-DisplayModes {
    param([string]$Device = '\\.\DISPLAY1')
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'DisplayApi+DEVMODE')
    $dm = New-Object DisplayApi+DEVMODE
    $dm.dmSize = [int16]$size
    $modes = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ([DisplayApi]::EnumDisplaySettings($Device, $i, [ref]$dm)) {
        $modes.Add([pscustomobject]@{ W=$dm.dmPelsWidth; H=$dm.dmPelsHeight; Hz=$dm.dmDisplayFrequency; Bpp=$dm.dmBitsPerPel })
        $i++
    }
    return $modes
}

# Current desktop mode of a device.
function Get-CurrentMode {
    param([string]$Device = '\\.\DISPLAY1')
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'DisplayApi+DEVMODE')
    $dm = New-Object DisplayApi+DEVMODE
    $dm.dmSize = [int16]$size
    if ([DisplayApi]::EnumDisplaySettings($Device, -1, [ref]$dm)) {
        return [pscustomobject]@{ W=$dm.dmPelsWidth; H=$dm.dmPelsHeight; Hz=$dm.dmDisplayFrequency; Bpp=$dm.dmBitsPerPel }
    }
    return $null
}

# ------------------------------------------------------ display state read ----
function Get-DisplayState {
    $amd = $null; $nv = $null

    foreach ($g in (Get-PnpDevice -Class Display -EA SilentlyContinue)) {
        $code = (Get-PnpDeviceProperty -InstanceId $g.InstanceId -EA SilentlyContinue |
                 Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        $rec = [PSCustomObject]@{
            Name = $g.FriendlyName; InstanceId = $g.InstanceId
            Status = "$($g.Status)"; Code = [int]$code; W = 0; H = 0; R = 0
        }
        if ($g.FriendlyName -match 'AMD|Radeon|ATI')         { $amd = $rec }
        elseif ($g.FriendlyName -match 'NVIDIA|GeForce|RTX') { $nv  = $rec }
    }

    foreach ($vc in (Get-CimInstance Win32_VideoController -EA SilentlyContinue)) {
        $target = $null
        if     ($amd -and $vc.Name -eq $amd.Name) { $target = $amd }
        elseif ($nv  -and $vc.Name -eq $nv.Name)  { $target = $nv }
        if ($target) {
            $target.W = [int]$vc.CurrentHorizontalResolution
            $target.H = [int]$vc.CurrentVerticalResolution
            $target.R = [int]$vc.CurrentRefreshRate
        }
    }

    # Active physical monitors
    $activeMonitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -EA SilentlyContinue |
                        Where-Object Active).Count

    # Is an INTERNAL-connection panel active? (panel lit via any GPU, incl. MUX/Ultimate)
    $internalActive = $false
    try {
        foreach ($cp in (Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -EA SilentlyContinue)) {
            # D3DKMDT_VOT_INTERNAL = 0x80000000 ; also treat the embedded/LVDS-ish low codes as internal
            $vot = [int64]([uint32]$cp.VideoOutputTechnology)
            if ($vot -eq 0x80000000 -or $vot -eq -2147483648) { $internalActive = $true; break }
        }
    } catch { }

    # Current desktop resolution of the primary display, and the panel's native
    # (max) resolution from its EDID. Used to detect the 640x480 stuck state.
    $cur = Get-CurrentMode
    $curW = if ($cur) { [int]$cur.W } else { 0 }
    $curH = if ($cur) { [int]$cur.H } else { 0 }

    # Get-CurrentMode (EnumDisplaySettings) can intermittently return 0x0 even
    # when the desktop is live and at native resolution. The per-GPU
    # Win32_VideoController resolution captured above is authoritative for the
    # active output, so fall back to the largest active-controller resolution
    # when the P/Invoke read comes back empty. Without this, the health check
    # sees CurrentW=0, declares the panel "down", and the scheduled task runs the
    # full (disruptive) ladder on every boot even when nothing is wrong.
    if ($curW -le 0) {
        foreach ($g in @($nv, $amd)) {
            if ($g -and [int]$g.W -gt $curW) { $curW = [int]$g.W; $curH = [int]$g.H }
        }
    }

    $nativeW = 0; $nativeH = 0
    try {
        $best = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -EA SilentlyContinue |
                ForEach-Object { $_.MonitorSourceModes } |
                Sort-Object -Property HorizontalActivePixels -Descending | Select-Object -First 1
        if ($best) { $nativeW = [int]$best.HorizontalActivePixels; $nativeH = [int]$best.VerticalActivePixels }
    } catch { }
    if ($nativeW -le 0) {
        # Fall back to the largest enumerable mode on the primary device.
        $bestMode = Get-DisplayModes | Sort-Object W,H -Descending | Select-Object -First 1
        if ($bestMode) { $nativeW = [int]$bestMode.W; $nativeH = [int]$bestMode.H }
    }

    [PSCustomObject]@{
        Amd = $amd; Nvidia = $nv
        ActiveMonitors = $activeMonitors
        InternalPanelActive = $internalActive
        CurrentW = $curW; CurrentH = $curH
        NativeW = $nativeW; NativeH = $nativeH
    }
}

# Panel is "healthy" only if the built-in screen is showing a USABLE image:
#   - an internal-connection panel is active (lit via AMD or NVIDIA/MUX), AND
#   - the desktop is at a real resolution, not a generic 640x480 fallback.
# A panel that is "on" but stuck at 640x480 is treated as UNHEALTHY so the
# resolution-fix step runs.
$script:MinHealthyWidth = 1280
function Test-PanelHealthy {
    param($State)

    $resOk = $State.CurrentW -ge $script:MinHealthyWidth
    # If we know the native width, also require we're within 90% of it (so a
    # panel forced to 1024x768 on a 2560-wide screen still counts as unhealthy).
    if ($State.NativeW -gt 0) {
        $resOk = $resOk -and ($State.CurrentW -ge [int]($State.NativeW * 0.9))
    }

    # Panel lit via the internal connection at a usable resolution.
    if ($State.InternalPanelActive -and $resOk) { return $true }

    # AMD path (Optimus): iGPU OK with a real mode AND usable resolution.
    if ($State.Amd -and $State.Amd.Code -eq 0 -and $State.Amd.Status -eq 'OK' -and $resOk) {
        return $true
    }
    return $false
}

function Write-State {
    param($State, [string]$Tag)
    $a = $State.Amd; $n = $State.Nvidia
    $as = if ($a) { "AMD[Code=$($a.Code),$($a.Status),$($a.W)x$($a.H)]" } else { 'AMD[absent]' }
    $ns = if ($n) { "NV[Code=$($n.Code),$($n.Status),$($n.W)x$($n.H)]" } else { 'NV[absent]' }
    Write-Log ("{0}: {1} {2} Monitors={3} InternalPanel={4} Desktop={5}x{6} Native={7}x{8}" -f `
        $Tag, $as, $ns, $State.ActiveMonitors, $State.InternalPanelActive, `
        $State.CurrentW, $State.CurrentH, $State.NativeW, $State.NativeH)
}

# ------------------------------------------------------- recovery actions ----

# Step 1 -- Force the panel to its native resolution. This is the primary,
# non-destructive fix for the Ultimate-mode 640x480 stuck state: the driver has
# the full mode table, the desktop just didn't bind to it. No admin required.
function Set-NativeResolution {
    param($State)
    Write-Log 'STEP 1: force native resolution (ChangeDisplaySettingsEx)' 'STEP'
    $dev = '\\.\DISPLAY1'
    $modes = Get-DisplayModes -Device $dev
    if (-not $modes -or $modes.Count -eq 0) {
        Write-Log '  no modes enumerable on primary device -- skipping (driver mode table empty)' 'WARN'
        return
    }

    # Prefer the panel's native resolution at the highest refresh; else the
    # largest available mode.
    $target = $null
    if ($State.NativeW -gt 0) {
        $target = $modes | Where-Object { $_.W -eq $State.NativeW -and $_.H -eq $State.NativeH } |
                  Sort-Object Hz -Descending | Select-Object -First 1
    }
    if (-not $target) {
        $target = $modes | Sort-Object W,H,Hz -Descending | Select-Object -First 1
    }
    if (-not $target) { Write-Log '  could not pick a target mode -- skipping' 'WARN'; return }

    # Already at (or above) target width? nothing to do.
    if ($State.CurrentW -ge $target.W) {
        Write-Log "  already at $($State.CurrentW)x$($State.CurrentH) (>= target $($target.W)) -- skipping" 'INFO'
        return
    }

    Write-Log "  applying $($target.W)x$($target.H)@$($target.Hz)Hz" 'INFO'
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'DisplayApi+DEVMODE')
    $set = New-Object DisplayApi+DEVMODE
    $set.dmSize = [int16]$size
    $set.dmDeviceName = $dev
    $set.dmPelsWidth = [int]$target.W
    $set.dmPelsHeight = [int]$target.H
    $set.dmBitsPerPel = 32
    $set.dmDisplayFrequency = [int]$target.Hz
    # DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL|DM_DISPLAYFREQUENCY
    $set.dmFields = 0x80000 -bor 0x100000 -bor 0x40000 -bor 0x400000
    # CDS_UPDATEREGISTRY = 0x01 (persist so the next boot keeps native)
    $r = [DisplayApi]::ChangeDisplaySettingsEx($dev, [ref]$set, [IntPtr]::Zero, 0x01, [IntPtr]::Zero)
    switch ($r) {
        0  { Write-Log '  resolution applied (SUCCESS)' 'OK' }
        1  { Write-Log '  applied but RESTART required' 'WARN' }
        default { Write-Log "  ChangeDisplaySettingsEx failed (code $r)" 'ERROR' }
    }
}

# Step 2 -- NVIDIA adapter recycle to force a panel EDID re-read. Admin.
# Cold-boot failure mode (observed 2026-06-16): in Ultimate mode the NVIDIA dGPU
# drives the built-in panel, but on some cold boots the eDP link trains without
# reading the panel's EDID. Result: no native mode table (only a few generic
# low-res entries like 1024x768), so Step 1 has nothing native to switch to and
# the panel sits at a blind fallback resolution. Disabling then re-enabling the
# NVIDIA adapter forces a fresh EDID read; the native mode table reappears and
# the desktop snaps back to native.
#
# SAFETY: in Ultimate mode the NVIDIA adapter is driving the ONLY active display,
# so disabling it blacks the screen. The re-enable is therefore done in a
# finally{} block with retries so the panel ALWAYS comes back even if a later
# line throws. Only runs when NVIDIA is the active output GPU.
function Invoke-NvidiaEdidRecycle {
    param($State)
    Write-Log 'STEP 2: NVIDIA adapter recycle (force panel EDID re-read)' 'STEP'
    if (-not (Test-IsAdmin)) { Write-Log '  not elevated -- skipping' 'WARN'; return }
    if (-not $State.Nvidia)  { Write-Log '  NVIDIA device not present -- skipping' 'WARN'; return }
    # Only meaningful when NVIDIA is actually driving an active output (Ultimate
    # mode). In Optimus the panel is on the AMD iGPU and this would not help.
    if ([int]$State.Nvidia.W -le 0) {
        Write-Log '  NVIDIA is not the active output GPU (Optimus?) -- skipping' 'WARN'
        return
    }

    $nvId = $State.Nvidia.InstanceId
    try {
        Write-Log "  disabling $($State.Nvidia.Name) (screen will blank briefly)" 'INFO'
        Disable-PnpDevice -InstanceId $nvId -Confirm:$false -EA Stop
        Start-Sleep -Seconds 3
        Write-Log '  rescanning hardware (pnputil /scan-devices)' 'INFO'
        & pnputil /scan-devices 2>&1 | Out-Null
        Start-Sleep -Seconds 1
    } catch {
        Write-Log "  disable/rescan error: $($_.Exception.Message)" 'WARN'
    } finally {
        # ALWAYS bring the adapter back, with retries, so we never leave the
        # only display disabled.
        $reEnabled = $false
        for ($i = 1; $i -le 5; $i++) {
            try {
                Enable-PnpDevice -InstanceId $nvId -Confirm:$false -EA Stop
                Write-Log "  NVIDIA adapter re-enabled (attempt $i)" 'OK'
                $reEnabled = $true
                break
            } catch {
                Write-Log "  re-enable attempt $i failed: $($_.Exception.Message)" 'WARN'
                Start-Sleep -Seconds 2
            }
        }
        if (-not $reEnabled) {
            Write-Log '  CRITICAL: could not re-enable NVIDIA adapter -- a reboot will restore it.' 'ERROR'
        }
    }

    # Let the EDID re-read and mode table rebuild, then bind native resolution.
    Start-Sleep -Seconds 5
    $fresh = Get-DisplayState
    Set-NativeResolution -State $fresh
}

# Step 3 -- GPU stack reset (Win+Ctrl+Shift+B). Requires an interactive session.
function Invoke-GraphicsStackReset {
    Write-Log 'STEP 1: GPU stack reset (Win+Ctrl+Shift+B)' 'STEP'
    if ([Environment]::UserInteractive -eq $false) {
        Write-Log '  session is non-interactive; keystroke cannot reach the desktop -- skipping' 'WARN'
        return
    }
    try {
        if (-not ('Win32KbdInput' -as [type])) {
            Add-Type -Namespace '' -Name 'Win32KbdInput' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
'@
        }
        $KEYUP = 0x2
        $WIN = 0x5B; $CTRL = 0x11; $SHIFT = 0x10; $B = 0x42
        foreach ($k in @($WIN,$CTRL,$SHIFT,$B)) { [Win32KbdInput]::keybd_event($k,0,0,[UIntPtr]::Zero) }
        Start-Sleep -Milliseconds 120
        foreach ($k in @($B,$SHIFT,$CTRL,$WIN)) { [Win32KbdInput]::keybd_event($k,0,$KEYUP,[UIntPtr]::Zero) }
        Write-Log '  Win+Ctrl+Shift+B injected' 'OK'
    } catch {
        Write-Log "  keystroke injection failed: $($_.Exception.Message)" 'ERROR'
    }
}

# Step 2 -- AMD iGPU disable/enable cycle. Requires admin.
function Invoke-AmdDeviceCycle {
    param($State)
    Write-Log 'STEP 2: AMD iGPU disable/enable cycle' 'STEP'
    if (-not (Test-IsAdmin)) { Write-Log '  not elevated -- skipping' 'WARN'; return }
    if (-not $State.Amd)      { Write-Log '  AMD device not present -- skipping' 'WARN'; return }
    try {
        Write-Log "  disabling $($State.Amd.Name)" 'INFO'
        Disable-PnpDevice -InstanceId $State.Amd.InstanceId -Confirm:$false -EA Stop
        Start-Sleep -Seconds 3
        Write-Log "  enabling $($State.Amd.Name)" 'INFO'
        Enable-PnpDevice -InstanceId $State.Amd.InstanceId -Confirm:$false -EA Stop
        Write-Log '  cycle issued' 'OK'
    } catch {
        Write-Log "  AMD cycle failed: $($_.Exception.Message)" 'ERROR'
    }
}

# Step 3 -- pnputil hardware rescan + restart GPU user-mode services. Admin.
function Invoke-RescanAndServices {
    Write-Log 'STEP 3: pnputil rescan + restart GPU services' 'STEP'
    if (-not (Test-IsAdmin)) { Write-Log '  not elevated -- skipping' 'WARN'; return }
    try { & pnputil /scan-devices 2>&1 | Out-Null; Write-Log '  pnputil /scan-devices done' 'OK' }
    catch { Write-Log "  pnputil failed: $($_.Exception.Message)" 'WARN' }
    foreach ($svcName in @('AMD External Events Utility','NVDisplay.ContainerLocalSystem')) {
        $svc = Get-Service -Name $svcName -EA SilentlyContinue
        if ($svc -and $svc.StartType -ne 'Disabled') {
            try { Restart-Service -Name $svcName -Force -EA Stop; Write-Log "  restarted '$svcName'" 'OK' }
            catch { Write-Log "  restart '$svcName' failed: $($_.Exception.Message)" 'WARN' }
        }
    }
}

# Step 4 -- DisplaySwitch mode-set cycle. Interactive session.
function Invoke-DisplaySwitchCycle {
    Write-Log 'STEP 4: DisplaySwitch mode-set cycle' 'STEP'
    $ds = Join-Path $env:WINDIR 'System32\DisplaySwitch.exe'
    if (-not (Test-Path $ds)) { Write-Log '  DisplaySwitch.exe not found -- skipping' 'WARN'; return }
    # NOTE: never use /internal here -- if the panel is still dead it also kills
    # any external/remote display, cutting off the only working screen. /extend
    # and /clone force a mode-set on the panel while keeping the external alive.
    foreach ($mode in @('/extend','/clone','/extend')) {
        try {
            Start-Process -FilePath $ds -ArgumentList $mode -WindowStyle Hidden -Wait -EA Stop
            Write-Log "  DisplaySwitch $mode" 'OK'
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "  DisplaySwitch $mode failed: $($_.Exception.Message)" 'WARN'
        }
    }
}

# Step 5 -- Re-apply known-good registry (TDR, power, fast-startup off). Admin.
function Set-KnownGoodRegistry {
    Write-Log 'STEP 5: re-apply known-good registry (harden for next boot)' 'STEP'
    if (-not (Test-IsAdmin)) { Write-Log '  not elevated -- skipping' 'WARN'; return }
    $reg = @{
        'HKLM:\SYSTEM\CurrentControlSet\Control\Power' = @{
            PlatformAoAcOverride = 0; CsEnabled = 0; HibernateEnabled = 0; HibernateEnabledDefault = 0
        }
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' = @{ HiberbootEnabled = 0 }
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' = @{
            TdrDelay = 30; TdrDdiDelay = 30; TdrLimitCount = 10; TdrLimitTime = 60
        }
    }
    foreach ($k in $reg.Keys) {
        if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
        foreach ($v in $reg[$k].GetEnumerator()) {
            try { Set-ItemProperty -Path $k -Name $v.Key -Value $v.Value -Type DWord -Force -EA Stop }
            catch { Write-Log "  reg fail $k\$($v.Key): $($_.Exception.Message)" 'WARN' }
        }
    }
    Write-Log '  registry applied' 'OK'
}

# ---------------------------------------------------- reboot ladder (last) ----
function Get-RebootState {
    if (Test-Path $script:RebootState) {
        try { return Get-Content $script:RebootState -Raw | ConvertFrom-Json } catch { }
    }
    return [PSCustomObject]@{ Count = 0; LastAttemptUtc = $null; LastReason = $null }
}
function Save-RebootState { param($S) $S | ConvertTo-Json | Set-Content -Path $script:RebootState -Force -EA SilentlyContinue }
function Clear-RebootState { Remove-Item $script:RebootState -Force -EA SilentlyContinue }

function Invoke-RebootLadder {
    Write-Log 'STEP 6: reboot ladder (last resort)' 'STEP'
    if (-not (Test-IsAdmin)) {
        Write-Log '  not elevated -- cannot reboot. Manual cold boot needed.' 'ERROR'
        return
    }
    $st = Get-RebootState
    if ([int]$st.Count -ge $MaxRebootAttempts) {
        $msg = "Auto-recovery exhausted after $($st.Count) reboot(s); panel still not usable. " +
               'Panel is MUXed to the NVIDIA RTX 4060 (Ultimate). If still black, do a full ' +
               'COLD shutdown (hold power 10s -> off -> press power) which clears any iGPU/MUX ' +
               'init fault; if low-res, run Recover-Display.ps1 -NoReboot to force native resolution.'
        Write-Log "  $msg" 'ERROR'
        Set-Content -Path $script:AlertFile -Value ("{0}`r`n{1}" -f (Get-Date), $msg) -Force -EA SilentlyContinue
        return
    }
    $attempt = [int]$st.Count + 1
    $st.Count = $attempt
    $st.LastAttemptUtc = (Get-Date).ToUniversalTime().ToString('o')

    if ($attempt -lt $MaxRebootAttempts) {
        $st.LastReason = 'warm restart'
        Save-RebootState $st
        Write-Log "  attempt $attempt/$MaxRebootAttempts -> RESTART to clear Code 43" 'WARN'
        Start-Process shutdown.exe -ArgumentList '/r','/t','8','/c','Display auto-recovery: restarting to clear AMD Code 43' -WindowStyle Hidden
    } else {
        $st.LastReason = 'cold shutdown'
        Save-RebootState $st
        $note = 'Display auto-recovery: full COLD shutdown. After it powers off, press the power button to cold-boot (this clears AMD Code 43).'
        Write-Log "  attempt $attempt/$MaxRebootAttempts -> COLD SHUTDOWN (press power to boot)" 'WARN'
        Set-Content -Path $script:AlertFile -Value ("{0}`r`n{1}" -f (Get-Date), $note) -Force -EA SilentlyContinue
        Start-Process shutdown.exe -ArgumentList '/s','/t','8','/c','Display auto-recovery: full shutdown. Press power to cold-boot.' -WindowStyle Hidden
    }
}

# ============================================================= main ==========
Write-Log '==================== RECOVER-DISPLAY START ====================' 'INFO'
Write-Log ("Elevated={0} Interactive={1} NoReboot={2} MaxReboots={3}" -f (Test-IsAdmin), [Environment]::UserInteractive, [bool]$NoReboot, $MaxRebootAttempts)

$state = Get-DisplayState
Write-State $state 'Initial'

if (Test-PanelHealthy -State $state) {
    Write-Log 'Panel already healthy -- nothing to do.' 'OK'
    Clear-RebootState
    Write-Log '==================== RECOVER-DISPLAY END (already-healthy) ====================' 'OK'
    return
}

Write-Log 'Built-in panel is DOWN -- starting escalation ladder.' 'WARN'

# Software ladder. Re-check health after each step; stop the instant it's lit.
# Order is cheapest/most-likely-first: resolution fix (the common Ultimate-mode
# 640x480 case) before any GPU cycling or reboot.
$softwareSteps = @(
    { Set-NativeResolution -State $state }
    { Invoke-NvidiaEdidRecycle -State $state }
    { Invoke-GraphicsStackReset }
    { Invoke-RescanAndServices }
    { Invoke-AmdDeviceCycle -State $state }
    { Invoke-DisplaySwitchCycle }
    { Set-KnownGoodRegistry }
)

$stepNum = 0
foreach ($step in $softwareSteps) {
    $stepNum++
    & $step
    Start-Sleep -Seconds $StepSettleSeconds
    $state = Get-DisplayState
    Write-State $state "After step $stepNum"
    if (Test-PanelHealthy -State $state) {
        Write-Log "RECOVERY SUCCESS after software step $stepNum -- panel is lit. Stopping." 'OK'
        Clear-RebootState
        Write-Log '==================== RECOVER-DISPLAY END (recovered) ====================' 'OK'
        return
    }
}

Write-Log 'Software ladder exhausted -- panel still dead.' 'WARN'

if ($NoReboot) {
    Write-Log 'NoReboot set -- not rebooting. Manual cold boot (hold power 10s -> off -> power on) clears any iGPU/MUX init fault.' 'WARN'
    Set-Content -Path $script:AlertFile -Value ("{0}`r`nSoftware recovery failed. If the panel is BLACK do a full COLD shutdown (hold power 10s, then power on). If it is LOW-RES, the resolution fix could not enumerate modes -- restart and re-run." -f (Get-Date)) -Force -EA SilentlyContinue
    Write-Log '==================== RECOVER-DISPLAY END (software-exhausted) ====================' 'WARN'
    return
}

Invoke-RebootLadder
Write-Log '==================== RECOVER-DISPLAY END (reboot-escalated) ====================' 'WARN'
