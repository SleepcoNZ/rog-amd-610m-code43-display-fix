$outFile = "$PSScriptRoot\results\repair3_output.txt"
$log = @()
$log += "START: $(Get-Date)"
try {
    # Search all ASUS keys for anything GPU/MUX related
    if (Test-Path 'HKLM:\SOFTWARE\ASUS') {
        $all = Get-ChildItem 'HKLM:\SOFTWARE\ASUS' -Recurse -ErrorAction SilentlyContinue
        foreach ($k in $all) {
            $name = $k.Name
            $log += "KEY: $name"
            $vals = Get-ItemProperty "Registry::$name" -ErrorAction SilentlyContinue
            $vals.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $log += "  $($_.Name) = $($_.Value)"
            }
        }
    } else {
        $log += "HKLM:\SOFTWARE\ASUS does not exist"
    }

    # Display adapter class
    $dp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (Test-Path $dp) {
        Get-ChildItem $dp -ErrorAction SilentlyContinue | ForEach-Object {
            $v = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($v.DriverDesc) {
                $log += "DISPLAY: $($v.DriverDesc) EnableMsHybrid=$($v.EnableMsHybrid)"
            }
        }
    }
} catch {
    $log += "ERROR: $($_.Exception.Message)"
}
$log += "END: $(Get-Date)"
$log | Out-File $outFile -Encoding UTF8
