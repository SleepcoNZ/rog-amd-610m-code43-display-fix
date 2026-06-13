$ErrorActionPreference = 'Continue'
$log = "$PSScriptRoot\results\setup-run.log"
if (Test-Path $log) { Remove-Item $log -Force }
Start-Transcript -Path $log -Force | Out-Null

Write-Host '=== Register-BootGuardian ==='
& "$PSScriptRoot\Register-BootGuardian.ps1"

Write-Host ''
Write-Host '=== Add-WakeTriggers ==='
& "$PSScriptRoot\Add-WakeTriggers.ps1"

Write-Host ''
Write-Host '=== Final Triggers ==='
$task = Get-ScheduledTask GPU_BootGuardian_ROG -ErrorAction SilentlyContinue
if ($task) {
    $task.Triggers | ForEach-Object {
        $sub = if ($_.Subscription) { ($_.Subscription -replace '\s+',' ') } else { '' }
        Write-Host ("{0} | Delay={1} | Sub={2}" -f $_.CimClass.CimClassName, $_.Delay, $sub)
    }
    Write-Host ''
    Write-Host '=== Task Info ==='
    $task | Get-ScheduledTaskInfo | Format-List
} else {
    Write-Host 'ERROR: Task GPU_BootGuardian_ROG not found after registration!' -ForegroundColor Red
}

Stop-Transcript | Out-Null
