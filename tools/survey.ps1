$root = 'C:\fpcupdeluxe'
Write-Host "--- $root tree (top-level dirs) ---"
if (Test-Path $root) {
  Get-ChildItem $root -Directory | Select-Object Name | Out-Host
} else {
  Write-Host "$root NOT PRESENT"
  exit 1
}

Write-Host "--- key binaries ---"
$paths = @(
  'C:\fpcupdeluxe\fpc\bin\x86_64-win64\ppcx64.exe',
  'C:\fpcupdeluxe\fpc\bin\x86_64-win64\ppcrossarm.exe',
  'C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.exe',
  'C:\fpcupdeluxe\fpcsrc\compiler\Makefile',
  'C:\fpcupdeluxe\lazarus\lazarus.exe',
  'C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.cfg'
)
foreach ($p in $paths) {
  if (Test-Path $p) { Write-Host "  OK : $p" } else { Write-Host "  -  : $p" }
}

Write-Host "--- arm-embedded units ---"
$ae = 'C:\fpcupdeluxe\fpc\units\arm-embedded'
if (Test-Path $ae) {
  Get-ChildItem $ae | Select-Object Name | Out-Host
} else {
  Write-Host '  arm-embedded units dir not present'
}

Write-Host "--- fpc.exe version probe ---"
if (Test-Path 'C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.exe') {
  & 'C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.exe' -iV 2>&1 | Out-Host
  & 'C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.exe' -it 2>&1 | Out-Host
}
