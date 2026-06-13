$p = "$PSScriptRoot\Boot-GPU-Guardian.ps1"
$c = Get-Content $p -Raw
$c = $c -replace [char]0x2014, '--' -replace [char]0x2013, '-'
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding $true))
"Saved with BOM. Length=$($c.Length)"
"--- Parse + snapshot test under powershell.exe ---"
$test = @"
. '$p' -WatchMinutes 0 -PollSeconds 1 *> `$null
'Parse OK. Test-GPUHealth:'
Test-GPUHealth | Format-Table Type, Device, InstanceId, Detail -AutoSize -Wrap
''
'Current snapshot:'
Get-StateSnapshot | Format-List
"@
$tmp = "$env:TEMP\guardian_test.ps1"
[System.IO.File]::WriteAllText($tmp, $test, (New-Object System.Text.UTF8Encoding $true))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
"Exit: $LASTEXITCODE"
Remove-Item $tmp -EA SilentlyContinue
