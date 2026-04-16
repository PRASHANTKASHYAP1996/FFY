const admin = require("firebase-admin");
const functions = require("firebase-functions");
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
const PLATFORM_PERCENT = 20;

const RATE_OPTIONS = [5, 10, 20, 50, 100];
const RINGING_TIMEOUT_SECONDS = 45;

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

  if (envAppId && envAppCertificate) {
    return { appId: envAppId, appCertificate: envAppCertificate };
  }

  const cfg = (functions.config && functions.config()) || {};
  const appId = cfg.agora && cfg.agora.app_id ? String(cfg.agora.app_id) : "";
  const appCertificate =
    cfg.agora && cfg.agora.app_certificate ? String(cfg.agora.app_certificate) : "";

  return { appId, appCertificate };
}

function getRazorpayConfig() {
  const envKeyId = strOr(process.env.RAZORPAY_KEY_ID);
  const envKeySecret = strOr(process.env.RAZORPAY_KEY_SECRET);

  if (envKeyId && envKeySecret) {
    return { keyId: envKeyId, keySecret: envKeySecret };
  }

  const cfg = (functions.config && functions.config()) || {};
  const keyId = cfg.razorpay && cfg.razorpay.key_id ? String(cfg.razorpay.key_id) : "";
  const keySecret =
    cfg.razorpay && cfg.razorpay.key_secret ? String(cfg.razorpay.key_secret) : "";

  return { keyId, keySecret };
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

function timestampToMs(ts) {
  if (ts && typeof ts.toDate === "function") {
    return ts.toDate().getTime();
  }
  return 0;
}

function computeFinalSeconds(callData) {
  const startedAtMs = timestampToMs(callData.startedAt);
  const endedAtMs = timestampToMs(callData.endedAt);

  if (startedAtMs > 0 && endedAtMs > 0 && endedAtMs >= startedAtMs) {
    return Math.max(0, Math.floor((endedAtMs - startedAtMs) / 1000));
  }

  const explicitEndedSeconds = intOr(callData.endedSeconds, -1);
  if (explicitEndedSeconds >= 0) {
    return explicitEndedSeconds;
  }

  if (startedAtMs > 0) {
    return Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
  }

  return 0;
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
  ].includes(strOr(reason));
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
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  if (calleeRef) {
    const calleeActiveCallId = strOr(callee.activeCallId);
    if (calleeActiveCallId === callRef.id) {
      tx.update(calleeRef, {
        activeCallId: "",
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
}

async function endCallAsRejectedIfStillRinging({ db, callRef, reason, endedBy = "system" }) {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(callRef);
    if (!snap.exists) return;

    const callNow = snap.data() || {};
    const statusNow = strOr(callNow.status);

    if (statusNow !== "ringing") return;

    tx.update(callRef, {
      status: "rejected",
      endedAt: admin.firestore.FieldValue.serverTimestamp(),
      endedAtMs: Date.now(),
      rejectedReason: reason,
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
  PLATFORM_PERCENT,
  RATE_OPTIONS,
  RINGING_TIMEOUT_SECONDS,
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
  stringArray,
  payoutFromVisibleRate,
  levelFromFollowers,
  maxVisibleRateForLevel,
  sanitizeListenerRateForFollowers,
  minuteKey,
  hourKey,
  getAgoraConfig,
  getRazorpayConfig,
  getRazorpayClient,
  buildAgoraTokenIfPossible,
  timestampToMs,
  computeFinalSeconds,
  isFinalStatus,
  isLiveStatus,
  isMissedReason,
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
  safeReleaseReserveAndLockTx,
  endCallAsRejectedIfStillRinging,
  applyFollowerDelta,
};