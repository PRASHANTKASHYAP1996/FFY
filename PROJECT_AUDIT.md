# Friendify — Project Overview & Full Wiring Audit

> Paid emotional‑support voice‑calling app for the Indian market.
> Flutter (Dart) client · Firebase backend (Cloud Functions v1, Firestore, Auth,
> Storage, App Check, FCM) · Agora voice · Razorpay payments (INR).
>
> Generated audit — reflects the codebase as of the current `main` branch.
> Status at generation: `flutter analyze` clean · **136 tests pass** · Android
> debug APK builds · **75 commits ahead of `origin/main` (unpushed)**.

---

## 1. What the app does

Friendify connects people who want to talk ("speakers") with people who listen
("listeners") over **paid, private 1‑on‑1 voice calls**, billed per minute from
a prepaid credit wallet. Around that core it has chat, a light social feed,
ratings/leaderboards, wallet top‑ups and listener payouts, moderation, and an
admin/analytics back office — all in one Flutter app.

**Core loops**
- **Speaker:** buy credits → find a listener (Explore) → chat / request access →
  call → pay per minute.
- **Listener:** go available → receive calls → earn credits → withdraw to bank.
- **Operator (you):** moderate users, approve withdrawals, watch metrics — via the
  in‑app Admin dashboard (admins only).

---

## 2. Tech stack & key dependencies

| Area | Package / service |
|---|---|
| UI | Flutter, Material 3, `google_fonts` (Poppins) |
| Auth | `firebase_auth` |
| Data | `cloud_firestore`, `firebase_storage` |
| Backend | `cloud_functions` (callables + triggers), Cloud Functions v1 |
| Abuse protection | `firebase_app_check` |
| Voice | `agora_rtc_engine` |
| Payments | `razorpay_flutter` (INR) |
| Push / calls | `firebase_messaging`, `flutter_local_notifications`, `flutter_callkit_incoming`, `flutter_foreground_task` |
| Device | `permission_handler`, `image_picker`, `shared_preferences` |

---

## 3. Architecture (layers)

```
┌──────────────────────────────────────────────────────────────┐
│  UI / Screens        lib/screens/**   (RedesignShell = home)  │
│      │                                                         │
│      ▼                                                         │
│  Repositories        lib/repositories/**   (singletons)       │
│      │   business API the UI talks to; no Firebase types leak  │
│      ▼                                                         │
│  Services            lib/services/**                          │
│      │   FirestoreService, CallManager, Agora, Notifications   │
│      ▼                                                         │
│  Firebase            Firestore · Cloud Functions · Auth · FCM  │
│                      Storage · App Check                       │
└──────────────────────────────────────────────────────────────┘

Pure, unit‑tested logic lives in  lib/shared/**  (no Flutter/Firebase deps):
  level_utils · people_match · discover_ranking · call_ready_resolver ·
  chat_unread · relative_time · chat_direction_resolver · listener_availability ·
  wallet_amount_formatter · chat_navigation_guards · user_safety_actions
```

**Entry point:** `main()` → `FriendifyApp` (`lib/app.dart`) → `BootGate`
(onboarding check) → `AuthGate` (Firebase auth) → `_SignedInGate` (profile repair)
→ `MainShellScreen` → **`RedesignShell`** (the 5‑tab home).

---

## 4. File map (by size)

### Screens — `lib/screens/`
| Lines | File | Purpose |
|---|---|---|
| 4673 | `chat_conversation_screen.dart` | 1‑on‑1 chat thread, call‑request state machine |
| 3454 | `admin_dashboard_screen.dart` | **Operator back office** — payouts, moderation, reconciliation *(admins only)* |
| 2810 | `profile_screen.dart` | Own profile, editor sheet, post composer |
| 2645 | `redesign/redesign_shell.dart` | **The app home** — 5‑tab shell (**Home / Explore / Talk / Chats / You**) |
| 2356 | `match_and_call_screen.dart` | Search + match + start‑call flow |
| 1769 | `listener_profile_screen.dart` | A listener's public profile, call/chat entry |
| 1524 | `wallet_details_screen.dart` | Wallet — balance, top‑up, withdraw, statement |
| 1472 | `analytics_dashboard_screen.dart` | Business metrics *(admins, dormant)* |
| 1239 | `caller_waiting_screen.dart` | "Ringing…" screen after starting a call |
| 1207 | `voice_call_screen.dart` | Live in‑call UI (Agora) |
| 980 | `onboarding_screen.dart` | First‑run basics: name, topics, languages, intent |
| 882 | `auth_screen.dart` | Login / signup |
| 846 | `call_history_screen.dart` | Past calls |
| 791 | `post_detail_screen.dart` | Single feed post + comments |
| 610 | `developer_diagnostics_screen.dart` | Field debug (Agora/Firebase/queries) *(dormant)* |
| 605 | `earnings_screen.dart` | Listener earnings & safety |
| 542 | `listener_leaderboard_screen.dart` | Top listeners |
| 500 | `notifications_center_screen.dart` | Notifications list |
| 496 | `crisis_help_screen.dart` | Crisis/helpline resources |
| 305 | `rate_call_screen.dart` | Post‑call rating |
| 282 | `legal_policy_screen.dart` | Legal/policy viewer |
| 227 | `help_support_screen.dart` | Help & support |
| 303 | `redesign/call_setup_screen.dart` | Call setup — duration (10/20/30), est. max cost, Start private call |
| 297 | `redesign/settings_screen.dart` | Settings **bottom sheet** (`showSettingsSheet`) — the You‑tab hub |
| 184 | `redesign/saved_listeners_screen.dart` | Saved (favourited) listeners |
| 165 | `redesign/blocked_users_screen.dart` | Manage blocked users |
| 13 | `main_shell_screen.dart` | Thin wrapper → `RedesignShell` |

### Repositories — `lib/repositories/` (the UI's data API)
| Lines | File | Owns |
|---|---|---|
| 2435 | `call_repository.dart` | Call access rules, readiness, chat sessions, start/accept/end |
| 888 | `user_repository.dart` | Profile, availability, favorites, following, blocking |
| 671 | `social_repository.dart` | Posts, likes, comments, saves, notifications |
| 664 | `admin_repository.dart` | Admin dashboard load, admin actions, `isCurrentUserAdmin()` |
| 628 | `wallet_repository.dart` | Balance, top‑ups, withdrawals |
| 501 | `history_repository.dart` | Call history |
| 250 | `wallet_transactions_repository.dart` | Ledger/statement rows |
| 247 | `analytics_repository.dart` | Analytics dashboard data |

### Services — `lib/services/`
| Lines | File | Role |
|---|---|---|
| 1593 | `firestore_service.dart` | Low‑level Firestore + callable invocations |
| 1587 | `call_manager.dart` | Call lifecycle orchestration |
| 1395 | `call_session_manager.dart` | Active call/session state |
| 1329 | `notifications_service.dart` | FCM, local notifications, CallKit |
| 412 | `agora_service.dart` | Agora engine wrapper |
| 230 | `call_latency_tracker.dart` | Call timing telemetry |
| 143 | `app_log.dart` | Structured logging |
| others | notification_channels · permissions · call_wake_lock · auth_scoped_subscriptions |

### Pure logic — `lib/shared/` (unit‑tested, no Flutter/Firebase)
`level_utils` (level 1–5 + titles, from follower count) · `people_match` (Explore
match %) · `discover_ranking` · `call_ready_resolver` · `chat_unread` ·
`relative_time` · `chat_direction_resolver` · `listener_availability` ·
`chat_navigation_guards` · `user_safety_actions` · `wallet_amount_formatter`
+ `models/**` + `core/constants/**`.

---

## 5. Backend — Cloud Functions (`functions/src/`, ~13k lines)

Entry: **`functions/index.js`** imports from `src/*` and re‑exports every
deployed function. Modules: `calls.js` (4676), `admin.js` (1681),
`triggers.js` (1476), `payments.js` (1431), `admin_dashboard.js` (1129),
`shared.js` (1064), `analytics.js` (951), `social.js` (843), `withdrawals.js` (50).

### Callable functions (client → backend), by module

**calls.js** — `startCall_v2`, `acceptIncomingCall_v1`, `rejectIncomingCall_v1`,
`cancelOutgoingCall_v1`, `endCallAuthoritative_v1`, `markCallJoined_v1`,
`ensureChatSession_v1`, `speakerRequestChatAccess_v1`,
`listenerRespondToChatRequest_v1`, `settleCallBilling_v2`, `releaseReserve_v2`,
`markAcceptedPrepaidWindow_v2`, `clearBusyLock_v2`, `reconcileReserveAndLocks_v2`,
`reconcileCallOnWrite_v2`, `repairUnsettledEndedCalls_v1`, +cleanup fns.

**payments.js** — `createTopupOrder_v1`, `createRazorpayOrder_v1`,
`verifyRazorpayPayment_v1`, `verifyTopupSandbox_v1`, `failTopupOrder_v1`,
`requestWithdrawal_v1`, `cancelMyWithdrawal_v1`.

**social.js** — `createSocialPost_v1`, `deleteSocialPost_v1`, `likeSocialPost_v1`,
`unlikeSocialPost_v1`, `saveSocialPost_v1`, `unsaveSocialPost_v1`,
`shareSocialPost_v1`, `addSocialPostComment_v1`, `deleteSocialPostComment_v1`,
`reportSocialPost_v1`, `reportSocialPostComment_v1`, `markNotificationRead_v1`,
`markAllNotificationsRead_v1`, `deleteNotification_v1`.

**admin.js** *(all gated by `requireAdmin`)* — `adminApproveWithdrawal_v1`,
`adminRejectWithdrawal_v1`, `adminUpdateWithdrawalPayoutProof_v1`,
`adminBlockUser_v1`, `adminUnblockUser_v1`, `adminResolveReport_v1`,
`adminDeleteReportedContent_v1`, `adminReviewAccountDeletionRequest_v1`,
`requestAccountDeletion_v1`, `checkAgoraServerConfig_v1`.

**admin_dashboard.js** — `adminGetDashboard_v1`, `adminRefreshDashboardCache_v1`.
**analytics.js** — `analyticsLoadSummary_v1`, `analyticsLoadTodaySummary_v1`,
`analyticsLoadRetentionSummary_v1`, `analyticsLoadLast7DaysTimeseries_v1`,
`analyticsLoadListenerLeaderboard_v1`, `analyticsRefreshCaches_v1`.

### Triggers & scheduled jobs
- **triggers.js** — `onChatMessageCreated`, `onChatMessageSeenUpdated`
  (unread counts), `notifyIncomingCall`, `notifyMissedCall_v2`,
  `aggregateReviewToUser_v2` (ratings rollup), `syncFollowersCount_v2`,
  `syncPublicUserProjection_v1` (public_users projection), `cleanupCallRateLimits_v1`.
- **calls.js scheduled** — `cleanupExpiredRingingCalls_v2`,
  `cleanupStaleAcceptedCalls_v2`, `cleanupAcceptedCreditLimit_v2`,
  `reconcileReserveAndLocks_v2`, `repairUnsettledEndedCalls_v1` (money/lock safety nets).
- **Backfills (manual/admin):** `backfillFollowersCount_v1`, `backfillPublicUsers_v1`.

---

## 6. Firestore data model (top‑level collections)

| Collection | Holds |
|---|---|
| `users` | Private user docs (profile, credits, earnings, flags) |
| `public_users` | Public projection (discoverable listeners) + `reviews/` subcollection |
| `calls` | Call documents (ringing → accepted → ended, billing) |
| `chat_sessions` | 1‑on‑1 chat threads (+ `messages/`), direction, unread counters, call‑request state |
| `social_posts` | Feed posts (+ likes/comments/saves) |
| `reviews` | Ratings |
| `reports` | Abuse reports |
| `withdrawal_requests` | Listener payout requests (admin‑approved) |
| `payment_orders` | Razorpay top‑up orders |
| notifications | Per‑user notification docs |

Field names are centralized in `lib/core/constants/firestore_paths.dart` (503 lines).

---

## 7. Key end‑to‑end connections (how a feature wires across layers)

### 📞 Voice call
```
match_and_call / listener_profile (UI)
  → CallRepository.createCallToListener()
  → FirestoreService → startCall_v2 (fn)  → calls doc + Agora token
  → CallerWaitingScreen ("ringing")
Listener side:
  notifyIncomingCall (trigger) → FCM/CallKit → IncomingCallOverlay
  → acceptIncomingCall_v1 (fn) → VoiceCallScreen (Agora joins channel)
End:
  endCallAuthoritative_v1 → settleCallBilling_v2 → wallet debit/earn
  → RateCallScreen → aggregateReviewToUser_v2 (rating rollup)
Safety nets (scheduled): expired‑ringing / stale‑accepted / reserve reconcile.
```

### 💬 Chat + call access
```
listener_profile / match → speakerRequestChatAccess_v1 → chat_sessions doc
  → listener sees request → listenerRespondToChatRequest_v1 (accept)
  → ChatConversationScreen → messages/ (onChatMessageCreated updates unread)
  → accepted session unlocks calling (CallReadyResolver gates the quick‑dial)
```
Direction (who is speaker vs listener) is resolved by
`ChatDirectionResolver`; unread counts by `ChatUnread` (keyed to the **raw**
`speakerId`/`listenerId`, matching `triggers.js unreadFieldForUser`).

### 💳 Top‑up (money in)
```
WalletDetailsScreen "Add money" → WalletRepository
  → createTopupOrder_v1 / createRazorpayOrder_v1 → Razorpay SDK (checkout)
  → verifyRazorpayPayment_v1 → credits added to users doc
```

### 🏦 Withdrawal (money out)
```
WalletDetailsScreen "Withdraw" → requestWithdrawal_v1 → withdrawal_requests doc
  → AdminDashboardScreen → adminApproveWithdrawal_v1 (+ payout proof/ref)
  → adminUpdateWithdrawalPayoutProof_v1 → listener paid
```

### ✨ Home (social feed)
```
Home tab (story circles = me + follows) / composer → SocialRepository
  → createSocialPost_v1 → social_posts → watchFeedPosts stream
  → followed‑only post cards (Like + count + person's L{n}·Title level)
```

### 🧭 Explore
```
UserRepository.watchAvailableListeners() (public_users, discoverable+isListener)
  → DiscoverRanking.applyFilters (search) → _applyExploreFilter
    (For you / Mutuals / Hindi / Rising) → people list rows
  → each: follow count · PeopleMatch % · L{n}·Title · Follow/Following · tap→profile
```

### 📞 Talk
```
watchAvailableListeners ∩ my follows (online) → per‑minute price + Call
  → CallSetupScreen (10/20/30 min, est. max cost) → createCallToListener
HistoryRepository.watchMyCallHistory → Paid/Earned this week + All/Paid/Earned
```

---

## 8. Security & gating

- **App Check** — callables assert App Check (`assertCallableAppCheck`).
- **Firestore rules** (`firestore.rules`) — 30+ helper functions incl.
  `isAdmin()` (custom‑claim **or** admin user‑doc), `isParticipant()`,
  per‑collection read/write gates, field‑level validation (`validRate`,
  `validCallAvailability`, protected‑field guards).
- **Admin enforcement is server‑side** — every admin callable calls
  `requireAdmin(context)`; `isCurrentUserAdmin()` on the client is a real server
  round‑trip (calls `adminGetDashboard_v1`), so the in‑app admin entry is genuinely
  gated, not cosmetic.
- **54 composite indexes** in `firestore.indexes.json`.

---

## 9. Tests (`test/`, 32 files, 136 tests)

Pure‑logic + widget coverage. Highlights:
`discover_ranking_test` (19) · `call_ready_resolver_test` (14) ·
`chat_direction_resolver_test` · `chat_unread_test` (10, incl. raw‑field invariant) ·
`relative_time_test` · `listener_availability_test` ·
`chat_navigation_guards_test` · `production_copy_test` (no placeholder copy ships) ·
wallet formatting/copy · onboarding layout · notification/push · legal links.

---

## 10. The UI redesign (this branch)

Converted a dark, Instagram‑like theme to a clean **light‑blue** design system
(`AppPalette`), then reshaped it to the finalized prototype: a **5‑tab shell**
**🏠 Home · 🧭 Explore · 📞 Talk · 💬 Chats · 👤 You**. Screens were restyled in
place — **money/call/chat logic was never touched**, only colours/layout.

Prototype‑aligned behaviour:
- **Home** — story circles (you + follows), followed‑only posts, Like + count +
  the person's `L{n} · Title` level beside the Like area (no comment/share).
- **Explore** — suggested‑people list rows with Follow/Following, follower count,
  match %, level, topic; chips **For you / Mutuals / Hindi / Rising**; tap → profile.
- **Talk** — call hub: Paid/Earned this week, online‑following (price + Call →
  call setup), call history (All/Paid/Earned). Nobody preselected.
- **Chats** — conversations + unread; thread with a Call action that opens call setup.
- **You** — profile + Posts/Followers/Following + level title + my posts;
  top‑right ⚙ opens the **Settings bottom sheet**.
- **Levels** — one shared `LevelUtils` (L1<100 … L5≥10k) with titles.

Known gaps (backend‑blocked / cosmetic, reported in the audits): a "Liked" tab
on You (no "posts I liked" query exists), and the profile opening as a full
screen rather than the prototype's modal.

---

## 11. Audit findings (this session)

### ✅ Fixed
- **Deploy‑breaker:** `functions/index.js` still exported the removed
  `cleanupExpiredStories_v1` as `undefined` — would break `firebase deploy`.
  Removed. (`238ce7a`)
- **Font never loaded:** theme declared `fontFamily: 'Poppins'` but no font was
  bundled → silent fallback to system font. Now loaded via `google_fonts`.
  (`1ba3f42`)
- **Orphaned Admin screen:** re‑wired a gated "Admin dashboard" row into the Me
  tab (admins only). (`e3198c4`)
- **Stale doc comment** on `RedesignShell` corrected. (`d4ad205`)

### ✅ Verified clean
- All **38 client `httpsCallable`** names resolve to exported functions.
- All **68 `index.js` imports** from `src/*` resolve to real exports.
- Shell wiring: entry point, 5 tabs, 8 nav targets, 8 Me‑menu rows, 36 callbacks,
  12 streams → 12 `StreamBuilder`s — all live.
- Firebase config present: `firebase.json`, `firestore.rules`,
  `firestore.indexes.json`, `firebase_options.dart`, `google-services.json`.

### ⏳ Open / dormant (by choice)
- **Analytics** + **Developer Diagnostics** screens remain unreachable (dormant).
  Same one‑block pattern re‑wires them (Analytics behind admin, Diagnostics behind
  `kDebugMode`) if wanted.
- **Poppins offline:** `google_fonts` fetches on first launch and caches. Drop the
  `.ttf` files into `assets/fonts/` + a pubspec `fonts:` block for fully offline /
  no first‑load flash.
- Vestigial `isStory` client code — harmless (feeds filter it; no path creates a story).
- Declared asset `assets/branding/friendify_icon_1024.png` exists but is unused in `lib/`.

---

## 12. Deployment & ship checklist

1. **Push code:** `git push origin main` (currently **75 commits unpushed**).
2. **Deploy backend:**
   ```bash
   firebase deploy --only functions,firestore:rules
   ```
   It will prompt to **delete `cleanupExpiredStories_v1`** — that's expected
   (stories were removed); confirm yes.
3. **Device pass:** verify the theme‑sweep bottom sheets render light (profile
   editor, new‑post composer, wallet top‑up/withdraw), Poppins is applied, and
   the admin row shows only for admins.

---

## 13. Convenience commands

```bash
flutter analyze lib test          # static analysis (currently clean)
flutter test                      # 136 tests
flutter build apk --debug         # Android build sanity check
node --check functions/index.js   # backend syntax check
```

---

_This document is a point‑in‑time audit/reference. Line counts and function lists
are generated from the source; regenerate after significant changes._
