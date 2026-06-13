# Post-Ultimate state check: MUX, GPUs, active monitors, panel routing
$ErrorActionPreference = 'SilentlyContinue'
$out = "$PSScriptRoot\logs\state-after.log"
$null = New-Item -ItemType Directory -Path (Split-Path $out) -Force
function W($m){ $m | Tee-Object -FilePath $out -Append }
"==== STATE @ $(Get-Date -Format o) ====" | Set-Content $out

W "`n--- GPUs ---"
Get-CimInstance Win32_VideoController | ForEach-Object {
    W ("{0,-34} Status={1,-6} CfgErr={2} Res={3}x{4} Driver={5}" -f `
        $_.Name, $_.Status, $_.ConfigManagerErrorCode, `
        $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution, $_.DriverVersion)
}

W "`n--- GPU_MUX (DSTS 0x00090016) ---"
try {
    $atk = Get-WmiObject -Namespace root\wmi -Class AsusAtkWmi_WMNB
    $v = [uint32]($atk.DSTS(0x00090016)).device_status
    $present = [bool]($v -band 0x00010000)
    $state = $v -band 0xFF
    $mode = if ($state -eq 0) {'Ultimate/dGPU (panel -> NVIDIA)'} elseif ($state -eq 1) {'Optimus/MSHybrid (panel -> AMD)'} else {"unknown($state)"}
    W ("DSTS=0x{0:X8} present={1} state={2} => {3}" -f $v, $present, $state, $mode)
} catch { W "MUX read failed: $($_.Exception.Message)" }

W "`n--- Active monitors (WMI) ---"
$mons = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams
W ("Active monitor count: {0}" -f ($mons | Measure-Object).Count)

W "`n--- PnP display adapters status ---"
Get-PnpDevice -Class Display | ForEach-Object {
    W ("{0,-34} Status={1} Problem={2}" -f $_.FriendlyName, $_.Status, $_.ProblemCode)
}

W "`n--- AMD 610M present? ---"
$amd = Get-PnpDevice -Class Display | Where-Object FriendlyName -match 'AMD|Radeon'
if ($amd) { W ("AMD device: {0} Status={1} Problem={2}" -f $amd.FriendlyName, $amd.Status, $amd.ProblemCode) }
else { W "AMD Radeon 610M: NOT PRESENT (disabled/hidden by Ultimate mode)" }

W "`n==== DONE ===="
Get-Content $out
