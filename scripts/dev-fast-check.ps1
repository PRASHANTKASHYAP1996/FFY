param(
  [switch]$Full
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Full) {
  Write-Host "Running full Flutter gate..."
  flutter analyze
  flutter test
  exit $LASTEXITCODE
}

$fastTests = @(
  "test/agora_client_config_test.dart",
  "test/app_user_model_test.dart",
  "test/chat_bootstrap_behavior_test.dart",
  "test/chat_call_request_ui_state_test.dart",
  "test/chat_direction_normalization_test.dart",
  "test/chat_direction_resolver_test.dart",
  "test/chat_navigation_guards_test.dart",
  "test/chat_session_direction_guard_test.dart",
  "test/firestore_paths_test.dart",
  "test/legal_links_readiness_test.dart",
  "test/legal_links_test.dart",
  "test/listener_availability_test.dart",
  "test/missed_call_query_test.dart",
  "test/notification_channels_test.dart",
  "test/notification_push_test.dart",
  "test/production_copy_test.dart",
  "test/recent_chat_direction_test.dart",
  "test/storage_paths_test.dart",
  "test/user_safety_actions_test.dart",
  "test/wallet_amount_formatting_test.dart",
  "test/wallet_copy_test.dart"
)

Write-Host "Running fast Dart analysis over app/test sources..."
dart analyze lib test

Write-Host "Running fast non-widget test subset..."
flutter test $fastTests
