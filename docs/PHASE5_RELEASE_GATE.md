# Phase 5 Release Gate Checklist

## A. Security + Integrity (must pass)

- [ ] Firestore rules deployed and validated in staging.
- [ ] Storage rules deployed (`profile_photos/{uid}/**` owner-write only).
- [ ] Callable App Check enforcement is `enforce` in production.
- [ ] No client path can mint wallet/reputation fields.
- [ ] `public_users` projection excludes deleted/disabled/admin-blocked/hidden users.

## B. Data Correctness

- [ ] Run `backfillPublicUsers_v1` once after deployment.
- [ ] Run `backfillFollowersCount_v1` once after follower mirror rollout.
- [ ] Confirm `followersCount`, `level`, `listenerRate` are server-authoritative.
- [ ] Validate chat role semantics with lexically reversed UIDs.

## C. Payments Honesty

- [ ] Wallet/withdrawal copy clearly states current mode (test/manual/live).
- [ ] No UI/backend claims “production ready” unless credentials and operations are truly live.

## D. Android Release

- [ ] Android `applicationId`/`namespace` set to final package id.
- [ ] Release keystore configured via `android/key.properties`.
- [ ] Release build is signed with upload key (not debug key).
- [ ] `google-services.json` package matches the Gradle Android application id.

## E. Manual QA (exact)

1. Create two users A/B where `uid(A) > uid(B)` lexically.
2. A requests chat/call from marketplace.
3. B sees incoming request and can allow/deny correctly.
4. A can only start call when session allows it.
5. Block/delete/admin-block test user and verify it disappears from discovery + public projection.
6. Follow/unfollow several users from A and confirm **A's** level does not increase from self-following behavior.
7. Confirm follower target count changes for followed user only.
8. Upload and delete profile photo at `profile_photos/{uid}/...` with owner and non-owner accounts.

## F. Deploy sequence

1. `firebase deploy --only firestore:rules,firestore:indexes,storage`
2. `firebase deploy --only functions`
3. Run backfills (`backfillPublicUsers_v1`, `backfillFollowersCount_v1`).
4. Verify admin dashboard + marketplace + chat request inbox in production project.
