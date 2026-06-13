$outFile = "$PSScriptRoot\results\repair3_output.txt"
$log = [System.Collections.ArrayList]::new()
[void]$log.Add("START: $(Get-Date)")
[void]$log.Add("Admin: $([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))")

try {
    # Step 1: Find ASUS ATK WMI
    [void]$log.Add("Looking for AsusAtkWmi_WMNB...")
    $atk = Get-CimInstance -Namespace root\WMI -ClassName AsusAtkWmi_WMNB -ErrorAction Stop
    [void]$log.Add("ATK WMI found: $($atk.InstanceName)")

    # Step 2: Read current MUX state (DeviceID 0x00090016 = GPU MUX)
    [void]$log.Add("Reading MUX state (DSTS 0x00090016)...")
    try {
        $state = Invoke-CimMethod -InputObject $atk -MethodName DSTS -Arguments @{ Device_ID = 0x00090016 } -ErrorAction Stop
        [void]$log.Add("Current MUX DSTS: ReturnValue=$($state.ReturnValue)")
    } catch {
        [void]$log.Add("DSTS failed: $($_.Exception.Message)")
    }

    # Step 3: Set MUX to discrete mode (0 = discrete/dGPU direct)
    [void]$log.Add("Setting MUX to discrete mode (DEVS 0x00090016 = 0)...")
    try {
        $result = Invoke-CimMethod -InputObject $atk -MethodName DEVS -Arguments @{ Device_ID = 0x00090016; Control_Status = 0 } -ErrorAction Stop
        [void]$log.Add("DEVS result: ReturnValue=$($result.ReturnValue)")
        [void]$log.Add("MUX TOGGLE ATTEMPTED - REBOOT REQUIRED")
    } catch {
        [void]$log.Add("DEVS failed: $($_.Exception.Message)")
    }

    # Step 4: Verify new state
    try {
        $newState = Invoke-CimMethod -InputObject $atk -MethodName DSTS -Arguments @{ Device_ID = 0x00090016 } -ErrorAction Stop
        [void]$log.Add("New MUX DSTS: ReturnValue=$($newState.ReturnValue)")
    } catch {
        [void]$log.Add("Post-verify failed: $($_.Exception.Message)")
    }
} catch {
    [void]$log.Add("ATK WMI ERROR: $($_.Exception.Message)")

    # Fallback: Try direct ACPI call via WMI
    [void]$log.Add("Trying fallback WMI classes...")
    try {
        $classes = Get-CimClass -Namespace root\WMI -ErrorAction Stop | Where-Object { $_.CimClassName -match 'ASUS|ATK|Asus' }
        foreach ($c in $classes) { [void]$log.Add("  Available: $($c.CimClassName)") }
    } catch {
        [void]$log.Add("WMI class enum failed: $($_.Exception.Message)")
    }
}

[void]$log.Add("END: $(Get-Date)")
$log | Out-File $outFile -Encoding UTF8
