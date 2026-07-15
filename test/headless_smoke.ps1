# Headless CLI smoke matrix.
#
# Runs the matrix of CLI flag combinations the headless dev-loop relies on,
# validating each documented exit code against test\dbg_smoke.gba:
#   Case A - clean run with --screenshot-frame N           -> exit 0, PNG
#   Case B - clean run, no screenshot                      -> exit 0
#   Case C - missing ROM                                   -> exit 1
#   Case D - missing BIOS                                  -> exit 1
#   Case E - 600-frame headless acceptance                 -> exit 0, PNG
#
# The bundled BIOS at bios\gba_bios.bin is the default; pass -Bios to
# point at a different image.
#
# Run from repo root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\headless_smoke.ps1
#
# Adds no automated assertions - a human (or agent) reads the exit codes
# and confirms case-by-case. Re-run any time after touching the headless
# code paths in gba_runner.pas / input.pas / gbarun.pas to catch
# regressions before they reach interactive testing.

param(
  [string]$Bios = 'bios\gba_bios.bin'
)

$ErrorActionPreference = 'Continue'

# Script lives in test\; repo root is one level up.
$repoRoot = Split-Path -Parent $PSScriptRoot
$rom  = Join-Path $repoRoot 'test\dbg_smoke.gba'
$exe  = Join-Path $repoRoot 'bin\gbarun.exe'
$bios = if ([System.IO.Path]::IsPathRooted($Bios)) { $Bios } else { Join-Path $repoRoot $Bios }
$shot = Join-Path $repoRoot 'bin\screenshots\dbg-frame30.png'
$shotE = Join-Path $repoRoot 'bin\screenshots\dbg-frame600.png'

Write-Host '--- Case A: clean run, --screenshot-frame 30 ---'
& $exe --rom $rom --bios $bios --headless --frames 30 --screenshot-frame 30 --screenshot $shot | Out-Null
Write-Host "exit code: $LASTEXITCODE"

Write-Host '--- Case B: clean run, no screenshot ---'
& $exe --rom $rom --bios $bios --headless --frames 30 | Out-Null
Write-Host "exit code: $LASTEXITCODE"

Write-Host '--- Case C: missing ROM ---'
& $exe --rom (Join-Path $repoRoot 'roms\nonexistent.gba') --bios $bios --headless --frames 30 | Out-Null
Write-Host "exit code: $LASTEXITCODE"

Write-Host '--- Case D: missing BIOS ---'
& $exe --rom $rom --bios (Join-Path $repoRoot 'bios\nonexistent.bin') --headless --frames 30 | Out-Null
Write-Host "exit code: $LASTEXITCODE"

Write-Host '--- Case E: 600-frame acceptance ---'
$start = Get-Date
& $exe --rom $rom --bios $bios --headless --frames 600 --screenshot $shotE | Out-Null
$elapsed = (Get-Date) - $start
Write-Host "exit=$LASTEXITCODE  elapsed=$($elapsed.TotalSeconds)s"
