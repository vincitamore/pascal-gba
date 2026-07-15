# Bootstrap script for installing devkitARM properly (replaces our
# stub libsysbase.a with the real thing).
#
# Step 1 — script: download the devkitPro updater, open it for you.
# Step 2 — interactive: in the installer GUI:
#            - Accept license
#            - Install location: C:\devkitPro  (default, recommended)
#            - Components: tick "devkitARM" + "GBA Development"
#              ("Required" group is always on; the rest are optional —
#              we only need ARM + GBA)
#            - Click Install. Takes ~5-15 min while pacman downloads
#              gcc-arm-none-eabi + newlib + libgba + gba-tools.
# Step 3 — script: re-run `verify-devkitpro.ps1` to confirm install
#            and configure FPC to use devkitARM's libs + binutils.

$ErrorActionPreference = 'Stop'

$url = 'https://github.com/devkitPro/installer/releases/download/v3.0.3/devkitProUpdater-3.0.3.exe'
$tmp = Join-Path $env:TEMP 'devkitpro-install'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$installer = Join-Path $tmp 'devkitProUpdater-3.0.3.exe'

if (-not (Test-Path $installer)) {
  Write-Host "Downloading devkitProUpdater-3.0.3.exe (~196 KB)..."
  Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
}
$size = (Get-Item $installer).Length
$sha  = (Get-FileHash $installer -Algorithm SHA256).Hash
Write-Host "Installer:    $installer"
Write-Host "Size:         $size bytes"
Write-Host "SHA-256:      $sha"
Write-Host ''
Write-Host '--- next steps (interactive) ---'
Write-Host '1. Installer is launching. In its GUI:'
Write-Host '   - Click through license + dest dir (default C:\devkitPro)'
Write-Host '   - At "Choose Components": tick "devkitARM" AND "GBA Development"'
Write-Host '   - Click Install. Downloads ~300 MB via dkp-pacman; takes 5-15 min.'
Write-Host '2. When the installer reports success, run: .\verify-devkitpro.ps1'
Write-Host ''
Write-Host 'Launching installer now (separate process). This script will exit.'
Start-Process -FilePath $installer
