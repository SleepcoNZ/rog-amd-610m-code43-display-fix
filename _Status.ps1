$out = @()
$out += "=== Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$out += ""
$out += "--- LOCKOUT file present? ---"
$lockoutPath = "$PSScriptRoot\results\guardian.LOCKOUT"
$out += "Path: $lockoutPath"
$out += "Exists: $(Test-Path $lockoutPath)"
if (Test-Path $lockoutPath) {
    $out += "Contents:"
    $out += (Get-Content $lockoutPath -Raw)
}
$out += ""
$out += "--- Scheduled task ---"
$t = Get-ScheduledTask GPU_BootGuardian_ROG -EA SilentlyContinue
if ($t) {
    $out += "Task present. State=$($t.State)"
    $info = $t | Get-ScheduledTaskInfo
    $out += "LastRunTime: $($info.LastRunTime)"
    $out += "LastTaskResult: $($info.LastTaskResult)"
    $out += "NumberOfMissedRuns: $($info.NumberOfMissedRuns)"
    $out += "Triggers: $($t.Triggers.Count)"
} else {
    $out += "TASK GONE -- GPU_BootGuardian_ROG no longer registered"
}
$out += ""
$out += "--- Current GPU state ---"
Get-CimInstance Win32_VideoController -EA SilentlyContinue | ForEach-Object {
    $out += "  $($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)Hz, Status=$($_.Status)"
}
$out += ""
$out += "--- PnP Display devices ---"
Get-PnpDevice -Class Display -EA SilentlyContinue | ForEach-Object {
    $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -EA SilentlyContinue
    $code = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    $out += "  $($_.FriendlyName): Status=$($_.Status), Code=$code"
}
$out += ""
$out += "--- Active monitors ---"
$mons = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -EA SilentlyContinue | Where-Object Active)
$out += "Count: $($mons.Count)"
foreach ($m in $mons) {
    $name = -join ($m.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
    $out += "  $name ($($m.InstanceName))"
}
$out += ""
$out += "--- Guardian log (last 40 lines) ---"
$log = "$PSScriptRoot\results\boot-guardian.log"
if (Test-Path $log) {
    Get-Content $log -Tail 40 | ForEach-Object { $out += $_ }
} else {
    $out += "(log not found)"
}

$out | Out-File "$PSScriptRoot\results\_status.txt" -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
