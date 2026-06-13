$out = @()
$amd = Get-PnpDevice -Class Display | Where-Object FriendlyName -match 'AMD Radeon\(TM\) 610M' | Select-Object -First 1
$out += "Target: $($amd.FriendlyName)"
$out += "InstanceId: $($amd.InstanceId)"
$out += "Before: Status=$($amd.Status)"
$out += ""
$out += "--- pnputil /restart-device ---"
$result = pnputil /restart-device "$($amd.InstanceId)" 2>&1
$out += $result
$out += ""
Start-Sleep -Seconds 4
$amd2 = Get-PnpDevice -Class Display | Where-Object FriendlyName -match 'AMD Radeon\(TM\) 610M' | Select-Object -First 1
$p = Get-PnpDeviceProperty -InstanceId $amd2.InstanceId
$code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
$out += "After: Status=$($amd2.Status), Code=$code"
$mons = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -EA SilentlyContinue | Where-Object Active).Count
$out += "Active monitors: $mons"
$out | Out-File "$PSScriptRoot\results\_restart.txt" -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
