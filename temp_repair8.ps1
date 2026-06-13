$outFile = "$PSScriptRoot\results\repair8_output.txt"
try {
    Set-Location "$PSScriptRoot"
    . .\lib\helpers.ps1
    $log = @()
    $log += "Admin: $(Test-IsAdmin)"

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $before = (Get-ItemProperty $regPath -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    $log += "Fast Startup BEFORE: $before (1=enabled, 0=disabled)"

    if ($before -eq 1) {
        Set-ItemProperty $regPath -Name HiberbootEnabled -Value 0
        $after = (Get-ItemProperty $regPath -Name HiberbootEnabled).HiberbootEnabled
        $log += "Fast Startup AFTER: $after"
        if ($after -eq 0) {
            $log += "SUCCESS: Fast Startup DISABLED. Next full shutdown+boot will reinitialize display hardware."
        } else {
            $log += "FAILED: Registry write did not take effect"
        }
    } else {
        $log += "Already disabled, nothing to do"
    }
    $log | Out-File $outFile -Encoding UTF8
} catch {
    "EXCEPTION: $($_.Exception.Message)" | Out-File $outFile -Encoding UTF8
}
