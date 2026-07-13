param(
  [Parameter(Mandatory = $true)]
  [string]$DeviceId,

  [string]$AgoraAppId = "d736041fa2ad4f4b9a417b2365fde277",

  [switch]$Attach,
  [switch]$WithPubGet
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Attach) {
  Write-Host "Attaching to running Friendify debug app on $DeviceId..."
  flutter attach -d $DeviceId
  exit $LASTEXITCODE
}

$pubFlag = if ($WithPubGet) { "" } else { "--no-pub" }

Write-Host "Starting Friendify debug session on $DeviceId..."
if ($pubFlag) {
  flutter run -d $DeviceId $pubFlag --dart-define=FRIENDIFY_AGORA_APP_ID=$AgoraAppId
} else {
  flutter run -d $DeviceId --dart-define=FRIENDIFY_AGORA_APP_ID=$AgoraAppId
}
