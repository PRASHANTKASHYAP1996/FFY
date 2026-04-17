# Friendify (Flutter + Firebase)

Friendify is a voice-first social app with chat, call permissions, wallet flows, and admin tooling.

## What this stabilization pass changes

- Functions are now deployment-ready with `functions/package.json` and Node 22 runtime.
- Public profile projection now reflects real `isListener`/`isAvailable` and suppresses blocked/hidden/deleted users.
- Follower counting is server-authoritative through `user_followers/{uid}/followers/{followerUid}` mirrors and backfill callable.
- Chat-session data now stores canonical pair identity plus role-intent fields (`requesterId`, `responderId`, `pendingFor`, `actionOwner`).
- Android release config now uses explicit `com.friendify.app` and does not use debug signing for release.
- Storage rules were added for profile photos.

## Setup

### 1) Flutter app

Use your local Flutter SDK (3.x, Dart 3.3+).

Recommended defines for launch controls:

- `--dart-define=FRIENDIFY_APP_CHECK_MODE=release`

### 2) Firebase Functions

```bash
cd functions
npm install
npm run check
```

Required environment (Firebase Functions secrets / env):

- `APP_CHECK_ENFORCE_CALLABLES` = `enforce` (recommended for prod)
- `AGORA_APP_ID`
- `AGORA_APP_CERTIFICATE`
- `RAZORPAY_KEY_ID`
- `RAZORPAY_KEY_SECRET`

> This repo is configured with `disallowLegacyRuntimeConfig: true`; do **not** rely on `functions.config()`.

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

App id is now explicitly set to `com.friendify.app` in Gradle.

Before running/releasing, ensure Firebase Android config matches this package:

- regenerate `android/app/google-services.json` for `com.friendify.app`, or
- if you intentionally use a different final package id, update both Gradle and Firebase app registration together.

## Deploy

```bash
firebase deploy --only firestore:rules,firestore:indexes,storage
firebase deploy --only functions
```

## Remaining external launch blockers (non-code)

- Final legal/policy/support text + approved URLs.
- Real payout operations and reconciliation SOP beyond test/manual modes.
- Live payment merchant onboarding and production credential rollout.
- Store listing/legal compliance assets.
