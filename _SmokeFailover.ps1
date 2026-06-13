# Smoke-test panel failover logic WITHOUT running the failover itself
$ErrorActionPreference = 'Continue'

# Suppress Write-Log noise during dot-source: redirect log path to a temp file
$tempLog = Join-Path $env:TEMP "guardian_smoke_$(Get-Random).log"

# Stub Main loop: just import functions without running them
# Easiest: read file, strip the Main loop section, then iex
$src = Get-Content "$PSScriptRoot\Boot-GPU-Guardian.ps1" -Raw
# Cut from "-------- Main loop --------" onwards
$idx = $src.IndexOf('# -------- Main loop --------')
if ($idx -gt 0) { $src = $src.Substring(0, $idx) }
# Override log location for the test
$src = $src -replace [regex]::Escape("`$script:Log  = Join-Path `$script:Root 'results\boot-guardian.log'"), "`$script:Log = '$tempLog'"
Invoke-Expression $src

Write-Host "=== Get-StateSnapshot ==="
$snap = Get-StateSnapshot
$snap | Format-List Time, ActiveMonitors
Write-Host "VC:"
$snap.VC | Format-Table -AutoSize
Write-Host "Pnp:"
$snap.Pnp | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Test-PanelFailoverCondition ==="
$cond = Test-PanelFailoverCondition -Snapshot $snap
Write-Host "Failover would trigger: $cond"

Write-Host ""
Write-Host "=== Test-GPUHealth ==="
$h = Test-GPUHealth
Write-Host "Issues found: $($h.Count)"
$h | Format-Table Type, Device, Detail -AutoSize

Write-Host ""
Write-Host "=== Smoke log tail ==="
if (Test-Path $tempLog) { Get-Content $tempLog -Tail 5 }
