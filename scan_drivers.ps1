# ============================================================================
# Phase 3: Driver Analysis
# ============================================================================
param([switch]$AsJob)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp = Get-Date -Format 'o'
    Phase     = 'Phase3_DriverAnalysis'
    Issues    = @()
    Data      = @{}
}

Write-DiagHeader "PHASE 3: Driver Analysis"

# --- 3.1 AMD Driver Deep Inspection ---
Write-DiagSection "3.1 AMD Driver Files & Integrity"
$amdDrivers = Safe-Execute "Inspecting AMD driver files" {
    $driverFiles = @()
    $searchPaths = @(
        'C:\Windows\System32\drivers\ati*.sys',
        'C:\Windows\System32\drivers\amd*.sys',
        'C:\Windows\System32\ati*.dll',
        'C:\Windows\System32\amd*.dll',
        'C:\Windows\SysWOW64\ati*.dll',
        'C:\Windows\SysWOW64\amd*.dll'
    )
    foreach ($pattern in $searchPaths) {
        $files = Get-ChildItem $pattern -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $sig = Get-AuthenticodeSignature $f.FullName -ErrorAction SilentlyContinue
            $driverFiles += @{
                Name       = $f.Name
                FullPath   = $f.FullName
                Size_KB    = [math]::Round($f.Length / 1KB)
                LastWrite  = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                Created    = $f.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
                SignStatus = $sig.Status.ToString()
                Signer     = $sig.SignerCertificate.Subject
                Version    = (Get-ItemProperty $f.FullName -ErrorAction SilentlyContinue).VersionInfo.FileVersion
            }
        }
    }
    $driverFiles
}
if ($amdDrivers.Success) {
    $results.Data.AMDDriverFiles = $amdDrivers.Data
    if (@($amdDrivers.Data).Count -eq 0) {
        Write-DiagResult "AMD Drivers" "No AMD driver files found!" 'ERROR'
        $results.Issues += "ERROR: No AMD driver files found in System32/drivers - driver may be completely missing"
    } else {
        foreach ($df in $amdDrivers.Data) {
            $s = if ($df.SignStatus -eq 'Valid') { 'OK' } else { 'WARN' }
            Write-DiagResult $df.Name "Size=$($df.Size_KB)KB Sig=$($df.SignStatus) Modified=$($df.LastWrite)" $s
            if ($df.SignStatus -ne 'Valid') {
                $results.Issues += "WARN: AMD driver file $($df.Name) signature is $($df.SignStatus) - possible corruption"
            }
        }
    }
}

# --- 3.2 AMD Registry Driver Info ---
Write-DiagSection "3.2 AMD Driver Registry Configuration"
$amdReg = Safe-Execute "Reading AMD driver registry" {
    $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $amdEntries = @()
    if (Test-Path $classPath) {
        Get-ChildItem $classPath -ErrorAction SilentlyContinue | ForEach-Object {
            $vals = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($vals.DriverDesc -match 'AMD|Radeon|ATI') {
                $amdEntries += @{
                    SubKey        = $_.PSChildName
                    DriverDesc    = $vals.DriverDesc
                    DriverVersion = $vals.DriverVersion
                    DriverDate    = $vals.DriverDate
                    ProviderName  = $vals.ProviderName
                    InfPath       = $vals.InfPath
                    InfSection    = $vals.InfSection
                    MatchingDevId = $vals.MatchingDeviceId
                    UserModeDriverName = $vals.UserModeDriverName
                    InstalledDisplayDrivers = $vals.InstalledDisplayDrivers
                }
            }
        }
    }
    $amdEntries
}
if ($amdReg.Success) {
    $results.Data.AMDRegistry = $amdReg.Data
    foreach ($entry in $amdReg.Data) {
        Write-DiagResult "AMD Reg [$($entry.SubKey)]" "Driver=$($entry.DriverDesc) Ver=$($entry.DriverVersion)" 'INFO'
        Write-DiagResult "  INF" "$($entry.InfPath) [$($entry.InfSection)]" 'INFO'
        Write-DiagResult "  Device ID" $entry.MatchingDevId 'INFO'
    }
}

# --- 3.3 NVIDIA Driver Deep Inspection ---
Write-DiagSection "3.3 NVIDIA Driver Files & Integrity"
$nvidiaDrivers = Safe-Execute "Inspecting NVIDIA driver files" {
    $driverFiles = @()
    $keyFiles = @(
        'C:\Windows\System32\drivers\nvlddmkm.sys',
        'C:\Windows\System32\nvapi64.dll',
        'C:\Windows\System32\nvcuda.dll',
        'C:\Windows\System32\nvml.dll',
        'C:\Windows\SysWOW64\nvapi.dll'
    )
    foreach ($path in $keyFiles) {
        if (Test-Path $path) {
            $f = Get-Item $path
            $sig = Get-AuthenticodeSignature $f.FullName -ErrorAction SilentlyContinue
            $vi = (Get-Command $f.FullName -ErrorAction SilentlyContinue).FileVersionInfo
            $driverFiles += @{
                Name       = $f.Name
                FullPath   = $f.FullName
                Size_MB    = [math]::Round($f.Length / 1MB, 1)
                LastWrite  = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                SignStatus = $sig.Status.ToString()
                Signer     = $sig.SignerCertificate.Subject
                FileVersion = $vi.FileVersion
                ProductVersion = $vi.ProductVersion
            }
        }
    }
    $driverFiles
}
if ($nvidiaDrivers.Success) {
    $results.Data.NVIDIADriverFiles = $nvidiaDrivers.Data
    foreach ($df in $nvidiaDrivers.Data) {
        $s = if ($df.SignStatus -eq 'Valid') { 'OK' } else { 'WARN' }
        Write-DiagResult $df.Name "Size=$($df.Size_MB)MB Ver=$($df.FileVersion) Sig=$($df.SignStatus)" $s
        if ($df.SignStatus -ne 'Valid') {
            $results.Issues += "WARN: NVIDIA driver file $($df.Name) signature is $($df.SignStatus)"
        }
    }
}

# --- 3.4 NVIDIA Registry Driver Info ---
Write-DiagSection "3.4 NVIDIA Driver Registry Configuration"
$nvReg = Safe-Execute "Reading NVIDIA driver registry" {
    $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $nvEntries = @()
    if (Test-Path $classPath) {
        Get-ChildItem $classPath -ErrorAction SilentlyContinue | ForEach-Object {
            $vals = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($vals.DriverDesc -match 'NVIDIA|GeForce') {
                $nvEntries += @{
                    SubKey        = $_.PSChildName
                    DriverDesc    = $vals.DriverDesc
                    DriverVersion = $vals.DriverVersion
                    DriverDate    = $vals.DriverDate
                    ProviderName  = $vals.ProviderName
                    InfPath       = $vals.InfPath
                    MatchingDevId = $vals.MatchingDeviceId
                }
            }
        }
    }
    $nvEntries
}
if ($nvReg.Success) {
    $results.Data.NVIDIARegistry = $nvReg.Data
    foreach ($entry in $nvReg.Data) {
        Write-DiagResult "NV Reg [$($entry.SubKey)]" "Driver=$($entry.DriverDesc) Ver=$($entry.DriverVersion)" 'INFO'
    }
}

# --- 3.5 All Display Driver Packages (pnputil) ---
Write-DiagSection "3.5 Installed Display Driver Packages"
$driverPkgs = Safe-Execute "Enumerating driver packages via pnputil" {
    $raw = pnputil /enum-drivers /class "Display" 2>&1
    $raw -join "`n"
}
if ($driverPkgs.Success) {
    $results.Data.DriverPackages = $driverPkgs.Data
    Write-Host $driverPkgs.Data
}

# --- 3.6 Driver Event History (last 30 days) ---
Write-DiagSection "3.6 Display/GPU Driver Events (last 30 days)"
$driverEvents = Safe-Execute "Scanning System event log for display driver events" {
    $startDate = (Get-Date).AddDays(-30)
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        StartTime = $startDate
    } -MaxEvents 5000 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'display|video|amd|nvidia|radeon|gpu|nvlddmkm|atikmdag|dwm|dxgkrnl|dxgmms' } |
        Select-Object -First 50 |
        ForEach-Object {
            @{
                TimeCreated = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $_.Id
                Level       = $_.LevelDisplayName
                Provider    = $_.ProviderName
                Message     = $_.Message.Substring(0, [Math]::Min($_.Message.Length, 300))
            }
        }
    $events
}
if ($driverEvents.Success) {
    $results.Data.DriverEvents = $driverEvents.Data
    $evtCount = @($driverEvents.Data).Count
    Write-DiagResult "Driver Events" "$evtCount event(s) found in last 30 days" $(if ($evtCount -gt 10) { 'WARN' } else { 'OK' })
    foreach ($evt in $driverEvents.Data | Select-Object -First 15) {
        $s = switch ($evt.Level) { 'Error' { 'ERROR' } 'Warning' { 'WARN' } default { 'INFO' } }
        Write-DiagResult "  [$($evt.TimeCreated)]" "EventId=$($evt.Id) $($evt.Provider): $($evt.Message.Substring(0, [Math]::Min($evt.Message.Length, 120)))" $s
    }
    $errorCount = @($driverEvents.Data | Where-Object { $_.Level -eq 'Error' }).Count
    if ($errorCount -gt 0) {
        $results.Issues += "WARN: $errorCount error-level display/GPU events in last 30 days"
    }
}

# --- 3.7 Windows Update Driver Changes ---
Write-DiagSection "3.7 Recent Windows Updates (driver-related)"
$wuHistory = Safe-Execute "Checking Windows Update history for driver updates" {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $historyCount = $searcher.GetTotalHistoryCount()
    $history = $searcher.QueryHistory(0, [Math]::Min($historyCount, 100))
    $driverUpdates = @()
    foreach ($h in $history) {
        if ($h.Title -match 'display|video|amd|nvidia|radeon|gpu|graphics') {
            $driverUpdates += @{
                Title     = $h.Title
                Date      = $h.Date.ToString('yyyy-MM-dd HH:mm:ss')
                Result    = switch ($h.ResultCode) { 0 { 'NotStarted' } 1 { 'InProgress' } 2 { 'Succeeded' } 3 { 'SucceededWithErrors' } 4 { 'Failed' } 5 { 'Aborted' } }
                Operation = switch ($h.Operation) { 1 { 'Install' } 2 { 'Uninstall' } }
            }
        }
    }
    $driverUpdates
}
if ($wuHistory.Success) {
    $results.Data.WindowsUpdateDrivers = $wuHistory.Data
    $wuCount = @($wuHistory.Data).Count
    Write-DiagResult "Driver WU History" "$wuCount display/GPU update(s) found" 'INFO'
    foreach ($wu in $wuHistory.Data | Select-Object -First 10) {
        $s = if ($wu.Result -eq 'Failed') { 'ERROR' } elseif ($wu.Result -eq 'Succeeded') { 'OK' } else { 'WARN' }
        Write-DiagResult "  [$($wu.Date)]" "$($wu.Operation): $($wu.Title) -> $($wu.Result)" $s
        if ($wu.Result -eq 'Failed') {
            $results.Issues += "WARN: Failed driver update: $($wu.Title) on $($wu.Date)"
        }
    }
}

# --- Summary ---
Write-DiagSection "Phase 3 Summary"
$severity = Get-Severity $results.Issues
Write-DiagResult "Overall Severity" $severity $severity
Write-DiagResult "Issues Found" "$($results.Issues.Count)" $(if ($results.Issues.Count -eq 0) { 'OK' } else { 'WARN' })
foreach ($issue in $results.Issues) {
    Write-Host "  ! $issue" -ForegroundColor $(if ($issue -match 'CRITICAL') { 'Magenta' } elseif ($issue -match 'ERROR') { 'Red' } else { 'Yellow' })
}

Save-Result "phase3_drivers.json" $results
Write-Host "`nPhase 3 Complete.`n" -ForegroundColor Cyan
return $results
