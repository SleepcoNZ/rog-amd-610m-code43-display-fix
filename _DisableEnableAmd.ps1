$out = @()
$logf = "$PSScriptRoot\results\_disen.txt"
$amd = Get-PnpDevice -Class Display | Where-Object FriendlyName -match 'AMD Radeon\(TM\) 610M' | Select-Object -First 1
$out += "Target: $($amd.FriendlyName)"
$out += "InstanceId: $($amd.InstanceId)"
$out += "Before: Status=$($amd.Status)"
$monsBefore = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -EA SilentlyContinue | Where-Object Active).Count
$out += "Active monitors before: $monsBefore"
$out += ""

$out += "--- Disable-PnpDevice ---"
try {
    Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA Stop
    $out += "Disabled OK"
} catch {
    $out += "Disable failed: $($_.Exception.Message)"
}

Start-Sleep -Seconds 4
$monsMid = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -EA SilentlyContinue | Where-Object Active).Count
$out += "Active monitors after disable: $monsMid"

$out += ""
$out += "--- Enable-PnpDevice ---"
try {
    Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -EA Stop
    $out += "Enabled OK"
} catch {
    $out += "Enable failed: $($_.Exception.Message)"
}

Start-Sleep -Seconds 6
$amd2 = Get-PnpDevice -Class Display | Where-Object FriendlyName -match 'AMD Radeon\(TM\) 610M' | Select-Object -First 1
$p = Get-PnpDeviceProperty -InstanceId $amd2.InstanceId
$code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
$out += "After: Status=$($amd2.Status), Code=$code"

$monsAfter = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -EA SilentlyContinue | Where-Object Active).Count
$out += "Active monitors after enable: $monsAfter"

Get-CimInstance Win32_VideoController | ForEach-Object {
    $out += "  $($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate) Status=$($_.Status)"
}

$out | Out-File $logf -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
