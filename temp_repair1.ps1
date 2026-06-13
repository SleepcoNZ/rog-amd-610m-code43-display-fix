$outFile = "$PSScriptRoot\results\repair1_output.txt"
try {
    Set-Location "$PSScriptRoot"
    $ErrorActionPreference = 'Continue'
    . .\lib\helpers.ps1
    $log = @()

    $isAdmin = Test-IsAdmin
    $log += "Admin: $isAdmin"

    $amd = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'AMD|Radeon|ATI' }
    if (-not $amd) {
        $log += "ERROR: AMD device not found"
    } else {
        $log += "Found: $($amd.FriendlyName) Status=$($amd.Status) InstanceId=$($amd.InstanceId)"
        $log += "Disabling..."
        Disable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        $log += "Re-enabling..."
        Enable-PnpDevice -InstanceId $amd.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 5
        $amdAfter = Get-PnpDevice -InstanceId $amd.InstanceId
        $props = Get-PnpDeviceProperty -InstanceId $amd.InstanceId
        $newCode = ($props | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        $log += "AFTER: Status=$($amdAfter.Status) ProblemCode=$newCode"
        if ($newCode -eq 0 -and $amdAfter.Status -eq 'OK') {
            $log += "SUCCESS: Code 43 CLEARED!"
        } else {
            $log += "STILL BROKEN: Code 43 persists"
        }
    }
    $log | Out-File $outFile -Encoding UTF8
} catch {
    "EXCEPTION: $($_.Exception.Message)" | Out-File $outFile -Encoding UTF8
}
