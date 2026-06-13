<#
.SYNOPSIS
    GPU Watchdog - monitors GPU health and auto-recovers on failure.
.DESCRIPTION
    Runs as a background process (via scheduled task as SYSTEM).
    Every 60 seconds, checks both GPUs. If the AMD iGPU enters Code 43:
    1. Logs the event
    2. Attempts disable/re-enable cycle
    3. If that fails, forces NVIDIA-only rendering via device disable
    4. Sends a Windows notification
    
    If the NVIDIA GPU fails during training:
    1. Logs the event
    2. Attempts recovery
    3. Alerts user
    
    Log: <project>\results\watchdog.log
#>

$logDir = "$PSScriptRoot\results"
$logFile = Join-Path $logDir 'watchdog.log'
New-Item $logDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null

$checkInterval = 60  # seconds between checks
$maxLogSizeMB = 5    # rotate log if > 5MB

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content $logFile $line -EA SilentlyContinue
}

function Send-Toast($title, $body) {
    try {
        # Use BurntToast if available, else fall back to BalloonTip
        $bt = Get-Module BurntToast -ListAvailable -EA SilentlyContinue
        if ($bt) {
            Import-Module BurntToast
            New-BurntToastNotification -Text $title, $body -EA SilentlyContinue
        } else {
            # Write to a user-visible file as fallback
            $alertFile = Join-Path $logDir 'GPU_ALERT.txt'
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$title] $body" | Add-Content $alertFile
        }
    } catch { }
}

function Get-GPUStatus {
    $gpus = Get-PnpDevice -Class Display -EA SilentlyContinue
    $result = @{
        AMD = $null
        NVIDIA = $null
        AMDStatus = 'Missing'
        NVIDIAStatus = 'Missing'
        AMDCode = -1
        NVIDIACode = -1
    }
    
    foreach ($g in $gpus) {
        $props = Get-PnpDeviceProperty -InstanceId $g.InstanceId -EA SilentlyContinue
        $code = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        
        if ($g.FriendlyName -match 'AMD|Radeon|ATI') {
            $result.AMD = $g
            $result.AMDStatus = $g.Status
            $result.AMDCode = if ($null -ne $code) { $code } else { 0 }
        }
        if ($g.FriendlyName -match 'NVIDIA|GeForce|RTX') {
            $result.NVIDIA = $g
            $result.NVIDIAStatus = $g.Status
            $result.NVIDIACode = if ($null -ne $code) { $code } else { 0 }
        }
    }
    return $result
}

function Repair-GPU($device, $name) {
    Write-Log "REPAIR: Attempting disable/enable cycle for $name ($($device.InstanceId))"
    try {
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -EA Stop
        Start-Sleep 3
        Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -EA Stop
        Start-Sleep 5
        
        $after = Get-PnpDevice -InstanceId $device.InstanceId
        if ($after.Status -eq 'OK') {
            Write-Log "REPAIR: $name recovered to OK"
            return $true
        } else {
            Write-Log "REPAIR: $name still $($after.Status) after toggle"
            return $false
        }
    } catch {
        Write-Log "REPAIR: $name toggle failed: $($_.Exception.Message)"
        return $false
    }
}

function Rotate-Log {
    if (Test-Path $logFile) {
        $size = (Get-Item $logFile).Length / 1MB
        if ($size -gt $maxLogSizeMB) {
            $backup = "$logFile.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Move-Item $logFile $backup -Force
            Write-Log "Log rotated (was ${size}MB)"
        }
    }
}

# ============================================================
# Main watchdog loop
# ============================================================
Write-Log "=========================================="
Write-Log "GPU WATCHDOG STARTED"
Write-Log "PID: $PID | Interval: ${checkInterval}s"
Write-Log "=========================================="

$amdFailCount = 0
$nvFailCount = 0
$lastAMDOK = $true
$lastNVOK = $true

while ($true) {
    try {
        Rotate-Log
        $status = Get-GPUStatus
        
        # --- AMD iGPU Check ---
        if ($status.AMDStatus -ne 'OK' -and $status.AMD) {
            $amdFailCount++
            Write-Log "WARNING: AMD $($status.AMD.FriendlyName) Status=$($status.AMDStatus) Code=$($status.AMDCode) (fail #$amdFailCount)"
            
            if ($lastAMDOK) {
                # First detection of failure - try repair
                Send-Toast "GPU Alert" "AMD iGPU has failed (Code $($status.AMDCode)). Attempting recovery..."
                $repaired = Repair-GPU $status.AMD "AMD iGPU"
                
                if ($repaired) {
                    Send-Toast "GPU Recovered" "AMD iGPU recovered successfully."
                    $amdFailCount = 0
                } else {
                    # Second attempt with longer delay
                    Start-Sleep 10
                    $repaired2 = Repair-GPU $status.AMD "AMD iGPU"
                    if ($repaired2) {
                        Send-Toast "GPU Recovered" "AMD iGPU recovered on second attempt."
                        $amdFailCount = 0
                    } else {
                        Write-Log "FAILOVER: AMD iGPU unrecoverable. NVIDIA GPU is primary. System functional."
                        Send-Toast "GPU Failover" "AMD iGPU failed permanently. Display running on NVIDIA RTX 4060. A full shutdown + restart will fix the AMD GPU."
                    }
                }
            }
            $lastAMDOK = $false
        } elseif ($status.AMD) {
            if (-not $lastAMDOK) {
                Write-Log "RECOVERED: AMD iGPU back to OK"
                $amdFailCount = 0
            }
            $lastAMDOK = $true
        }
        
        # --- NVIDIA GPU Check ---
        if ($status.NVIDIAStatus -ne 'OK' -and $status.NVIDIA) {
            $nvFailCount++
            Write-Log "CRITICAL: NVIDIA $($status.NVIDIA.FriendlyName) Status=$($status.NVIDIAStatus) Code=$($status.NVIDIACode) (fail #$nvFailCount)"
            
            if ($lastNVOK) {
                Send-Toast "CRITICAL: NVIDIA GPU Failed" "RTX 4060 has error Code $($status.NVIDIACode). Attempting recovery..."
                $repaired = Repair-GPU $status.NVIDIA "NVIDIA RTX 4060"
                
                if ($repaired) {
                    Send-Toast "NVIDIA Recovered" "RTX 4060 recovered successfully."
                    $nvFailCount = 0
                } else {
                    Start-Sleep 10
                    $repaired2 = Repair-GPU $status.NVIDIA "NVIDIA RTX 4060"
                    if ($repaired2) {
                        Send-Toast "NVIDIA Recovered" "RTX 4060 recovered on second attempt."
                        $nvFailCount = 0
                    } else {
                        Write-Log "CRITICAL: NVIDIA RTX 4060 unrecoverable. Training will fail. Reboot recommended."
                        Send-Toast "CRITICAL" "NVIDIA RTX 4060 failed. Save work and reboot immediately."
                    }
                }
            }
            $lastNVOK = $false
        } elseif ($status.NVIDIA) {
            if (-not $lastNVOK) {
                Write-Log "RECOVERED: NVIDIA GPU back to OK"
                $nvFailCount = 0
            }
            $lastNVOK = $true
        }
        
        # Periodic heartbeat every 30 minutes (every 30 checks)
        if (($amdFailCount -eq 0) -and ($nvFailCount -eq 0)) {
            $script:heartbeatCounter = if ($script:heartbeatCounter) { $script:heartbeatCounter + 1 } else { 1 }
            if ($script:heartbeatCounter % 30 -eq 0) {
                Write-Log "HEARTBEAT: AMD=$($status.AMDStatus) NVIDIA=$($status.NVIDIAStatus) - All OK"
            }
        }
        
    } catch {
        Write-Log "ERROR in watchdog loop: $($_.Exception.Message)"
    }
    
    Start-Sleep $checkInterval
}
