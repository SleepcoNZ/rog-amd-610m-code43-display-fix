<#
.SYNOPSIS
    Install-AutoRecovery.ps1 -- Registers the refactored display auto-recovery
    as ONE scheduled task, and removes the old overlapping tasks.

    Run ONCE, as Administrator (local console -- Splashtop cannot pass UAC).

.DESCRIPTION
    Replaces the previous tangle of tasks (GPU_BootGuardian_ROG,
    GPU_Watchdog_ROG, ...) with a single task:

        Display_AutoRecover_ROG

    Key design fix over the old setup: the task runs as the LOGGED-IN USER with
    "Highest" privileges (LogonType Interactive, RunLevel Highest). Because the
    user is a local admin, Task Scheduler grants the full elevated token with NO
    UAC prompt -- so the recovery engine can BOTH inject the Win+Ctrl+Shift+B
    keystroke into the desktop AND cycle devices / reboot. The old SYSTEM/session-0
    task could do neither against the user's desktop.

    Triggers:
      - At logon (current user)           -> covers boot
      - On resume from sleep              -> Power-Troubleshooter EventID 1
      - On workstation unlock             -> session state change
    These are exactly the moments the AMD 610M drops into Code 43.

.PARAMETER RunNow
    Start the task immediately after registering (will run the recovery ladder,
    which may reboot if the panel is currently dead).

.PARAMETER MaxRebootAttempts
    Passed through to Recover-Display.ps1 (default 2: warm restart, then cold off).
#>
[CmdletBinding()]
param(
    [switch]$RunNow,
    [int]$MaxRebootAttempts = 2
)

# ---- elevation ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not elevated -- relaunching as Administrator..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($RunNow) { $argList += '-RunNow' }
    $argList += @('-MaxRebootAttempts', $MaxRebootAttempts)
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "ERROR: elevation was declined or blocked (Splashtop can't pass UAC)." -ForegroundColor Red
        Write-Host "Run this from a LOCAL elevated PowerShell window instead." -ForegroundColor Yellow
    }
    return
}

$ErrorActionPreference = 'Continue'
$root   = $PSScriptRoot
$engine = Join-Path $root 'Recover-Display.ps1'
if (-not (Test-Path $engine)) { Write-Host "ERROR: not found: $engine" -ForegroundColor Red; exit 1 }

$taskName = 'Display_AutoRecover_ROG'

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " INSTALL DISPLAY AUTO-RECOVERY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ---- 1. Remove old / superseded tasks ----
$oldTasks = @(
    'GPU_BootGuardian_ROG'
    'GPU_Watchdog_ROG'
    'GPU_Watchdog'
    'GPU_Failover_ROG'
    'BootGPUGuardian'
)
Write-Host "[1/4] Removing superseded tasks..." -ForegroundColor Yellow
foreach ($t in $oldTasks) {
    $existing = Get-ScheduledTask -TaskName $t -EA SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -EA SilentlyContinue
        Write-Host "    removed: $t" -ForegroundColor DarkGray
    }
}

# ---- 2. Identify the interactive user for the principal ----
$consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName   # DOMAIN\user
if (-not $consoleUser) { $consoleUser = "$env:USERDOMAIN\$env:USERNAME" }
Write-Host "[2/4] Task will run as interactive user: $consoleUser (Highest privileges)" -ForegroundColor Yellow

# warn if that user is not a local admin (device cycle / reboot would fail)
try {
    $userOnly = $consoleUser.Split('\')[-1]
    $adminMembers = (Get-LocalGroupMember -Group 'Administrators' -EA SilentlyContinue).Name
    if ($adminMembers -and -not ($adminMembers -match [Regex]::Escape($userOnly))) {
        Write-Host "    WARNING: $consoleUser may not be a local admin; elevated steps could fail." -ForegroundColor Red
    }
} catch { }

# ---- 3. Build action / triggers / principal / settings ----
Write-Host "[3/4] Registering $taskName..." -ForegroundColor Yellow

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -MaxRebootAttempts {1}" -f $engine, $MaxRebootAttempts)

# Trigger A: at logon of the interactive user (covers boot)
$trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $consoleUser

# Trigger B: on resume from sleep/hibernate (Power-Troubleshooter EventID 1)
$wakeQuery = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>
  </Query>
</QueryList>
'@
$trigWake = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler) `
    -Property @{ Enabled = $true; Subscription = $wakeQuery } -ClientOnly

# Trigger C: on workstation unlock (SessionUnlock = 8)
$trigUnlock = New-CimInstance -CimClass (Get-CimClass MSFT_TaskSessionStateChangeTrigger root/Microsoft/Windows/TaskScheduler) `
    -Property @{ Enabled = $true; StateChange = 8; UserId = $consoleUser } -ClientOnly

$principal = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA SilentlyContinue
Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger @($trigLogon, $trigWake, $trigUnlock) `
    -Principal $principal `
    -Settings $settings `
    -Description 'Lights the built-in laptop panel after an AMD 610M Code 43 (boot/wake/unlock). Escalates software fixes -> reboot, then stops once the panel is on.' | Out-Null

Write-Host "    registered." -ForegroundColor Green

# ---- 4. Verify ----
Write-Host "[4/4] Verifying..." -ForegroundColor Yellow
$task = Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue
if ($task) {
    Write-Host "    OK: $taskName ($($task.State))" -ForegroundColor Green
    $task.Triggers | ForEach-Object {
        switch ($_.CimClass.CimClassName) {
            'MSFT_TaskLogonTrigger'              { "      [LOGON]  at logon of $($_.UserId)" }
            'MSFT_TaskEventTrigger'              { "      [WAKE]   on resume from sleep (Power-Troubleshooter ID 1)" }
            'MSFT_TaskSessionStateChangeTrigger' { "      [UNLOCK] on workstation unlock" }
            default                              { "      [$($_.CimClass.CimClassName)]" }
        }
    } | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
} else {
    Write-Host "    ERROR: task not found after registration." -ForegroundColor Red
}

Write-Host ""
Write-Host "Done. Engine: $engine" -ForegroundColor Cyan
Write-Host "Log:    $root\results\recover-display.log" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Test without rebooting (panel already healthy => exits immediately):" -ForegroundColor Yellow
Write-Host "  Start-ScheduledTask -TaskName $taskName"
Write-Host "  Get-Content '$root\results\recover-display.log' -Tail 30 -Wait"
Write-Host ""

if ($RunNow) {
    Write-Host "RunNow set -- starting recovery task now..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $taskName
}
