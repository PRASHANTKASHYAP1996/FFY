param(
  [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "Cleaning local Flutter build artifacts..."
flutter clean

Remove-Item -LiteralPath (Join-Path $root "build") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root ".dart_tool") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root "android\.gradle") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root "android\.kotlin") -Recurse -Force -ErrorAction SilentlyContinue

if (-not $SkipPubGet) {
  flutter pub get
}

Write-Host "Local build cleanup complete."
