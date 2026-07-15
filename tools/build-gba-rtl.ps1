# Build the FPC arm-gba RTL from source, using the existing cross-compiler
# and ARM binutils. Mirrors the official FPC build but scoped to just the
# bits needed for -Tgba.

$ErrorActionPreference = 'Stop'

$fpcRoot      = 'C:\fpcupdeluxe'
$fpcSrc       = "$fpcRoot\fpcsrc"
$fpcBinDir    = "$fpcRoot\fpc\bin\x86_64-win64"
$ppcrossarm   = "$fpcBinDir\ppcrossarm.exe"
$binutilsDir  = "$fpcRoot\cross\bin\arm-embedded"
$make         = "$fpcRoot\fpcbootstrap\make.exe"
$rtlInstall   = "$fpcRoot\fpc\units\arm-gba"

# Sanity
foreach ($p in @($fpcSrc,$ppcrossarm,$binutilsDir,$make)) {
  if (-not (Test-Path $p)) { Write-Host "MISSING: $p"; exit 1 }
}

# PATH: binutils + FPC native compiler, fpcbootstrap (make)
$env:PATH = "$binutilsDir;$fpcBinDir;$($fpcRoot)\fpcbootstrap;$env:PATH"
$env:FPC  = $ppcrossarm   # standard FPC build var

# Idempotent: apply our FPC RTL patches before building (three
# upstream defects: heap allocator, linklibs, prt0 static init).
& "$PSScriptRoot\fpc-patches\apply.ps1"

Write-Host "--- build env ---"
Write-Host "  PATH prefix: $binutilsDir;$fpcBinDir;$($fpcRoot)\fpcbootstrap"
Write-Host "  FPC env var: $env:FPC"

Push-Location "$fpcSrc\rtl"
try {
  Write-Host "`n--- make distclean ---"
  & $make distclean `
    OS_TARGET=gba CPU_TARGET=arm `
    "PP=$ppcrossarm" `
    "BINUTILSPREFIX=arm-none-eabi-" `
    "CROSSBINDIR=$binutilsDir" 2>&1 | Select-Object -Last 5 | Out-Host

  Write-Host "`n--- make all (verbose tail) ---"
  $log = & $make all `
    OS_TARGET=gba CPU_TARGET=arm `
    "PP=$ppcrossarm" `
    "BINUTILSPREFIX=arm-none-eabi-" `
    "CROSSBINDIR=$binutilsDir" `
    OPT=-O2 2>&1
  $log | Select-Object -Last 30 | Out-Host

  if ($LASTEXITCODE -ne 0) {
    Write-Host "`n--- BUILD FAILED (exit $LASTEXITCODE); full log tail: ---"
    $log | Select-Object -Last 80 | Out-Host
    exit $LASTEXITCODE
  }
}
finally {
  Pop-Location
}

# Install
Write-Host "`n--- installing units to $rtlInstall ---"
New-Item -ItemType Directory -Force -Path $rtlInstall | Out-Null
$artifactsDir = "$fpcSrc\rtl\units\arm-gba"
if (Test-Path $artifactsDir) {
  Copy-Item -Path "$artifactsDir\*" -Destination $rtlInstall -Force -Recurse
  $cnt = (Get-ChildItem $rtlInstall -Recurse -Filter '*.ppu').Count
  Write-Host "  installed $cnt .ppu files"
} else {
  Write-Host "  build output dir $artifactsDir not present"
}

Write-Host "`n--- verification ---"
$tmpDir = Join-Path $env:TEMP 'gba-toolchain-sanity'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$src = Join-Path $tmpDir 'noop.pp'
Set-Content -Path $src -Value @'
program noop;
begin
end.
'@
Push-Location $tmpDir
& $ppcrossarm -Tgba "-Fu$rtlInstall" $src 2>&1 | Out-Host
Pop-Location
Get-ChildItem $tmpDir -Filter 'noop*' -ErrorAction SilentlyContinue |
  Select-Object Length,Name | Format-Table -AutoSize | Out-Host
