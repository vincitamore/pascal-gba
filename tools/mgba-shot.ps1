# Boot a ROM in mGBA (SDL build) and capture its client area to a PNG.
#
# Cross-validation helper: this emulator's own screenshots prove the cart
# against THIS implementation; a capture from mGBA proves it against an
# independent reference. mGBA 0.10 has no headless screenshot surface, so
# the capture is a GDI copy of the live window's client rect -- the window
# appears briefly on the desktop and is closed automatically.
#
# Usage:
#   powershell -File tools\mgba-shot.ps1 -Rom test\mode0_demo.gba `
#       -Out bin\mgba_mode0.png [-Seconds 6] [-Scale 2] [-MgbaSdl path]
#
# The mGBA SDL binary is located via -MgbaSdl, the MGBA_SDL environment
# variable, or `mgba-sdl.exe` on PATH, in that order.

param(
    [Parameter(Mandatory = $true)][string]$Rom,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Seconds = 6,
    [int]$Scale = 2,
    [string]$MgbaSdl = ""
)

$ErrorActionPreference = "Stop"

if (-not $MgbaSdl) { $MgbaSdl = $env:MGBA_SDL }
if (-not $MgbaSdl) {
    $cmd = Get-Command "mgba-sdl.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $MgbaSdl = $cmd.Source }
}
if (-not $MgbaSdl -or -not (Test-Path $MgbaSdl)) {
    throw "mgba-sdl.exe not found: pass -MgbaSdl, set MGBA_SDL, or add it to PATH"
}
$Rom = (Resolve-Path $Rom).Path

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class MgbaShotWin32 {
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X, Y; }
}
'@
Add-Type -AssemblyName System.Drawing

$p = Start-Process -FilePath $MgbaSdl -ArgumentList "-$Scale", "`"$Rom`"" -PassThru
try {
    Start-Sleep -Seconds $Seconds
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { throw "mGBA window did not appear (bad ROM path?)" }
    [MgbaShotWin32]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 500
    $r = New-Object MgbaShotWin32+RECT
    [MgbaShotWin32]::GetClientRect($h, [ref]$r) | Out-Null
    $pt = New-Object MgbaShotWin32+POINT
    [MgbaShotWin32]::ClientToScreen($h, [ref]$pt) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { throw "empty client rect" }
    $bmp = New-Object System.Drawing.Bitmap($w, $ht)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    $bmp.Save($Out)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "OK: $Out (${w}x${ht} after $Seconds s)"
}
finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
