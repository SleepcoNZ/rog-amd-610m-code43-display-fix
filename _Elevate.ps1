Remove-Item "$PSScriptRoot\results\setup-run.log" -EA SilentlyContinue
Write-Host "Launching elevated process. Click YES on UAC prompt." -ForegroundColor Yellow
try {
    $proc = Start-Process powershell.exe `
        -ArgumentList '-ExecutionPolicy','Bypass','-NoProfile','-File',"$PSScriptRoot\_RunSetup.ps1" `
        -Verb RunAs -Wait -PassThru
    Write-Host "Elevated process finished. Exit code: $($proc.ExitCode)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    return
}
Write-Host ""
Write-Host "--- LOG ---" -ForegroundColor Cyan
if (Test-Path "$PSScriptRoot\results\setup-run.log") {
    Get-Content "$PSScriptRoot\results\setup-run.log"
} else {
    Write-Host "No log file - script did not start (UAC likely denied)."
}
