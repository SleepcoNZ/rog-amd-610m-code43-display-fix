$outFile = "$PSScriptRoot\results\repair3_output.txt"
$log = @()
try {
    $log += "Admin: $([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

    # 1. Search ASUS registry keys
    $gpuMuxPaths = @(
        'HKLM:\SOFTWARE\ASUS\ASUS System Control Interface\GPUMux',
        'HKLM:\SOFTWARE\ASUS\Armoury Crate Service\GPUSwitch',
        'HKLM:\SOFTWARE\ASUS\GPUSwitch',
        'HKLM:\SOFTWARE\ASUS\ASUS System Control Interface\GPUSwitch',
        'HKLM:\SOFTWARE\ASUS\Armoury Crate Service\GPUMux'
    )
    foreach ($path in $gpuMuxPaths) {
        if (Test-Path $path) {
            $log += "FOUND: $path"
            $props = Get-ItemProperty $path -EA SilentlyContinue
            $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $log += "  $($_.Name) = $($_.Value)" }
        }
    }

    # 2. Broad ASUS GPU key search  
    if (Test-Path 'HKLM:\SOFTWARE\ASUS') {
        $children = Get-ChildItem 'HKLM:\SOFTWARE\ASUS' -Recurse -EA SilentlyContinue | Where-Object { $_.Name -match 'GPU|Mux|Display|Switch' }
        foreach ($c in $children) {
            $log += "ASUS KEY: $($c.Name)"
        }
    }

    # 3. WMI classes
    $wmiClasses = Get-CimClass -Namespace root\WMI -EA SilentlyContinue | Where-Object { $_.CimClassName -match 'ASUS|ATK' }
    foreach ($cls in $wmiClasses) { $log += "WMI: $($cls.CimClassName)" }

    # 4. ACPI MUX toggle
    try {
        $atk = Get-CimInstance -Namespace root\WMI -ClassName AsusAtkWmi_WMNB -EA Stop
        $log += "ATK WMI FOUND"
        try {
            $state = Invoke-CimMethod -InputObject $atk -MethodName DSTS -Arguments @{ Device_ID = 0x00090016 } -EA Stop
            $log += "MUX DSTS result: $($state.ReturnValue)"
        } catch { $log += "DSTS failed: $($_.Exception.Message)" }
        try {
            $set = Invoke-CimMethod -InputObject $atk -MethodName DEVS -Arguments @{ Device_ID = 0x00090016; Control_Status = 0 } -EA Stop
            $log += "MUX DEVS set to 0 (dGPU): $($set.ReturnValue)"
            $log += "REBOOT REQUIRED for MUX change"
        } catch { $log += "DEVS failed: $($_.Exception.Message)" }
    } catch { $log += "ATK WMI not available: $($_.Exception.Message)" }

    # 5. Display class registry
    $dp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    Get-ChildItem $dp -EA SilentlyContinue | ForEach-Object {
        $v = Get-ItemProperty $_.PSPath -EA SilentlyContinue
        if ($v.DriverDesc -match 'AMD|NVIDIA') {
            $log += "$($v.DriverDesc): EnableMsHybrid=$($v.EnableMsHybrid) HybridGPUType=$($v.HybridGraphicsGPUType)"
        }
    }

    $log | Out-File $outFile -Encoding UTF8
} catch {
    (@("OUTER EXCEPTION: $($_.Exception.Message)") + $log) | Out-File $outFile -Encoding UTF8
}
