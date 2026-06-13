<#
.SYNOPSIS
    ASUS ROG MUX Switch + Critical Repairs - Run as Administrator
.DESCRIPTION
    Right-click this file -> Run with PowerShell (as Admin)
    Or: Open Admin PowerShell -> .\Run-AdminRepairs.ps1
    
    This script:
    1. Toggles MUX switch to Discrete GPU mode (bypass broken iGPU)
    2. Power-cycles all display adapters
    3. Attempts AMD driver reinstall
    4. Reports results
    
    After running, do a FULL SHUTDOWN (not restart):
      shutdown /s /t 0
    Then power the laptop back on manually.
#>

$outFile = Join-Path $PSScriptRoot 'results\admin_repairs_output.txt'
$log = [System.Collections.ArrayList]::new()

function Log($msg) {
    [void]$log.Add("$(Get-Date -Format 'HH:mm:ss') $msg")
    Write-Host $msg
}

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script MUST be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click -> Run as Administrator, or open an Admin PowerShell first." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Log "=== ADMIN REPAIRS STARTED ==="
Log "User: $env:USERNAME, Admin: $isAdmin"

# ============================================================
# REPAIR A: MUX Switch Toggle via ASUS WMI
# ============================================================
Log ""
Log "=== REPAIR A: MUX Switch Toggle ==="
try {
    $atk = Get-CimInstance -Namespace root\WMI -ClassName AsusAtkWmi_WMNB -ErrorAction Stop
    Log "ASUS ATK WMI found: $($atk.InstanceName)"

    # Read current MUX state
    try {
        $state = Invoke-CimMethod -InputObject $atk -MethodName DSTS -Arguments @{ Device_ID = 0x00090016 } -ErrorAction Stop
        $currentVal = $state.ReturnValue
        Log "Current MUX state (0x00090016): $currentVal"
        # Bit 0: 0=Discrete, 1=Optimus/MSHybrid
        if ($currentVal -band 0x00010000) {
            $currentMode = $currentVal -band 0xFFFF
            Log "Decoded: MUX supported, current mode = $currentMode"
        }
    } catch {
        Log "DSTS read failed: $($_.Exception.Message)"
    }

    # Set MUX to discrete mode (bypass iGPU)
    try {
        $result = Invoke-CimMethod -InputObject $atk -MethodName DEVS -Arguments @{ Device_ID = 0x00090016; Control_Status = 0 } -ErrorAction Stop
        Log "MUX set to DISCRETE: ReturnValue=$($result.ReturnValue)"
        Log ">>> REBOOT REQUIRED for MUX change to take effect <<<"
    } catch {
        Log "DEVS set failed: $($_.Exception.Message)"
        
        # Try alternative value (1 = Ultimate/Direct)
        try {
            $result2 = Invoke-CimMethod -InputObject $atk -MethodName DEVS -Arguments @{ Device_ID = 0x00090016; Control_Status = 1 } -ErrorAction Stop
            Log "MUX set to 1 (alt discrete): ReturnValue=$($result2.ReturnValue)"
        } catch {
            Log "Alt DEVS also failed: $($_.Exception.Message)"
        }
    }

    # Verify
    try {
        $newState = Invoke-CimMethod -InputObject $atk -MethodName DSTS -Arguments @{ Device_ID = 0x00090016 } -ErrorAction Stop
        Log "New MUX state: $($newState.ReturnValue)"
    } catch {
        Log "Post-verify failed: $($_.Exception.Message)"
    }
} catch {
    Log "ASUS ATK WMI not available: $($_.Exception.Message)"
    Log "Listing available ASUS WMI classes..."
    try {
        $classes = Get-CimClass -Namespace root\WMI -ErrorAction Stop | Where-Object { $_.CimClassName -match 'ASUS|ATK' }
        foreach ($c in $classes) { Log "  $($c.CimClassName)" }
    } catch {
        Log "WMI enum failed: $($_.Exception.Message)"
    }
}

# ============================================================
# REPAIR B: Power-Cycle Display Adapters
# ============================================================
Log ""
Log "=== REPAIR B: Power-Cycle Display Adapters ==="
$gpus = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue

foreach ($gpu in $gpus) {
    Log "Disabling $($gpu.FriendlyName) ($($gpu.Status))..."
    Disable-PnpDevice -InstanceId $gpu.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 5

foreach ($gpu in $gpus) {
    Log "Enabling $($gpu.FriendlyName)..."
    Enable-PnpDevice -InstanceId $gpu.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 8

# Check results
$gpusAfter = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue
foreach ($g in $gpusAfter) {
    $props = Get-PnpDeviceProperty -InstanceId $g.InstanceId -ErrorAction SilentlyContinue
    $code = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    $status = if ($g.Status -eq 'OK' -and $code -eq 0) { "OK" } else { "PROBLEM (Code $code)" }
    Log "  $($g.FriendlyName): Status=$($g.Status) ProblemCode=$code => $status"
}

# ============================================================
# REPAIR C: AMD Driver Remove & Rescan
# ============================================================
Log ""
Log "=== REPAIR C: AMD Driver Remove & Rescan ==="
$amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
if ($amd -and $amd.Status -ne 'OK') {
    Log "AMD still broken, attempting driver remove & rescan..."
    try {
        & pnputil /remove-device "$($amd.InstanceId)" 2>&1 | ForEach-Object { Log "  $_" }
        Start-Sleep -Seconds 3
        & pnputil /scan-devices 2>&1 | ForEach-Object { Log "  $_" }
        Start-Sleep -Seconds 10
        
        $amdAfter = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
        if ($amdAfter) {
            $props = Get-PnpDeviceProperty -InstanceId $amdAfter.InstanceId -ErrorAction SilentlyContinue
            $code = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
            Log "AMD after rescan: Status=$($amdAfter.Status) ProblemCode=$code"
        } else {
            Log "AMD device not found after rescan - will need manual driver install"
        }
    } catch {
        Log "AMD remove/rescan failed: $($_.Exception.Message)"
    }
} elseif ($amd -and $amd.Status -eq 'OK') {
    Log "AMD is now OK! Skipping driver remove."
} else {
    Log "AMD device not found"
}

# ============================================================
# REPAIR D: SFC + DISM (quick)
# ============================================================
Log ""
Log "=== REPAIR D: Quick SFC scan ==="
try {
    $sfcOut = & sfc /verifyonly 2>&1
    $sfcText = $sfcOut -join " "
    if ($sfcText -match 'did not find any integrity violations') {
        Log "SFC: System files are clean"
    } elseif ($sfcText -match 'found corrupt files') {
        Log "SFC: Corruption found - running /scannow..."
        & sfc /scannow 2>&1 | Select-Object -Last 3 | ForEach-Object { Log "  $_" }
    } else {
        Log "SFC result: $($sfcOut | Select-Object -Last 2)"
    }
} catch {
    Log "SFC failed: $($_.Exception.Message)"
}

# ============================================================
# Summary
# ============================================================
Log ""
Log "=== SUMMARY ==="
$gpusFinal = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue
foreach ($g in $gpusFinal) {
    $props = Get-PnpDeviceProperty -InstanceId $g.InstanceId -ErrorAction SilentlyContinue
    $code = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
    Log "  $($g.FriendlyName): Status=$($g.Status) Code=$code"
}

Log ""
Log "=== NEXT STEPS ==="
Log "1. Do a FULL SHUTDOWN (not restart): shutdown /s /t 0"
Log "2. Wait 10 seconds, then power on the laptop"
Log "3. Check if the built-in screen turns on"
Log "4. If screen is still black, try connecting an external monitor via HDMI/USB-C"
Log ""
Log "=== REPAIRS COMPLETE ==="

# Save results
$log | Out-File $outFile -Encoding UTF8
Write-Host "`nResults saved to: $outFile" -ForegroundColor Green
Write-Host "`nPress Enter to exit..." -ForegroundColor Cyan
Read-Host
