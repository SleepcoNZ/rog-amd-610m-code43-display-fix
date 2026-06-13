# ============================================================================
# Phase 4: Event Log & Crash Analysis
# ============================================================================
param([switch]$AsJob)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp = Get-Date -Format 'o'
    Phase     = 'Phase4_EventAnalysis'
    Issues    = @()
    Data      = @{}
}

Write-DiagHeader "PHASE 4: Event Log & Crash Analysis"

# --- 4.1 TDR (Timeout Detection Recovery) Events ---
Write-DiagSection "4.1 TDR (GPU Timeout Detection Recovery) Events"
$tdrEvents = Safe-Execute "Scanning for TDR events" {
    # Event IDs: 14 (LiveKernelEvent TDR), 4101 (Display driver timeout)
    $events = @()

    # dxgkrnl TDR events
    try {
        $tdr = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Display'
        } -MaxEvents 100 -ErrorAction SilentlyContinue
        foreach ($e in $tdr) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Provider    = $e.ProviderName
                Message     = $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
            }
        }
    } catch {}

    # Kernel-WHEA for GPU hardware errors
    try {
        $whea = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id      = 14, 4101, 4097, 7, 219
        } -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'display|video|gpu|amd|nvidia|radeon|dxgkrnl|TDR|timeout' }
        foreach ($e in $whea) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Provider    = $e.ProviderName
                Message     = $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
            }
        }
    } catch {}

    $events | Sort-Object { $_.TimeCreated } -Descending | Select-Object -First 30
}
if ($tdrEvents.Success) {
    $results.Data.TDREvents = $tdrEvents.Data
    $tdrCount = @($tdrEvents.Data).Count
    Write-DiagResult "TDR Events" "$tdrCount event(s) found" $(if ($tdrCount -gt 5) { 'WARN' } elseif ($tdrCount -gt 0) { 'INFO' } else { 'OK' })
    foreach ($evt in $tdrEvents.Data | Select-Object -First 10) {
        Write-DiagResult "  [$($evt.TimeCreated)]" "Id=$($evt.Id) $($evt.Provider): $($evt.Message.Substring(0,[Math]::Min($evt.Message.Length,150)))" 'WARN'
    }
    if ($tdrCount -gt 5) {
        $results.Issues += "WARN: $tdrCount TDR/display timeout events - indicates GPU instability before failure"
    }
}

# --- 4.2 System Critical/Error Events (display-related) ---
Write-DiagSection "4.2 System Critical & Error Events (Display-Related)"
$sysErrors = Safe-Execute "Scanning System log for critical display errors" {
    $startDate = (Get-Date).AddDays(-60)
    Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Level     = 1, 2  # Critical, Error
        StartTime = $startDate
    } -MaxEvents 3000 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match 'display|video|gpu|amd|nvidia|radeon|dxgkrnl|nvlddmkm|atikmdag|dwm|graphics|monitor|panel|backlight|edp|hdmi'
        } |
        Select-Object -First 30 |
        ForEach-Object {
            @{
                TimeCreated = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $_.Id
                Level       = $_.LevelDisplayName
                Provider    = $_.ProviderName
                Message     = $_.Message.Substring(0, [Math]::Min($_.Message.Length, 500))
            }
        }
}
if ($sysErrors.Success) {
    $results.Data.SystemDisplayErrors = $sysErrors.Data
    $errCount = @($sysErrors.Data).Count
    Write-DiagResult "Display Errors" "$errCount critical/error event(s) in last 60 days" $(if ($errCount -gt 10) { 'ERROR' } elseif ($errCount -gt 0) { 'WARN' } else { 'OK' })
    foreach ($evt in $sysErrors.Data | Select-Object -First 10) {
        $s = if ($evt.Level -eq 'Critical') { 'CRITICAL' } else { 'ERROR' }
        Write-DiagResult "  [$($evt.TimeCreated)]" "$($evt.Provider) Id=$($evt.Id): $($evt.Message.Substring(0,[Math]::Min($evt.Message.Length,150)))" $s
    }
    if ($errCount -gt 10) {
        $results.Issues += "ERROR: $errCount critical/error display events - significant GPU/display instability"
    }
}

# --- 4.3 WHEA Hardware Errors ---
Write-DiagSection "4.3 WHEA (Hardware Error Architecture) Events"
$wheaEvents = Safe-Execute "Scanning WHEA operational log" {
    $events = @()
    try {
        $whea = Get-WinEvent -LogName 'Microsoft-Windows-Kernel-WHEA/Operational' -MaxEvents 200 -ErrorAction Stop
        foreach ($e in $whea) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Provider    = $e.ProviderName
                Message     = $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
            }
        }
    }
    catch {
        $events += @{ Error = "WHEA log not available: $($_.Exception.Message)" }
    }

    # Also check for PCIe errors that affect GPU
    try {
        $pcie = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
        } -MaxEvents 5000 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'PCIe|PCI Express|bus error|corrected hardware|uncorrectable' } |
            Select-Object -First 20
        foreach ($e in $pcie) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Provider    = $e.ProviderName
                Message     = "PCIe: " + $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
            }
        }
    } catch {}

    $events
}
if ($wheaEvents.Success) {
    $results.Data.WHEAEvents = $wheaEvents.Data
    $wheaCount = @($wheaEvents.Data | Where-Object { -not $_.Error }).Count
    Write-DiagResult "WHEA Events" "$wheaCount hardware error event(s)" $(if ($wheaCount -gt 10) { 'ERROR' } elseif ($wheaCount -gt 0) { 'WARN' } else { 'OK' })
    foreach ($evt in ($wheaEvents.Data | Where-Object { -not $_.Error } | Select-Object -First 10)) {
        Write-DiagResult "  [$($evt.TimeCreated)]" "Id=$($evt.Id): $($evt.Message.Substring(0,[Math]::Min($evt.Message.Length,150)))" 'WARN'
    }
    if ($wheaCount -gt 5) {
        $results.Issues += "WARN: $wheaCount WHEA hardware errors - possible PCIe/GPU hardware fault"
    }
}

# --- 4.4 Unexpected Shutdown / BSOD Events ---
Write-DiagSection "4.4 Unexpected Shutdowns & BSODs"
$shutdowns = Safe-Execute "Scanning for unexpected shutdowns and BSODs" {
    $events = @()

    # Event ID 41 (Kernel-Power) = unexpected shutdown
    # Event ID 1001 (BugCheck) = BSOD
    # Event ID 6008 = unexpected shutdown
    try {
        $ue = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id      = 41, 1001, 6008, 1003
        } -MaxEvents 50 -ErrorAction SilentlyContinue
        foreach ($e in $ue) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Provider    = $e.ProviderName
                Message     = $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
                EventType   = switch ($e.Id) {
                    41   { 'Unexpected Shutdown (Kernel-Power)' }
                    1001 { 'BugCheck (BSOD)' }
                    6008 { 'Unexpected Shutdown' }
                    1003 { 'BSOD Error Report' }
                }
            }
        }
    } catch {}

    $events | Sort-Object { $_.TimeCreated } -Descending
}
if ($shutdowns.Success) {
    $results.Data.Shutdowns = $shutdowns.Data
    $sdCount = @($shutdowns.Data).Count
    Write-DiagResult "Unexpected Shutdowns/BSODs" "$sdCount event(s)" $(if ($sdCount -gt 5) { 'ERROR' } elseif ($sdCount -gt 0) { 'WARN' } else { 'OK' })
    foreach ($evt in $shutdowns.Data | Select-Object -First 10) {
        Write-DiagResult "  [$($evt.TimeCreated)]" "$($evt.EventType): $($evt.Message.Substring(0,[Math]::Min($evt.Message.Length,150)))" 'ERROR'
    }
    if ($sdCount -gt 3) {
        $results.Issues += "ERROR: $sdCount unexpected shutdowns/BSODs - system instability possibly caused GPU damage"
    }
}

# --- 4.5 Minidump Analysis ---
Write-DiagSection "4.5 Minidump / Crash Dump Files"
$minidumps = Safe-Execute "Checking for crash dump files" {
    $dumps = @()
    $dumpPaths = @(
        'C:\Windows\Minidump',
        'C:\Windows\MEMORY.DMP'
    )

    # Minidump directory
    if (Test-Path 'C:\Windows\Minidump') {
        $dmpFiles = Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        foreach ($d in $dmpFiles | Select-Object -First 10) {
            $dumps += @{
                Name      = $d.Name
                Path      = $d.FullName
                Size_KB   = [math]::Round($d.Length / 1KB)
                Date      = $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                DaysAgo   = [math]::Round(((Get-Date) - $d.LastWriteTime).TotalDays, 1)
            }
        }
    }

    # Full memory dump
    if (Test-Path 'C:\Windows\MEMORY.DMP') {
        $md = Get-Item 'C:\Windows\MEMORY.DMP'
        $dumps += @{
            Name    = 'MEMORY.DMP (Full dump)'
            Path    = $md.FullName
            Size_MB = [math]::Round($md.Length / 1MB)
            Date    = $md.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            DaysAgo = [math]::Round(((Get-Date) - $md.LastWriteTime).TotalDays, 1)
        }
    }

    $dumps
}
if ($minidumps.Success) {
    $results.Data.Minidumps = $minidumps.Data
    $dmpCount = @($minidumps.Data).Count
    Write-DiagResult "Dump Files" "$dmpCount crash dump(s) found" $(if ($dmpCount -gt 3) { 'WARN' } elseif ($dmpCount -gt 0) { 'INFO' } else { 'OK' })
    foreach ($d in $minidumps.Data) {
        $s = if ($d.DaysAgo -lt 7) { 'WARN' } else { 'INFO' }
        Write-DiagResult "  $($d.Name)" "Size=$($d.Size_KB)KB Date=$($d.Date) ($($d.DaysAgo) days ago)" $s
        if ($d.DaysAgo -lt 3) {
            $results.Issues += "WARN: Recent crash dump ($($d.Name)) from $($d.Date) - may be related to display failure"
        }
    }
}

# --- 4.6 Application Crash Events (GPU-Related) ---
Write-DiagSection "4.6 Application Crashes (GPU-Related)"
$appCrashes = Safe-Execute "Scanning Application log for GPU-related crashes" {
    $startDate = (Get-Date).AddDays(-30)
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        Id        = 1000, 1001, 1002  # App Error, WER, App Hang
        StartTime = $startDate
    } -MaxEvents 1000 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match 'nvlddmkm|atikmdag|amdwddmg|dwm\.exe|dxgi|d3d11|gpu|cuda|ollama|python'
        } |
        Select-Object -First 20 |
        ForEach-Object {
            @{
                TimeCreated = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $_.Id
                Provider    = $_.ProviderName
                Message     = $_.Message.Substring(0, [Math]::Min($_.Message.Length, 500))
            }
        }
}
if ($appCrashes.Success) {
    $results.Data.AppCrashes = $appCrashes.Data
    $crashCount = @($appCrashes.Data).Count
    Write-DiagResult "GPU App Crashes" "$crashCount event(s)" $(if ($crashCount -gt 5) { 'WARN' } elseif ($crashCount -gt 0) { 'INFO' } else { 'OK' })
    foreach ($evt in $appCrashes.Data | Select-Object -First 5) {
        Write-DiagResult "  [$($evt.TimeCreated)]" "$($evt.Message.Substring(0,[Math]::Min($evt.Message.Length,150)))" 'WARN'
    }
}

# --- 4.7 LiveKernelReports ---
Write-DiagSection "4.7 LiveKernelReports (GPU Hangs)"
$lkr = Safe-Execute "Checking LiveKernelReports directory" {
    $reports = @()
    $lkrPath = 'C:\Windows\LiveKernelReports'
    if (Test-Path $lkrPath) {
        Get-ChildItem $lkrPath -Recurse -Filter '*.dmp' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                $reports += @{
                    Name    = $_.Name
                    Dir     = $_.Directory.Name
                    Size_KB = [math]::Round($_.Length / 1KB)
                    Date    = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    DaysAgo = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays, 1)
                }
            }
    }
    $reports
}
if ($lkr.Success) {
    $results.Data.LiveKernelReports = $lkr.Data
    $lkrCount = @($lkr.Data).Count
    Write-DiagResult "LiveKernelReports" "$lkrCount report(s) found" $(if ($lkrCount -gt 5) { 'WARN' } elseif ($lkrCount -gt 0) { 'INFO' } else { 'OK' })
    foreach ($r in $lkr.Data | Select-Object -First 5) {
        Write-DiagResult "  $($r.Dir)/$($r.Name)" "Size=$($r.Size_KB)KB Date=$($r.Date)" 'WARN'
    }
    if ($lkrCount -gt 3) {
        $results.Issues += "WARN: $lkrCount LiveKernelReports (GPU hang dumps) found - GPU was experiencing hangs before failure"
    }
}

# --- Summary ---
Write-DiagSection "Phase 4 Summary"
$severity = Get-Severity $results.Issues
Write-DiagResult "Overall Severity" $severity $severity
Write-DiagResult "Issues Found" "$($results.Issues.Count)" $(if ($results.Issues.Count -eq 0) { 'OK' } else { 'WARN' })
foreach ($issue in $results.Issues) {
    Write-Host "  ! $issue" -ForegroundColor $(if ($issue -match 'CRITICAL') { 'Magenta' } elseif ($issue -match 'ERROR') { 'Red' } else { 'Yellow' })
}

Save-Result "phase4_events.json" $results
Write-Host "`nPhase 4 Complete.`n" -ForegroundColor Cyan
return $results
