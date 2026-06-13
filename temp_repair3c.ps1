$outFile = "$PSScriptRoot\results\repair3_output.txt"
$log = @()
$log += "START: $(Get-Date)"
$log += "User: $env:USERNAME"
$log += "Admin: $([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
try {
    if (Test-Path 'HKLM:\SOFTWARE\ASUS') {
        $all = Get-ChildItem 'HKLM:\SOFTWARE\ASUS' -Recurse -ErrorAction SilentlyContinue
        foreach ($k in $all) {
            $keyName = $k.Name -replace '^HKEY_LOCAL_MACHINE','HKLM:'
            if ($k.Name -match 'GPU|Mux|Display|Switch|Mode|Armoury|Smart') {
                $log += "KEY: $($k.Name)"
                try {
                    $vals = Get-ItemProperty "Registry::$($k.Name)" -ErrorAction SilentlyContinue
                    $vals.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                        $log += "  $($_.Name) = $($_.Value)"
                    }
                } catch {}
            }
        }
    } else {
        $log += "ASUS key not found"
    }
    $dp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    Get-ChildItem $dp -EA SilentlyContinue | ForEach-Object {
        $v = Get-ItemProperty $_.PSPath -EA SilentlyContinue
        if ($v.DriverDesc) { $log += "GPU: $($v.DriverDesc) Hybrid=$($v.EnableMsHybrid)" }
    }
} catch {
    $log += "ERROR: $($_.Exception.Message)"
}
$log += "END: $(Get-Date)"
$log | Out-File $outFile -Encoding UTF8
