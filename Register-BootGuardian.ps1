<#
.SYNOPSIS
    Registers Boot-GPU-Guardian.ps1 as a SYSTEM scheduled task that runs at
    every boot. Run ONCE, as Administrator.

.NOTES
    Task name: GPU_BootGuardian_ROG
    Trigger:   At system startup
    Account:   SYSTEM, highest privileges
    Lifetime:  Self-terminates after ~5 min (script has its own deadline)
#>
[CmdletBinding()]
param(
    [int]$WatchMinutes = 5
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run as Administrator (local console, not Splashtop)." -ForegroundColor Red
    exit 1
}

$script = Join-Path $PSScriptRoot 'Boot-GPU-Guardian.ps1'
if (-not (Test-Path $script)) { Write-Host "ERROR: Not found: $script" -ForegroundColor Red; exit 1 }

$taskName = 'GPU_BootGuardian_ROG'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -WatchMinutes $WatchMinutes"
$trigger = New-ScheduledTaskTrigger -AtStartup
# Small delay so display drivers have a chance to load
$trigger.Delay = 'PT30S'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes ($WatchMinutes + 2)) `
    -MultipleInstances IgnoreNew

# Remove existing if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA SilentlyContinue

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Boot-time GPU/display health watchdog. Runs for $WatchMinutes min after boot."

Write-Host ""
Write-Host "Registered: $taskName" -ForegroundColor Green
Write-Host "  Trigger : At startup, 30s delay"
Write-Host "  Watch   : $WatchMinutes minutes"
Write-Host "  Account : SYSTEM"
Write-Host "  Log     : $PSScriptRoot\results\boot-guardian.log"
Write-Host ""
Write-Host "Test it now (without rebooting):" -ForegroundColor Yellow
Write-Host "  Start-ScheduledTask -TaskName $taskName"
Write-Host "  Get-Content '$PSScriptRoot\results\boot-guardian.log' -Tail 20 -Wait"
