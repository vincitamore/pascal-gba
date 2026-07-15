# Build the host-side (win64) runner and test binaries into bin\.
#
# Run from the repo root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-host.ps1
#
# Requires a native win64 Free Pascal compiler (3.2+). The fpcupdeluxe install
# at C:\fpcupdeluxe is found automatically; otherwise fpc.exe must be on PATH,
# or pass -Fpc <path-to-fpc.exe>.
param(
  [string]$Fpc = ''
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root

if (-not $Fpc) {
  $candidates = @('C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.exe', 'fpc')
  foreach ($c in $candidates) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $Fpc = $c; break }
  }
}
if (-not $Fpc) { throw 'No host FPC found. Pass -Fpc <path to fpc.exe>.' }

New-Item -ItemType Directory -Force bin | Out-Null

# All host-side programs under test\. dbg_smoke.pp is the cart-side ROM and is
# built by build-gba.ps1 instead.
$targets = @(
  'test\gbarun.pas',
  'test\sprite_smoke.pas',
  'test\audio_smoke.pas',
  'test\hello_gba.pas',
  'test\hello_d.pas',
  'test\test_armcore.pas',
  'test\test_ppu.pas',
  'test\test_bios_hle.pas',
  'test\test_save.pas',
  'test\test_replay.pas',
  'test\test_dbglog.pas',
  'test\test_phase_b.pas',
  'test\test_phase_d.pas',
  'test\test_phase_e.pas',
  'test\test_phase_f.pas'
)

$failed = @()
foreach ($t in $targets) {
  Write-Host "--- $t ---"
  & $Fpc -Mobjfpc -Sh -O3 -Fusrc -FEbin -FUbin $t
  if ($LASTEXITCODE -ne 0) { $failed += $t }
}

if ($failed.Count -gt 0) {
  Write-Host "FAILED: $($failed -join ', ')"
  exit 1
}
Write-Host "OK: $($targets.Count) host binaries in bin\"
