# Build a Pascal source file to a .gba ROM.
#
# Usage:
#   .\build-gba.ps1 test\dbg_smoke
#   .\build-gba.ps1 -KeepIntermediates test\dbg_smoke
#
# Assumes the toolchain installed by tools\install-tgba.ps1 +
# tools\build-gba-rtl.ps1 is at C:\fpcupdeluxe. See README.md
# "Cross-compiling to GBA" for the one-time setup steps.

param(
  [Parameter(Mandatory)]
  [string]$Source,
  [switch]$KeepIntermediates
)

$ErrorActionPreference = 'Stop'

$fpcRoot     = 'C:\fpcupdeluxe'
$ppcrossarm  = "$fpcRoot\fpc\bin\x86_64-win64\ppcrossarm.exe"
$rtlDir      = "$fpcRoot\fpc\units\arm-gba"
$binutilsDir = "$fpcRoot\cross\bin\arm-embedded"

# Precondition check. Cross compiler + RTL are always required.
# libsysbase comes from EITHER devkitARM (preferred, via fpc-gba.cfg
# below) OR a pre-existing stub at $rtlDir\libsysbase.a (fallback).
foreach ($p in @($ppcrossarm,$rtlDir,$binutilsDir)) {
  if (-not (Test-Path $p)) {
    Write-Host "Missing toolchain piece: $p"
    Write-Host "Run tools\install-tgba.ps1 + tools\build-gba-rtl.ps1"
    exit 1
  }
}

$dkpCfg = Join-Path $PSScriptRoot 'tools\fpc-gba.cfg'
$stubLibsysbase = "$rtlDir\libsysbase.a"
if (-not (Test-Path $dkpCfg) -and -not (Test-Path $stubLibsysbase)) {
  Write-Host "No libsysbase: neither devkitARM nor stub installed."
  Write-Host "Run tools\install-devkitpro.ps1"
  exit 1
}

$env:PATH = "$binutilsDir;$env:PATH"

# Resolve source. Caller can pass with or without .pp extension.
$srcPath = $Source
if (-not $srcPath.EndsWith('.pp') -and -not $srcPath.EndsWith('.pas')) {
  if (Test-Path "$srcPath.pp")        { $srcPath = "$srcPath.pp" }
  elseif (Test-Path "$srcPath.pas")   { $srcPath = "$srcPath.pas" }
}
if (-not (Test-Path $srcPath)) {
  Write-Host "Source not found: $srcPath"
  exit 1
}

$srcFull = (Resolve-Path $srcPath).Path
$srcDir  = Split-Path $srcFull -Parent
$srcBase = [System.IO.Path]::GetFileNameWithoutExtension($srcFull)

# Add src/ to the unit search so user code can `uses Gba_Dbg, ...`
$projectSrc = Join-Path $PSScriptRoot 'src'

# Delete prior .gba so we never confuse "old success" with "new success"
Remove-Item -ErrorAction SilentlyContinue (Join-Path $srcDir "$srcBase.gba")

Push-Location $srcDir
try {
  Write-Host "--- compiling $srcBase -> $srcBase.gba ---"

  # If devkitPro has been installed and verify-devkitpro.ps1 wrote
  # fpc-gba.cfg, prefer its binutils + lib paths over the fpcupdeluxe
  # binutils. Otherwise fall back to the stub paths.
  $dkpCfg = Join-Path $PSScriptRoot 'tools\fpc-gba.cfg'
  $compilerArgs = @('-Tgba','-Parm')
  if (Test-Path $dkpCfg) {
    $compilerArgs += "@$dkpCfg"
    $compilerArgs += "-Fu$rtlDir"
    $compilerArgs += "-Fu$projectSrc"
    $compilerArgs += '-XParm-none-eabi-'
  }
  else {
    $compilerArgs += "-Fu$rtlDir"
    $compilerArgs += "-Fu$projectSrc"
    $compilerArgs += "-FD$binutilsDir"
    $compilerArgs += '-XParm-none-eabi-'
  }
  $compilerArgs += $srcBase
  & $ppcrossarm @compilerArgs 2>&1 | Out-Host

  $exitcode = $LASTEXITCODE
}
finally {
  if (-not $KeepIntermediates) {
    Remove-Item -ErrorAction SilentlyContinue "$srcDir\$srcBase.o","$srcDir\$srcBase.s","$srcDir\$srcBase.ppu","$srcDir\$srcBase.elf","$srcDir\link*.res","$srcDir\ppas.bat","$srcDir\$($srcBase)_ppas.bat"
  }
  Pop-Location
}

# NormMatt's BIOS replacement DOES verify the Nintendo logo bytes at
# $04..$9F at boot, so we run our Python gbafix replacement to patch
# those plus the header checksum. Without this the BIOS sits in its
# splash loop forever and never hands off to cart code.
if (Test-Path "$srcDir\$srcBase.gba") {
  $romPath = "$srcDir\$srcBase.gba"
  $gbafix = Join-Path $PSScriptRoot 'tools\gbafix.py'
  if (Test-Path $gbafix) {
    & python $gbafix $romPath --title $srcBase.ToUpper() | Out-Host
  }
  else {
    Write-Host "WARNING: $gbafix not found; ROM may not boot (no Nintendo logo)"
  }
  $size = (Get-Item $romPath).Length
  Write-Host "OK: $romPath ($size bytes)"
  exit 0
}
else {
  Write-Host "BUILD FAILED (no .gba produced); exit $exitcode"
  if ($exitcode -ne 0) { exit $exitcode } else { exit 1 }
}
