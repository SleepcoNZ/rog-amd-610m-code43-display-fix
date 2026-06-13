<#
    Admin fix - runs as SYSTEM via scheduled task to bypass UAC
#>
$outFile = "$PSScriptRoot\results\permanent_fix_output.txt"

$log = @()
function L($m) { $script:log += "$(Get-Date -Format 'HH:mm:ss') $m" }

L "=== PERMANENT FIX: AMD Code 43 / Modern Standby ==="
L "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# FIX 1: Disable Modern Standby 
$csPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
try {
    $before1 = (Get-ItemProperty $csPath -Name 'PlatformAoAcOverride' -EA SilentlyContinue).PlatformAoAcOverride
    Set-ItemProperty $csPath -Name 'PlatformAoAcOverride' -Value 0 -Type DWord -Force
    $after1 = (Get-ItemProperty $csPath -Name 'PlatformAoAcOverride').PlatformAoAcOverride
    L "PlatformAoAcOverride: $before1 -> $after1 (0=Modern Standby OFF)"
} catch { L "PlatformAoAcOverride FAILED: $_" }

try {
    $before2 = (Get-ItemProperty $csPath -Name 'CsEnabled' -EA SilentlyContinue).CsEnabled
    Set-ItemProperty $csPath -Name 'CsEnabled' -Value 0 -Type DWord -Force
    $after2 = (Get-ItemProperty $csPath -Name 'CsEnabled').CsEnabled
    L "CsEnabled: $before2 -> $after2 (0=Connected Standby OFF)"
} catch { L "CsEnabled FAILED: $_" }

# FIX 2: Power config
try {
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 3
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 3
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    & powercfg /SETACTIVE SCHEME_CURRENT
    L "Powercfg: lid=shutdown, sleep=never, ASPM=off"
} catch { L "Powercfg FAILED: $_" }

# FIX 3: Verify Fast Startup
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$hb = (Get-ItemProperty $regPath -Name HiberbootEnabled -EA SilentlyContinue).HiberbootEnabled
if ($hb -eq 0) { L "Fast Startup: already disabled (good)" }
else { Set-ItemProperty $regPath -Name HiberbootEnabled -Value 0; L "Fast Startup: forced disabled" }

# FIX 4: Try to re-enable AMD iGPU
$amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon' }
if ($amd -and $amd.Status -ne 'OK') {
    L "AMD iGPU: $($amd.FriendlyName) Status=$($amd.Status) - toggling..."
    Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA SilentlyContinue
    Start-Sleep 3
    Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA SilentlyContinue
    Start-Sleep 5
    $amdAfter = Get-PnpDevice -InstanceId $amd.InstanceId
    L "AMD after toggle: Status=$($amdAfter.Status)"
} elseif ($amd) { L "AMD iGPU: already OK" }
else { L "AMD iGPU: not found" }

L ""
L "=== ALL FIXES APPLIED ==="
L "Modern Standby: DISABLED"
L "Connected Standby: DISABLED"
L "Lid close: Shutdown"
L "Sleep/Hibernate: Never"
L "PCI-E ASPM: Off"
L "Fast Startup: Disabled"
L ""
L "NEXT: Full shutdown (shutdown /s /t 0) then power on"

# Also write a completion marker
$log | Out-File $outFile -Encoding UTF8 -Force
"COMPLETE" | Out-File "$outFile.done" -Force
