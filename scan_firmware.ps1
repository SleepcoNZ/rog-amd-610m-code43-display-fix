# ============================================================================
# Phase 5: Firmware & BIOS Diagnostics
# ============================================================================
param([switch]$AsJob)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\helpers.ps1"

$results = @{
    Timestamp = Get-Date -Format 'o'
    Phase     = 'Phase5_Firmware'
    Issues    = @()
    Data      = @{}
}

Write-DiagHeader "PHASE 5: Firmware & BIOS Diagnostics"

# --- 5.1 BIOS Version & Details ---
Write-DiagSection "5.1 BIOS / UEFI Firmware"
$bios = Safe-Execute "Querying BIOS information" {
    $b = Get-CimInstance Win32_BIOS
    $mb = Get-CimInstance Win32_BaseBoard

    # Check ASUS-specific BIOS entries
    $asusBios = @{}
    $asusPaths = @(
        'HKLM:\HARDWARE\DESCRIPTION\System\BIOS',
        'HKLM:\SOFTWARE\ASUS\BIOS'
    )
    foreach ($p in $asusPaths) {
        if (Test-Path $p) {
            $asusBios[$p.Split('\')[-1]] = Get-ItemProperty $p -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS*
        }
    }

    @{
        SMBIOSVersion    = $b.SMBIOSBIOSVersion
        BIOSVersion      = $b.BIOSVersion
        ReleaseDate      = $b.ReleaseDate
        Manufacturer     = $b.Manufacturer
        SerialNumber     = $b.SerialNumber
        EmbeddedController = $b.EmbeddedControllerMajorVersion
        SystemBiosVersion = ($asusBios['BIOS'] | Select-Object -ExpandProperty SystemBiosVersion -ErrorAction SilentlyContinue) -join ', '
        BaseBoardProduct = $mb.Product
        BaseBoardVersion = $mb.Version
        AsusRegistry     = $asusBios
    }
}
if ($bios.Success) {
    $results.Data.BIOS = $bios.Data
    Write-DiagResult "BIOS Version" $bios.Data.SMBIOSVersion 'INFO'
    Write-DiagResult "Release Date" "$($bios.Data.ReleaseDate)" 'INFO'
    Write-DiagResult "Manufacturer" $bios.Data.Manufacturer 'INFO'
    Write-DiagResult "BaseBoard" "$($bios.Data.BaseBoardProduct) v$($bios.Data.BaseBoardVersion)" 'INFO'

    # Flag if BIOS is very old (older than 1 year)
    if ($bios.Data.ReleaseDate -and $bios.Data.ReleaseDate -lt (Get-Date).AddYears(-1)) {
        $results.Issues += "WARN: BIOS is older than 1 year ($($bios.Data.ReleaseDate)) - may be missing critical fixes for display/GPU"
    }
}

# --- 5.2 UEFI / Secure Boot / TPM ---
Write-DiagSection "5.2 UEFI / Secure Boot / TPM"
$secBoot = Safe-Execute "Checking Secure Boot and TPM" {
    $info = @{}
    try { $info.SecureBootEnabled = Confirm-SecureBootUEFI } catch { $info.SecureBootEnabled = "Error: $($_.Exception.Message)" }
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $info.TpmPresent = $tpm.TpmPresent
        $info.TpmReady = $tpm.TpmReady
        $info.TpmEnabled = $tpm.TpmEnabled
    } catch {
        $info.TpmError = $_.Exception.Message
    }

    # UEFI firmware type
    try {
        $fw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop
        $info.UEFISecureBootState = $fw.UEFISecureBootEnabled
    } catch {}

    $info
}
if ($secBoot.Success) {
    $results.Data.SecureBoot = $secBoot.Data
    Write-DiagResult "Secure Boot" "$($secBoot.Data.SecureBootEnabled)" 'INFO'
    Write-DiagResult "TPM Present" "$($secBoot.Data.TpmPresent)" 'INFO'
    Write-DiagResult "TPM Ready" "$($secBoot.Data.TpmReady)" 'INFO'
}

# --- 5.3 ACPI Error Analysis ---
Write-DiagSection "5.3 ACPI Errors (Display Initialization)"
$acpiErrors = Safe-Execute "Scanning for ACPI errors" {
    $events = @()
    try {
        $acpi = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'ACPI'
        } -MaxEvents 100 -ErrorAction SilentlyContinue
        foreach ($e in $acpi) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Message     = $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
            }
        }
    } catch {}

    # Also check for ACPI-related errors from other providers
    try {
        $general = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Level   = 1, 2
        } -MaxEvents 2000 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'ACPI|firmware|UEFI|BIOS' } |
            Select-Object -First 20
        foreach ($e in $general) {
            $events += @{
                TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Id          = $e.Id
                Level       = $e.LevelDisplayName
                Provider    = $e.ProviderName
                Message     = $e.Message.Substring(0, [Math]::Min($e.Message.Length, 500))
            }
        }
    } catch {}

    $events
}
if ($acpiErrors.Success) {
    $results.Data.ACPIErrors = $acpiErrors.Data
    $acpiCount = @($acpiErrors.Data).Count
    Write-DiagResult "ACPI Events" "$acpiCount event(s)" $(if ($acpiCount -gt 5) { 'WARN' } elseif ($acpiCount -gt 0) { 'INFO' } else { 'OK' })
    foreach ($evt in $acpiErrors.Data | Select-Object -First 5) {
        $s = if ($evt.Level -match 'Error|Critical') { 'ERROR' } else { 'WARN' }
        Write-DiagResult "  [$($evt.TimeCreated)]" "Id=$($evt.Id): $($evt.Message.Substring(0,[Math]::Min($evt.Message.Length,150)))" $s
    }
    $acpiErrCount = @($acpiErrors.Data | Where-Object { $_.Level -match 'Error|Critical' }).Count
    if ($acpiErrCount -gt 0) {
        $results.Issues += "WARN: $acpiErrCount ACPI errors found - may affect display/GPU initialization at boot time"
    }
}

# --- 5.4 Power Configuration ---
Write-DiagSection "5.4 Power Configuration (GPU Power States)"
$power = Safe-Execute "Checking power configuration" {
    $info = @{}

    # Active power scheme
    $scheme = powercfg /getactivescheme 2>&1
    $info.ActiveScheme = ($scheme -join ' ').Trim()

    # GPU-specific power settings
    $gpuPower = powercfg /query SCHEME_CURRENT SUB_VIDEO 2>&1
    $info.VideoSettings = ($gpuPower -join "`n")

    # Hibernate/Sleep state that might affect display
    $sleepStates = powercfg /availablesleepstates 2>&1
    $info.SleepStates = ($sleepStates -join "`n")

    # Check if Fast Startup is enabled (can cause display issues)
    $fastStartup = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue
    $info.FastStartupEnabled = $fastStartup.HiberbootEnabled

    # Connected Standby / Modern Standby
    $cs = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
    $info.CsEnabled = $cs.CsEnabled

    $info
}
if ($power.Success) {
    $results.Data.PowerConfig = $power.Data
    Write-DiagResult "Power Scheme" $power.Data.ActiveScheme 'INFO'
    Write-DiagResult "Fast Startup" $(if ($power.Data.FastStartupEnabled -eq 1) { "ENABLED (can cause display issues on boot)" } else { "Disabled" }) $(if ($power.Data.FastStartupEnabled -eq 1) { 'WARN' } else { 'OK' })
    Write-DiagResult "Connected Standby" $(if ($power.Data.CsEnabled -eq 1) { "Enabled" } else { "Disabled" }) 'INFO'

    if ($power.Data.FastStartupEnabled -eq 1) {
        $results.Issues += "WARN: Fast Startup is enabled - this can prevent display hardware from reinitializing properly on boot"
    }
}

# --- 5.5 ASUS-Specific Firmware Services ---
Write-DiagSection "5.5 ASUS Firmware Services Status"
$asusServices = Safe-Execute "Checking ASUS service states" {
    $services = @(
        'ArmouryCrateService',
        'AsusSystemControlInterface',
        'ASUSOptimization',
        'AsHotplugCtrl',
        'ASUSSmartDisplayControl',
        'AsusCertService',
        'LightingService',
        'GameSDK Service'
    )
    $serviceStatus = @()
    foreach ($svc in $services) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            $serviceStatus += @{
                Name        = $s.DisplayName
                ServiceName = $s.Name
                Status      = $s.Status.ToString()
                StartType   = $s.StartType.ToString()
            }
        } else {
            # Try partial match
            $s = Get-Service | Where-Object { $_.DisplayName -match $svc -or $_.Name -match $svc } | Select-Object -First 1
            if ($s) {
                $serviceStatus += @{
                    Name        = $s.DisplayName
                    ServiceName = $s.Name
                    Status      = $s.Status.ToString()
                    StartType   = $s.StartType.ToString()
                }
            }
        }
    }
    $serviceStatus
}
if ($asusServices.Success) {
    $results.Data.ASUSServices = $asusServices.Data
    foreach ($svc in $asusServices.Data) {
        $s = if ($svc.Status -eq 'Running') { 'OK' } elseif ($svc.Status -eq 'Stopped' -and $svc.StartType -eq 'Manual') { 'INFO' } else { 'WARN' }
        Write-DiagResult "$($svc.Name)" "Status=$($svc.Status) StartType=$($svc.StartType)" $s
        if ($svc.ServiceName -match 'ArmouryCrate|SystemControl|GPUSwitch' -and $svc.Status -ne 'Running') {
            $results.Issues += "WARN: Critical ASUS service '$($svc.Name)' is $($svc.Status) - may prevent GPU/MUX management"
        }
    }
}

# --- Summary ---
Write-DiagSection "Phase 5 Summary"
$severity = Get-Severity $results.Issues
Write-DiagResult "Overall Severity" $severity $severity
Write-DiagResult "Issues Found" "$($results.Issues.Count)" $(if ($results.Issues.Count -eq 0) { 'OK' } else { 'WARN' })
foreach ($issue in $results.Issues) {
    Write-Host "  ! $issue" -ForegroundColor $(if ($issue -match 'CRITICAL') { 'Magenta' } elseif ($issue -match 'ERROR') { 'Red' } else { 'Yellow' })
}

Save-Result "phase5_firmware.json" $results
Write-Host "`nPhase 5 Complete.`n" -ForegroundColor Cyan
return $results
