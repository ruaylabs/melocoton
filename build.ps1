# Melocoton Desktop Build Script for Windows
# Run this in PowerShell from the project root

# Stop on error
$ErrorActionPreference = "Stop"

# Install Elixir dependencies
mix deps.get

# Clean up previous builds
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue _build\prod
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue burrito_out

# Install assets nodejs dependencies
npm install --prefix assets

# Compile assets
$env:MIX_ENV = "prod"
mix assets.deploy

# Set Burrito target
$env:BURRITO_TARGET = "windows"

# Compile Elixir application
mix release

# Copy Burrito output to Tauri binaries directory
$source = ".\burrito_out\melocoton_windows.exe"
$dest = ".\src-tauri\binaries\webserver-x86_64-pc-windows-msvc.exe"

if (Test-Path $source) {
    Copy-Item -Path $source -Destination $dest -Force
    Write-Host "Copied Burrito binary to $dest"
} else {
    Write-Error "Burrito binary not found at $source"
    exit 1
}

# Build Tauri app
Push-Location src-tauri
npm install
npm run tauri build
Pop-Location
