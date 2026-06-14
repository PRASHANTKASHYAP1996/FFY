const admin = require("firebase-admin");
const functions = require("firebase-functions/v1");
const Razorpay = require("razorpay");
const crypto = require("crypto");

admin.initializeApp();

// OPTIONAL: Agora token support
let AgoraTokenBuilder, RtcRole;
try {
  ({ RtcTokenBuilder: AgoraTokenBuilder, RtcRole } = require("agora-access-token"));
} catch (_) {
  AgoraTokenBuilder = null;
  RtcRole = null;
}

// ---------- CONFIG ----------
const REGION = "us-central1";
// Cap concurrent instances per function as a runaway-cost safety net. v1 has no
// global default, so functions use the shared `regionalFunctions` builder below
// (or merge maxInstances into their own runWith for secret/heavier functions).
const MAX_INSTANCES = 40;
const regionalFunctions = functions
  .region(REGION)
  .runWith({ maxInstances: MAX_INSTANCES });
const PLATFORM_PERCENT = 20;

const RATE_OPTIONS = [5, 10, 20, 50, 100];
const RINGING_TIMEOUT_SECONDS = 45;
const BILLING_GRACE_SECONDS = 60;

const MAX_CALLS_PER_MINUTE = 3;
const MAX_CALLS_PER_HOUR = 12;

const CLEANUP_BATCH_LIMIT = 200;

const MIN_WITHDRAWAL_AMOUNT = 50;
const MAX_WITHDRAWAL_AMOUNT = 50000;

const MIN_TOPUP_AMOUNT = 10;
const MAX_TOPUP_AMOUNT = 200000;

// If caller hangs up after this many ms without the listener answering,
// treat it as a missed call for notification purposes.
const MISSED_CALL_MIN_RING_MS = 5000;

// Small buffer for timer-based automatic endings.
const PREPAID_END_GRACE_MS = 1500;

// ---------- HELPERS ----------
function intOr(val, fallback) {
  const n = Number(val);
  return Number.isFinite(n) ? Math.floor(n) : fallback;
}

function strOr(val, fallback = "") {
  return typeof val === "string" ? val : fallback;
}

function boolOr(val, fallback = false) {
  return typeof val === "boolean" ? val : fallback;
}

function adminActionCategory(actionType = "") {
  const safe = strOr(actionType).trim().toLowerCase();
  if (safe === "admin_dashboard_cache_refreshed") return "cache";
  if (safe.includes("withdrawal") || safe.includes("payout")) {
    return "finance";
  }
  if (safe.includes("report") || safe.includes("moderation")) {
    return "moderation";
  }
  if (safe.includes("account_deletion")) return "accountDeletion";
  if (safe.includes("user_blocked") || safe.includes("user_unblocked")) {
    return "userAccess";
  }
  return "other";
}

function shortLogId(value) {
  const safe = strOr(value).trim();
  if (!safe) return "";
  if (safe.length <= 12) return safe;
  return `${safe.slice(0, 6)}...${safe.slice(-4)}`;
}

function logKeyNeedsRedaction(normalizedKey) {
  return normalizedKey.includes("token") ||
    normalizedKey.includes("secret") ||
    normalizedKey.includes("signature") ||
    normalizedKey.includes("certificate") ||
    normalizedKey.includes("password") ||
    normalizedKey.includes("accountnumber");
}

function logKeyLooksLikeId(normalizedKey) {
  if (normalizedKey === "id" || normalizedKey === "uid") return true;
  if (normalizedKey === "valid") return false;
  return normalizedKey.includes("uid") ||
    normalizedKey.includes("userid") ||
    normalizedKey.includes("traceid") ||
    normalizedKey.includes("callid") ||
    normalizedKey.includes("sessionid") ||
    normalizedKey.includes("messageid") ||
    normalizedKey.includes("orderid") ||
    normalizedKey.includes("paymentid") ||
    normalizedKey.includes("requestid") ||
    normalizedKey.endsWith("id");
}

function safeLogFieldValue(normalizedKey, value) {
  if (typeof value === "string") {
    if (logKeyLooksLikeId(normalizedKey)) return shortLogId(value);
    return value.length > 160 ? `${value.slice(0, 157)}...` : value;
  }

  if (typeof value === "number" || typeof value === "boolean" || value === null) {
    return value;
  }

  return undefined;
}

function safeLogFields(fields = {}) {
  const out = {};
  Object.entries(fields || {}).forEach(([key, value]) => {
    const normalizedKey = strOr(key).toLowerCase();
    if (logKeyNeedsRedaction(normalizedKey)) {
      out[key] = "[redacted]";
      return;
    }

    const safeValue = safeLogFieldValue(normalizedKey, value);
    if (safeValue !== undefined) out[key] = safeValue;
  });
  return out;
}

function logEvent(eventName, fields = {}) {
  console.log(`[friendify] ${eventName}`, safeLogFields(fields));
}

function logError(eventName, error, fields = {}) {
  logEvent(eventName, {
    ...fields,
    errorCode: strOr(error && error.code),
    errorMessage: strOr(error && error.message, "unknown error"),
  });
}

async function deleteStoragePathIfSafe(
  rawPath,
  { allowedPrefixes = [] } = {}
) {
  const normalizedPath = strOr(rawPath)
    .trim()
    .replace(/^\/+/, "");
  if (!normalizedPath) {
    return { attempted: false, deleted: false, reason: "missing_path" };
  }
  if (normalizedPath.includes("..") || normalizedPath.includes("\\")) {
    return { attempted: false, deleted: false, reason: "unsafe_path" };
  }

  const prefixes = allowedPrefixes
    .map((prefix) => strOr(prefix).trim().replace(/^\/+/, ""))
    .filter(Boolean);
  if (
    prefixes.length > 0 &&
    !prefixes.some((prefix) => normalizedPath.startsWith(prefix))
  ) {
    return { attempted: false, deleted: false, reason: "prefix_mismatch" };
  }

  try {
    await admin.storage().bucket().file(normalizedPath).delete({
      ignoreNotFound: true,
    });
    return { attempted: true, deleted: true, path: normalizedPath };
  } catch (error) {
    logError("storage.delete_failed", error, { path: normalizedPath });
    return {
      attempted: true,
      deleted: false,
      path: normalizedPath,
      reason: "delete_failed",
    };
  }
}

async function deleteCollectionGroupDocsByField({
  collectionId,
  field,
  value,
  batchSize = 250,
}) {
  const safeCollectionId = strOr(collectionId).trim();
  const safeField = strOr(field).trim();
  const safeValue = strOr(value).trim();
  if (!safeCollectionId || !safeField || !safeValue) return 0;

  let deleted = 0;
  while (true) {
    const snap = await admin.firestore()
      .collectionGroup(safeCollectionId)
      .where(safeField, "==", safeValue)
      .limit(batchSize)
      .get();
    if (snap.empty) return deleted;

    const batch = admin.firestore().batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deleted += snap.size;
  }
}

async function reviewReportsForDeletedPost({
  postId,
  resolution = "post_deleted",
  reviewedBy = "system",
  note = "",
  batchSize = 250,
}) {
  const safePostId = strOr(postId).trim();
  if (!safePostId) return 0;

  const now = Date.now();
  const snap = await admin.firestore()
    .collection("reports")
    .where("postId", "==", safePostId)
    .limit(batchSize)
    .get();
  if (snap.empty) return 0;

  const closedStatuses = new Set(["reviewed", "resolved", "closed"]);
  const batch = admin.firestore().batch();
  let reviewed = 0;

  snap.docs.forEach((doc) => {
    const data = doc.data() || {};
    const status = strOr(data.status, "open").trim().toLowerCase();
    if (closedStatuses.has(status)) return;

    batch.update(doc.ref, {
      status: "reviewed",
      resolution: strOr(resolution, "post_deleted").trim() || "post_deleted",
      adminNote: strOr(note).trim(),
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
      reviewedAtMs: now,
      reviewedBy: strOr(reviewedBy, "system").trim() || "system",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: now,
    });
    reviewed += 1;
  });

  if (reviewed > 0) {
    await batch.commit();
  }
  return reviewed;
}

async function reviewReportsForDeletedComment({
  postId,
  commentId,
  resolution = "comment_deleted",
  reviewedBy = "system",
  note = "",
  batchSize = 250,
}) {
  const safePostId = strOr(postId).trim();
  const safeCommentId = strOr(commentId).trim();
  if (!safePostId || !safeCommentId) return 0;

  const now = Date.now();
  const snap = await admin.firestore()
    .collection("reports")
    .where("commentId", "==", safeCommentId)
    .limit(batchSize)
    .get();
  if (snap.empty) return 0;

  const closedStatuses = new Set(["reviewed", "resolved", "closed"]);
  const batch = admin.firestore().batch();
  let reviewed = 0;

  snap.docs.forEach((doc) => {
    const data = doc.data() || {};
    if (strOr(data.postId).trim() !== safePostId) return;

    const status = strOr(data.status, "open").trim().toLowerCase();
    if (closedStatuses.has(status)) return;

    batch.update(doc.ref, {
      status: "reviewed",
      resolution: strOr(resolution, "comment_deleted").trim() || "comment_deleted",
      adminNote: strOr(note).trim(),
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
      reviewedAtMs: now,
      reviewedBy: strOr(reviewedBy, "system").trim() || "system",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: now,
    });
    reviewed += 1;
  });

  if (reviewed > 0) {
    await batch.commit();
  }
  return reviewed;
}

const APP_CHECK_CALLABLE_MODE = (() => {
  const configured = strOr(process.env.APP_CHECK_ENFORCE_CALLABLES, "enforce")
    .trim()
    .toLowerCase();
  if (configured === "off" || configured === "monitor" || configured === "enforce") {
    return configured;
  }
  console.warn(
    `[appcheck] invalid APP_CHECK_ENFORCE_CALLABLES="${configured}", defaulting to "enforce"`
  );
  return "enforce";
})();

function appCheckEnforceEnabled() {
  return APP_CHECK_CALLABLE_MODE === "enforce";
}

function appCheckMonitorEnabled() {
  return APP_CHECK_CALLABLE_MODE === "monitor";
}

function assertCallableAppCheck(context, fnName) {
  const appId = strOr(context && context.app && context.app.appId).trim();
  if (appId) return;

  if (appCheckMonitorEnabled()) {
    const uid = strOr(context && context.auth && context.auth.uid).trim();
    console.log(
      `[appcheck-monitor] missing token on ${fnName} uid=${uid || "anonymous"}`
    );
    return;
  }

  if (appCheckEnforceEnabled()) {
    const uid = strOr(context && context.auth && context.auth.uid).trim();
    logEvent("callable.appcheck.missing", {
      fnName,
      authState: uid ? "authenticated" : "anonymous",
      uid: shortLogId(uid),
    });
    throw new functions.https.HttpsError(
      "failed-precondition",
      "app_check_failed",
      {
        reason: "app_check_failed",
        appCheckStatus: "failed",
      }
    );
  }
}

function stringArray(val) {
  if (!Array.isArray(val)) return [];
  return [
    ...new Set(
      val
        .filter((v) => typeof v === "string")
        .map((v) => v.trim())
        .filter(Boolean)
    ),
  ];
}

function payoutFromVisibleRate(visibleRate, platformPercent) {
  return Math.floor((visibleRate * (100 - platformPercent)) / 100);
}

function levelFromFollowers(followers) {
  if (followers >= 100000) return 5;
  if (followers >= 10000) return 4;
  if (followers >= 1000) return 3;
  if (followers >= 100) return 2;
  return 1;
}

function maxVisibleRateForLevel(level) {
  switch (level) {
    case 5:
      return 100;
    case 4:
      return 50;
    case 3:
      return 20;
    case 2:
      return 10;
    default:
      return 5;
  }
}

function sanitizeListenerRateForFollowers(rate, followers) {
  const safeRate = RATE_OPTIONS.includes(rate) ? rate : 5;
  const level = levelFromFollowers(followers);
  const maxRate = maxVisibleRateForLevel(level);
  return safeRate <= maxRate ? safeRate : maxRate;
}

function minuteKey(nowMs) {
  const d = new Date(nowMs);
  const yyyy = String(d.getUTCFullYear());
  const mm = String(d.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(d.getUTCDate()).padStart(2, "0");
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mi = String(d.getUTCMinutes()).padStart(2, "0");
  return `${yyyy}${mm}${dd}_${hh}${mi}`;
}

function hourKey(nowMs) {
  const d = new Date(nowMs);
  const yyyy = String(d.getUTCFullYear());
  const mm = String(d.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(d.getUTCDate()).padStart(2, "0");
  const hh = String(d.getUTCHours()).padStart(2, "0");
  return `${yyyy}${mm}${dd}_${hh}`;
}

function getAgoraConfig() {
  const envAppId = strOr(process.env.AGORA_APP_ID);
  const envAppCertificate = strOr(process.env.AGORA_APP_CERTIFICATE);

  return { appId: envAppId, appCertificate: envAppCertificate };
}

function isPlaceholderSecret(value) {
  const raw = strOr(value).trim();
  if (!raw) return false;

  const lower = raw.toLowerCase();
  return (
    raw.includes("<") ||
    raw.includes(">") ||
    lower.includes("your-") ||
    lower.includes("your_") ||
    lower.includes("todo") ||
    lower.includes("replace_me") ||
    lower.includes("placeholder")
  );
}

function evaluateAgoraTokenConfig({
  appId,
  appCertificate,
  tokenBuilderAvailable = Boolean(AgoraTokenBuilder && RtcRole),
} = {}) {
  const safeAppId =
    appId === undefined ? strOr(process.env.AGORA_APP_ID) : strOr(appId);
  const safeAppCertificate =
    appCertificate === undefined
      ? strOr(process.env.AGORA_APP_CERTIFICATE)
      : strOr(appCertificate);

  const missingRequirements = [];
  if (!tokenBuilderAvailable) {
    missingRequirements.push("agora-access-token package");
  }
  if (!safeAppId) {
    missingRequirements.push("AGORA_APP_ID");
  }
  if (!safeAppCertificate) {
    missingRequirements.push("AGORA_APP_CERTIFICATE");
  }
  if (safeAppId && isPlaceholderSecret(safeAppId)) {
    missingRequirements.push("AGORA_APP_ID_PLACEHOLDER");
  }
  if (safeAppCertificate && isPlaceholderSecret(safeAppCertificate)) {
    missingRequirements.push("AGORA_APP_CERTIFICATE_PLACEHOLDER");
  }

  return {
    appId: safeAppId,
    appCertificate: safeAppCertificate,
    tokenBuilderAvailable,
    missingRequirements,
    isReady: missingRequirements.length === 0,
  };
}

function assertAgoraTokenConfigReady(overrides = {}) {
  const readiness = evaluateAgoraTokenConfig(overrides);
  if (readiness.isReady) {
    return readiness;
  }

  throw new functions.https.HttpsError(
    "failed-precondition",
    "server_config_missing",
    {
      reason: "server_config_missing",
      missingRequirements: readiness.missingRequirements,
    }
  );
}

function getRazorpayConfig() {
  const envKeyId = strOr(process.env.RAZORPAY_KEY_ID);
  const envKeySecret = strOr(process.env.RAZORPAY_KEY_SECRET);

  return { keyId: envKeyId, keySecret: envKeySecret };
}

function getRazorpayClient() {
  const { keyId, keySecret } = getRazorpayConfig();

  if (!keyId || !keySecret) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay keys are not configured on the server."
    );
  }

  return new Razorpay({
    key_id: keyId,
    key_secret: keySecret,
  });
}

function buildAgoraTokenIfPossible({ channelId, uidInt, expireSeconds = 3600 }) {
  if (!AgoraTokenBuilder || !RtcRole) return "";

  const { appId, appCertificate } = getAgoraConfig();
  if (!appId || !appCertificate) return "";

  const now = Math.floor(Date.now() / 1000);
  const expireTs = now + expireSeconds;

  return AgoraTokenBuilder.buildTokenWithUid(
    appId,
    appCertificate,
    channelId,
    uidInt,
    RtcRole.PUBLISHER,
    expireTs
  );
}

function buildAgoraTokenOrThrow({ channelId, uidInt, expireSeconds = 3600 }) {
  const { appId, appCertificate } = assertAgoraTokenConfigReady();
  const now = Math.floor(Date.now() / 1000);
  const expireTs = now + expireSeconds;

  return AgoraTokenBuilder.buildTokenWithUid(
    appId,
    appCertificate,
    strOr(channelId),
    intOr(uidInt, 0),
    RtcRole.PUBLISHER,
    expireTs
  );
}

function timestampToMs(ts) {
  if (ts && typeof ts.toDate === "function") {
    return ts.toDate().getTime();
  }
  return 0;
}

function computeFinalSeconds(callData) {
  const explicitEndedSeconds = intOr(callData.endedSeconds, -1);
  if (explicitEndedSeconds >= 0) {
    return explicitEndedSeconds;
  }

  const startedAtMs =
    intOr(callData.billableStartedAtMs, 0) ||
    intOr(callData.bothJoinedAtMs, 0) ||
    timestampToMs(callData.billableStartedAt) ||
    timestampToMs(callData.bothJoinedAt) ||
    intOr(callData.startedAtMs, 0) ||
    timestampToMs(callData.startedAt);
  const endedAtMs = timestampToMs(callData.endedAt);

  if (startedAtMs > 0 && endedAtMs > 0 && endedAtMs >= startedAtMs) {
    return Math.max(0, Math.floor((endedAtMs - startedAtMs) / 1000));
  }

  if (startedAtMs > 0) {
    return Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
  }

  return 0;
}

// Server-authoritative billable duration used for settlement.
// Deliberately ignores the client-reported `endedSeconds` (which a caller can
// under-report to dodge charges, and which the prepaid-window cleanup cron
// writes as 0) and derives talk time purely from server-set timestamps:
//   billableStartedAtMs (set when both parties join) -> endedAtMs (set at end).
// Returns 0 when the call never became billable (e.g. one party never joined),
// which correctly results in no charge and no payout.
function serverBillableSeconds(callData = {}) {
  const billableStartedAtMs =
    intOr(callData.billableStartedAtMs, 0) ||
    intOr(callData.bothJoinedAtMs, 0) ||
    timestampToMs(callData.billableStartedAt) ||
    timestampToMs(callData.bothJoinedAt) ||
    intOr(callData.startedAtMs, 0) ||
    timestampToMs(callData.startedAt);
  if (billableStartedAtMs <= 0) return 0;

  const endedAtMs = callEndedAtMs(callData) || Date.now();
  if (endedAtMs <= billableStartedAtMs) return 0;

  return Math.floor((endedAtMs - billableStartedAtMs) / 1000);
}

function isFinalStatus(status) {
  return status === "ended" || status === "rejected";
}

function isLiveStatus(status) {
  return status === "ringing" || status === "accepted";
}

function isMissedReason(reason) {
  return [
    "server_timeout",
    "timeout",
    "callee_timeout",
    "ring_timeout",
  ].includes(strOr(reason).trim());
}

function normalizedRejectedEndedReason(reason) {
  const safeReason = strOr(reason, "rejected").trim() || "rejected";
  return isMissedReason(safeReason) ? "missed" : safeReason;
}

function callCreatedAtMs(callData) {
  const createdAtMs = intOr(callData.createdAtMs, 0);
  if (createdAtMs > 0) return createdAtMs;
  return timestampToMs(callData.createdAt);
}

function callEndedAtMs(callData) {
  const endedAtMs = intOr(callData.endedAtMs, 0);
  if (endedAtMs > 0) return endedAtMs;
  return timestampToMs(callData.endedAt);
}

function ringDurationMs(callData) {
  const createdAtMs = callCreatedAtMs(callData);
  if (createdAtMs <= 0) return 0;

  const endedAtMs = callEndedAtMs(callData);
  if (endedAtMs > createdAtMs) {
    return endedAtMs - createdAtMs;
  }

  return Math.max(0, Date.now() - createdAtMs);
}

function shouldSendMissedCall(before, after) {
  const beforeData = before || {};
  const afterData = after || {};

  const oldStatus = strOr(beforeData.status);
  const newStatus = strOr(afterData.status);

  if (oldStatus !== "ringing") return false;

  if (
    newStatus === "rejected" &&
    isMissedReason(strOr(afterData.rejectedReason))
  ) {
    return true;
  }

  if (newStatus === "ended") {
    const startedAtMs = timestampToMs(afterData.startedAt);
    if (startedAtMs > 0) return false;

    const endedBy = strOr(afterData.endedBy);
    const callerId = strOr(afterData.callerId);
    const ringMs = ringDurationMs(afterData);

    if (
      endedBy &&
      callerId &&
      endedBy === callerId &&
      ringMs >= MISSED_CALL_MIN_RING_MS
    ) {
      return true;
    }
  }

  return false;
}

function walletTxRef(db, txId) {
  return db.collection("wallet_transactions").doc(txId);
}

function buildCallChargeTxId(callId, userId) {
  return `${callId}_charge_${userId}`;
}

function buildCallEarningTxId(callId, userId) {
  return `${callId}_earning_${userId}`;
}

function buildTopupTxId(orderId) {
  return `${orderId}_topup`;
}

function safeCurrency(currency) {
  const raw = strOr(currency, "INR").trim().toUpperCase();
  return raw || "INR";
}

function paymentOrderRef(db, orderId) {
  return db.collection("payment_orders").doc(orderId);
}

function createWalletTxDoc({
  userId,
  type,
  amount,
  balanceAfter,
  callId = "",
  status = "completed",
  method = "system",
  notes = "",
  source = "system",
  currency = "INR",
  direction = "",
  paymentOrderId = "",
  paymentId = "",
  withdrawalRequestId = "",
  gateway = "",
  idempotencyKey = "",
  metadata = {},
}) {
  let safeDirection = strOr(direction).trim().toLowerCase();
  if (safeDirection !== "credit" && safeDirection !== "debit") {
    safeDirection = amount >= 0 ? "credit" : "debit";
  }

  const doc = {
    userId: strOr(userId),
    type: strOr(type),
    amount: intOr(amount, 0),
    balanceAfter: intOr(balanceAfter, 0),
    status: strOr(status, "completed"),
    method: strOr(method, "system"),
    notes: strOr(notes),
    source: strOr(source, "system"),
    currency: safeCurrency(currency),
    direction: safeDirection,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    metadata: metadata && typeof metadata === "object" ? metadata : {},
  };

  if (callId) doc.callId = strOr(callId);
  if (paymentOrderId) doc.paymentOrderId = strOr(paymentOrderId);
  if (paymentId) doc.paymentId = strOr(paymentId);
  if (withdrawalRequestId) doc.withdrawalRequestId = strOr(withdrawalRequestId);
  if (gateway) doc.gateway = strOr(gateway);
  if (idempotencyKey) doc.idempotencyKey = strOr(idempotencyKey);

  return doc;
}

function createPaymentOrderDoc({
  userId,
  amount,
  currency = "INR",
  gateway = "sandbox",
  gatewayOrderId = "",
  status = "created",
  idempotencyKey = "",
  metadata = {},
}) {
  return {
    userId: strOr(userId),
    gateway: strOr(gateway, "sandbox"),
    orderId: strOr(gatewayOrderId),
    paymentId: "",
    amount: intOr(amount, 0),
    currency: safeCurrency(currency),
    status: strOr(status, "created"),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    verifiedAt: null,
    failureReason: "",
    idempotencyKey: strOr(idempotencyKey),
    metadata: metadata && typeof metadata === "object" ? metadata : {},
  };
}

async function acquireExecutionLock({
  db,
  lockId,
  lockType = "execution",
  resourceId = "",
  owner = "server",
  ttlMs = 30000,
}) {
  const safeLockId = strOr(lockId).trim();
  if (!safeLockId) return false;

  const lockRef = db.collection("wallet_locks").doc(safeLockId);
  const nowMs = Date.now();
  const expiresAt = nowMs + Math.max(1000, intOr(ttlMs, 30000));

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(lockRef);

    if (snap.exists) {
      const data = snap.data() || {};
      const existingExpiresAt = intOr(data.expiresAt, 0);

      if (existingExpiresAt > nowMs) {
        return false;
      }
    }

    tx.set(lockRef, {
      lockType: strOr(lockType, "execution"),
      resourceId: strOr(resourceId || safeLockId, safeLockId),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt,
      owner: strOr(owner, "server"),
    });

    return true;
  });
}

async function safeReleaseReserveAndLockTx(tx, { db, callRef, callData }) {
  if (callNeedsSettlementCleanup(callData)) {
    return;
  }

  const callerId = strOr(callData.callerId);
  const calleeId = strOr(callData.calleeId);
  const reservedUpfront = intOr(callData.reservedUpfront, 0);

  const users = db.collection("users");
  const callerRef = callerId ? users.doc(callerId) : null;
  const calleeRef = calleeId ? users.doc(calleeId) : null;

  const refs = [];
  if (callerRef) refs.push(callerRef);
  if (calleeRef && (!callerRef || calleeRef.path !== callerRef.path)) refs.push(calleeRef);

  const snaps = refs.length > 0 ? await tx.getAll(...refs) : [];
  const snapMap = {};
  for (let i = 0; i < refs.length; i++) {
    snapMap[refs[i].path] = snaps[i];
  }

  const callerSnap = callerRef ? snapMap[callerRef.path] : null;
  const calleeSnap = calleeRef ? snapMap[calleeRef.path] : null;

  const caller = callerSnap && callerSnap.exists ? callerSnap.data() || {} : {};
  const callee = calleeSnap && calleeSnap.exists ? calleeSnap.data() || {} : {};

  if (callerRef && reservedUpfront > 0 && callData.reserveReleased !== true) {
    const reserved = intOr(caller.reservedCredits, 0);
    const newReserved = Math.max(0, reserved - reservedUpfront);

    tx.update(callerRef, {
      reservedCredits: newReserved,
    });

    tx.update(callRef, {
      reserveReleased: true,
      reserveReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  if (callerRef) {
    const callerActiveCallId = strOr(caller.activeCallId);
    if (callerActiveCallId === callRef.id) {
      tx.update(callerRef, {
        activeCallId: "",
        isOnCall: false,
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  if (calleeRef) {
    const calleeActiveCallId = strOr(callee.activeCallId);
    if (calleeActiveCallId === callRef.id) {
      tx.update(calleeRef, {
        activeCallId: "",
        isOnCall: false,
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
}

function callNeedsSettlementCleanup(callData = {}) {
  return strOr(callData.status) === "ended" && boolOr(callData.settled, false) !== true;
}

function callShouldHoldReserve(callData = {}) {
  const reservedUpfront = intOr(callData.reservedUpfront, 0);
  if (reservedUpfront <= 0 || boolOr(callData.reserveReleased, false)) {
    return false;
  }

  const status = strOr(callData.status);
  return status === "ringing" || status === "accepted" || callNeedsSettlementCleanup(callData);
}

function callShouldKeepBusyLock(callData = {}) {
  return isLiveStatus(strOr(callData.status)) || callNeedsSettlementCleanup(callData);
}

async function endCallAsRejectedIfStillRinging({ db, callRef, reason, endedBy = "system" }) {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(callRef);
    if (!snap.exists) return;

    const callNow = snap.data() || {};
    const statusNow = strOr(callNow.status);

    if (statusNow !== "ringing") return;

    const rawReason = strOr(reason, "rejected").trim() || "rejected";
    const endedReason = normalizedRejectedEndedReason(rawReason);

    tx.update(callRef, {
      status: "rejected",
      endedAt: admin.firestore.FieldValue.serverTimestamp(),
      endedAtMs: Date.now(),
      rejectedReason: rawReason,
      endedReason,
      endReasonCode: rawReason,
      missedBy: endedReason === "missed" ? strOr(callNow.calleeId) : "",
      endedBy,
      endedSeconds: 0,
    });

    await safeReleaseReserveAndLockTx(tx, { db, callRef, callData: callNow });
  });
}

async function applyFollowerDelta(db, targetUserId, delta) {
  if (!targetUserId || !delta) return;

  const userRef = db.collection("users").doc(targetUserId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    if (!snap.exists) return;

    const user = snap.data() || {};
    const oldFollowers = intOr(user.followersCount, 0);
    const newFollowers = Math.max(0, oldFollowers + delta);
    const newLevel = levelFromFollowers(newFollowers);
    const oldRate = intOr(user.listenerRate, 5);
    const newRate = sanitizeListenerRateForFollowers(oldRate, newFollowers);

    tx.update(userRef, {
      followersCount: newFollowers,
      level: newLevel,
      listenerRate: newRate,
      lastSeen: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;
const Timestamp = admin.firestore.Timestamp;

module.exports = {
  admin,
  functions,
  Razorpay,
  crypto,
  db,
  FieldValue,
  Timestamp,
  REGION,
  MAX_INSTANCES,
  regionalFunctions,
  PLATFORM_PERCENT,
  RATE_OPTIONS,
  RINGING_TIMEOUT_SECONDS,
  BILLING_GRACE_SECONDS,
  MAX_CALLS_PER_MINUTE,
  MAX_CALLS_PER_HOUR,
  CLEANUP_BATCH_LIMIT,
  MIN_WITHDRAWAL_AMOUNT,
  MAX_WITHDRAWAL_AMOUNT,
  MIN_TOPUP_AMOUNT,
  MAX_TOPUP_AMOUNT,
  MISSED_CALL_MIN_RING_MS,
  PREPAID_END_GRACE_MS,
  intOr,
  strOr,
  boolOr,
  adminActionCategory,
  shortLogId,
  safeLogFields,
  logEvent,
  logError,
  deleteStoragePathIfSafe,
  deleteCollectionGroupDocsByField,
  reviewReportsForDeletedPost,
  reviewReportsForDeletedComment,
  assertCallableAppCheck,
  stringArray,
  payoutFromVisibleRate,
  levelFromFollowers,
  maxVisibleRateForLevel,
  sanitizeListenerRateForFollowers,
  minuteKey,
  hourKey,
  getAgoraConfig,
  evaluateAgoraTokenConfig,
  assertAgoraTokenConfigReady,
  getRazorpayConfig,
  getRazorpayClient,
  buildAgoraTokenIfPossible,
  buildAgoraTokenOrThrow,
  isPlaceholderSecret,
  timestampToMs,
  computeFinalSeconds,
  serverBillableSeconds,
  isFinalStatus,
  isLiveStatus,
  isMissedReason,
  normalizedRejectedEndedReason,
  callCreatedAtMs,
  callEndedAtMs,
  ringDurationMs,
  shouldSendMissedCall,
  walletTxRef,
  buildCallChargeTxId,
  buildCallEarningTxId,
  buildTopupTxId,
  safeCurrency,
  paymentOrderRef,
  createWalletTxDoc,
  createPaymentOrderDoc,
  acquireExecutionLock,
  callNeedsSettlementCleanup,
  callShouldHoldReserve,
  callShouldKeepBusyLock,
  safeReleaseReserveAndLockTx,
  endCallAsRejectedIfStillRinging,
  applyFollowerDelta,
};
