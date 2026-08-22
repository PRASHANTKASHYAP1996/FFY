# Friendify — Pre‑Launch Checklist

> ## ⛔ NOT PRODUCTION‑READY
>
> Friendify **must not be published, uploaded to Play, or treated as
> release‑ready** in its current state. The items below are unresolved.

### Release status — as of the PowerX publishing‑prep pass

| Area | State |
|---|---|
| Android package id | ✅ `com.powerx.friendify` (applicationId, namespace, Kotlin sources) |
| compileSdk / targetSdk | ✅ Pinned to **API 36** (Android 16) |
| Release signing safeguards | ✅ Debug keystore / debug alias / incomplete `key.properties` all rejected |
| Native lib packaging | ✅ `useLegacyPackaging = false` pinned |
| Dart format / analyze / tests | ✅ Clean · clean · 136/136 |
| **Firebase configuration** | ❌ **Still targets `com.friendify.app`** |
| **Release AAB build** | ❌ **Blocked** — cannot be produced |
| **Final 16 KB alignment verification** | ❌ **Blocked** — debug‑APK only so far |

**Firebase (blocking).** `android/app/google-services.json` still registers the
legacy package **`com.friendify.app`**, and `lib/firebase_options.dart` +
`flutterfire.json` still carry that app's id. These must be replaced with a
**PowerX‑owned** Firebase Android client for **`com.powerx.friendify`**
(not personal‑Gmail owned). No credentials were invented or modified.

**Blocked verifications.** Until that config arrives:
- the **release AAB cannot be built**, so release signing is unproven end‑to‑end;
- **16 KB alignment is only confirmed on a debug APK** (32/32 `.so` ZIP‑aligned,
  41/41 ELF `p_align` ≥ 16384). Re‑confirm on the first real release AAB.


> App: **Friendify — by PowerX** · package **`com.powerx.friendify`**
> Firebase project **`friendify-ef682`** (`481804518660`)
>
> **Code state:** feature‑complete · `flutter analyze` clean · 136 tests green.
> **Current hard blocker:** the Android build is broken until the new
> `google-services.json` (for `com.powerx.friendify`) is in place — that one
> step gates everything below.

Legend: 🔴 blocker · 🟠 required before public launch · 🟡 recommended · ✅ done

---

## A. Your tasks (in order)

### 1. 🔴 Firebase — register the new package  *(unblocks the build)*
- [ ] Firebase Console → project `friendify-ef682` → **Add app → Android**
- [ ] Package name: **`com.powerx.friendify`** (exact)
- [ ] Add **SHA‑1 + SHA‑256** for both debug and release keystores
      *(debug SHA: `keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android`)*
- [ ] **App Check** → register the new app with **Play Integrity**; add a **debug token** for your dev device
- [ ] Download the new **`google-services.json`** → replace `android/app/google-services.json`
- [ ] Regenerate the Dart/FlutterFire config (they still hold the OLD app id):
      `flutterfire configure --project=friendify-ef682 --platforms=android`
      -> rewrites `lib/firebase_options.dart` + `flutterfire.json`
- [ ] *(Leave the old `com.friendify.app` app in Firebase — harmless; remove later)*

### 2. 🔴 Verify the build comes back
```bash
flutter build apk --debug
```
- [ ] Builds successfully (no "No matching client…" error)
- [ ] *(Then ping Claude to run the full rename verification: package id in the APK, auth/FCM/App Check config, no stray `com.friendify.app`.)*

### 3. 🔴 Deploy the backend
```bash
firebase deploy --only functions,firestore:rules
```
- [ ] Answer **yes** when it asks to delete `cleanupExpiredStories_v1` (stories were removed — expected)
- [ ] Confirms functions + rules deployed with no errors

### 4. 🟡 Push the code
```bash
git push origin main
```
- [ ] Commits pushed *(needs GitHub login: `gh auth login` or a PAT)*

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
- [ ] Create `android/key.properties` (storeFile, storePassword, keyAlias, keyPassword) + release keystore
```bash
flutter build appbundle --release
```
- [ ] AAB builds; verify package id = `com.powerx.friendify`

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
- Verify the rename after step 1–2 (package id in artifact, config checks).
- Add **crash reporting** (Crashlytics) wiring.
- Any UI/logic fixes surfaced by device QA in step 5.

## C. Notes
- Nothing here changes package IDs or technical identifiers beyond the approved
  `com.powerx.friendify` rename. Friendify stays an independent product.
- The **only** thing blocking a green build right now is step 1's
  `google-services.json`. Everything else can proceed once that's in.
