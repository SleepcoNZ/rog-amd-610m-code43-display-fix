# Force-set display resolution on \\.\DISPLAY1 using ChangeDisplaySettingsEx
$sig = @"
using System;
using System.Runtime.InteropServices;
public class DispForce {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
        public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel;
        public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
        public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll")]
    public static extern bool EnumDisplaySettings(string dev, int n, ref DEVMODE dm);
    [DllImport("user32.dll")]
    public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
    public const int ENUM_CURRENT = -1;
    public const uint CDS_UPDATEREGISTRY = 0x01;
    public const int DM_PELSWIDTH = 0x80000; 
    public const int DM_PELSHEIGHT = 0x100000;
    public const int DM_BITSPERPEL = 0x40000;
    public const int DM_DISPLAYFREQUENCY = 0x400000;
}
"@
Add-Type $sig

$dev = '\\.\DISPLAY1'

# 1) Enumerate modes for the EXPLICIT device name
$dmSizeBytes = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'DispForce+DEVMODE')
$dm = New-Object DispForce+DEVMODE
$dm.dmSize = [int16]$dmSizeBytes
$modes = New-Object System.Collections.Generic.List[object]
$i = 0
while ([DispForce]::EnumDisplaySettings($dev, $i, [ref]$dm)) {
    $modes.Add([pscustomobject]@{ W=$dm.dmPelsWidth; H=$dm.dmPelsHeight; Hz=$dm.dmDisplayFrequency; Bpp=$dm.dmBitsPerPel })
    $i++
}
"Modes for ${dev}: $($modes.Count)"
$modes | Sort-Object W,H,Hz -Descending | Select-Object -First 6 | Format-Table -Auto

# 2) Pick target: prefer 2560x1440, else 1920x1080, else best available
$target = $modes | Where-Object { $_.W -eq 2560 -and $_.H -eq 1440 } | Sort-Object Hz -Descending | Select-Object -First 1
if (-not $target) { $target = $modes | Where-Object { $_.W -eq 1920 -and $_.H -eq 1080 } | Sort-Object Hz -Descending | Select-Object -First 1 }
if (-not $target) { $target = $modes | Sort-Object W,H,Hz -Descending | Select-Object -First 1 }

if ($target) {
    "Applying target: $($target.W)x$($target.H)@$($target.Hz)"
    $set = New-Object DispForce+DEVMODE
    $set.dmSize = [int16]$dmSizeBytes
    $set.dmDeviceName = $dev
    $set.dmPelsWidth = $target.W
    $set.dmPelsHeight = $target.H
    $set.dmBitsPerPel = 32
    $set.dmDisplayFrequency = $target.Hz
    $set.dmFields = [DispForce]::DM_PELSWIDTH -bor [DispForce]::DM_PELSHEIGHT -bor [DispForce]::DM_BITSPERPEL -bor [DispForce]::DM_DISPLAYFREQUENCY
    $r = [DispForce]::ChangeDisplaySettingsEx($dev, [ref]$set, [IntPtr]::Zero, [DispForce]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)
    $meaning = switch ($r) { 0 {'SUCCESS'} 1 {'RESTART REQUIRED'} -1 {'FAILED'} -2 {'BADMODE'} -5 {'BADFLAGS'} default {"code $r"} }
    "ChangeDisplaySettingsEx result: $r ($meaning)"
} else {
    "No modes available to set - driver mode table is empty (deeper driver-binding issue)."
}

Start-Sleep -Seconds 2
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "Now: {0} Bounds={1}" -f $_.DeviceName, $_.Bounds }
