# ============================================================================
# DisplayDiagnostics - Master Orchestrator
# ASUS ROG Strix G713PV - Black Screen Diagnostic & Repair Platform
# ============================================================================
#
# Usage:
#   .\run_diagnostics.ps1                    # Run all scans (no repairs)
#   .\run_diagnostics.ps1 -IncludeRepairs    # Run scans + interactive repairs
#   .\run_diagnostics.ps1 -Phase 2           # Run specific phase only
#   .\run_diagnostics.ps1 -QuickScan         # Run only Phase 1 & 2 (fast)
#   .\run_diagnostics.ps1 -RepairOnly 3      # Run specific repair only
#   .\run_diagnostics.ps1 -Elevated          # Internal flag for admin re-launch
# ============================================================================

param(
    [switch]$IncludeRepairs,
    [int]$Phase = 0,
    [switch]$QuickScan,
    [int]$RepairOnly = 0,
    [switch]$Elevated,
    [switch]$GenerateReportOnly
)

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot
. "$scriptRoot\lib\helpers.ps1"

$isAdmin = Test-IsAdmin
$startTime = Get-Date

# ============================================================================
# Banner
# ============================================================================
Write-Host @"

 ========================================================================
  DISPLAY DIAGNOSTICS PLATFORM
  ASUS ROG Strix G713PV ($env:COMPUTERNAME)
 ========================================================================
  CPU:  AMD Ryzen 9 7845HX with Radeon Graphics
  iGPU: AMD Radeon(TM) 610M  [SUSPECTED FAULT - Code 43]
  dGPU: NVIDIA GeForce RTX 4060 Laptop GPU
  RAM:  64.0 GB (63.2 GB usable)
  Issue: Internal display completely black (no BIOS splash)
  Access: Via Splashtop remote only
 ========================================================================
  Admin: $isAdmin | Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
 ========================================================================

"@ -ForegroundColor Cyan

# ============================================================================
# Admin elevation for scans that need it
# ============================================================================
if (-not $isAdmin) {
    Write-Host "  NOTE: Running as standard user. Scans that need admin will" -ForegroundColor Yellow
    Write-Host "        be run in a separate elevated process." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# Generate Report Only
# ============================================================================
if ($GenerateReportOnly) {
    & "$scriptRoot\generate_report.ps1" -OpenReport
    return
}

# ============================================================================
# Specific Repair Only
# ============================================================================
if ($RepairOnly -gt 0) {
    if (-not $isAdmin) {
        Write-Host "  Repairs require admin. Elevating..." -ForegroundColor Yellow
        $outputFile = Join-Path $scriptRoot "results\repair_elevated_output.txt"
        Start-Process powershell -Verb RunAs -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$scriptRoot\repair_display.ps1`"",
            "-RepairId", "$RepairOnly"
        ) -Wait
        Write-Host "  Elevated repair complete. Check output above." -ForegroundColor Green
    } else {
        & "$scriptRoot\repair_display.ps1" -RepairId $RepairOnly
    }
    return
}

# ============================================================================
# Run Diagnostic Phases
# ============================================================================
$phasesToRun = if ($QuickScan) { @(1, 2) }
               elseif ($Phase -gt 0) { @($Phase) }
               else { @(1, 2, 3, 4, 5, 6) }

$phaseScripts = @{
    1 = @{ Script = 'scan_system.ps1';    Name = 'System Inventory';      NeedsAdmin = $false }
    2 = @{ Script = 'scan_display.ps1';   Name = 'Display Diagnostics';   NeedsAdmin = $false }
    3 = @{ Script = 'scan_drivers.ps1';   Name = 'Driver Analysis';       NeedsAdmin = $false }
    4 = @{ Script = 'scan_events.ps1';    Name = 'Event Log Analysis';    NeedsAdmin = $false }
    5 = @{ Script = 'scan_firmware.ps1';  Name = 'Firmware & BIOS';       NeedsAdmin = $false }
    6 = @{ Script = 'scan_integrity.ps1'; Name = 'System Integrity';      NeedsAdmin = $true  }
}

$allResults = @{}

foreach ($p in $phasesToRun) {
    $info = $phaseScripts[$p]
    if (-not $info) {
        Write-Host "  Unknown phase: $p" -ForegroundColor Red
        continue
    }

    $scriptPath = Join-Path $scriptRoot $info.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Host "  Script not found: $scriptPath" -ForegroundColor Red
        continue
    }

    Write-Host "`n  Starting Phase $p : $($info.Name)..." -ForegroundColor Cyan
    $phaseStart = Get-Date

    if ($info.NeedsAdmin -and -not $isAdmin) {
        Write-Host "  Phase $p needs admin. Running elevated..." -ForegroundColor Yellow
        $outputFile = Join-Path $scriptRoot "results\phase${p}_elevated_output.txt"
        Start-Process powershell -Verb RunAs -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$scriptPath`"",
            "*>", "`"$outputFile`""
        ) -Wait
        if (Test-Path $outputFile) {
            Get-Content $outputFile | Write-Host
        }
    } else {
        try {
            $result = & $scriptPath
            $allResults["Phase$p"] = $result
        }
        catch {
            Write-Host "  Phase $p FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $elapsed = ((Get-Date) - $phaseStart).TotalSeconds
    Write-Host "  Phase $p completed in $([math]::Round($elapsed, 1))s" -ForegroundColor DarkGray
}

# ============================================================================
# Generate Report
# ============================================================================
Write-Host "`n  Generating diagnostic report..." -ForegroundColor Cyan
& "$scriptRoot\generate_report.ps1"

# ============================================================================
# Repairs (if requested)
# ============================================================================
if ($IncludeRepairs) {
    Write-Host "`n  Starting repair phase..." -ForegroundColor Cyan
    if (-not $isAdmin) {
        Write-Host "  Repairs require admin. Elevating..." -ForegroundColor Yellow
        Start-Process powershell -Verb RunAs -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$scriptRoot\repair_display.ps1`"",
            "-RunAll"
        ) -Wait
    } else {
        & "$scriptRoot\repair_display.ps1" -RunAll
    }

    # Regenerate report after repairs
    Write-Host "`n  Regenerating report with repair results..." -ForegroundColor Cyan
    & "$scriptRoot\generate_report.ps1" -OpenReport
}

# ============================================================================
# Summary
# ============================================================================
$totalElapsed = ((Get-Date) - $startTime).TotalSeconds

Write-Host @"

 ========================================================================
  DIAGNOSTICS COMPLETE
 ========================================================================
  Phases Run:   $($phasesToRun -join ', ')
  Total Time:   $([math]::Round($totalElapsed, 1)) seconds
  Results Dir:  $(Join-Path $scriptRoot 'results')
  Report:       $(Join-Path $scriptRoot 'results\diagnostic_report.html')
 ========================================================================

  Quick Actions:
    .\run_diagnostics.ps1 -RepairOnly 1       # Re-enable AMD iGPU
    .\run_diagnostics.ps1 -RepairOnly 3       # Toggle MUX switch
    .\run_diagnostics.ps1 -RepairOnly 7       # Power-cycle all GPUs
    .\run_diagnostics.ps1 -IncludeRepairs     # Run all repairs
    .\run_diagnostics.ps1 -GenerateReportOnly # Regenerate report

"@ -ForegroundColor Cyan
