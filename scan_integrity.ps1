# ============================================================================
# Phase 6: System File & Image Integrity
# Requires: Admin privileges (will self-elevate)
# ============================================================================
param([switch]$AsJob)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp = Get-Date -Format 'o'
    Phase     = 'Phase6_Integrity'
    Issues    = @()
    Data      = @{}
}

Write-DiagHeader "PHASE 6: System File & Image Integrity"

$isAdmin = Test-IsAdmin

# --- 6.1 Display Subsystem DLL Verification ---
Write-DiagSection "6.1 Display Subsystem DLL Verification"
$dllCheck = Safe-Execute "Verifying critical display DLLs" {
    $criticalFiles = @(
        'C:\Windows\System32\dxgi.dll',
        'C:\Windows\System32\d3d11.dll',
        'C:\Windows\System32\d3d12.dll',
        'C:\Windows\System32\d3d10warp.dll',
        'C:\Windows\System32\dwm.exe',
        'C:\Windows\System32\dwmcore.dll',
        'C:\Windows\System32\win32kfull.sys',
        'C:\Windows\System32\dxgkrnl.sys',
        'C:\Windows\System32\dxgmms1.sys',
        'C:\Windows\System32\dxgmms2.sys',
        'C:\Windows\System32\DriverStore\FileRepository',
        'C:\Windows\System32\OpenCL.dll',
        'C:\Windows\System32\vulkan-1.dll'
    )
    $fileResults = @()
    foreach ($path in $criticalFiles) {
        if ($path -match 'FileRepository$') {
            # Check driver store has AMD and NVIDIA folders
            if (Test-Path $path) {
                $amdFolders = Get-ChildItem $path -Directory -Filter 'u*amd*' -ErrorAction SilentlyContinue
                $nvFolders = Get-ChildItem $path -Directory -Filter '*nvl*' -ErrorAction SilentlyContinue
                $fileResults += @{
                    Name       = 'DriverStore AMD Folders'
                    Path       = $path
                    Exists     = $true
                    Count      = @($amdFolders).Count
                    Details    = ($amdFolders | Select-Object -First 3 | ForEach-Object { $_.Name }) -join '; '
                }
                $fileResults += @{
                    Name       = 'DriverStore NVIDIA Folders'
                    Path       = $path
                    Exists     = $true
                    Count      = @($nvFolders).Count
                    Details    = ($nvFolders | Select-Object -First 3 | ForEach-Object { $_.Name }) -join '; '
                }
            }
            continue
        }
        $exists = Test-Path $path
        $info = @{
            Name   = Split-Path $path -Leaf
            Path   = $path
            Exists = $exists
        }
        if ($exists) {
            $f = Get-Item $path
            $sig = Get-AuthenticodeSignature $path -ErrorAction SilentlyContinue
            $info.Size_KB    = [math]::Round($f.Length / 1KB)
            $info.LastWrite  = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            $info.SignStatus = $sig.Status.ToString()
            $info.Signer     = $sig.SignerCertificate.Subject
        }
        $fileResults += $info
    }
    $fileResults
}
if ($dllCheck.Success) {
    $results.Data.DisplayDLLs = $dllCheck.Data
    foreach ($f in $dllCheck.Data) {
        if (-not $f.Exists) {
            Write-DiagResult $f.Name "MISSING!" 'ERROR'
            $results.Issues += "ERROR: Critical display file missing: $($f.Path)"
        } elseif ($f.SignStatus -and $f.SignStatus -ne 'Valid') {
            Write-DiagResult $f.Name "Sig=$($f.SignStatus) Size=$($f.Size_KB)KB" 'WARN'
            $results.Issues += "WARN: $($f.Name) has invalid signature ($($f.SignStatus)) - possible corruption"
        } elseif ($f.Count -ne $null) {
            Write-DiagResult $f.Name "Count=$($f.Count) [$($f.Details)]" $(if ($f.Count -gt 0) { 'OK' } else { 'WARN' })
        } else {
            Write-DiagResult $f.Name "OK Size=$($f.Size_KB)KB Sig=$($f.SignStatus)" 'OK'
        }
    }
}

# --- 6.2 SFC Scan (requires admin) ---
Write-DiagSection "6.2 System File Checker (SFC)"
if ($isAdmin) {
    $sfcResult = Safe-Execute "Running SFC /scannow (this may take several minutes)" {
        $output = & sfc /scannow 2>&1
        $outputText = $output -join "`n"
        @{
            Output     = $outputText
            HasErrors  = $outputText -match 'found corrupt|could not repair|integrity violations'
            Repaired   = $outputText -match 'successfully repaired'
            Clean      = $outputText -match 'did not find any integrity violations'
        }
    }
    if ($sfcResult.Success) {
        $results.Data.SFC = $sfcResult.Data
        if ($sfcResult.Data.Clean) {
            Write-DiagResult "SFC" "No integrity violations found" 'OK'
        } elseif ($sfcResult.Data.Repaired) {
            Write-DiagResult "SFC" "Found and repaired corrupt files" 'WARN'
            $results.Issues += "WARN: SFC found and repaired corrupt system files - display DLLs may have been affected"
        } elseif ($sfcResult.Data.HasErrors) {
            Write-DiagResult "SFC" "Found corrupt files that could NOT be repaired" 'ERROR'
            $results.Issues += "ERROR: SFC found unrepairable corruption - run DISM RestoreHealth then SFC again"
        }
        # Show last 10 lines of output
        $lines = $sfcResult.Data.Output -split "`n"
        $lines | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
} else {
    Write-DiagResult "SFC" "SKIPPED - requires admin. Will run via elevated orchestrator." 'WARN'
    $results.Data.SFC = @{ Skipped = $true; Reason = "Not running as admin" }
}

# --- 6.3 DISM Health Check (requires admin) ---
Write-DiagSection "6.3 DISM Component Store Health"
if ($isAdmin) {
    $dismResult = Safe-Execute "Running DISM /ScanHealth (this may take several minutes)" {
        $checkOutput = & DISM /Online /Cleanup-Image /CheckHealth 2>&1
        $scanOutput = & DISM /Online /Cleanup-Image /ScanHealth 2>&1
        $checkText = $checkOutput -join "`n"
        $scanText = $scanOutput -join "`n"
        @{
            CheckHealth = $checkText
            ScanHealth  = $scanText
            Healthy     = $scanText -match 'No component store corruption detected'
            Repairable  = $scanText -match 'component store corruption.*repairable'
            Corrupt     = $scanText -match 'component store corruption' -and -not ($scanText -match 'No component store corruption')
        }
    }
    if ($dismResult.Success) {
        $results.Data.DISM = $dismResult.Data
        if ($dismResult.Data.Healthy) {
            Write-DiagResult "DISM" "Component store is healthy" 'OK'
        } elseif ($dismResult.Data.Repairable) {
            Write-DiagResult "DISM" "Component store corruption detected (repairable)" 'WARN'
            $results.Issues += "WARN: DISM found repairable corruption - run DISM /RestoreHealth"
        } elseif ($dismResult.Data.Corrupt) {
            Write-DiagResult "DISM" "Component store corruption detected" 'ERROR'
            $results.Issues += "ERROR: Component store corruption detected by DISM"
        }
    }
} else {
    Write-DiagResult "DISM" "SKIPPED - requires admin" 'WARN'
    $results.Data.DISM = @{ Skipped = $true }
}

# --- 6.4 Windows Image Health via Registry ---
Write-DiagSection "6.4 Component Based Servicing (CBS) Log Check"
$cbsCheck = Safe-Execute "Checking CBS log for display component errors" {
    $cbsLog = 'C:\Windows\Logs\CBS\CBS.log'
    if (Test-Path $cbsLog) {
        $logSize = (Get-Item $cbsLog).Length / 1MB
        # Read last 500 lines looking for display-related errors
        $tail = Get-Content $cbsLog -Tail 500 -ErrorAction SilentlyContinue
        $displayErrors = $tail | Where-Object { $_ -match 'display|video|gpu|dxgi|d3d|dwm|graphics' -and $_ -match 'error|fail|corrupt' }
        @{
            LogSizeMB     = [math]::Round($logSize, 1)
            DisplayErrors = ($displayErrors | Select-Object -Last 10) -join "`n"
            ErrorCount    = @($displayErrors).Count
        }
    } else {
        @{ Available = $false }
    }
}
if ($cbsCheck.Success) {
    $results.Data.CBSLog = $cbsCheck.Data
    if ($cbsCheck.Data.Available -eq $false) {
        Write-DiagResult "CBS Log" "Not accessible" 'WARN'
    } else {
        Write-DiagResult "CBS Log" "Size=$($cbsCheck.Data.LogSizeMB)MB DisplayErrors=$($cbsCheck.Data.ErrorCount)" $(if ($cbsCheck.Data.ErrorCount -gt 0) { 'WARN' } else { 'OK' })
        if ($cbsCheck.Data.ErrorCount -gt 0) {
            Write-Host $cbsCheck.Data.DisplayErrors -ForegroundColor DarkGray
        }
    }
}

# --- 6.5 Driver Store Integrity ---
Write-DiagSection "6.5 Driver Store Integrity"
$driverStore = Safe-Execute "Verifying driver store" {
    $storePath = 'C:\Windows\System32\DriverStore\FileRepository'
    $amdDirs = Get-ChildItem $storePath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'amd|ati|radeon' }
    $nvDirs = Get-ChildItem $storePath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'nv|nvidia|geforce' }

    $amdDetail = $amdDirs | ForEach-Object {
        $files = Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue
        @{
            Name      = $_.Name
            FileCount = @($files).Count
            Size_MB   = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
            Modified  = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    $nvDetail = $nvDirs | ForEach-Object {
        $files = Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue
        @{
            Name      = $_.Name
            FileCount = @($files).Count
            Size_MB   = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
            Modified  = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    @{
        AMD_Packages    = $amdDetail
        NVIDIA_Packages = $nvDetail
        AMD_Count       = @($amdDirs).Count
        NVIDIA_Count    = @($nvDirs).Count
    }
}
if ($driverStore.Success) {
    $results.Data.DriverStore = $driverStore.Data
    Write-DiagResult "AMD Driver Packages" "$($driverStore.Data.AMD_Count) package(s) in driver store" $(if ($driverStore.Data.AMD_Count -gt 0) { 'OK' } else { 'ERROR' })
    Write-DiagResult "NVIDIA Driver Packages" "$($driverStore.Data.NVIDIA_Count) package(s) in driver store" $(if ($driverStore.Data.NVIDIA_Count -gt 0) { 'OK' } else { 'ERROR' })
    foreach ($pkg in $driverStore.Data.AMD_Packages) {
        Write-DiagResult "  AMD" "$($pkg.Name) Files=$($pkg.FileCount) Size=$($pkg.Size_MB)MB" 'INFO'
    }
    foreach ($pkg in $driverStore.Data.NVIDIA_Packages) {
        Write-DiagResult "  NV" "$($pkg.Name) Files=$($pkg.FileCount) Size=$($pkg.Size_MB)MB" 'INFO'
    }
    if ($driverStore.Data.AMD_Count -eq 0) {
        $results.Issues += "CRITICAL: No AMD driver packages in DriverStore - driver is completely missing"
    }
}

# --- Summary ---
Write-DiagSection "Phase 6 Summary"
$severity = Get-Severity $results.Issues
Write-DiagResult "Overall Severity" $severity $severity
Write-DiagResult "Issues Found" "$($results.Issues.Count)" $(if ($results.Issues.Count -eq 0) { 'OK' } else { 'WARN' })
foreach ($issue in $results.Issues) {
    Write-Host "  ! $issue" -ForegroundColor $(if ($issue -match 'CRITICAL') { 'Magenta' } elseif ($issue -match 'ERROR') { 'Red' } else { 'Yellow' })
}

Save-Result "phase6_integrity.json" $results
Write-Host "`nPhase 6 Complete.`n" -ForegroundColor Cyan
return $results
