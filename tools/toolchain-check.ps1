# Quick presence check for the GBA cross-compile toolchain and
# repo-local build artifacts. Paths under C:\fpcupdeluxe and
# C:\devkitPro are the documented install locations; the three
# repo-relative paths resolve from the repository root.

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$paths = @(
  'C:\fpcupdeluxe\fpc\bin\x86_64-win64\ppcrossarm.exe',
  'C:\fpcupdeluxe\fpc\units\arm-gba',
  'C:\devkitPro\devkitARM\bin\arm-none-eabi-gcc.exe',
  'C:\devkitPro\libgba\lib\libgba.a',
  'C:\devkitPro\devkitARM\arm-none-eabi\lib\libsysbase.a',
  (Join-Path $repoRoot 'test\dbg_smoke.gba'),
  (Join-Path $repoRoot 'bin\gbarun.exe'),
  (Join-Path $repoRoot 'tools\fpc-gba.cfg')
)
foreach ($p in $paths) {
  if (Test-Path $p) { Write-Host ('OK   ' + $p) }
  else { Write-Host ('MISS ' + $p) }
}
