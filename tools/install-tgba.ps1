# Install FPC -Tgba cross-compile toolchain via fpcupdeluxe.
#
# Run-once script. Idempotent in the sense that fpcupdeluxe will resume
# from the install dir on re-run, but the first run does the bulk of
# the download + build.
#
# Steps:
#   1. Download fpcupdeluxe-x86_64-win64.exe to $tmpDir.
#   2. Verify SHA-256 against the GitHub-API-reported digest.
#   3. Run fpcupdeluxe in CLI mode pointing at the install dir.
#      Builds: native ppcx64 + cross ppcrossarm + arm-embedded RTL
#      with SUBARCH=armv4t (GBA).
#   4. Print where ppcrossarm.exe + arm-embedded units ended up.
#
# Expected wall-clock: 15-30 minutes (most of it building FPC from
# source). Disk: ~500 MB into $installDir.

$ErrorActionPreference = 'Stop'

$installDir   = 'C:\fpcupdeluxe'
$tmpDir       = Join-Path $env:TEMP 'fpcupdeluxe-install'
$url          = 'https://github.com/LongDirtyAnimAlf/fpcupdeluxe/releases/download/v2.4.0i/fpcupdeluxe-x86_64-win64.exe'
$expectedSha  = '6c0d653587c327d9a9af61c87eb6bfa7a5ece64f55487b7ba5c44ece2d5566f3'
$installerExe = Join-Path $tmpDir 'fpcupdeluxe.exe'

New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

# --- 1. Download ---
if (-not (Test-Path $installerExe)) {
  Write-Host "Downloading fpcupdeluxe..."
  Invoke-WebRequest -Uri $url -OutFile $installerExe -UseBasicParsing
}
else {
  Write-Host "fpcupdeluxe already downloaded at $installerExe"
}

# --- 2. Verify SHA-256 ---
$actualSha = (Get-FileHash -Algorithm SHA256 -Path $installerExe).Hash.ToLower()
Write-Host "Expected SHA-256: $expectedSha"
Write-Host "Actual   SHA-256: $actualSha"
if ($actualSha -ne $expectedSha.ToLower()) {
  Write-Host "SHA MISMATCH \u2014 ABORTING."
  exit 1
}
Write-Host "SHA verified."

# --- 3. Run fpcupdeluxe CLI: install FPC + ARM-embedded cross + GBA subarch ---
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Phase 3a \u2014 install base FPC (release_3_2_2) if not already present.
$ppcx64 = Join-Path $installDir 'fpc\bin\x86_64-win64\ppcx64.exe'
if (-not (Test-Path $ppcx64)) {
  Write-Host "`n--- Phase 3a: installing base FPC into $installDir ---"
  & $installerExe `
    --installdir="$installDir" `
    --fpcURL='gitlab' `
    --fpcBranch='release_3_2_2' `
    --only='FPC'
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Phase 3a failed with exit $LASTEXITCODE"
    exit $LASTEXITCODE
  }
}
else {
  Write-Host "Base FPC already present at $ppcx64 \u2014 skipping Phase 3a"
}

# Phase 3b \u2014 build ARM-embedded cross compiler with armv4t subarch (GBA).
$ppcrossarm = Join-Path $installDir 'fpc\bin\x86_64-win64\ppcrossarm.exe'
$armEmbeddedUnits = Join-Path $installDir 'fpc\units\arm-embedded'
if ((-not (Test-Path $ppcrossarm)) -or (-not (Test-Path $armEmbeddedUnits))) {
  Write-Host "`n--- Phase 3b: building arm-embedded cross compiler (SUBARCH=armv4t) ---"
  & $installerExe `
    --installdir="$installDir" `
    --ostarget='embedded' `
    --cputarget='arm' `
    --subarch='armv4t' `
    --only='FPCCROSSBUILDONLY'
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Phase 3b failed with exit $LASTEXITCODE"
    exit $LASTEXITCODE
  }
}
else {
  Write-Host "Cross compiler already present \u2014 skipping Phase 3b"
}

# --- 4. Report ---
Write-Host "`n--- Install complete ---"
Write-Host "ppcx64:    $ppcx64    $(if (Test-Path $ppcx64) { '[OK]' } else { '[MISSING]' })"
Write-Host "ppcrossarm: $ppcrossarm  $(if (Test-Path $ppcrossarm) { '[OK]' } else { '[MISSING]' })"
Write-Host "arm-embedded units: $armEmbeddedUnits  $(if (Test-Path $armEmbeddedUnits) { '[OK]' } else { '[MISSING]' })"
if (Test-Path $armEmbeddedUnits) {
  Write-Host "  unit count: $((Get-ChildItem $armEmbeddedUnits -Recurse -Filter '*.ppu').Count) .ppu files"
}
