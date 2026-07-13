# Friendify (Flutter + Firebase)

Friendify is a voice-first social app with chat, call permissions, wallet flows, and admin tooling.

## What this stabilization pass changes

- Functions are now validated locally against a Node 22 runtime target.
- Public profile projection now reflects real `isListener`/`isAvailable` and suppresses blocked/hidden/deleted users.
- Follower counting is server-authoritative through `user_followers/{uid}/followers/{followerUid}` mirrors and backfill callable.
- Chat-session data now stores canonical pair identity plus role-intent fields (`requesterId`, `responderId`, `pendingFor`, `actionOwner`).
- Android release builds are now blocked if the Gradle application id still points at `com.example.*`.
- Storage rules were added for profile photos.

## Setup

### 1) Flutter app

Use your local Flutter SDK (3.x, Dart 3.3+).

Recommended Dart defines for launch controls:

- `--dart-define=FRIENDIFY_APP_CHECK_MODE=release`
- `--dart-define=FRIENDIFY_AGORA_APP_ID=<your-production-agora-app-id>`

Optional debug/dev-only Agora fallback:

- `--dart-define=FRIENDIFY_AGORA_TEST_APP_ID=<your-debug-or-staging-agora-app-id>`

Important: `--dart-define=FRIENDIFY_APP_ID=...` does **not** change the Android
package name or Gradle `applicationId`. Android package migration must be done
through Gradle properties and Firebase app regeneration.

Release builds are blocked if `FRIENDIFY_AGORA_APP_ID` is empty.
Debug/dev builds may use `FRIENDIFY_AGORA_TEST_APP_ID`, but the selected client
Agora app ID must match the server `AGORA_APP_ID` that Firebase Functions uses
to mint tokens.

### 2) Firebase Functions

```bash
cd functions
npm ci
```

Required environment (Firebase Functions secrets / env):

- `APP_CHECK_ENFORCE_CALLABLES` = `enforce` (recommended for prod)
- `AGORA_APP_ID`
- `AGORA_APP_CERTIFICATE`
- `RAZORPAY_KEY_ID`
- `RAZORPAY_KEY_SECRET`

> This repo is configured with `disallowLegacyRuntimeConfig: true`; do **not** rely on `functions.config()`.

The Flutter client `FRIENDIFY_AGORA_APP_ID` must match this server-side
`AGORA_APP_ID`. If Functions cannot mint Agora tokens because `AGORA_APP_ID`
or `AGORA_APP_CERTIFICATE` is missing, call creation now fails clearly instead
of creating a broken call session.

### 3) Maintenance scripts with ADC

For local admin scripts/callables backfill operations, use Application Default Credentials:

```bash
gcloud auth application-default login
firebase use <project-id>
```

### 4) Android release signing (no secrets in repo)

Create `android/key.properties` (local, uncommitted):

```properties
storeFile=/absolute/path/to/your-upload-keystore.jks
storePassword=***
keyAlias=***
keyPassword=***
```

Set your final Android package id using either:

- environment variable: `ORG_GRADLE_PROJECT_FRIENDIFY_APP_ID=com.friendify.app`
- or `friendify.appId=com.friendify.app` in `android/local.properties`

Example release build commands:

```powershell
$env:ORG_GRADLE_PROJECT_FRIENDIFY_APP_ID='com.friendify.app'
flutter build appbundle --release
```

```properties
# android/local.properties
friendify.appId=com.friendify.app
```

### 5) Final package / Firebase migration before Play Store

Current repo-side package/Firebase alignment is configured for `com.friendify.app` and is checked by `scripts/verify-release-readiness.ps1`.

Keep these gates intact for final production builds:

1. Final Android package id remains `com.friendify.app`.
2. Android source stays at `android/app/src/main/kotlin/com/friendify/app/MainActivity.kt` with the matching Kotlin package declaration.
3. Set `ORG_GRADLE_PROJECT_FRIENDIFY_APP_ID=com.friendify.app` (or `friendify.appId=com.friendify.app`) for Android builds.
4. Keep the Firebase Android app registration, `android/app/google-services.json`, `flutterfire.json`, and `lib/firebase_options.dart` aligned for `com.friendify.app`.
5. Register release SHA-1/SHA-256 fingerprints for the upload/app-signing keys.
6. In Firebase App Check, keep the Debug provider only for debug/dev workflows and enable Play Integrity for the release Android app `com.friendify.app`.
7. Build a release artifact and verify the Gradle guard no longer blocks the build.

Release builds must not ship with any `com.example.*` package.
Release builds are also blocked if `android/app/google-services.json` still points at the old package or `lib/firebase_options.dart` is still marked as pre-migration config.

## Validation Setup

### Flutter validation

Run from the repo root:

```bash
flutter clean
flutter pub get
flutter analyze
flutter test
```

If you are validating voice calls locally, include the Agora client define(s)
for the build you are testing:

```bash
flutter run --dart-define=FRIENDIFY_AGORA_APP_ID=<matching-agora-app-id>
```

Debug/dev example:

```bash
flutter run --dart-define=FRIENDIFY_AGORA_TEST_APP_ID=<debug-or-staging-agora-app-id>
```

### Release verifier

Before attempting a signed release build, run the repo-side verifier from the
repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-release-readiness.ps1
```

This complements the Gradle release guard by checking for stale repo config:

- `android/app/google-services.json` still matches `com.friendify.app`
- `flutterfire.json` points to the same Android app id as `android/app/google-services.json`
- `flutterfire.json` still targets Firebase project `friendify-ef682`
- `lib/firebase_options.dart` no longer contains regeneration markers
- release docs still mention the required legal/support defines:
  - `FRIENDIFY_PRIVACY_URL`
  - `FRIENDIFY_TERMS_URL`
  - `FRIENDIFY_REFUND_URL`
  - `FRIENDIFY_SUPPORT_URL`
  - `FRIENDIFY_SUPPORT_EMAIL`
- App Check release mode is documented as `FRIENDIFY_APP_CHECK_MODE=release`
- `FRIENDIFY_AGORA_APP_ID` is documented for release builds
- the signed release smoke test reminder is still present in the release docs

Example signed release build with the required non-secret defines:

```powershell
$env:ORG_GRADLE_PROJECT_FRIENDIFY_APP_ID='com.friendify.app'
flutter build appbundle --release `
  --dart-define=FRIENDIFY_APP_CHECK_MODE=release `
  --dart-define=FRIENDIFY_AGORA_APP_ID=<matching-agora-app-id> `
  --dart-define=FRIENDIFY_PRIVACY_URL=<https-url> `
  --dart-define=FRIENDIFY_TERMS_URL=<https-url> `
  --dart-define=FRIENDIFY_REFUND_URL=<https-url> `
  --dart-define=FRIENDIFY_SUPPORT_URL=<https-url> `
  --dart-define=FRIENDIFY_SUPPORT_EMAIL=<support-email>
```

Replace the placeholder examples above with real values before building a
release artifact. Literal placeholder strings such as `YOUR_REAL_*`,
`<https-url>`, and `<support-email>` are rejected by the app's release
readiness checks at startup.

The verifier does not replace the final signed release smoke test on device.

### Functions validation

Run from the `functions` directory:

```bash
cd functions
npm ci
npm test
npm run check
npm run check:chat-contract
npm run check:migrate-chat-docids
```

## Deploy

```bash
firebase deploy --only "firestore:rules,firestore:indexes,storage"
firebase deploy --only "functions"
```

## Remaining external launch blockers (non-code)

- Final legal/policy/support text + approved URLs.
- Real payout operations and reconciliation SOP beyond test/manual modes.
- Live payment merchant onboarding and production credential rollout.
- Store listing/legal compliance assets.
