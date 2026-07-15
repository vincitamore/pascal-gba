# Build the bundled replacement BIOS from bios\src\ into bios\gba_bios.bin.
#
# Run from the repo root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-bios.ps1
#
# Requires devkitARM (tools\install-devkitpro.ps1). The whole BIOS assembles as
# one translation unit: entrypoint.s includes definition.s, bios_calls\, and
# boot_screen\, then objcopy flattens it to a 16 KiB binary.
param(
  [string]$DevkitArm = 'C:\devkitPro\devkitARM'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$as      = Join-Path $DevkitArm 'bin\arm-none-eabi-as.exe'
$objcopy = Join-Path $DevkitArm 'bin\arm-none-eabi-objcopy.exe'
foreach ($tool in @($as, $objcopy)) {
  if (-not (Test-Path $tool)) {
    throw "devkitARM tool not found: $tool (run tools\install-devkitpro.ps1)"
  }
}

$srcDir = Join-Path $root 'bios\src'
$obj    = Join-Path $srcDir 'entrypoint.o'
$out    = Join-Path $root 'bios\gba_bios.bin'

Push-Location $srcDir
try {
  & $as entrypoint.s -mcpu=arm7tdmi -o $obj
  if ($LASTEXITCODE -ne 0) { throw "arm-none-eabi-as failed ($LASTEXITCODE)" }
  & $objcopy $obj $out -O binary
  if ($LASTEXITCODE -ne 0) { throw "arm-none-eabi-objcopy failed ($LASTEXITCODE)" }
} finally {
  if (Test-Path $obj) { Remove-Item $obj }
  Pop-Location
}

$size = (Get-Item $out).Length
if ($size -ne 16384) {
  throw "BIOS built at $size bytes; expected 16384"
}
Write-Host "OK: $out (16384 bytes)"
