$ErrorActionPreference = 'Continue'
$rom = 'test\dbg_smoke.gba'

if (-not (Test-Path $rom)) { Write-Host "BUILD FIRST"; exit 1 }
Write-Host "--- ROM info ---"
Get-Item $rom | Format-Table Name,Length | Out-Host

# Delete stale .sav (the runner creates one based on cart-header save type)
if (Test-Path "test\dbg_smoke.sav") { Remove-Item "test\dbg_smoke.sav" -Force }

Write-Host "--- run 600 frames ---"
$out = & 'bin\gbarun.exe' --rom $rom --headless --frames 600 2>&1
$out | Select-String -Pattern 'dbglog' | ForEach-Object { Write-Host "  DBGLOG: $_" }
Write-Host "--- PC samples (every 60 frames) + dbglog markers ---"
$out | Select-String -Pattern 'frame |Rendered|Final PC|dbglog|IRQ entries' |
  ForEach-Object { Write-Host "  $_" }
