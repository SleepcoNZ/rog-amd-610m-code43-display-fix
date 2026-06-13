# Probes ASUS GPU MUX exposure and System Control Interface install state
$out = @()
$out += "=== ASUS MUX / GPU Mode probe :: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$out += ""

# 1) ASUS System Control Interface driver
$out += "--- ASUS System Control Interface ---"
$asci = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.FriendlyName -match 'ASUS.*System Control|ASUS Optimization' -or $_.HardwareID -match 'AsusOptimization|ATKACPI' }
if ($asci) {
    foreach ($d in $asci) { $out += "  $($d.FriendlyName) :: Status=$($d.Status) :: $($d.InstanceId)" }
} else {
    $out += "  (none found)"
}
$out += ""

# 2) Armoury Crate / Service
$out += "--- Armoury Crate services ---"
Get-Service -EA SilentlyContinue | Where-Object { $_.Name -match 'Armoury|Asus|ROG' } | ForEach-Object {
    $out += "  $($_.Name) :: $($_.Status) :: $($_.DisplayName)"
}
$out += ""

# 3) ASUS WMI namespace probe
$out += "--- ASUS_WMI namespace ---"
$ns = Get-CimInstance -Namespace root -ClassName __Namespace -EA SilentlyContinue | Where-Object { $_.Name -match 'asus|wmi' -or $_.Name -eq 'WMI' }
foreach ($n in $ns) { $out += "  root\$($n.Name)" }
$out += ""

# 4) Look for AsusAtkWmiDeviceClass methods / DSTS / DEVS
$out += "--- root\WMI :: ASUS classes ---"
try {
    $cls = Get-CimClass -Namespace root\WMI -EA SilentlyContinue | Where-Object { $_.CimClassName -match 'Asus|ATK|Atk' }
    foreach ($c in $cls) { $out += "  $($c.CimClassName)" }
} catch { $out += "  (probe failed: $_)" }
$out += ""

# 5) Try the standard ATK DSTS query for GPU mode (id 0x00090018 historically on G-series)
$out += "--- ATK DSTS/DEVS GPU mode query ---"
$atkClassNames = @('AsusAtkWmiDeviceClass','ATK','AsusAtkWmi')
foreach ($cn in $atkClassNames) {
    try {
        $inst = Get-CimInstance -Namespace root\WMI -ClassName $cn -EA SilentlyContinue
        if ($inst) {
            $out += "  Class $cn instance found"
            try {
                $r = Invoke-CimMethod -InputObject $inst[0] -MethodName 'DSTS' -Arguments @{ arg0 = [uint32]0x00090018 } -EA SilentlyContinue
                $out += "  DSTS 0x00090018 -> $($r | ConvertTo-Json -Compress -Depth 3)"
            } catch { $out += "  DSTS call failed: $($_.Exception.Message)" }
            try {
                $r2 = Invoke-CimMethod -InputObject $inst[0] -MethodName 'DSTS' -Arguments @{ arg0 = [uint32]0x00090020 } -EA SilentlyContinue
                $out += "  DSTS 0x00090020 -> $($r2 | ConvertTo-Json -Compress -Depth 3)"
            } catch { }
        }
    } catch { }
}
$out += ""

# 6) Direct check: NVIDIA dGPU MUX state via Win32_VideoController + driver path
$out += "--- Display device adapter strings ---"
Get-CimInstance Win32_VideoController -EA SilentlyContinue | ForEach-Object {
    $out += "  $($_.Name)"
    $out += "    PNPDeviceID: $($_.PNPDeviceID)"
    $out += "    Avail: $($_.Availability)  ConfigManagerErrorCode: $($_.ConfigManagerErrorCode)"
    $out += "    VideoModeDesc: $($_.VideoModeDescription)"
}
$out += ""

# 7) Check display config: which adapter currently owns built-in panel target
$out += "--- Connected display targets (Get-CimInstance Win32_DesktopMonitor) ---"
Get-CimInstance Win32_DesktopMonitor -EA SilentlyContinue | ForEach-Object {
    $out += "  $($_.Name) :: PNPDeviceID=$($_.PNPDeviceID) :: ScreenW=$($_.ScreenWidth) ScreenH=$($_.ScreenHeight)"
}

$out += ""
$out += "--- DisplaySwitch.exe presence ---"
$out += "  $(Test-Path "$env:WINDIR\System32\DisplaySwitch.exe")"

$dest = "$PSScriptRoot\results\_mux_probe.txt"
$out | Out-File $dest -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "Saved to: $dest"
