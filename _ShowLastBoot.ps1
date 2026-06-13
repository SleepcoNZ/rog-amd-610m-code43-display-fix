$log = "$PSScriptRoot\results\boot-guardian.log"
$lines = Get-Content $log
$starts = @()
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'BOOT GUARDIAN START') { $starts += $i } }
"Total starts: $($starts.Count)"
"Last start at line: $($starts[-1])"
""
"--- Last boot's log (full) ---"
$lines[($starts[-1])..($lines.Count - 1)] | ForEach-Object { $_ }
""
"--- FAILOVER references anywhere in log ---"
$lines | Where-Object { $_ -match 'FAILOVER|Failover|failover' }
