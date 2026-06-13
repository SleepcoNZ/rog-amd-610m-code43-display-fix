$tokens = $null; $errs = $null
[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Boot-GPU-Guardian.ps1",[ref]$tokens,[ref]$errs) | Out-Null
if ($errs) { $errs | ForEach-Object { Write-Host "ERR L$($_.Extent.StartLineNumber): $($_.Message)" } } else { Write-Host 'PARSE OK' }
