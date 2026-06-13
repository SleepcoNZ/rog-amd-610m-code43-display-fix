# ============================================================================
# Phase 8: HTML Diagnostic Report Generator
# ============================================================================
param([switch]$OpenReport)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

Write-DiagHeader "PHASE 8: Generating Diagnostic Report"

$resultsDir = Join-Path $PSScriptRoot "results"
$reportPath = Join-Path $resultsDir "diagnostic_report.html"

# Load all phase results
$phases = @{}
$phaseFiles = @(
    @{ Name = 'System Inventory';       File = 'phase1_system.json' }
    @{ Name = 'Display Diagnostics';    File = 'phase2_display.json' }
    @{ Name = 'Driver Analysis';        File = 'phase3_drivers.json' }
    @{ Name = 'Event Log Analysis';     File = 'phase4_events.json' }
    @{ Name = 'Firmware & BIOS';        File = 'phase5_firmware.json' }
    @{ Name = 'System Integrity';       File = 'phase6_integrity.json' }
    @{ Name = 'Repairs';                File = 'phase7_repairs.json' }
)

foreach ($pf in $phaseFiles) {
    $path = Join-Path $resultsDir $pf.File
    if (Test-Path $path) {
        $phases[$pf.Name] = Get-Content $path -Raw | ConvertFrom-Json
        Write-Host "  Loaded: $($pf.File)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Missing: $($pf.File)" -ForegroundColor Yellow
    }
}

# Collect all issues
$allIssues = @()
foreach ($pName in $phases.Keys) {
    $p = $phases[$pName]
    if ($p.Issues) {
        foreach ($issue in $p.Issues) {
            $severity = if ($issue -match '^CRITICAL') { 'CRITICAL' }
                        elseif ($issue -match '^ERROR') { 'ERROR' }
                        elseif ($issue -match '^WARN') { 'WARN' }
                        else { 'INFO' }
            $allIssues += @{ Phase = $pName; Severity = $severity; Message = $issue }
        }
    }
}

# Determine overall severity
$overallSeverity = 'OK'
if ($allIssues | Where-Object { $_.Severity -eq 'CRITICAL' }) { $overallSeverity = 'CRITICAL' }
elseif ($allIssues | Where-Object { $_.Severity -eq 'ERROR' }) { $overallSeverity = 'ERROR' }
elseif ($allIssues | Where-Object { $_.Severity -eq 'WARN' }) { $overallSeverity = 'WARN' }

# Build root cause analysis
$rootCauses = @()
$recommendations = @()

# Analyze patterns
$hasCode43 = $allIssues | Where-Object { $_.Message -match 'Code 43' }
$hasNoPanel = $allIssues | Where-Object { $_.Message -match 'No monitor|panel.*not.*recognized|panel.*invisible' }
$hasBacklightFail = $allIssues | Where-Object { $_.Message -match 'Backlight.*not responding|backlight.*failed' }
$hasTDR = $allIssues | Where-Object { $_.Message -match 'TDR|timeout' }
$hasDriverCorrupt = $allIssues | Where-Object { $_.Message -match 'driver.*missing|driver.*corrupt|signature.*invalid' }
$hasFastStartup = $allIssues | Where-Object { $_.Message -match 'Fast Startup' }
$hasBSOD = $allIssues | Where-Object { $_.Message -match 'shutdown|BSOD' }
$hasWHEA = $allIssues | Where-Object { $_.Message -match 'WHEA|hardware error|PCIe' }

if ($hasCode43) {
    $rootCauses += "AMD Radeon 610M iGPU has Code 43 — Windows disabled it due to reported problems. This is the PRIMARY cause of the black screen since the iGPU routes the internal display in hybrid/Optimus mode."
    $recommendations += "1. [HIGH PRIORITY] Toggle MUX switch to dGPU (discrete) mode via BIOS or Armoury Crate to bypass the broken iGPU"
    $recommendations += "2. Clean reinstall AMD Radeon 610M driver (use AMD Cleanup Utility, then install latest from AMD support)"
    $recommendations += "3. If MUX switch fixes display: update AMD driver, then switch back to hybrid mode to test if iGPU works with new driver"
}

if ($hasNoPanel) {
    $rootCauses += "The internal display panel is not detected by Windows EDID scanning. This could mean the panel is disconnected (eDP cable issue), the panel has failed, or the GPU driving it (AMD iGPU) is non-functional."
    $recommendations += "4. Test with external monitor (HDMI/USB-C) to isolate whether the issue is GPU-side or panel-side"
    $recommendations += "5. If external monitor works via NVIDIA GPU: the iGPU→panel path is broken, MUX switch to dGPU may fix it"
}

if ($hasBacklightFail) {
    $rootCauses += "Backlight WMI interface is not responding. If the panel EDID is also missing, the panel may be physically disconnected. If EDID is present but backlight is off, it could be a backlight inverter failure."
}

if ($hasTDR) {
    $rootCauses += "Multiple GPU Timeout Detection Recovery (TDR) events found — the GPU was experiencing hangs/timeouts before the failure. Heavy GPU workload during Cortana V4 training likely triggered repeated TDRs that eventually led to Code 43."
}

if ($hasWHEA) {
    $rootCauses += "Hardware error events (WHEA) detected on the PCIe bus. This suggests the iGPU may have experienced a hardware-level fault, possibly from thermal stress during heavy compute workload."
    $recommendations += "6. Check GPU temperatures during light workload — if AMD iGPU runs hot even idle, thermal paste/cooling may need attention"
}

if ($hasFastStartup) {
    $rootCauses += "Fast Startup (hiberboot) is enabled. This skips full hardware reinitialization on boot, which can leave display adapters in a broken state — especially after a crash."
    $recommendations += "7. Disable Fast Startup and do a full shutdown + cold boot"
}

if ($hasBSOD) {
    $rootCauses += "Recent unexpected shutdowns or BSODs detected. Crashes during GPU-intensive workloads can corrupt driver state and leave devices in Code 43."
}

if ($rootCauses.Count -eq 0) {
    $rootCauses += "Diagnostic data still being collected. Run all scan phases to identify root cause."
}

if ($recommendations.Count -eq 0) {
    $recommendations += "Run all diagnostic phases and repair actions"
}

# Always add these
$recommendations += "8. [IF ALL SOFTWARE FIXES FAIL] Physical inspection: reseat the eDP display cable connecting the panel to the motherboard"
$recommendations += "9. [IF ALL SOFTWARE FIXES FAIL] BIOS reset: disconnect battery for 30 seconds, reconnect, boot into BIOS setup and verify MUX switch setting"
$recommendations += "10. [LAST RESORT] Panel replacement if confirmed dead via external monitor test + MUX switch test"

# Generate HTML
$severityColors = @{
    'CRITICAL' = '#ff4444'
    'ERROR'    = '#ff8800'
    'WARN'     = '#ffcc00'
    'INFO'     = '#4488ff'
    'OK'       = '#44cc44'
}

$issueRows = ($allIssues | ForEach-Object {
    $color = $severityColors[$_.Severity]
    "<tr><td style='color:$color;font-weight:bold'>$($_.Severity)</td><td>$($_.Phase)</td><td>$($_.Message)</td></tr>"
}) -join "`n"

$rootCauseHtml = ($rootCauses | ForEach-Object { "<li>$_</li>" }) -join "`n"
$recsHtml = ($recommendations | ForEach-Object { "<li>$_</li>" }) -join "`n"

# Phase detail sections
$phaseDetailHtml = ""
foreach ($pf in $phaseFiles) {
    if ($phases.ContainsKey($pf.Name)) {
        $p = $phases[$pf.Name]
        $phaseDetailHtml += @"
<div class='phase-section'>
<h3>$($pf.Name)</h3>
<pre class='json-block'>$($p | ConvertTo-Json -Depth 5 | Out-String)</pre>
</div>
"@
    }
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Display Diagnostics Report - ROG Strix G713PV</title>
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1a1a2e; color: #e0e0e0; padding: 20px; }
    .container { max-width: 1200px; margin: 0 auto; }
    h1 { color: #00d4ff; font-size: 28px; margin-bottom: 5px; }
    h2 { color: #ff6b6b; font-size: 20px; margin: 25px 0 10px; border-bottom: 2px solid #333; padding-bottom: 8px; }
    h3 { color: #ffd93d; font-size: 16px; margin: 15px 0 8px; }
    .header { background: #16213e; padding: 25px; border-radius: 10px; margin-bottom: 20px; border-left: 5px solid #00d4ff; }
    .header .subtitle { color: #888; font-size: 14px; }
    .severity-badge { display: inline-block; padding: 5px 15px; border-radius: 20px; font-weight: bold; font-size: 18px; }
    .severity-CRITICAL { background: #ff4444; color: white; }
    .severity-ERROR { background: #ff8800; color: white; }
    .severity-WARN { background: #ffcc00; color: black; }
    .severity-OK { background: #44cc44; color: white; }
    .card { background: #16213e; padding: 20px; border-radius: 8px; margin: 10px 0; }
    table { width: 100%; border-collapse: collapse; margin: 10px 0; }
    th { background: #0f3460; padding: 10px; text-align: left; font-size: 13px; }
    td { padding: 8px 10px; border-bottom: 1px solid #333; font-size: 13px; }
    tr:hover { background: #1a1a3e; }
    .root-cause { background: #2d1b1b; border-left: 4px solid #ff4444; padding: 15px; margin: 10px 0; border-radius: 5px; }
    .recommendation { background: #1b2d1b; border-left: 4px solid #44cc44; padding: 15px; margin: 10px 0; border-radius: 5px; }
    ul { margin-left: 20px; }
    li { margin: 8px 0; line-height: 1.5; }
    .phase-section { margin: 10px 0; }
    .json-block { background: #0a0a1a; padding: 15px; border-radius: 5px; overflow-x: auto; font-size: 11px; max-height: 400px; overflow-y: auto; white-space: pre-wrap; word-wrap: break-word; }
    .system-info { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .info-item { background: #0f3460; padding: 10px; border-radius: 5px; }
    .info-label { color: #888; font-size: 12px; }
    .info-value { color: #fff; font-size: 14px; font-weight: bold; }
    .timestamp { color: #666; font-size: 12px; }
    details { margin: 5px 0; }
    summary { cursor: pointer; color: #00d4ff; padding: 5px; }
    summary:hover { color: #fff; }
</style>
</head>
<body>
<div class='container'>

<div class='header'>
    <h1>Display Diagnostics Report</h1>
    <div class='subtitle'>ASUS ROG Strix G713PV ($env:COMPUTERNAME)</div>
    <div class='subtitle'>AMD Ryzen 9 7845HX | AMD Radeon 610M (iGPU) | NVIDIA RTX 4060 Laptop (dGPU)</div>
    <div class='timestamp'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
    <br>
    <span class='severity-badge severity-$overallSeverity'>Overall: $overallSeverity</span>
    <span style='margin-left:15px;color:#888'>Issues: $($allIssues.Count) | Phases: $($phases.Count)/7</span>
</div>

<h2>Root Cause Analysis</h2>
<div class='root-cause'>
<ul>
$rootCauseHtml
</ul>
</div>

<h2>Recommendations (Priority Order)</h2>
<div class='recommendation'>
<ol>
$recsHtml
</ol>
</div>

<h2>All Issues Found ($($allIssues.Count))</h2>
<div class='card'>
<table>
<tr><th>Severity</th><th>Phase</th><th>Issue</th></tr>
$issueRows
</table>
</div>

<h2>Detailed Phase Results</h2>
<div class='card'>
$phaseDetailHtml
</div>

<h2>Hardware Quick Reference</h2>
<div class='card'>
<div class='system-info'>
    <div class='info-item'><div class='info-label'>Device</div><div class='info-value'>ASUS ROG Strix G713PV</div></div>
    <div class='info-item'><div class='info-label'>CPU</div><div class='info-value'>AMD Ryzen 9 7845HX</div></div>
    <div class='info-item'><div class='info-label'>iGPU (BROKEN)</div><div class='info-value'>AMD Radeon 610M — Code 43</div></div>
    <div class='info-item'><div class='info-label'>dGPU</div><div class='info-value'>NVIDIA GeForce RTX 4060 Laptop</div></div>
    <div class='info-item'><div class='info-label'>RAM</div><div class='info-value'>64 GB (63.2 GB usable)</div></div>
    <div class='info-item'><div class='info-label'>Display Resolution</div><div class='info-value'>640x480 (default/broken)</div></div>
    <div class='info-item'><div class='info-label'>Internal Panel</div><div class='info-value'>No BIOS splash / completely black</div></div>
    <div class='info-item'><div class='info-label'>Remote Access</div><div class='info-value'>Splashtop (only way to see screen)</div></div>
</div>
</div>

<h2>Next Steps If Software Fixes Fail</h2>
<div class='card'>
<ol>
    <li><strong>External monitor test:</strong> Connect HDMI or USB-C to Display Port adapter to external monitor. If it works via NVIDIA dGPU, the issue is isolated to the iGPU→internal panel path.</li>
    <li><strong>BIOS MUX switch:</strong> Boot into BIOS (press F2/DEL at power on — even if you can't see it, the laptop may still respond). Navigate to Advanced → GPU MUX and switch to dGPU/discrete mode. Save and exit.</li>
    <li><strong>CMOS/Battery reset:</strong> Power off. Disconnect AC. Remove bottom panel. Disconnect battery. Hold power button 30 seconds. Reconnect. Boot. This resets BIOS to defaults including MUX switch.</li>
    <li><strong>eDP cable reseat:</strong> With bottom panel open, locate the thin ribbon cable from motherboard to display panel. Disconnect and reconnect firmly.</li>
    <li><strong>Panel replacement:</strong> If external monitor works but internal panel shows nothing even after all fixes, the panel or backlight board has failed. Contact ASUS support for warranty repair.</li>
</ol>
</div>

</div>
</body>
</html>
"@

$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "  Report saved to: $reportPath" -ForegroundColor Green

if ($OpenReport) {
    Start-Process $reportPath
}

Write-Host "`nPhase 8 Complete.`n" -ForegroundColor Cyan
return $reportPath
