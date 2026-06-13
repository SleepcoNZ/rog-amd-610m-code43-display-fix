# ============================================================================
# DisplayDiagnostics - Shared Helper Functions
# ============================================================================

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ResultsDir = Join-Path $script:ProjectRoot "results"

function Ensure-ResultsDir {
    if (-not (Test-Path $script:ResultsDir)) {
        New-Item -ItemType Directory -Force -Path $script:ResultsDir | Out-Null
    }
}

function Write-DiagHeader {
    param([string]$Title)
    $line = "=" * 70
    $output = @"

$line
  $Title
  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$line

"@
    Write-Host $output -ForegroundColor Cyan
    return $output
}

function Write-DiagSection {
    param([string]$Title)
    $line = "-" * 50
    $output = "`n--- $Title $line`n"
    Write-Host $output -ForegroundColor Yellow
    return $output
}

function Write-DiagResult {
    param(
        [string]$Label,
        [string]$Value,
        [ValidateSet('OK','WARN','ERROR','INFO','CRITICAL')]
        [string]$Status = 'INFO'
    )
    $colors = @{
        'OK'       = 'Green'
        'WARN'     = 'Yellow'
        'ERROR'    = 'Red'
        'CRITICAL' = 'Magenta'
        'INFO'     = 'White'
    }
    $prefix = "[$Status]"
    $output = "$prefix $Label : $Value"
    Write-Host $output -ForegroundColor $colors[$Status]
    return $output
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-AsAdmin {
    param(
        [string]$ScriptPath,
        [string]$OutputFile
    )
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    if ($OutputFile) {
        $argList += " *> `"$OutputFile`""
    }
    $proc = Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait -PassThru
    return $proc.ExitCode
}

function Save-Result {
    param(
        [string]$FileName,
        [object]$Data
    )
    Ensure-ResultsDir
    $path = Join-Path $script:ResultsDir $FileName
    if ($Data -is [string]) {
        $Data | Out-File -FilePath $path -Encoding UTF8
    } else {
        $Data | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8
    }
    Write-Host "  -> Saved: $path" -ForegroundColor DarkGray
    return $path
}

function Load-Result {
    param([string]$FileName)
    $path = Join-Path $script:ResultsDir $FileName
    if (Test-Path $path) {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    return $null
}

function Safe-Execute {
    param(
        [string]$Description,
        [scriptblock]$Block
    )
    try {
        Write-Host "  Running: $Description..." -ForegroundColor DarkGray
        $result = & $Block
        return @{ Success = $true; Data = $result; Error = $null }
    }
    catch {
        Write-Host "  FAILED: $Description - $($_.Exception.Message)" -ForegroundColor Red
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Get-Severity {
    param([string[]]$Issues)
    if ($Issues | Where-Object { $_ -match 'CRITICAL' }) { return 'CRITICAL' }
    if ($Issues | Where-Object { $_ -match 'ERROR' }) { return 'ERROR' }
    if ($Issues | Where-Object { $_ -match 'WARN' }) { return 'WARN' }
    return 'OK'
}
