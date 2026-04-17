# Stabilization Changelog

## Backend
- Added `functions/package.json` with Node 20 engine and deploy/check scripts.
- Removed legacy `functions.config()` secret fallback in favor of env-based config.
- Defaulted callable App Check mode to enforced when invalid/missing.
- Fixed public projection correctness (`isListener`, `isAvailable`, visibility suppression).
- Added follower mirror and authoritative recomputation trigger + backfill callable.
- Added canonical chat role-intent fields (`requesterId`, `responderId`, `pendingFor`, `actionOwner`).

## Firebase config
- Added `storage.rules` and Firebase Storage config wiring in `firebase.json`.
- Added indexes for pending chat requests and discoverable listener query.

## App
- Marketplace listener list now queries server-side discoverable listeners.
- Stopped forcing listener availability/listener mode in repository mapping.
- Incoming request streams now query `pendingFor` + `callRequestOpen`.
- Softened global accessibility text scaling clamp upper bound.

## Android
- Replaced placeholder app id usage with explicit `com.friendify.app` namespace/applicationId.
- Removed debug signing from release and introduced keystore property pattern.
