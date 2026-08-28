# Friendify — Pre‑Launch Checklist

> ## ⛔ NOT PRODUCTION‑READY
>
> Friendify **must not be published, uploaded to Play, or treated as
> release‑ready** in its current state. The items below are unresolved.

### Release status — verified

**Verified code / build state**

| Area | State |
|---|---|
| Android package id | ✅ `com.powerx.friendify` (applicationId, namespace, Kotlin sources, release artifact) |
| compileSdk / targetSdk | ✅ Pinned to **API 36** (Android 16) |
| Release signing safeguards | ✅ Debug keystore / debug alias / incomplete `key.properties` all rejected |
| Native lib packaging | ✅ `useLegacyPackaging = false` pinned |
| Release AAB build | ✅ Builds successfully; artifact package id confirmed `com.powerx.friendify` |
| 16 KB page alignment | ✅ 64‑bit ABIs pass on the **release AAB** (arm64‑v8a 32/32, x86_64 32/32). armeabi‑v7a is 32‑bit and out of scope |
| Sensitive permissions | ✅ `CAMERA`, `NFC`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` removed; Agora screen‑sharing service removed; legacy `BLUETOOTH` capped at `maxSdkVersion="30"` |
| Dart format / analyze / tests | ✅ Clean · clean · 136/136 |
| Backend lint / check / tests | ✅ Pass · pass · **156/156** (113 behavioral + 43 Firestore‑rules) |
| Git sync | ✅ `main` and `origin/main` synchronized at `7e671a5` |

**Verified deployed backend state**

| Area | State |
|---|---|
| Firebase Android client | ✅ Registered for `com.powerx.friendify` in `friendify-ef682` |
| Firebase config sources | ✅ `google-services.json`, `firebase_options.dart`, `firebase.json`, `flutterfire.json` all agree |
| SHA fingerprints | ✅ Debug + **upload‑key** SHA‑1/SHA‑256 registered on the new client |
| Cloud Functions | ✅ Local/deployed match **69/69** |
| Firestore rules | ✅ Deployed rules match local exactly |
| Firestore indexes | ✅ **27/27 READY**, matching local |
| Public review reads | ✅ Listener‑profile reviews readable; all client writes still denied |

**Still open — see section A**

| Area | State |
|---|---|
| **Razorpay live credentials** | ❌ Not configured or verified |
| **Production Razorpay guard** | ❌ Committed and pushed, **not deployed** to the two payment functions |
| **Play App Signing SHA‑1/SHA‑256** | ❌ Not registered (upload‑key fingerprints do **not** substitute) |
| **Play‑distributed App Check / Play Integrity** | ❌ Pending |
| **Device QA** | ❌ Pending |
| **Play Console listing / Data Safety / rating** | ❌ Pending |

**Non‑blocking observations.** The stale capital‑`Calls` Firestore index is still
present (duplicate of a lowercase `calls` index; no query targets it). Cloud
Functions run in `us-central1` while the database is in `asia-south1` — a
latency optimization concern, not a blocker.

> App: **Friendify — by PowerX** · package **`com.powerx.friendify`**
> Firebase project **`friendify-ef682`** (`481804518660`)
>
> **Code state:** feature‑complete · `flutter analyze` clean · 136 Flutter tests
> green · 156 backend tests green · release AAB builds.
> **Current hard blockers:** live Razorpay credentials, Play App Signing
> fingerprints, and real‑device QA. **Do not treat payments as working.**

Legend: 🔴 blocker · 🟠 required before public launch · 🟡 recommended · ✅ done

---

## A. Your tasks (in order)

### 1. ✅ Firebase — register the new package  *(done)*
- [x] Firebase Console → project `friendify-ef682` → **Add app → Android**
- [x] Package name: **`com.powerx.friendify`** (exact)
- [x] Add **SHA‑1 + SHA‑256** for both debug and upload keystores
      *(debug SHA: `keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android`)*
- [ ] 🔴 **App Check** → register the app with **Play Integrity** and add the
      **Play App Signing** SHA‑1/SHA‑256 once Play generates them. The upload‑key
      fingerprints already registered do **not** cover Play‑distributed installs
- [x] Download the new **`google-services.json`** → replace `android/app/google-services.json`
- [x] Regenerate the Dart/FlutterFire config
      (`flutterfire configure --project=friendify-ef682 --platforms=android`)
- [x] *(Old `com.friendify.app` client deliberately retained for rollback)*

### 2. ✅ Verify the build  *(done)*
```bash
flutter build appbundle --release
```
- [x] Release AAB builds successfully
- [x] Artifact package id verified `com.powerx.friendify`; no stray `com.friendify.app`

### 3. ✅ Deploy the backend  *(done — except the payment guard)*
- [x] Cloud Functions deployed and reconciled: **69/69** local = deployed
- [x] Firestore rules deployed; deployed rules match local exactly
- [x] Firestore indexes verified **27/27 READY** (no index deployment needed)
- [ ] 🔴 Redeploy `createRazorpayOrder_v1` + `verifyRazorpayPayment_v1` so the
      production credential guard takes effect — **only after** live Razorpay
      keys are configured, otherwise the guard will (correctly) block them

### 4. ✅ Push the code  *(done)*
- [x] `main` and `origin/main` synchronized at `7e671a5`

### 5. 🔴 Real‑device QA — calls + payments  *(most important)*
Install the debug build on a real phone, sign in, and verify:
- [ ] **Google Sign‑In** works
- [ ] **Voice call** end‑to‑end: start → ringing → accept → talk → hang up (2 devices ideal)
- [ ] **Incoming call** notification + CallKit full‑screen works (app backgrounded/locked)
- [ ] **Wallet top‑up** via Razorpay completes and credits update
- [ ] **Per‑minute billing** debits correctly after a call
- [ ] **Withdrawal** request flow (listener side)
- [ ] **FCM** push notifications arrive
- [ ] **Bottom sheets** render light (settings, new post, wallet top‑up)
- [ ] No overflow/clipped text on a small screen

### 6. 🟠 Production payments (Razorpay)
- [ ] Razorpay **KYC** complete + business/payout account live
- [ ] Switch from **sandbox/test keys → production keys** (backend config)
- [ ] Confirm real top‑up + real payout on a live account (small amount)

### 7. 🟠 Release signing + AAB
- [x] Local upload keystore + `android/key.properties` in place (untracked)
- [x] AAB builds; package id verified `com.powerx.friendify`
- [ ] 🔴 Enrol in **Play App Signing** and register Play's SHA‑1/SHA‑256 on the
      Firebase client (required for App Check on Play builds)

### 8. 🟠 Google Play Console
- [ ] Create app listing (title, short/full description, **Friendify — by PowerX**)
- [ ] Screenshots (phone), feature graphic, icon
- [ ] **Privacy policy URL** (live)
- [ ] **Data safety** form (collects: account, messages, audio for calls, payments)
- [ ] **Content rating** questionnaire
- [ ] Confirm **payments policy**: pay‑per‑minute for human voice calls = real‑world service (Razorpay allowed) — verify against Play's payments policy for your case
- [ ] Upload AAB to **Internal testing** first → test → then Closed/Production

### 9. 🟡 Nice‑to‑have before/after launch
- [ ] **Crash reporting** (`firebase_crashlytics`) — Claude can wire the Dart side on request
- [ ] iOS bundle id + `GoogleService-Info.plist` *(only if shipping iOS — currently Android‑only)*

---

## B. What Claude can still do on the code side (just ask)
- Add **crash reporting** (Crashlytics) wiring.
- Redeploy the two payment functions once live Razorpay keys are configured.
- Investigate the `us-central1` / `asia-south1` cross‑region latency.
- Remove the stale capital‑`Calls` Firestore index (non‑blocking).
- Any UI/logic fixes surfaced by device QA in step 5.

## C. Notes
- Nothing here changes package IDs or technical identifiers beyond the approved
  `com.powerx.friendify` rename. Friendify stays an independent product.
- The build and backend are green. What remains is **operational**: live payment
  credentials, Play App Signing, Play Console submission, and device QA.
- ⚠️ `docs/PHASE5_RELEASE_GATE.md` and `QA_CHECKLIST.md` still name the old
  `com.friendify.app` package as final. They are stale relative to this
  checklist; treat this file and `README.md` as authoritative for package id.
