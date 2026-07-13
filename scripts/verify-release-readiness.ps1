[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$expectedPackageName = 'com.friendify.app'

$googleServicesPath = Join-Path $repoRoot 'android\app\google-services.json'
$firebaseOptionsPath = Join-Path $repoRoot 'lib\firebase_options.dart'
$staleFirebaseOptionsPath = Join-Path $repoRoot 'lib\firebase_options.stale.dart'
$flutterfirePath = Join-Path $repoRoot 'flutterfire.json'
$readmePath = Join-Path $repoRoot 'README.md'
$releaseGatePath = Join-Path $repoRoot 'docs\PHASE5_RELEASE_GATE.md'
$androidManifestPath = Join-Path $repoRoot 'android\app\src\main\AndroidManifest.xml'

$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
$expectedGoogleServicesAppId = ''

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

if (-not (Test-Path $googleServicesPath)) {
    Add-Failure "android/app/google-services.json is missing."
} else {
    $googleServices = Get-Content $googleServicesPath -Raw | ConvertFrom-Json
    $androidClients = @(
        $googleServices.client |
            Where-Object {
                $_.client_info.android_client_info.package_name -eq $expectedPackageName
            }
    )
    $packageNames = @(
        $googleServices.client |
            ForEach-Object { $_.client_info.android_client_info.package_name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Sort-Object -Unique

    $packageNames = @($packageNames)
    $examplePackageNames = @(
        $packageNames |
            Where-Object { $_ -like 'com.example*' }
    )

    if ($androidClients.Count -eq 0) {
        $actualPackages = if ($packageNames.Count -gt 0) {
            $packageNames -join ', '
        } else {
            '<missing package_name>'
        }
        Add-Failure "android/app/google-services.json must contain an Android client for package_name '$expectedPackageName' (found: $actualPackages)."
    } elseif ($androidClients.Count -gt 1) {
        Add-Failure "android/app/google-services.json contains multiple Android clients for package_name '$expectedPackageName'."
    } else {
        Add-Pass "android/app/google-services.json contains an Android client for $expectedPackageName."
    }

    if ($examplePackageNames.Count -gt 0) {
        Add-Failure "android/app/google-services.json still contains stale example Android client(s): $($examplePackageNames -join ', '). Download a fresh Firebase file containing only $expectedPackageName before release."
    }

    if ($androidClients.Count -eq 1) {
        $expectedGoogleServicesAppId = [string]$androidClients[0].client_info.mobilesdk_app_id
    }
}

if (-not (Test-Path $flutterfirePath)) {
    Add-Failure "flutterfire.json is missing."
} else {
    $flutterfire = Get-Content $flutterfirePath -Raw | ConvertFrom-Json
    $flutterfireAndroidAppId = [string]$flutterfire.platforms.android.default.appId
    $flutterfireDartAndroidAppId = [string]$flutterfire.platforms.dart.'lib/firebase_options.dart'.configurations.android
    $flutterfireProjectIds = @(
        [string]$flutterfire.platforms.android.default.projectId
        [string]$flutterfire.platforms.dart.'lib/firebase_options.dart'.projectId
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    $flutterfireProjectIds = @($flutterfireProjectIds)

    if ([string]::IsNullOrWhiteSpace($flutterfireAndroidAppId)) {
        Add-Failure "flutterfire.json is missing platforms.android.default.appId."
    }

    if ([string]::IsNullOrWhiteSpace($flutterfireDartAndroidAppId)) {
        Add-Failure "flutterfire.json is missing platforms.dart.'lib/firebase_options.dart'.configurations.android."
    }

    if (
        -not [string]::IsNullOrWhiteSpace($flutterfireAndroidAppId) -and
        -not [string]::IsNullOrWhiteSpace($flutterfireDartAndroidAppId) -and
        $flutterfireAndroidAppId -ne $flutterfireDartAndroidAppId
    ) {
        Add-Failure "flutterfire.json Android app ids do not match (android.default=$flutterfireAndroidAppId, dart.android=$flutterfireDartAndroidAppId)."
    }

    if ($flutterfireProjectIds.Count -ne 1 -or $flutterfireProjectIds[0] -ne 'friendify-ef682') {
        $actualProjects = if ($flutterfireProjectIds.Count -gt 0) {
            $flutterfireProjectIds -join ', '
        } else {
            '<missing projectId>'
        }
        Add-Failure "flutterfire.json must point to projectId 'friendify-ef682' (found: $actualProjects)."
    } else {
        Add-Pass "flutterfire.json projectId matches friendify-ef682."
    }

    if (
        -not [string]::IsNullOrWhiteSpace($expectedGoogleServicesAppId) -and
        -not [string]::IsNullOrWhiteSpace($flutterfireAndroidAppId) -and
        $flutterfireAndroidAppId -ne $expectedGoogleServicesAppId
    ) {
        Add-Failure "flutterfire.json Android app id '$flutterfireAndroidAppId' does not match android/app/google-services.json app id '$expectedGoogleServicesAppId'. Re-run flutterfire configure after replacing google-services.json."
    } elseif (
        -not [string]::IsNullOrWhiteSpace($expectedGoogleServicesAppId) -and
        -not [string]::IsNullOrWhiteSpace($flutterfireAndroidAppId)
    ) {
        Add-Pass "flutterfire.json Android app id matches android/app/google-services.json."
    }
}

if (-not (Test-Path $firebaseOptionsPath)) {
    Add-Failure "lib/firebase_options.dart is missing."
} else {
    $firebaseOptionsText = Get-Content $firebaseOptionsPath -Raw
    $staleMarkers = @(
        'REGENERATION REQUIRED:',
        'REGENERATE_WITH_FLUTTERFIRE',
        'pre-migration setup'
    ) | Where-Object { $firebaseOptionsText.Contains($_) }

    if ($staleMarkers.Count -gt 0) {
        Add-Failure "lib/firebase_options.dart still contains regeneration markers: $($staleMarkers -join ', ')."
    } else {
        Add-Pass 'lib/firebase_options.dart has no stale regeneration markers.'
    }
}

if (Test-Path $staleFirebaseOptionsPath) {
    Add-Failure "lib/firebase_options.stale.dart is present under lib/. Remove stale generated Firebase config snapshots before release so analyzer/build tooling cannot pick up obsolete project config."
}

if (-not (Test-Path $androidManifestPath)) {
    Add-Failure "android/app/src/main/AndroidManifest.xml is missing."
} else {
    $androidManifestText = Get-Content $androidManifestPath -Raw
    $usesPhoneCallForegroundService =
        $androidManifestText.Contains('android:foregroundServiceType="phoneCall"') -or
        $androidManifestText.Contains('phoneCall|') -or
        $androidManifestText.Contains('|phoneCall')

    if ($usesPhoneCallForegroundService) {
        if (-not $androidManifestText.Contains('android.permission.FOREGROUND_SERVICE_PHONE_CALL')) {
            Add-Failure "Android manifest uses phoneCall foreground service type but is missing android.permission.FOREGROUND_SERVICE_PHONE_CALL."
        }
        if (-not $androidManifestText.Contains('android.permission.MANAGE_OWN_CALLS')) {
            Add-Failure "Android manifest uses phoneCall foreground service type but is missing android.permission.MANAGE_OWN_CALLS."
        }
        if (
            $androidManifestText.Contains('android.permission.FOREGROUND_SERVICE_PHONE_CALL') -and
            $androidManifestText.Contains('android.permission.MANAGE_OWN_CALLS')
        ) {
            Add-Pass 'Android phone-call foreground service permissions are declared.'
        }
    }
}

$localArchiveFiles = @(
    Get-ChildItem -Path $repoRoot -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like '*.zip' -or
            $_.Name -like '*.7z' -or
            $_.Name -like '*.rar' -or
            $_.Name -like '*.tar' -or
            $_.Name -like '*.tar.gz'
        }
)
if ($localArchiveFiles.Count -gt 0) {
    $archiveNames = ($localArchiveFiles | ForEach-Object { $_.Name }) -join ', '
    Add-Failure "Local archive/export artifact(s) found at repo root: $archiveNames. Remove them or create a clean export outside the repo before release."
}

$docsText = @()
foreach ($docPath in @($readmePath, $releaseGatePath)) {
    if (-not (Test-Path $docPath)) {
        Add-Failure "$docPath is missing."
        continue
    }
    $docsText += Get-Content $docPath -Raw
}

if ($docsText.Count -gt 0) {
    $combinedDocs = $docsText -join "`n"
    $requiredDocMentions = @(
        'FRIENDIFY_PRIVACY_URL',
        'FRIENDIFY_TERMS_URL',
        'FRIENDIFY_REFUND_URL',
        'FRIENDIFY_SUPPORT_URL',
        'FRIENDIFY_SUPPORT_EMAIL',
        'FRIENDIFY_APP_CHECK_MODE=release',
        'Play Integrity',
        'FRIENDIFY_AGORA_APP_ID',
        'signed release smoke test'
    )

    $missingMentions = $requiredDocMentions | Where-Object { -not $combinedDocs.Contains($_) }
    if ($missingMentions.Count -gt 0) {
        Add-Failure "Release docs are missing required references: $($missingMentions -join ', ')."
    } else {
        Add-Pass 'README.md and docs/PHASE5_RELEASE_GATE.md document legal/support defines, App Check release mode, Agora app id, and signed release smoke testing.'
    }
}

Write-Host ''
foreach ($message in $passes) {
    Write-Host "[PASS] $message" -ForegroundColor Green
}
foreach ($message in $failures) {
    Write-Host "[FAIL] $message" -ForegroundColor Red
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Release readiness verification failed. Fix the blockers above before attempting a signed release build.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Release readiness verification passed. Repo-side release prerequisites look aligned.' -ForegroundColor Green
