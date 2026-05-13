const crypto = require("crypto");

const {
  admin,
  functions,
  REGION,
  PLATFORM_PERCENT,
  RINGING_TIMEOUT_SECONDS,
  BILLING_GRACE_SECONDS,
  MAX_CALLS_PER_MINUTE,
  MAX_CALLS_PER_HOUR,
  CLEANUP_BATCH_LIMIT,
  PREPAID_END_GRACE_MS,
  intOr,
  strOr,
  boolOr,
  assertCallableAppCheck,
  payoutFromVisibleRate,
  sanitizeListenerRateForFollowers,
  minuteKey,
  hourKey,
  assertAgoraTokenConfigReady,
  buildAgoraTokenOrThrow,
  timestampToMs,
  computeFinalSeconds,
  isFinalStatus,
  isLiveStatus,
  walletTxRef,
  buildCallChargeTxId,
  buildCallEarningTxId,
  acquireExecutionLock,
  createWalletTxDoc,
  callNeedsSettlementCleanup,
  callShouldHoldReserve,
  callShouldKeepBusyLock,
  safeReleaseReserveAndLockTx,
  endCallAsRejectedIfStillRinging,
  normalizedRejectedEndedReason,
  shortLogId,
  logEvent,
  logError,
} = require("./shared");

const CLEANUP_MAX_BATCH_COUNT = 5;
const CLEANUP_LEGACY_SCAN_MAX_BATCH_COUNT = 2;

function stableAgoraUidFromSeed(seed) {
  const raw = strOr(seed).trim();
  if (!raw) {
    throw new functions.https.HttpsError(
      "internal",
      "Cannot generate Agora uid for empty seed"
    );
  }

  let hash = 0;
  for (let i = 0; i < raw.length; i++) {
    hash = (hash * 31 + raw.charCodeAt(i)) >>> 0;
  }

  const uid = (hash % 2147483646) + 1;
  return uid;
}

function buildDistinctAgoraUids({ callerId, listenerId, channelId }) {
  const callerUid = stableAgoraUidFromSeed(`caller:${callerId}:${channelId}`);
  let listenerUid = stableAgoraUidFromSeed(
    `listener:${listenerId}:${channelId}`
  );

  if (listenerUid === callerUid) {
    listenerUid = stableAgoraUidFromSeed(
      `listener:${listenerId}:${channelId}:fallback`
    );
  }

  if (listenerUid === callerUid) {
    throw new functions.https.HttpsError(
      "internal",
      "Failed to generate distinct Agora uids"
    );
  }

  return {
    callerAgoraUid: callerUid,
    calleeAgoraUid: listenerUid,
  };
}

function generateAgoraChannelId() {
  return crypto.randomBytes(16).toString("hex");
}

exports._generateAgoraChannelId = generateAgoraChannelId;

function clientTraceFields(data = {}) {
  return {
    clientTraceId: strOr(data && data.clientTraceId).trim(),
    clientRunTraceId: strOr(data && data.clientRunTraceId).trim(),
    clientTraceSeq: intOr(data && data.clientTraceSeq, 0),
    clientDeviceEpochUs: intOr(data && data.clientDeviceEpochUs, 0),
    clientMonoUs: intOr(data && data.clientMonoUs, 0),
  };
}

function logFunctionTrace(functionName, phase, data = {}, fields = {}) {
  logEvent("FUNCTION_TRACE", {
    functionName,
    phase,
    serverEpochMs: Date.now(),
    ...clientTraceFields(data),
    ...fields,
  });
}

function timingNowMs() {
  return Date.now();
}

function elapsedSinceMs(startMs) {
  return Math.max(0, Date.now() - intOr(startMs, Date.now()));
}

function logCallTiming(functionName, phase, startMs, fields = {}) {
  logEvent("CALL_TIMING", {
    functionName,
    phase,
    elapsedMs: elapsedSinceMs(startMs),
    ...fields,
  });
}

function shouldRunLiveCallFallbackScan(user = {}) {
  return !strOr(user.activeCallId).trim() && boolOr(user.isOnCall, false) === true;
}

async function clearParticipantBusyLocksTx(tx, {
  db,
  callId,
  callerId,
  calleeId,
}) {
  const safeCallId = strOr(callId).trim();
  const safeCallerId = strOr(callerId).trim();
  const safeCalleeId = strOr(calleeId).trim();
  if (!safeCallId) return;

  const users = db.collection("users");
  const refs = [];
  if (safeCallerId) refs.push(users.doc(safeCallerId));
  if (safeCalleeId && safeCalleeId !== safeCallerId) {
    refs.push(users.doc(safeCalleeId));
  }
  if (refs.length === 0) return;

  const snaps = await tx.getAll(...refs);
  for (let i = 0; i < refs.length; i++) {
    const snap = snaps[i];
    if (!snap || !snap.exists) continue;
    const user = snap.data() || {};
    if (strOr(user.activeCallId).trim() !== safeCallId) continue;

    tx.update(refs[i], {
      activeCallId: "",
      isOnCall: false,
      activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      lastSeen: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
}

function sanitizeErrorMessageForLog(value) {
  return strOr(value, "unknown")
    .replace(/agoraToken\s*[:=]\s*\S+/gi, "agoraToken=[redacted]")
    .replace(/fcmToken\s*[:=]\s*\S+/gi, "fcmToken=[redacted]")
    .replace(/certificate\s*[:=]\s*\S+/gi, "certificate=[redacted]")
    .slice(0, 240);
}

function buildParticipantTokenDoc({
  userId,
  channelId,
  agoraUid,
  agoraToken,
  nowMs,
}) {
  return {
    userId: strOr(userId).trim(),
    channelId: strOr(channelId).trim(),
    agoraUid: intOr(agoraUid, 0),
    agoraToken: strOr(agoraToken).trim(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: intOr(nowMs, Date.now()),
    expiresAtMs: intOr(nowMs, Date.now()) + 3600 * 1000,
  };
}

exports._buildParticipantTokenDoc = buildParticipantTokenDoc;

function chatDocIdForPair({ speakerId, listenerId }) {
  const a = strOr(speakerId).trim();
  const b = strOr(listenerId).trim();
  if (!a || !b || a === b) return "";
  const ids = [a, b].sort();
  return `${ids[0]}_${ids[1]}`;
}

function onlyChatModeEnabled(user = {}) {
  const callAvailability =
    user.callAvailability && typeof user.callAvailability === "object"
      ? user.callAvailability
      : {};
  return boolOr(
    callAvailability.onlyChatMode,
    boolOr(user.onlyChatMode, false)
  );
}

function callHttpsError(code, reason, message = reason, details = {}) {
  return new functions.https.HttpsError(code, message, {
    reason,
    ...details,
  });
}

function startCallPrecondition(reason, message = reason, details = {}) {
  return callHttpsError("failed-precondition", reason, message, details);
}

function startCallEligibilityError({ caller = {}, listener = {} }) {
  if (
    caller.deleted === true ||
    caller.disabled === true ||
    caller.adminDeleted === true
  ) {
    return {
      code: "permission-denied",
      reason: "unknown_precondition",
      message: "Your account is not eligible to place calls",
    };
  }

  if (onlyChatModeEnabled(caller)) {
    return {
      code: "failed-precondition",
      reason: "self_only_chat_mode",
      message: "self_only_chat_mode",
    };
  }

  if (onlyChatModeEnabled(listener)) {
    return {
      code: "failed-precondition",
      reason: "peer_only_chat_mode",
      message: "peer_only_chat_mode",
    };
  }

  if (
    listener.deleted === true ||
    listener.disabled === true ||
    listener.adminDeleted === true ||
    listener.adminBlocked === true
  ) {
    return {
      code: "failed-precondition",
      reason: "peer_busy",
      message: "Listener not available",
    };
  }

  if (boolOr(listener.isListener, false) !== true) {
    return {
      code: "failed-precondition",
      reason: "peer_busy",
      message: "Selected user is not available for listener calls",
    };
  }

  if (boolOr(listener.isAvailable, false) !== true) {
    return {
      code: "failed-precondition",
      reason: "peer_busy",
      message: "Listener is offline right now",
    };
  }

  return null;
}

exports._startCallEligibilityError = startCallEligibilityError;

function availableCreditsForCalls(user = {}) {
  const credits = Math.max(0, intOr(user.credits, 0));
  const reservedCredits = Math.max(0, intOr(user.reservedCredits, 0));
  const pendingWithdrawalCredits = Math.max(
    0,
    intOr(user.pendingWithdrawalCredits, 0)
  );
  return Math.max(0, credits - reservedCredits - pendingWithdrawalCredits);
}

exports._availableCreditsForCalls = availableCreditsForCalls;
function computeSettlementAmounts({
  billedMinutes,
  speakerRate,
  listenerRate,
  currentCredits,
  currentReservedCredits,
  reservedUpfront,
  reserveAlreadyReleased,
}) {
  const safeBilledMinutes = Math.max(0, intOr(billedMinutes, 0));
  const safeSpeakerRate = Math.max(0, intOr(speakerRate, 0));
  const safeListenerRate = Math.max(0, intOr(listenerRate, 0));
  const safeCredits = Math.max(0, intOr(currentCredits, 0));
  const safeReservedCredits = Math.max(0, intOr(currentReservedCredits, 0));
  const safeReservedUpfront = Math.max(0, intOr(reservedUpfront, 0));

  const speakerCharge = safeBilledMinutes * safeSpeakerRate;
  const listenerPayout = safeBilledMinutes * safeListenerRate;
  const safeSpeakerCharge = Math.min(speakerCharge, safeCredits);
  const safePaidMinutes =
    safeSpeakerRate > 0
      ? Math.min(safeBilledMinutes, Math.floor(safeSpeakerCharge / safeSpeakerRate))
      : 0;
  const safeListenerPayout = Math.min(
    safePaidMinutes * safeListenerRate,
    safeSpeakerCharge
  );
  const safePlatformProfit = Math.max(0, safeSpeakerCharge - safeListenerPayout);
  const shouldReleaseReserve =
    safeReservedUpfront > 0 && reserveAlreadyReleased !== true;
  const newReserved = shouldReleaseReserve
    ? Math.max(0, safeReservedCredits - safeReservedUpfront)
    : safeReservedCredits;
  const newCredits = Math.max(0, safeCredits - safeSpeakerCharge);

  return {
    speakerCharge,
    listenerPayout,
    safeSpeakerCharge,
    safeListenerPayout,
    safePlatformProfit,
    safePaidMinutes,
    shouldReleaseReserve,
    newReserved,
    newCredits,
  };
}

exports._computeSettlementAmounts = computeSettlementAmounts;

function isMalformedRingingCleanupCandidate(callData = {}) {
  if (strOr(callData.status) !== "ringing") return false;
  return !strOr(callData.callerId) ||
    !strOr(callData.calleeId) ||
    !strOr(callData.channelId);
}

function isExpiredRingingCleanupCandidate(callData = {}, nowMs) {
  if (strOr(callData.status) !== "ringing") return false;
  const expiresAtMs = intOr(callData.expiresAtMs, 0);
  return expiresAtMs > 0 && expiresAtMs <= Math.max(0, intOr(nowMs, 0));
}

function deriveAcceptedPrepaidEndsAtMs(callData = {}) {
  const explicitPrepaidEndsAtMs = intOr(callData.prepaidEndsAtMs, 0);
  if (explicitPrepaidEndsAtMs > 0) return explicitPrepaidEndsAtMs;

  const startedAtMs =
    intOr(callData.billableStartedAtMs, 0) ||
    intOr(callData.bothJoinedAtMs, 0) ||
    timestampToMs(callData.billableStartedAt) ||
    timestampToMs(callData.bothJoinedAt) ||
    intOr(callData.startedAtMs, 0) || timestampToMs(callData.startedAt);
  const maxPrepaidMinutes = intOr(callData.maxPrepaidMinutes, 0);
  if (startedAtMs <= 0 || maxPrepaidMinutes <= 0) return 0;

  return startedAtMs + maxPrepaidMinutes * 60 * 1000;
}

function isAcceptedCreditLimitCleanupCandidate(callData = {}, nowMs) {
  if (strOr(callData.status) !== "accepted") return false;

  const prepaidEndsAtMs = deriveAcceptedPrepaidEndsAtMs(callData);
  if (prepaidEndsAtMs <= 0) return false;

  return Math.max(0, intOr(nowMs, 0)) >= prepaidEndsAtMs + PREPAID_END_GRACE_MS;
}

function isAcceptedStaleCleanupCandidate(callData = {}, staleBeforeMs) {
  if (strOr(callData.status) !== "accepted") return false;

  const acceptedAtMs =
    intOr(callData.acceptedAtMs, 0) ||
    timestampToMs(callData.acceptedAt) ||
    intOr(callData.createdAtMs, 0) ||
    timestampToMs(callData.createdAt);
  if (
    acceptedAtMs <= 0 ||
    acceptedAtMs > Math.max(0, intOr(staleBeforeMs, 0))
  ) {
    return false;
  }

  const billableStartedAtMs =
    intOr(callData.billableStartedAtMs, 0) ||
    timestampToMs(callData.billableStartedAt);
  const bothJoinedAtMs =
    intOr(callData.bothJoinedAtMs, 0) || timestampToMs(callData.bothJoinedAt);
  return billableStartedAtMs <= 0 && bothJoinedAtMs <= 0;
}

function isMalformedAcceptedCleanupCandidate(callData = {}) {
  if (strOr(callData.status) !== "accepted") return false;
  return !strOr(callData.callerId) ||
    !strOr(callData.calleeId) ||
    !strOr(callData.channelId);
}

exports._isMalformedRingingCleanupCandidate = isMalformedRingingCleanupCandidate;
exports._isExpiredRingingCleanupCandidate = isExpiredRingingCleanupCandidate;
exports._isAcceptedCreditLimitCleanupCandidate =
  isAcceptedCreditLimitCleanupCandidate;
exports._isAcceptedStaleCleanupCandidate = isAcceptedStaleCleanupCandidate;
exports._isMalformedAcceptedCleanupCandidate =
  isMalformedAcceptedCleanupCandidate;

async function drainCallCleanupQueryBatches({
  fetchBatch,
  processDoc,
  batchLimit = CLEANUP_BATCH_LIMIT,
  maxBatchCount = CLEANUP_MAX_BATCH_COUNT,
}) {
  const safeBatchLimit = Math.max(1, intOr(batchLimit, CLEANUP_BATCH_LIMIT));
  const safeMaxBatchCount = Math.max(
    1,
    intOr(maxBatchCount, CLEANUP_MAX_BATCH_COUNT)
  );

  let cursor = null;
  let processedCount = 0;

  for (let batchIndex = 0; batchIndex < safeMaxBatchCount; batchIndex++) {
    const docs = await fetchBatch(cursor, safeBatchLimit);
    if (!Array.isArray(docs) || docs.length === 0) break;

    for (const doc of docs) {
      await processDoc(doc);
      processedCount += 1;
    }

    if (docs.length < safeBatchLimit) break;
    cursor = docs[docs.length - 1];
  }

  return processedCount;
}

exports._drainCallCleanupQueryBatches = drainCallCleanupQueryBatches;

async function forEachCleanupCallQueryBatch({
  buildQuery,
  processDoc,
  batchLimit = CLEANUP_BATCH_LIMIT,
  maxBatchCount = CLEANUP_MAX_BATCH_COUNT,
}) {
  return drainCallCleanupQueryBatches({
    batchLimit,
    maxBatchCount,
    fetchBatch: async (cursor, effectiveBatchLimit) => {
      let query = buildQuery();
      if (cursor) {
        query = query.startAfter(cursor);
      }

      const snap = await query.limit(effectiveBatchLimit).get();
      return snap.docs;
    },
    processDoc,
  });
}

async function forEachUserReconcileQueryBatch({
  buildQuery,
  processDoc,
  batchLimit = CLEANUP_BATCH_LIMIT,
  maxBatchCount = CLEANUP_MAX_BATCH_COUNT,
}) {
  return drainCallCleanupQueryBatches({
    batchLimit,
    maxBatchCount,
    fetchBatch: async (cursor, effectiveBatchLimit) => {
      let query = buildQuery();
      if (cursor) {
        query = query.startAfter(cursor);
      }

      const snap = await query.limit(effectiveBatchLimit).get();
      return snap.docs;
    },
    processDoc,
  });
}

async function endAcceptedCallIfStillAccepted({
  db,
  callRef,
  reason,
  nowMs = currentServerMs(),
  shouldEnd,
}) {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(callRef);
    if (!snap.exists) return;

    const callNow = snap.data() || {};
    if (strOr(callNow.status) !== "accepted") return;
    if (typeof shouldEnd === "function" && shouldEnd(callNow) !== true) return;

    tx.update(callRef, {
      status: "ended",
      endedAt: admin.firestore.FieldValue.serverTimestamp(),
      endedAtMs: nowMs,
      endedReason: strOr(reason, "system_cleanup"),
      endedBy: "system",
      endedSeconds: 0,
    });
  });
}

function buildChatSystemMessage({
  senderId,
  receiverId,
  type,
  text,
  systemAction,
  metadata,
}) {
  const nowMs = Date.now();
  const cleanMetadata =
    metadata && typeof metadata === "object" ? metadata : {};

  return {
    text: strOr(text),
    type: strOr(type, "system"),
    senderId: strOr(senderId),
    receiverId: strOr(receiverId),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: nowMs,
    seen: false,
    seenAt: null,
    seenAtMs: 0,
    systemAction: strOr(systemAction),
    metadata: cleanMetadata,
  };
}

function messagePreviewFromAction(action) {
  switch (strOr(action).trim()) {
    case "request_chat_access":
      return {
        type: "access_request",
        text: "Chat request sent",
      };
    case "request_call_access":
      return {
        type: "access_request",
        text: "Call request sent",
      };
    case "allow_chat_only":
      return {
        type: "system",
        text: "Chat request accepted",
      };
    case "allow_call":
      return {
        type: "access_approved",
        text: "Call access allowed",
      };
    case "deny_call":
      return {
        type: "access_denied",
        text: "Call access denied",
      };
    case "block_pair":
      return {
        type: "system",
        text: "This chat has been blocked",
      };
    default:
      return {
        type: "system",
        text: "Chat session updated",
      };
  }
}

function assertDirectionalPairIds({ speakerId, listenerId }) {
  const safeSpeakerId = strOr(speakerId).trim();
  const safeListenerId = strOr(listenerId).trim();

  if (!safeSpeakerId || !safeListenerId || safeSpeakerId === safeListenerId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Invalid chat pair"
    );
  }

  const ids = [safeSpeakerId, safeListenerId].sort();
  const canonicalDocId = `${ids[0]}_${ids[1]}`;
  const directDocId = `${safeSpeakerId}_${safeListenerId}`;
  const oppositeDocId = `${safeListenerId}_${safeSpeakerId}`;

  return {
    speakerId: ids[0],
    listenerId: ids[1],
    pairUserA: ids[0],
    pairUserB: ids[1],
    participantIds: ids,
    pairKey: canonicalDocId,
    actualListenerId: safeListenerId,
    actualSpeakerId: safeSpeakerId,
    canonicalDocId,
    reverseDocId: directDocId === canonicalDocId ? oppositeDocId : directDocId,
    requesterId: safeSpeakerId,
    responderId: safeListenerId,
    otherId: safeListenerId,
  };
}

function normalizeParticipantIds(value, fallbackIds = []) {
  const source = Array.isArray(value) ? value : fallbackIds;
  const ids = [];
  const seen = new Set();

  for (const raw of source) {
    const safe = strOr(raw).trim();
    if (!safe) continue;
    if (seen.has(safe)) continue;
    seen.add(safe);
    ids.push(safe);
  }

  ids.sort();
  if (ids.length === 2 && ids[0] !== ids[1]) {
    return ids;
  }

  return [...fallbackIds].map((v) => strOr(v).trim()).filter(Boolean).sort();
}

function resolveActualListenerId({
  chat = {},
  pair,
  allowRequesterDerivation = false,
  allowPairActualListenerFallback = false,
}) {
  const participantIds = normalizeParticipantIds(chat.participantIds, pair.participantIds);
  const requestedBy =
    strOr(chat.requesterId).trim() || strOr(chat.callRequestedBy).trim();
  const candidates = [
    chat.responderId,
    chat.pendingFor,
    chat.actualListenerId,
    chat.listenerUserId,
  ];

  for (const candidate of candidates) {
    const safe = strOr(candidate).trim();
    if (participantIds.includes(safe) && safe !== requestedBy) {
      return safe;
    }
  }

  if (
    allowRequesterDerivation &&
    participantIds.length === 2 &&
    participantIds.includes(requestedBy)
  ) {
    const other = participantIds.find((uid) => uid !== requestedBy);
    if (other) return other;
  }

  if (
    allowPairActualListenerFallback &&
    participantIds.includes(pair.actualListenerId)
  ) {
    return pair.actualListenerId;
  }

  return "";
}

function buildChatSessionContractFields({
  pair,
  chat = {},
  allowPairActualListenerFallback = false,
}) {
  const participantIds = normalizeParticipantIds(
    chat.participantIds,
    pair.participantIds
  );
  const actualListenerId = resolveActualListenerId({
    chat,
    pair,
    allowPairActualListenerFallback,
  });

  return {
    sessionId: pair.canonicalDocId,
    speakerId: pair.speakerId,
    listenerId: pair.listenerId,
    pairUserA: pair.pairUserA,
    pairUserB: pair.pairUserB,
    participantIds,
    pairKey: pair.pairKey,
    actualListenerId,
  };
}

function chatIdentityCompleteForDirection({ chat = {}, speakerId, listenerId }) {
  const pair = assertDirectionalPairIds({ speakerId, listenerId });
  const participantIds = normalizeParticipantIds(chat.participantIds, pair.participantIds);

  if (participantIds.length !== 2) return false;
  if (participantIds[0] !== pair.participantIds[0]) return false;
  if (participantIds[1] !== pair.participantIds[1]) return false;
  if (strOr(chat.speakerId).trim() !== pair.speakerId) return false;
  if (strOr(chat.listenerId).trim() !== pair.listenerId) return false;
  if (strOr(chat.pairUserA).trim() !== pair.pairUserA) return false;
  if (strOr(chat.pairUserB).trim() !== pair.pairUserB) return false;
  if (strOr(chat.pairKey).trim() !== pair.pairKey) return false;

  const explicitSessionId =
    strOr(chat.chatSessionId).trim() || strOr(chat.sessionId).trim();
  if (explicitSessionId && explicitSessionId !== pair.canonicalDocId) {
    return false;
  }

  return true;
}

function chatDirectionCompleteForDirection({ chat = {}, speakerId, listenerId }) {
  if (!chatIdentityCompleteForDirection({ chat, speakerId, listenerId })) {
    return false;
  }

  const pair = assertDirectionalPairIds({ speakerId, listenerId });
  const direction = callDirectionState({ chat, speakerId, listenerId });

  if (!direction.participantIds.includes(direction.actualListenerId)) {
    return false;
  }

  const requestStateNeedsActors =
    direction.callRequestOpen ||
    direction.callAllowed ||
    direction.callRequestedBy ||
    direction.requesterId ||
    direction.responderId ||
    direction.pendingFor ||
    direction.actionOwner;

  if (direction.callRequestedBy &&
      !direction.participantIds.includes(direction.callRequestedBy)) {
    return false;
  }

  if (requestStateNeedsActors) {
    if (!direction.participantIds.includes(direction.requesterId)) {
      return false;
    }
    if (!direction.participantIds.includes(direction.responderId)) {
      return false;
    }
    if (direction.requesterId === direction.responderId) {
      return false;
    }
    if (direction.callRequestedBy &&
        direction.requesterId !== direction.callRequestedBy) {
      return false;
    }
  }

  if (direction.pendingFor &&
      !direction.participantIds.includes(direction.pendingFor)) {
    return false;
  }
  if (direction.actionOwner &&
      !direction.participantIds.includes(direction.actionOwner)) {
    return false;
  }
  if (direction.callRequestOpen &&
      direction.responderId &&
      direction.pendingFor !== direction.responderId) {
    return false;
  }

  if (direction.actualListenerId !== pair.actualListenerId) {
    return false;
  }
  if (direction.requesterId && direction.requesterId !== pair.requesterId) {
    return false;
  }
  if (direction.callRequestedBy &&
      direction.callRequestedBy !== pair.requesterId) {
    return false;
  }
  if (direction.responderId && direction.responderId !== pair.responderId) {
    return false;
  }
  if (direction.callRequestOpen &&
      direction.pendingFor &&
      direction.pendingFor !== pair.responderId) {
    return false;
  }

  return true;
}

function callDirectionState({ chat = {}, speakerId, listenerId }) {
  const pair = assertDirectionalPairIds({ speakerId, listenerId });
  const participantIds = normalizeParticipantIds(
    chat.participantIds,
    pair.participantIds
  );

  return {
    ...pair,
    participantIds,
    actualListenerId: strOr(chat.actualListenerId).trim(),
    requesterId: strOr(chat.requesterId).trim(),
    responderId: strOr(chat.responderId).trim(),
    pendingFor: strOr(chat.pendingFor).trim(),
    actionOwner: strOr(chat.actionOwner).trim(),
    callRequestedBy: strOr(chat.callRequestedBy).trim(),
    callAllowed: boolOr(chat.callAllowed, false),
    callRequestOpen: boolOr(chat.callRequestOpen, false),
    status: strOr(chat.status).trim(),
  };
}

function directionalCallApprovalError({
  chatExists,
  reverseExists,
  chat = {},
  speakerId,
  listenerId,
  speakerBlocked = false,
  listenerBlocked = false,
}) {
  if (!chatExists) {
    return {
      code: "failed-precondition",
      reason: "call_access_not_accepted",
      message: "SESSION_NOT_FOUND",
    };
  }

  if (reverseExists) {
    return {
      code: "failed-precondition",
      reason: "call_access_not_accepted",
      message: "LEGACY_SESSION_MIGRATION_REQUIRED",
    };
  }

  if (speakerBlocked || listenerBlocked) {
    return {
      code: "permission-denied",
      reason: "unknown_precondition",
      message: "CHAT_PAIR_BLOCKED",
    };
  }

  const direction = callDirectionState({ chat, speakerId, listenerId });

  if (!direction.actualListenerId) {
    return {
      code: "failed-precondition",
      reason: "call_access_not_accepted",
      message: "CALL_NOT_ALLOWED_FOR_DIRECTION",
    };
  }

  if (direction.actualListenerId !== direction.actualListenerId.trim() ||
      !direction.participantIds.includes(direction.actualListenerId)) {
    return {
      code: "failed-precondition",
      reason: "listener_mismatch",
      message: "CALL_NOT_ALLOWED_FOR_DIRECTION",
    };
  }

  if (direction.actualListenerId !== strOr(listenerId).trim()) {
    return {
      code: "failed-precondition",
      reason: "listener_mismatch",
      message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
    };
  }

  if (direction.status === "accepted") {
    return null;
  }

  if (direction.responderId && direction.responderId !== strOr(listenerId).trim()) {
    return {
      code: "failed-precondition",
      reason: "listener_mismatch",
      message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
    };
  }

  const effectiveRequester =
    direction.requesterId || direction.callRequestedBy;

  if (!effectiveRequester) {
    return {
      code: "failed-precondition",
      reason: "call_access_not_accepted",
      message: "CALL_NOT_ALLOWED_FOR_DIRECTION",
    };
  }

  if (direction.requesterId && direction.requesterId !== strOr(speakerId).trim()) {
    return {
      code: "failed-precondition",
      reason: "caller_not_speaker",
      message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
    };
  }

  if (direction.callRequestedBy &&
      direction.callRequestedBy !== strOr(speakerId).trim()) {
    return {
      code: "failed-precondition",
      reason: "caller_not_speaker",
      message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
    };
  }

  if (effectiveRequester !== strOr(speakerId).trim()) {
    return {
      code: "failed-precondition",
      reason: "caller_not_speaker",
      message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
    };
  }

  if (direction.callRequestOpen === true && direction.callAllowed !== true) {
    return {
      code: "failed-precondition",
      reason: "call_access_not_accepted",
      message: "REQUEST_NOT_APPROVED",
    };
  }

  if (direction.callAllowed !== true) {
    return {
      code: "failed-precondition",
      reason: "call_access_not_accepted",
      message: "CALL_NOT_ALLOWED_FOR_DIRECTION",
    };
  }

  return null;
}

function buildSpeakerRequestAccessPatch({ pair, chat = {}, nowMs }) {
  const currentStatus = strOr(chat.status, "pending");
  const chatAlreadyAccepted =
    currentStatus === "accepted" || currentStatus === "active";
  const requestAction = chatAlreadyAccepted
    ? "request_call_access"
    : "request_chat_access";
  const nextStatus = chatAlreadyAccepted ? "accepted" : "pending";

  return {
    requestAction,
    nextStatus,
    update: {
      ...buildChatSessionContractFields({ pair, chat }),
      actualListenerId: pair.actualListenerId,
      status: nextStatus,
      callAllowed: false,
      callRequestedBy: pair.requesterId,
      requesterId: pair.requesterId,
      responderId: pair.responderId,
      pendingFor: pair.responderId,
      actionOwner: pair.requesterId,
      callRequestOpen: true,
      callAllowedAt: null,
      callAllowedAtMs: 0,
      callRequestAt: admin.firestore.FieldValue.serverTimestamp(),
      callRequestAtMs: nowMs,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    },
  };
}

function buildListenerResponsePatch({
  pair,
  chat = {},
  speakerId,
  listenerId,
  action,
  nowMs,
  sessionId = "",
}) {
  const currentSpeakerBlocked = boolOr(chat.speakerBlocked, false);
  const currentListenerBlocked = boolOr(chat.listenerBlocked, false);
  const currentCallRequestOpen = boolOr(chat.callRequestOpen, false);
  const currentRequestedBy = strOr(
    chat.requesterId,
    strOr(chat.callRequestedBy)
  );

  const update = {
    ...buildChatSessionContractFields({ pair, chat }),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };

  let nextStatus = strOr(chat.status, "pending");
  let nextCallAllowed = boolOr(chat.callAllowed, false);
  let nextCallRequestOpen = currentCallRequestOpen;
  let nextCallRequestedBy = currentRequestedBy;
  let nextSpeakerBlocked = currentSpeakerBlocked;
  let nextListenerBlocked = currentListenerBlocked;

  if (action === "allow_chat_only") {
    nextStatus = "accepted";
    nextCallAllowed = false;
    nextCallRequestOpen = false;
    nextCallRequestedBy = "";
    update.callAllowedAt = null;
    update.callAllowedAtMs = 0;
  } else if (action === "allow_call") {
    nextStatus = "accepted";
    nextCallAllowed = true;
    nextCallRequestOpen = false;
    nextCallRequestedBy = currentRequestedBy || speakerId;
    update.callAllowedAt = admin.firestore.FieldValue.serverTimestamp();
    update.callAllowedAtMs = nowMs;
    update.acceptedAt = admin.firestore.FieldValue.serverTimestamp();
    update.acceptedAtMs = nowMs;
    update.acceptedBy = listenerId;
  } else if (action === "deny_call") {
    nextStatus = "accepted";
    nextCallAllowed = false;
    nextCallRequestOpen = false;
    nextCallRequestedBy = "";
    update.callAllowedAt = null;
    update.callAllowedAtMs = 0;
  } else if (action === "block_pair") {
    nextStatus = "blocked";
    nextCallAllowed = false;
    nextCallRequestOpen = false;
    nextCallRequestedBy = "";
    nextListenerBlocked = true;
    update.callAllowedAt = null;
    update.callAllowedAtMs = 0;
  }

  const nextPendingFor = nextCallRequestOpen
    ? (nextCallRequestedBy === speakerId
        ? listenerId
        : nextCallRequestedBy === listenerId
          ? speakerId
          : "")
    : "";
  const nextResponderId =
    nextCallRequestedBy === speakerId
      ? listenerId
      : nextCallRequestedBy === listenerId
        ? speakerId
        : "";

  update.status = nextStatus;
  update.callAllowed = nextCallAllowed;
  update.callRequestOpen = nextCallRequestOpen;
  update.actualListenerId = listenerId;
  update.pendingFor = nextPendingFor;
  update.callRequestedBy = nextCallRequestedBy;
  update.requesterId = nextCallRequestedBy;
  update.responderId = nextResponderId;
  update.actionOwner = listenerId;
  update.speakerBlocked = nextSpeakerBlocked;
  update.listenerBlocked = nextListenerBlocked;
  update.callRequestAtMs =
    action === "allow_call" ||
    action === "allow_chat_only" ||
    action === "deny_call" ||
    action === "block_pair"
      ? 0
      : intOr(chat.callRequestAtMs, 0);

  if (
    action === "allow_call" ||
    action === "allow_chat_only" ||
    action === "deny_call" ||
    action === "block_pair"
  ) {
    update.callRequestAt = null;
  }

  return {
    update,
    responsePayload: {
      ok: true,
      sessionId,
      status: update.status,
      callAllowed: update.callAllowed,
      callRequestOpen: update.callRequestOpen,
      callRequestedBy: update.callRequestedBy,
      actualListenerId: update.actualListenerId,
      requesterId: update.requesterId,
      responderId: update.responderId,
      pendingFor: update.pendingFor,
      actionOwner: update.actionOwner,
      speakerBlocked: update.speakerBlocked,
      listenerBlocked: update.listenerBlocked,
      action,
    },
  };
}

function rejectIncomingAuthorizationError({ actorUid, calleeId }) {
  const safeActorUid = strOr(actorUid).trim();
  const safeCalleeId = strOr(calleeId).trim();
  if (!safeActorUid || !safeCalleeId || safeActorUid !== safeCalleeId) {
    return {
      code: "permission-denied",
      message: "Only the callee can reject this incoming call.",
    };
  }
  return null;
}

exports._directionalCallApprovalError = directionalCallApprovalError;
exports._rejectIncomingAuthorizationError = rejectIncomingAuthorizationError;
exports._buildSpeakerRequestAccessPatch = buildSpeakerRequestAccessPatch;
exports._buildListenerResponsePatch = buildListenerResponsePatch;
exports._buildChatSessionContractFields = buildChatSessionContractFields;
exports._resolveActualListenerId = resolveActualListenerId;
exports._chatIdentityCompleteForDirection = chatIdentityCompleteForDirection;
exports._chatDirectionCompleteForDirection = chatDirectionCompleteForDirection;

async function ensureCanonicalChatSessionForPairTx({
  tx,
  db,
  speakerId,
  listenerId,
}) {
  const pair = assertDirectionalPairIds({ speakerId, listenerId });
  const ref = db.collection("chat_sessions").doc(pair.canonicalDocId);
  const snap = await tx.get(ref);
  const nowMs = Date.now();

  if (!snap.exists) {
    const data = {
      ...buildChatSessionContractFields({
        pair,
        allowPairActualListenerFallback: true,
      }),
      requesterId: "",
      responderId: "",
      pendingFor: "",
      actionOwner: "",
      status: "pending",
      callAllowed: false,
      callRequestedBy: "",
      callRequestOpen: false,
      callRequestAt: null,
      callRequestAtMs: 0,
      callAllowedAt: null,
      callAllowedAtMs: 0,
      speakerBlocked: false,
      listenerBlocked: false,
      lastMessageText: "",
      lastMessageSenderId: "",
      lastMessageType: "",
      lastMessageAt: null,
      lastMessageAtMs: 0,
      speakerUnreadCount: 0,
      listenerUnreadCount: 0,
      archived: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAtMs: nowMs,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    };

    tx.set(ref, data, { merge: true });

    return {
      ref,
      data,
      existed: false,
      canonicalDocId: pair.canonicalDocId,
      reverseDocId: pair.reverseDocId,
    };
  }

  const existing = snap.data() || {};
  tx.set(ref, buildChatSessionContractFields({ pair, chat: existing }), {
    merge: true,
  });
  return {
    ref,
    data: {
      ...existing,
      ...buildChatSessionContractFields({ pair, chat: existing }),
    },
    existed: true,
    canonicalDocId: pair.canonicalDocId,
    reverseDocId: pair.reverseDocId,
  };
}

async function validateChatPairForBootstrapTx({
  tx,
  db,
  speakerId,
  listenerId,
  requesterId,
}) {
  const pair = assertDirectionalPairIds({ speakerId, listenerId });

  if (requesterId !== pair.speakerId && requesterId !== pair.listenerId) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You are not part of this chat pair"
    );
  }

  const users = db.collection("users");
  const speakerRef = users.doc(pair.speakerId);
  const listenerRef = users.doc(pair.listenerId);

  const [speakerSnap, listenerSnap] = await Promise.all([
    tx.get(speakerRef),
    tx.get(listenerRef),
  ]);

  if (!speakerSnap.exists) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Speaker profile missing"
    );
  }

  if (!listenerSnap.exists) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Listener profile missing"
    );
  }

  const speaker = speakerSnap.data() || {};
  const listener = listenerSnap.data() || {};

  if (speaker.adminBlocked === true) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Speaker not available"
    );
  }

  if (listener.adminBlocked === true) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Listener not available"
    );
  }

  const speakerBlockedUsers = Array.isArray(speaker.blocked)
    ? speaker.blocked
    : [];
  const listenerBlockedUsers = Array.isArray(listener.blocked)
    ? listener.blocked
    : [];

  if (speakerBlockedUsers.includes(pair.listenerId)) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Speaker blocked this listener"
    );
  }

  if (listenerBlockedUsers.includes(pair.speakerId)) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Listener blocked this speaker"
    );
  }

  const chatSessions = db.collection("chat_sessions");
  const chatRef = chatSessions.doc(pair.canonicalDocId);
  const reverseRef = chatSessions.doc(pair.reverseDocId);

  const [chatSnap, reverseSnap] = await Promise.all([
    tx.get(chatRef),
    tx.get(reverseRef),
  ]);

  if (!chatSnap.exists && reverseSnap.exists) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Legacy duplicate chat session exists. Run admin cleanup before continuing."
    );
  }

  return {
    ...pair,
    speaker,
    listener,
    chatRef,
    reverseRef,
    chatSnap,
    reverseSnap,
  };
}

async function getCanonicalChatGateTx({ tx, db, speakerId, listenerId }) {
  const pair = assertDirectionalPairIds({ speakerId, listenerId });

  const chatRef = db.collection("chat_sessions").doc(pair.canonicalDocId);
  const reverseRef = db.collection("chat_sessions").doc(pair.reverseDocId);

  const [chatSnap, reverseSnap] = await Promise.all([
    tx.get(chatRef),
    tx.get(reverseRef),
  ]);

  const chat = chatSnap.exists ? chatSnap.data() || {} : {};

  return {
    canonicalChatSessionId: pair.canonicalDocId,
    reverseChatSessionId: pair.reverseDocId,
    chatRef,
    reverseRef,
    chatExists: chatSnap.exists,
    reverseExists: reverseSnap.exists,
    chat,
    callAllowed: boolOr(chat.callAllowed, false),
    callRequestOpen: boolOr(chat.callRequestOpen, false),
    callRequestedBy: strOr(chat.callRequestedBy),
    speakerBlocked: boolOr(chat.speakerBlocked, false),
    listenerBlocked: boolOr(chat.listenerBlocked, false),
    status: chatSnap.exists ? strOr(chat.status, "pending") : "none",
  };
}

async function assertCanonicalChatAllowsCallTx({
  tx,
  db,
  speakerId,
  listenerId,
}) {
  const gate = await getCanonicalChatGateTx({
    tx,
    db,
    speakerId,
    listenerId,
  });

  const directionError = directionalCallApprovalError({
    chatExists: gate.chatExists,
    reverseExists: gate.reverseExists,
    chat: gate.chat,
    speakerId,
    listenerId,
    speakerBlocked: gate.speakerBlocked,
    listenerBlocked: gate.listenerBlocked,
  });
  if (directionError) {
    throw callHttpsError(
      directionError.code,
      directionError.reason || "unknown_precondition",
      directionError.message
    );
  }

  return gate;
}

async function getCallForTransitionTx({ tx, db, callId, actorUid }) {
  const callRef = db.collection("calls").doc(callId);
  const callSnap = await tx.get(callRef);

  if (!callSnap.exists) {
    throw new functions.https.HttpsError("not-found", "Call not found");
  }

  const call = callSnap.data() || {};
  const callerId = strOr(call.callerId).trim();
  const calleeId = strOr(call.calleeId).trim();
  const status = strOr(call.status).trim();

  if (!callerId || !calleeId) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Call participants missing"
    );
  }

  if (actorUid !== callerId && actorUid !== calleeId) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You are not part of this call"
    );
  }

  return {
    callRef,
    call,
    callerId,
    calleeId,
    status,
  };
}

function isFirestoreWriteRace(error) {
  const code = strOr(error && error.code).toLowerCase();
  const message = strOr(error && error.message).toLowerCase();
  return (
    code === "failed-precondition" ||
    code === "aborted" ||
    code === "9" ||
    code === "10" ||
    message.includes("precondition") ||
    message.includes("too much contention")
  );
}

async function acceptIncomingCallFastPath({
  db,
  callId,
  actorUid,
}) {
  const callRef = db.collection("calls").doc(callId);
  const callLoadStartMs = timingNowMs();
  const callSnap = await callRef.get();

  if (!callSnap.exists) {
    throw new functions.https.HttpsError("not-found", "Call not found");
  }

  const call = callSnap.data() || {};
  const callerId = strOr(call.callerId).trim();
  const calleeId = strOr(call.calleeId).trim();
  const status = strOr(call.status).trim();
  logCallTiming("acceptIncomingCall_v1", "call_load", callLoadStartMs, {
    callId,
    attempt: 0,
    status,
    mode: "fast_precondition_read",
  });
  logEvent("call_loaded", {
    callId,
    actorUid: shortLogId(actorUid),
    status,
    mode: "fast_precondition_read",
  });

  if (!callerId || !calleeId) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Call participants missing"
    );
  }

  if (actorUid !== callerId && actorUid !== calleeId) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You are not part of this call"
    );
  }

  if (calleeId !== actorUid) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Only callee can accept this call"
    );
  }

  if (status === "accepted") {
    const channelId = strOr(call.channelId).trim();
    const calleeAgoraUid = intOr(call.calleeAgoraUid, 0);
    const tokenLoadStartMs = timingNowMs();
    let calleeAgoraToken = strOr(call.agoraTokenCallee, "").trim();
    if (!calleeAgoraToken) {
      const calleeTokenSnap = await callRef
        .collection("participantTokens")
        .doc(calleeId)
        .get();
      const calleeToken = calleeTokenSnap.exists
        ? calleeTokenSnap.data() || {}
        : {};
      calleeAgoraToken = strOr(calleeToken.agoraToken, "").trim();
    }
    logCallTiming("acceptIncomingCall_v1", "participant_token_load", tokenLoadStartMs, {
      callId,
      attempt: 0,
      tokenPresent: !!calleeAgoraToken,
      alreadyAccepted: true,
      mode: "fast_precondition_read",
    });
    return {
      handled: true,
      responsePayload: {
        ok: true,
        callId,
        status: "accepted",
        channelId,
        calleeAgoraUid,
        agoraUid: calleeAgoraUid,
        agoraToken: calleeAgoraToken,
        alreadyAccepted: true,
      },
    };
  }

  if (isFinalStatus(status)) {
    return {
      handled: true,
      responsePayload: {
        ok: true,
        callId,
        status,
        alreadyFinal: true,
      },
    };
  }

  if (status !== "ringing") {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Only ringing calls can be accepted"
    );
  }
  logEvent("status_validated", {
    callId,
    status,
    mode: "fast_precondition_read",
  });

  const expiresAtMs = intOr(call.expiresAtMs, 0);
  const nowMs = currentServerMs();
  if (expiresAtMs > 0 && expiresAtMs <= nowMs) {
    return {
      handled: false,
      reason: "expired_requires_transaction_cleanup",
    };
  }

  const channelId = strOr(call.channelId).trim();
  const calleeAgoraUid = intOr(call.calleeAgoraUid, 0);
  const users = db.collection("users");
  const validationReadStartMs = timingNowMs();
  const calleeTokenRef = callRef
    .collection("participantTokens")
    .doc(calleeId);
  const profileRefs = [users.doc(calleeId)];
  if (callerId) profileRefs.push(users.doc(callerId));

  const [calleeTokenSnap, ...profileSnaps] = await Promise.all([
    calleeTokenRef.get(),
    ...profileRefs.map((ref) => ref.get()),
  ]);
  const calleeToken = calleeTokenSnap.exists
    ? calleeTokenSnap.data() || {}
    : {};
  const calleeAgoraToken =
    strOr(call.agoraTokenCallee, "").trim() ||
    strOr(calleeToken.agoraToken, "").trim();
  logCallTiming("acceptIncomingCall_v1", "participant_validation_read", validationReadStartMs, {
    callId,
    attempt: 0,
    tokenPresent: !!calleeAgoraToken,
    profileReadCount: profileRefs.length,
    mode: "fast_precondition_read",
  });
  logCallTiming("acceptIncomingCall_v1", "participant_token_load", validationReadStartMs, {
    callId,
    attempt: 0,
    tokenPresent: !!calleeAgoraToken,
    parallelWithProfileRead: true,
    mode: "fast_precondition_read",
  });
  logEvent("participant_token_loaded", {
    callId,
    tokenPresent: !!calleeAgoraToken,
    agoraUidPresent: calleeAgoraUid > 0,
    mode: "fast_precondition_read",
  });

  const profileReadStartMs = timingNowMs();
  const calleeSnap = profileSnaps[0];
  const callerSnap = callerId ? profileSnaps[1] : null;
  logCallTiming("acceptIncomingCall_v1", "participant_profile_read", profileReadStartMs, {
    callId,
    attempt: 0,
    callerPresent: Boolean(callerSnap && callerSnap.exists),
    calleePresent: Boolean(calleeSnap && calleeSnap.exists),
    alreadyLoaded: true,
    mode: "fast_precondition_read",
  });
  const callee = calleeSnap && calleeSnap.exists ? calleeSnap.data() || {} : {};
  const caller =
    callerSnap && callerSnap.exists ? callerSnap.data() || {} : {};
  if (onlyChatModeEnabled(callee)) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "self_only_chat_mode"
    );
  }
  if (onlyChatModeEnabled(caller)) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "peer_only_chat_mode"
    );
  }

  logEvent("accepted_write_begin", {
    callId,
    mode: "fast_precondition_update",
  });
  const acceptedWriteStartMs = timingNowMs();
  try {
    await callRef.update(
      {
        status: "accepted",
        acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
        acceptedAtMs: nowMs,
        startedAtMs: 0,
        billableStartedAtMs: 0,
        bothJoinedAtMs: 0,
      },
      { lastUpdateTime: callSnap.updateTime }
    );
  } catch (e) {
    if (isFirestoreWriteRace(e)) {
      logCallTiming("acceptIncomingCall_v1", "fast_precondition_race", acceptedWriteStartMs, {
        callId,
        code: strOr(e && e.code, "unknown"),
      });
      return {
        handled: false,
        reason: "precondition_race",
      };
    }
    throw e;
  }
  logCallTiming("acceptIncomingCall_v1", "accepted_write_committed", acceptedWriteStartMs, {
    callId,
    attempt: 0,
    mode: "fast_precondition_update",
  });
  logEvent("accepted_write_ok", {
    callId,
    mode: "fast_precondition_update",
  });

  return {
    handled: true,
    responsePayload: {
      ok: true,
      callId,
      status: "accepted",
      channelId,
      calleeAgoraUid,
      agoraUid: calleeAgoraUid,
      agoraToken: calleeAgoraToken,
    },
  };
}

function currentServerMs() {
  return Date.now();
}

async function assertNoLiveCallForUser({
  db,
  uid,
  errorMessage,
  reason = "active_call_exists",
}) {
  const [asCaller, asCallee] = await Promise.all([
    db
      .collection("calls")
      .where("callerId", "==", uid)
      .where("status", "in", ["ringing", "accepted"])
      .limit(1)
      .get(),
    db
      .collection("calls")
      .where("calleeId", "==", uid)
      .where("status", "in", ["ringing", "accepted"])
      .limit(1)
      .get(),
  ]);

  if (!asCaller.empty || !asCallee.empty) {
    throw startCallPrecondition(reason, errorMessage);
  }
}

async function getLiveParticipantCallId(db, userId) {
  const [asCaller, asCallee] = await Promise.all([
    db
      .collection("calls")
      .where("callerId", "==", userId)
      .where("status", "in", ["ringing", "accepted", "ended"])
      .limit(10)
      .get(),
    db
      .collection("calls")
      .where("calleeId", "==", userId)
      .where("status", "in", ["ringing", "accepted", "ended"])
      .limit(10)
      .get(),
  ]);

  for (const doc of asCaller.docs) {
    if (callShouldKeepBusyLock(doc.data() || {})) {
      return doc.id;
    }
  }

  for (const doc of asCallee.docs) {
    if (callShouldKeepBusyLock(doc.data() || {})) {
      return doc.id;
    }
  }

  return "";
}

function getTrueReservedCreditsForCalls(calls = []) {
  let total = 0;

  for (const call of calls) {
    if (!callShouldHoldReserve(call)) continue;
    total += intOr(call.reservedUpfront, 0);
  }

  return total;
}

exports._getTrueReservedCreditsForCalls = getTrueReservedCreditsForCalls;

async function verifyTrackedActiveCallTx({ tx, db, userRef, userId, user }) {
  const activeCallId = strOr(user.activeCallId).trim();
  if (!activeCallId) return "";

  const activeCallSnap = await tx.get(db.collection("calls").doc(activeCallId));
  if (activeCallSnap.exists) {
    const call = activeCallSnap.data() || {};
    const status = strOr(call.status).trim();
    const callerId = strOr(call.callerId).trim();
    const calleeId = strOr(call.calleeId).trim();
    if (isLiveStatus(status) && (callerId === userId || calleeId === userId)) {
      return activeCallId;
    }
  }

  tx.update(userRef, {
    activeCallId: "",
    isOnCall: false,
    activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return "";
}

async function getTrueReservedCreditsForUser(db, userId) {
  const heldReserveCallsSnap = await db
    .collection("calls")
    .where("callerId", "==", userId)
    .where("status", "in", ["ringing", "accepted", "ended"])
    .limit(20)
    .get();

  return getTrueReservedCreditsForCalls(
    heldReserveCallsSnap.docs.map((doc) => doc.data() || {})
  );
}

exports.ensureChatSession_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "ensureChatSession_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const requesterId = strOr(context.auth.uid).trim();
    const speakerId = strOr(data && data.speakerId).trim();
    const listenerId = strOr(data && data.listenerId).trim();

    if (!speakerId || !listenerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "speakerId and listenerId are required"
      );
    }

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      await validateChatPairForBootstrapTx({
        tx,
        db,
        speakerId,
        listenerId,
        requesterId,
      });

      const normalized = await ensureCanonicalChatSessionForPairTx({
        tx,
        db,
        speakerId,
        listenerId,
      });

      const chat = normalized.data || {};
      const identityComplete = chatIdentityCompleteForDirection({
        chat,
        speakerId,
        listenerId,
      });
      const directionComplete = chatDirectionCompleteForDirection({
        chat,
        speakerId,
        listenerId,
      });

      responsePayload = {
        ok: true,
        sessionId: normalized.ref.id,
        existed: normalized.existed === true,
        speakerId,
        listenerId,
        pairKey: normalized.canonicalDocId,
        participantIds: normalizeParticipantIds(chat.participantIds, [speakerId, listenerId]),
      actualListenerId: resolveActualListenerId({
        chat,
        pair: assertDirectionalPairIds({ speakerId, listenerId }),
      }),
        status: strOr(chat.status, "pending"),
        callAllowed: boolOr(chat.callAllowed, false),
        callRequestOpen: boolOr(chat.callRequestOpen, false),
        callRequestedBy: strOr(chat.callRequestedBy),
        speakerBlocked: boolOr(chat.speakerBlocked, false),
        listenerBlocked: boolOr(chat.listenerBlocked, false),
        identityComplete,
        directionComplete,
      };
    });

    return responsePayload;
  });

exports.speakerRequestChatAccess_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "speakerRequestChatAccess_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const speakerId = strOr(context.auth.uid).trim();
    const listenerId = strOr(data && data.listenerId).trim();

    if (!speakerId || !listenerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "listenerId required"
      );
    }

    if (speakerId === listenerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Cannot request access to yourself"
      );
    }

    const db = admin.firestore();
    const users = db.collection("users");
    const speakerRef = users.doc(speakerId);
    const listenerRef = users.doc(listenerId);
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const pairContext = await validateChatPairForBootstrapTx({
        tx,
        db,
        speakerId,
        listenerId,
        requesterId: speakerId,
      });

      const [speakerSnap, listenerSnap] = await Promise.all([
        tx.get(speakerRef),
        tx.get(listenerRef),
      ]);

      if (!speakerSnap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Speaker profile missing"
        );
      }

      if (!listenerSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Listener not found");
      }

      const speaker = speakerSnap.data() || {};
      const listener = listenerSnap.data() || {};

      if (speaker.adminBlocked === true) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Your account is blocked"
        );
      }

      if (listener.adminBlocked === true) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Listener not available"
        );
      }

      const speakerBlockedUsers = Array.isArray(speaker.blocked)
        ? speaker.blocked
        : [];
      const listenerBlockedUsers = Array.isArray(listener.blocked)
        ? listener.blocked
        : [];

      if (speakerBlockedUsers.includes(listenerId)) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "You blocked this listener"
        );
      }

      if (listenerBlockedUsers.includes(speakerId)) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Listener blocked you"
        );
      }

      if (onlyChatModeEnabled(speaker)) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "self_only_chat_mode"
        );
      }

      if (onlyChatModeEnabled(listener)) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "peer_only_chat_mode"
        );
      }

      const normalized = await ensureCanonicalChatSessionForPairTx({
        tx,
        db,
        speakerId,
        listenerId,
      });

      const chatRef = normalized.ref;
      const chat = normalized.data || {};
      const nowMs = Date.now();

      const speakerBlocked = boolOr(chat.speakerBlocked, false);
      const listenerBlocked = boolOr(chat.listenerBlocked, false);
      const callAllowed = boolOr(chat.callAllowed, false);

      if (speakerBlocked || listenerBlocked) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Chat is blocked for this pair"
        );
      }

      const requestState = buildSpeakerRequestAccessPatch({
        pair: pairContext,
        chat,
        nowMs,
      });

      const messageRef = chatRef
        .collection("messages")
        .doc(`call_request_sent_${chatRef.id}`);
      const existingSystemMessageSnap = await tx.get(messageRef);
      const preview = messagePreviewFromAction(requestState.requestAction);

      tx.set(
        chatRef,
        requestState.update,
        { merge: true }
      );

      if (existingSystemMessageSnap.exists) {
        console.log("call_system_message.duplicate_suppressed", {
          action: requestState.requestAction,
        });
      } else {
        tx.set(
          messageRef,
          buildChatSystemMessage({
            senderId: speakerId,
            receiverId: listenerId,
            type: preview.type,
            text: preview.text,
            systemAction: requestState.requestAction,
            metadata: {
              action: requestState.requestAction,
              requesterId: speakerId,
              receiverId: listenerId,
              sessionId: chatRef.id,
            },
          })
        );
      }

      responsePayload = {
        ok: true,
        sessionId: chatRef.id,
        status: requestState.nextStatus,
        callAllowed: false,
        callRequestOpen: true,
        callRequestedBy: speakerId,
        actualListenerId: pairContext.actualListenerId,
        requesterId: pairContext.requesterId,
        responderId: pairContext.responderId,
        pendingFor: pairContext.responderId,
        actionOwner: pairContext.requesterId,
        speakerBlocked: false,
        listenerBlocked: false,
        action: requestState.requestAction,
      };
    });

    return responsePayload;
  });

exports.listenerRespondToChatRequest_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "listenerRespondToChatRequest_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const listenerId = strOr(context.auth.uid).trim();
    const speakerId = strOr(data && data.speakerId).trim();
    const action = strOr(data && data.action).trim();

    if (!speakerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "speakerId required"
      );
    }

    if (!action) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "action required"
      );
    }

    if (speakerId === listenerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Invalid chat pair"
      );
    }

    const allowedActions = [
      "allow_chat_only",
      "allow_call",
      "deny_call",
      "block_pair",
    ];

    if (!allowedActions.includes(action)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Unsupported action"
      );
    }

    const db = admin.firestore();
    const users = db.collection("users");
    const speakerRef = users.doc(speakerId);
    const listenerRef = users.doc(listenerId);
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const pairContext = await validateChatPairForBootstrapTx({
        tx,
        db,
        speakerId,
        listenerId,
        requesterId: listenerId,
      });

      const [speakerSnap, listenerSnap] = await Promise.all([
        tx.get(speakerRef),
        tx.get(listenerRef),
      ]);

      if (!speakerSnap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Speaker profile missing"
        );
      }

      if (!listenerSnap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Listener profile missing"
        );
      }

      const speaker = speakerSnap.data() || {};
      const listener = listenerSnap.data() || {};

      if (listener.adminBlocked === true) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Your account is blocked"
        );
      }

      if (speaker.adminBlocked === true) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Speaker not available"
        );
      }

      if (action === "allow_call") {
        if (onlyChatModeEnabled(listener)) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "self_only_chat_mode"
          );
        }

        if (onlyChatModeEnabled(speaker)) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "peer_only_chat_mode"
          );
        }
      }

      const normalized = await ensureCanonicalChatSessionForPairTx({
        tx,
        db,
        speakerId,
        listenerId,
      });

      const chatRef = normalized.ref;
      const chat = normalized.data || {};
      const nowMs = Date.now();

      const currentSpeakerBlocked = boolOr(chat.speakerBlocked, false);
      const currentListenerBlocked = boolOr(chat.listenerBlocked, false);
      const currentCallRequestOpen = boolOr(chat.callRequestOpen, false);
      const currentCallAllowed = boolOr(chat.callAllowed, false);
      const currentActualListenerId = strOr(chat.actualListenerId);
      const currentRequestedBy = strOr(
        chat.requesterId,
        strOr(chat.callRequestedBy)
      );
      const currentPendingFor = strOr(chat.pendingFor);
      const currentResponderId = strOr(
        chat.responderId,
        currentRequestedBy === speakerId
          ? listenerId
          : currentRequestedBy === listenerId
            ? speakerId
            : ""
      );

      if (currentSpeakerBlocked || currentListenerBlocked) {
        if (action !== "block_pair") {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Chat is already blocked"
          );
        }
      }

      if (action !== "block_pair") {
        if (!currentCallRequestOpen) {
          if (action === "allow_call" && currentCallAllowed) {
            if (
              currentRequestedBy === speakerId &&
              currentResponderId === listenerId
            ) {
              responsePayload = {
                ok: true,
                sessionId: chatRef.id,
                status: strOr(chat.status, "accepted"),
                callAllowed: true,
                callRequestOpen: false,
                callRequestedBy: currentRequestedBy,
                actualListenerId: currentActualListenerId || listenerId,
                requesterId: currentRequestedBy,
                responderId: currentResponderId,
                pendingFor: "",
                actionOwner: listenerId,
                speakerBlocked: false,
                listenerBlocked: false,
                action,
              };
              return;
            }

            throw new functions.https.HttpsError(
              "failed-precondition",
              "call_request_already_accepted"
            );
          }

          throw new functions.https.HttpsError(
            "failed-precondition",
            "call_request_not_found"
          );
        }

        if (currentPendingFor !== listenerId) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "invalid_call_request_state"
          );
        }

        if (currentRequestedBy !== speakerId) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "invalid_call_request_state"
          );
        }

        if (currentResponderId !== listenerId) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "invalid_call_request_state"
          );
        }

        if (currentActualListenerId && currentActualListenerId !== listenerId) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "invalid_call_request_state"
          );
        }
      }

      const listenerResponsePatch = buildListenerResponsePatch({
        pair: pairContext,
        chat,
        speakerId,
        listenerId,
        action,
        nowMs,
        sessionId: chatRef.id,
      });
      const update = listenerResponsePatch.update;

      const systemMessageId =
        action === "allow_call"
          ? `call_access_allowed_${chatRef.id}`
          : `call_access_${action}_${chatRef.id}`;
      const messageRef = chatRef.collection("messages").doc(systemMessageId);
      const existingSystemMessageSnap = await tx.get(messageRef);
      const preview = messagePreviewFromAction(action);

      tx.set(chatRef, update, { merge: true });
      if (existingSystemMessageSnap.exists) {
        console.log("call_system_message.duplicate_suppressed", {
          action,
        });
      } else {
        tx.set(
          messageRef,
          buildChatSystemMessage({
            senderId: listenerId,
            receiverId: speakerId,
            type: preview.type,
            text: preview.text,
            systemAction: action,
            metadata: {
              action,
              speakerId,
              listenerId,
              sessionId: chatRef.id,
              callAllowed: boolOr(update.callAllowed, false),
              listenerBlocked: boolOr(update.listenerBlocked, false),
            },
          })
        );
      }

      responsePayload = listenerResponsePatch.responsePayload;
    });

    return responsePayload;
  });

exports.acceptIncomingCall_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "acceptIncomingCall_v1");
    let acceptStage = "accept_begin";
    logEvent("accept_begin", {});

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    acceptStage = "auth_ok";
    const actorUid = strOr(context.auth.uid).trim();
    const callId = strOr(data && data.callId).trim();
    const functionStartMs = timingNowMs();
    logFunctionTrace("acceptIncomingCall_v1", "begin", data, {
      callId,
      actorUid: shortLogId(actorUid),
    });
    logEvent("auth_ok", {
      callId,
      actorUid: shortLogId(actorUid),
    });

    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    logEvent("call.accept.request", {
      callId,
      actorUid: shortLogId(actorUid),
    });

    const db = admin.firestore();
    let responsePayload = null;
    let transactionAttempt = 0;

    try {
      const fastPathStartMs = timingNowMs();
      const fastPathResult = await acceptIncomingCallFastPath({
        db,
        callId,
        actorUid,
      });
      logCallTiming("acceptIncomingCall_v1", "fast_path_total", fastPathStartMs, {
        callId,
        handled: Boolean(fastPathResult && fastPathResult.handled),
        reason: strOr(fastPathResult && fastPathResult.reason),
      });

      if (fastPathResult && fastPathResult.handled) {
        responsePayload = fastPathResult.responsePayload;
        acceptStage = "accept_return_success";
      } else {
        logEvent("call.accept.fast_path_fallback", {
          callId,
          reason: strOr(fastPathResult && fastPathResult.reason, "unknown"),
        });
        const transactionStartMs = timingNowMs();
        await db.runTransaction(async (tx) => {
        transactionAttempt += 1;
        acceptStage = "call_loaded";
        const callLoadStartMs = timingNowMs();
        const { callRef, call, calleeId, status } = await getCallForTransitionTx({
          tx,
          db,
          callId,
          actorUid,
        });
        logCallTiming("acceptIncomingCall_v1", "call_load", callLoadStartMs, {
          callId,
          attempt: transactionAttempt,
          status,
        });
        logEvent("call_loaded", {
          callId,
          actorUid: shortLogId(actorUid),
          status,
        });

        if (calleeId !== actorUid) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "Only callee can accept this call"
          );
        }

        if (status === "accepted") {
          const channelId = strOr(call.channelId).trim();
          const calleeAgoraUid = intOr(call.calleeAgoraUid, 0);
          const tokenLoadStartMs = timingNowMs();
          let calleeAgoraToken = strOr(call.agoraTokenCallee, "").trim();
          if (!calleeAgoraToken) {
            const calleeTokenRef = callRef
              .collection("participantTokens")
              .doc(calleeId);
            const calleeTokenSnap = await tx.get(calleeTokenRef);
            const calleeToken = calleeTokenSnap.exists
              ? calleeTokenSnap.data() || {}
              : {};
            calleeAgoraToken = strOr(calleeToken.agoraToken, "").trim();
          }
          logCallTiming("acceptIncomingCall_v1", "participant_token_load", tokenLoadStartMs, {
            callId,
            attempt: transactionAttempt,
            tokenPresent: !!calleeAgoraToken,
            alreadyAccepted: true,
          });
          responsePayload = {
            ok: true,
            callId,
            status: "accepted",
            channelId,
            calleeAgoraUid,
            agoraUid: calleeAgoraUid,
            agoraToken: calleeAgoraToken,
            alreadyAccepted: true,
          };
          acceptStage = "accept_return_success";
          return;
        }

        if (isFinalStatus(status)) {
          responsePayload = {
            ok: true,
            callId,
            status,
            alreadyFinal: true,
          };
          acceptStage = "accept_return_success";
          return;
        }

        acceptStage = "status_validated";
        if (status !== "ringing") {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Only ringing calls can be accepted"
          );
        }
        logEvent("status_validated", {
          callId,
          status,
        });

        const expiresAtMs = intOr(call.expiresAtMs, 0);
        const nowMs = currentServerMs();
        if (expiresAtMs > 0 && expiresAtMs <= nowMs) {
          await clearParticipantBusyLocksTx(tx, {
            db,
            callId,
            callerId,
            calleeId,
          });
          tx.update(callRef, {
            status: "rejected",
            endedAt: admin.firestore.FieldValue.serverTimestamp(),
            endedAtMs: nowMs,
            endedSeconds: 0,
            endedBy: "system",
            endedReason: "missed",
            rejectedReason: "callee_timeout",
            endReasonCode: "callee_timeout",
            missedBy: calleeId,
          });

          responsePayload = {
            ok: true,
            callId,
            status: "rejected",
            alreadyExpired: true,
          };
          acceptStage = "accept_return_success";
          return;
        }

        const callerId = strOr(call.callerId).trim();
        const channelId = strOr(call.channelId).trim();
        const calleeAgoraUid = intOr(call.calleeAgoraUid, 0);
        const users = db.collection("users");
        acceptStage = "participant_validation_loaded";
        const validationReadStartMs = timingNowMs();
        const calleeTokenRef = callRef
          .collection("participantTokens")
          .doc(calleeId);
        const profileRefs = [users.doc(calleeId)];
        if (callerId) profileRefs.push(users.doc(callerId));
        const [calleeTokenSnap, profileSnaps] = await Promise.all([
          tx.get(calleeTokenRef),
          tx.getAll(...profileRefs),
        ]);
        const calleeToken = calleeTokenSnap.exists
          ? calleeTokenSnap.data() || {}
          : {};
        const calleeAgoraToken =
          strOr(call.agoraTokenCallee, "").trim() ||
          strOr(calleeToken.agoraToken, "").trim();
        logCallTiming("acceptIncomingCall_v1", "participant_validation_read", validationReadStartMs, {
          callId,
          attempt: transactionAttempt,
          tokenPresent: !!calleeAgoraToken,
          profileReadCount: profileRefs.length,
        });
        logCallTiming("acceptIncomingCall_v1", "participant_token_load", validationReadStartMs, {
          callId,
          attempt: transactionAttempt,
          tokenPresent: !!calleeAgoraToken,
          parallelWithProfileRead: true,
        });
        logEvent("participant_token_loaded", {
          callId,
          tokenPresent: !!calleeAgoraToken,
          agoraUidPresent: calleeAgoraUid > 0,
        });
        const profileReadStartMs = timingNowMs();
        const calleeSnap = profileSnaps[0];
        const callerSnap = callerId ? profileSnaps[1] : null;
        logCallTiming("acceptIncomingCall_v1", "participant_profile_read", profileReadStartMs, {
          callId,
          attempt: transactionAttempt,
          callerPresent: Boolean(callerSnap && callerSnap.exists),
          calleePresent: Boolean(calleeSnap && calleeSnap.exists),
          alreadyLoaded: true,
        });
        const callee = calleeSnap && calleeSnap.exists ? calleeSnap.data() || {} : {};
        const caller =
          callerSnap && callerSnap.exists ? callerSnap.data() || {} : {};
        if (onlyChatModeEnabled(callee)) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "self_only_chat_mode"
          );
        }
        if (onlyChatModeEnabled(caller)) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "peer_only_chat_mode"
          );
        }

        acceptStage = "accepted_write_begin";
        logEvent("accepted_write_begin", {
          callId,
        });
        const acceptedWriteStartMs = timingNowMs();
        tx.update(callRef, {
          status: "accepted",
          acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
          acceptedAtMs: nowMs,
          startedAtMs: 0,
          billableStartedAtMs: 0,
          bothJoinedAtMs: 0,
        });
        logCallTiming("acceptIncomingCall_v1", "accepted_write_scheduled", acceptedWriteStartMs, {
          callId,
          attempt: transactionAttempt,
        });
        acceptStage = "accepted_write_ok";
        logEvent("accepted_write_ok", {
          callId,
        });

        responsePayload = {
          ok: true,
          callId,
          status: "accepted",
          channelId,
          calleeAgoraUid,
          agoraUid: calleeAgoraUid,
          agoraToken: calleeAgoraToken,
        };
        });
        logCallTiming("acceptIncomingCall_v1", "transaction_total", transactionStartMs, {
          callId,
          attempts: transactionAttempt,
        });
      }
    } catch (e) {
      logCallTiming("acceptIncomingCall_v1", "failed_total", functionStartMs, {
        callId,
        stage: acceptStage,
        attempts: transactionAttempt,
        code: strOr(e && e.code, "internal"),
      });
      logEvent("call.accept.failed", {
        callId,
        stage: acceptStage,
        code: strOr(e && e.code, "internal"),
        errorName: strOr(e && e.name, "Error"),
        errorMessage: sanitizeErrorMessageForLog(e && e.message),
      });
      throw e;
    }

    logEvent("call.accept.result", {
      callId,
      status: responsePayload && responsePayload.status,
      alreadyAccepted: Boolean(responsePayload && responsePayload.alreadyAccepted),
      alreadyFinal: Boolean(responsePayload && responsePayload.alreadyFinal),
      alreadyExpired: Boolean(responsePayload && responsePayload.alreadyExpired),
    });
    logEvent("accept_return_success", {
      callId,
      status: responsePayload && responsePayload.status,
      tokenPresent: Boolean(responsePayload && responsePayload.agoraToken),
      agoraUidPresent: intOr(responsePayload && responsePayload.agoraUid, 0) > 0,
    });
    logFunctionTrace("acceptIncomingCall_v1", "success", data, {
      callId,
      status: responsePayload && responsePayload.status,
      tokenPresent: Boolean(responsePayload && responsePayload.agoraToken),
    });
    logCallTiming("acceptIncomingCall_v1", "success_total", functionStartMs, {
      callId,
      status: responsePayload && responsePayload.status,
      attempts: transactionAttempt,
    });

    return responsePayload;
  });

exports.markCallJoined_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "markCallJoined_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const actorUid = strOr(context.auth.uid).trim();
    const callId = strOr(data && data.callId).trim();
    logFunctionTrace("markCallJoined_v1", "begin", data, {
      callId,
      actorUid: shortLogId(actorUid),
    });
    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const callRef = db.collection("calls").doc(callId);
      const snap = await tx.get(callRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "Call not found");
      }

      const call = snap.data() || {};
      const callerId = strOr(call.callerId);
      const calleeId = strOr(call.calleeId);
      if (actorUid !== callerId && actorUid !== calleeId) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only call participants can mark join state"
        );
      }

      if (strOr(call.status) !== "accepted") {
        responsePayload = {
          ok: true,
          callId,
          status: strOr(call.status),
          ignored: true,
        };
        return;
      }

      const nowMs = currentServerMs();
      const patch = {
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      const isCaller = actorUid === callerId;
      const callerJoinedAtMs = intOr(call.callerJoinedAtMs, 0);
      const calleeJoinedAtMs = intOr(call.calleeJoinedAtMs, 0);
      const nextCallerJoinedAtMs = isCaller && callerJoinedAtMs <= 0
        ? nowMs
        : callerJoinedAtMs;
      const nextCalleeJoinedAtMs = !isCaller && calleeJoinedAtMs <= 0
        ? nowMs
        : calleeJoinedAtMs;

      if (isCaller && callerJoinedAtMs <= 0) {
        patch.callerJoinedAt = admin.firestore.FieldValue.serverTimestamp();
        patch.callerJoinedAtMs = nowMs;
      }
      if (!isCaller && calleeJoinedAtMs <= 0) {
        patch.calleeJoinedAt = admin.firestore.FieldValue.serverTimestamp();
        patch.calleeJoinedAtMs = nowMs;
      }

      const hasBothJoined =
        nextCallerJoinedAtMs > 0 && nextCalleeJoinedAtMs > 0;
      const alreadyBillable =
        intOr(call.billableStartedAtMs, 0) > 0 ||
        intOr(call.bothJoinedAtMs, 0) > 0;

      if (hasBothJoined && !alreadyBillable) {
        patch.bothJoinedAt = admin.firestore.FieldValue.serverTimestamp();
        patch.bothJoinedAtMs = nowMs;
        patch.billableStartedAt = admin.firestore.FieldValue.serverTimestamp();
        patch.billableStartedAtMs = nowMs;
        patch.startedAt = admin.firestore.FieldValue.serverTimestamp();
        patch.startedAtMs = nowMs;
      }

      tx.set(callRef, patch, { merge: true });

      responsePayload = {
        ok: true,
        callId,
        status: "accepted",
        callerJoined: nextCallerJoinedAtMs > 0,
        calleeJoined: nextCalleeJoinedAtMs > 0,
        billableStarted: hasBothJoined || alreadyBillable,
      };
    });

    logEvent("call.join.marked", {
      callId,
      actorUid: shortLogId(actorUid),
      billableStarted: Boolean(
        responsePayload && responsePayload.billableStarted
      ),
    });

    return responsePayload;
  });

exports.rejectIncomingCall_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "rejectIncomingCall_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const actorUid = strOr(context.auth.uid).trim();
    const callId = strOr(data && data.callId).trim();
    const rejectedReason = strOr(data && data.rejectedReason).trim();
    logFunctionTrace("rejectIncomingCall_v1", "begin", data, {
      callId,
      actorUid: shortLogId(actorUid),
      reason: rejectedReason || "rejected",
    });
    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    logEvent("call.reject.request", {
      callId,
      actorUid: shortLogId(actorUid),
      reason: rejectedReason || "rejected",
    });

    const db = admin.firestore();
    let responsePayload = null;
    const functionStartMs = timingNowMs();
    let transactionAttempt = 0;

    await db.runTransaction(async (tx) => {
      transactionAttempt += 1;
      const callLoadStartMs = timingNowMs();
      const transition = await getCallForTransitionTx({
        tx,
        db,
        callId,
        actorUid,
      });
      const { callRef, calleeId, status } = transition;
      const call = transition.call || {};
      logCallTiming("rejectIncomingCall_v1", "call_load", callLoadStartMs, {
        callId,
        attempt: transactionAttempt,
        status,
      });

      const authError = rejectIncomingAuthorizationError({
        actorUid,
        calleeId,
      });
      if (authError) {
        throw new functions.https.HttpsError(
          authError.code,
          authError.message
        );
      }

      if (status === "rejected") {
        responsePayload = {
          ok: true,
          callId,
          status: "rejected",
          alreadyRejected: true,
        };
        return;
      }

      if (status === "ended") {
        responsePayload = {
          ok: true,
          callId,
          status: "ended",
          alreadyFinal: true,
        };
        return;
      }

      if (status !== "ringing") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only ringing calls can be rejected"
        );
      }

      const rawRejectedReason = rejectedReason || "rejected";
      const endedReason = normalizedRejectedEndedReason(rawRejectedReason);
      const busyLockCleanupStartMs = timingNowMs();
      await clearParticipantBusyLocksTx(tx, {
        db,
        callId,
        callerId: call.callerId,
        calleeId,
      });
      logCallTiming("rejectIncomingCall_v1", "busy_lock_cleanup", busyLockCleanupStartMs, {
        callId,
        attempt: transactionAttempt,
      });

      const rejectedWriteStartMs = timingNowMs();
      tx.update(callRef, {
        status: "rejected",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endedAtMs: currentServerMs(),
        endedSeconds: 0,
        endedBy: actorUid,
        rejectedReason: rawRejectedReason,
        endedReason,
        endReasonCode: rawRejectedReason,
        missedBy: endedReason === "missed" ? calleeId : "",
      });
      logCallTiming("rejectIncomingCall_v1", "rejected_write_scheduled", rejectedWriteStartMs, {
        callId,
        attempt: transactionAttempt,
      });

      responsePayload = {
        ok: true,
        callId,
        status: "rejected",
      };
    });
    logCallTiming("rejectIncomingCall_v1", "success_total", functionStartMs, {
      callId,
      attempts: transactionAttempt,
      status: responsePayload && responsePayload.status,
    });

    logEvent("call.reject.result", {
      callId,
      status: responsePayload && responsePayload.status,
      alreadyRejected: Boolean(responsePayload && responsePayload.alreadyRejected),
      alreadyFinal: Boolean(responsePayload && responsePayload.alreadyFinal),
    });
    logFunctionTrace("rejectIncomingCall_v1", "success", data, {
      callId,
      status: responsePayload && responsePayload.status,
      alreadyFinal: Boolean(responsePayload && responsePayload.alreadyFinal),
    });

    return responsePayload;
  });

exports.cancelOutgoingCall_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "cancelOutgoingCall_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const actorUid = strOr(context.auth.uid).trim();
    const callId = strOr(data && data.callId).trim();
    const reason = strOr(data && data.reason).trim();
    logFunctionTrace("cancelOutgoingCall_v1", "begin", data, {
      callId,
      actorUid: shortLogId(actorUid),
      reason: reason || "caller_cancelled",
    });
    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    logEvent("call.cancel.request", {
      callId,
      actorUid: shortLogId(actorUid),
      reason: reason || "caller_cancelled",
    });

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const transition = await getCallForTransitionTx({
        tx,
        db,
        callId,
        actorUid,
      });
      const { callRef, callerId, status } = transition;
      const call = transition.call || {};

      if (callerId !== actorUid) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only caller can cancel this ringing call"
        );
      }

      if (status === "ended") {
        responsePayload = {
          ok: true,
          callId,
          status: "ended",
          alreadyEnded: true,
        };
        return;
      }

      if (status === "rejected") {
        responsePayload = {
          ok: true,
          callId,
          status: "rejected",
          alreadyFinal: true,
        };
        return;
      }

      if (status !== "ringing") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only ringing calls can be cancelled"
        );
      }

      await clearParticipantBusyLocksTx(tx, {
        db,
        callId,
        callerId,
        calleeId: call.calleeId,
      });

      tx.update(callRef, {
        status: "ended",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endedAtMs: currentServerMs(),
        endedReason: reason || "caller_cancelled",
        endedBy: actorUid,
        endedSeconds: 0,
      });

      responsePayload = {
        ok: true,
        callId,
        status: "ended",
      };
    });

    logEvent("call.cancel.result", {
      callId,
      status: responsePayload && responsePayload.status,
      alreadyEnded: Boolean(responsePayload && responsePayload.alreadyEnded),
      alreadyFinal: Boolean(responsePayload && responsePayload.alreadyFinal),
    });
    logFunctionTrace("cancelOutgoingCall_v1", "success", data, {
      callId,
      status: responsePayload && responsePayload.status,
      alreadyFinal: Boolean(responsePayload && responsePayload.alreadyFinal),
    });

    return responsePayload;
  });

exports.endCallAuthoritative_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "endCallAuthoritative_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const actorUid = strOr(context.auth.uid).trim();
    const callId = strOr(data && data.callId).trim();
    const reason = strOr(data && data.reason).trim();
    const endedSeconds = Math.max(0, intOr(data && data.endedSeconds, 0));
    const functionStartMs = timingNowMs();
    let endStage = "end_begin";
    logFunctionTrace("endCallAuthoritative_v1", "begin", data, {
      callId,
      actorUid: shortLogId(actorUid),
      reason: reason || "user_end",
      endedSeconds,
    });
    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    logEvent("call.end.request", {
      callId,
      actorUid: shortLogId(actorUid),
      reason: reason || "user_end",
      endedSeconds,
    });

    const db = admin.firestore();
    let responsePayload = null;
    let transactionAttempt = 0;

    try {
      const transactionStartMs = timingNowMs();
      await db.runTransaction(async (tx) => {
        transactionAttempt += 1;
        endStage = "call_loaded";
        const callLoadStartMs = timingNowMs();
        const { callRef, status, call } = await getCallForTransitionTx({
          tx,
          db,
          callId,
          actorUid,
        });
        logCallTiming("endCallAuthoritative_v1", "call_load", callLoadStartMs, {
          callId,
          attempt: transactionAttempt,
          status,
        });

        if (status === "ended") {
          responsePayload = {
            ok: true,
            callId,
            status: "ended",
            alreadyEnded: true,
            endedSeconds: intOr(call.endedSeconds, endedSeconds),
          };
          endStage = "end_return_success";
          return;
        }

        if (status === "rejected") {
          responsePayload = {
            ok: true,
            callId,
            status: "rejected",
            alreadyFinal: true,
            endedSeconds: 0,
          };
          endStage = "end_return_success";
          return;
        }

        if (status !== "accepted" && status !== "ringing") {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Only live calls can be ended"
          );
        }

        endStage = "ended_write_begin";
        await clearParticipantBusyLocksTx(tx, {
          db,
          callId,
          callerId: call.callerId,
          calleeId: call.calleeId,
        });
        const endedWriteStartMs = timingNowMs();
        tx.update(callRef, {
          status: "ended",
          endedAt: admin.firestore.FieldValue.serverTimestamp(),
          endedAtMs: currentServerMs(),
          endedReason: reason || "user_end",
          endedBy: actorUid,
          endedSeconds: status === "accepted" ? endedSeconds : 0,
        });
        logCallTiming("endCallAuthoritative_v1", "ended_write_scheduled", endedWriteStartMs, {
          callId,
          attempt: transactionAttempt,
        });

        responsePayload = {
          ok: true,
          callId,
          status: "ended",
          endedSeconds: status === "accepted" ? endedSeconds : 0,
        };
        endStage = "end_return_success";
      });
      logCallTiming("endCallAuthoritative_v1", "transaction_total", transactionStartMs, {
        callId,
        attempts: transactionAttempt,
      });
    } catch (e) {
      logCallTiming("endCallAuthoritative_v1", "failed_total", functionStartMs, {
        callId,
        stage: endStage,
        attempts: transactionAttempt,
        code: strOr(e && e.code, "internal"),
      });
      throw e;
    }

    logEvent("call.end.result", {
      callId,
      status: responsePayload && responsePayload.status,
      alreadyEnded: Boolean(responsePayload && responsePayload.alreadyEnded),
      alreadyFinal: Boolean(responsePayload && responsePayload.alreadyFinal),
      endedSeconds: responsePayload && responsePayload.endedSeconds,
    });
    logFunctionTrace("endCallAuthoritative_v1", "success", data, {
      callId,
      status: responsePayload && responsePayload.status,
      endedSeconds: responsePayload && responsePayload.endedSeconds,
    });
    logCallTiming("endCallAuthoritative_v1", "success_total", functionStartMs, {
      callId,
      status: responsePayload && responsePayload.status,
      attempts: transactionAttempt,
    });

    return responsePayload;
  });

exports.startCall_v2 = functions
  .region(REGION)
  .runWith({ secrets: ["AGORA_APP_ID", "AGORA_APP_CERTIFICATE"] })
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "startCall_v2");
    
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const callerId = strOr(context.auth.uid).trim();
    const listenerId = strOr(data && data.listenerId).trim();
    const functionStartMs = timingNowMs();
    let startStage = "start_call_begin";

    logFunctionTrace("startCall_v2", "begin", data, {
      callerId: shortLogId(callerId),
      listenerId: shortLogId(listenerId),
    });
    logEvent("start_call_begin", {
      callerId: shortLogId(callerId),
      listenerId: shortLogId(listenerId),
    });
    startStage = "auth_ok";
    logEvent("auth_ok", {
      callerId: shortLogId(callerId),
    });

    if (!listenerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "listenerId required"
      );
    }

    if (listenerId === callerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Cannot call yourself"
      );
    }
    startStage = "input_validated";
    logEvent("input_validated", {
      callerId: shortLogId(callerId),
      listenerId: shortLogId(listenerId),
    });

    logEvent("call.start.request", {
      callerId: shortLogId(callerId),
      listenerId: shortLogId(listenerId),
    });

    const db = admin.firestore();
    const users = db.collection("users");
    const calls = db.collection("calls");
    const rateLimits = db.collection("rate_limits");

    const callerRef = users.doc(callerId);
    const listenerRef = users.doc(listenerId);
    const limiterRef = rateLimits.doc(callerId);

    const nowMs = Date.now();
    const callRef = calls.doc();
    const channelId = generateAgoraChannelId();

    const mKey = minuteKey(nowMs);
    const hKey = hourKey(nowMs);
    let startLogReservedUpfront = 0;
    let startLogMaxPrepaidMinutes = 0;
    let startLogChatId = "";
    let callerAgoraTokenForResponse = "";
    let callerAgoraUid = 0;
    let calleeAgoraUid = 0;
    let transactionAttempt = 0;

    try {
      const preTransactionStartMs = timingNowMs();
      startStage = "agora_config_check";
      assertAgoraTokenConfigReady();

      const builtAgoraUids = buildDistinctAgoraUids({
        callerId,
        listenerId,
        channelId,
      });
      callerAgoraUid = builtAgoraUids.callerAgoraUid;
      calleeAgoraUid = builtAgoraUids.calleeAgoraUid;
      logCallTiming("startCall_v2", "pre_transaction", preTransactionStartMs, {
        callId: callRef.id,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
      });

      const transactionStartMs = timingNowMs();
      await db.runTransaction(async (tx) => {
      transactionAttempt += 1;
      startStage = "speaker_listener_loaded";
      const profileReadStartMs = timingNowMs();
      const [callerSnap, listenerSnap, limiterSnap] = await tx.getAll(
        callerRef,
        listenerRef,
        limiterRef
      );
      logCallTiming("startCall_v2", "profile_and_limiter_read", profileReadStartMs, {
        callId: callRef.id,
        attempt: transactionAttempt,
        callerPresent: callerSnap.exists,
        listenerPresent: listenerSnap.exists,
        limiterPresent: limiterSnap.exists,
      });

      if (!callerSnap.exists) {
        throw startCallPrecondition(
          "unknown_precondition",
          "Caller profile missing"
        );
      }

      if (!listenerSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Listener not found");
      }

      const caller = callerSnap.data() || {};
      const listener = listenerSnap.data() || {};
      logEvent("speaker_listener_loaded", {
        callId: callRef.id,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
      });

      logEvent("call.start.eligibility_begin", {
        callId: callRef.id,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
      });
      const eligibilityError = startCallEligibilityError({
        caller,
        listener,
      });
      if (eligibilityError) {
        throw callHttpsError(
          eligibilityError.code,
          eligibilityError.reason || "unknown_precondition",
          eligibilityError.message
        );
      }
      logEvent("call.start.eligibility_success", {
        callId: callRef.id,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
      });

      if (caller.adminBlocked === true) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Your account is blocked"
        );
      }

      const callerBlocked = Array.isArray(caller.blocked) ? caller.blocked : [];
      const listenerBlocked = Array.isArray(listener.blocked)
        ? listener.blocked
        : [];

      if (callerBlocked.includes(listenerId)) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "You blocked this listener"
        );
      }

      if (listenerBlocked.includes(callerId)) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Listener blocked you"
        );
      }

      startStage = "chat_gate_begin";
      logEvent("call.start.chat_gate_begin", {
        callId: callRef.id,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
      });
      logEvent("chat_gate_begin", {
        callId: callRef.id,
      });
      const chatGateStartMs = timingNowMs();
      const chatGate = await assertCanonicalChatAllowsCallTx({
        tx,
        db,
        speakerId: callerId,
        listenerId,
      });
      logCallTiming("startCall_v2", "chat_gate", chatGateStartMs, {
        callId: callRef.id,
        attempt: transactionAttempt,
        chatId: chatGate.canonicalChatSessionId,
      });
      logEvent("call.start.chat_gate_success", {
        callId: callRef.id,
        chatId: chatGate.canonicalChatSessionId,
      });
      logEvent("chat_gate_ok", {
        callId: callRef.id,
        chatId: chatGate.canonicalChatSessionId,
      });

      startStage = "active_call_check_begin";
      logEvent("call.start.active_call_check_begin", {
        callId: callRef.id,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
      });
      logEvent("active_call_check_begin", {
        callId: callRef.id,
      });
      const trackedActiveCheckStartMs = timingNowMs();
      const callerTrackedLiveCallId = await verifyTrackedActiveCallTx({
        tx,
        db,
        userRef: callerRef,
        userId: callerId,
        user: caller,
      });
      if (callerTrackedLiveCallId) {
        throw startCallPrecondition(
          "active_call_exists",
          "You already have an active call"
        );
      }

      const listenerTrackedLiveCallId = await verifyTrackedActiveCallTx({
        tx,
        db,
        userRef: listenerRef,
        userId: listenerId,
        user: listener,
      });
      if (listenerTrackedLiveCallId) {
        throw startCallPrecondition("peer_busy", "Listener is busy");
      }
      logCallTiming("startCall_v2", "tracked_active_call_check", trackedActiveCheckStartMs, {
        callId: callRef.id,
        attempt: transactionAttempt,
      });
      logEvent("call.start.active_call_check_success", {
        callId: callRef.id,
      });
      logEvent("active_call_check_ok", {
        callId: callRef.id,
      });

      const lim = limiterSnap.exists ? limiterSnap.data() || {} : {};
      const limMinuteKey = strOr(lim.minuteKey);
      const limHourKey = strOr(lim.hourKey);

      const minuteCount = intOr(
        limMinuteKey === mKey ? lim.minuteCount : 0,
        0
      );
      const hourCount = intOr(limHourKey === hKey ? lim.hourCount : 0, 0);

      if (minuteCount >= MAX_CALLS_PER_MINUTE) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          "Too many call attempts. Please wait a minute."
        );
      }

      if (hourCount >= MAX_CALLS_PER_HOUR) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          "Too many call attempts. Please try later."
        );
      }

      const liveCallScanStartMs = timingNowMs();
      const liveCallScanTasks = [];
      if (shouldRunLiveCallFallbackScan(caller)) {
        liveCallScanTasks.push(assertNoLiveCallForUser({
          db,
          uid: callerId,
          errorMessage: "You already have an active call",
          reason: "active_call_exists",
        }));
      }
      if (shouldRunLiveCallFallbackScan(listener)) {
        liveCallScanTasks.push(assertNoLiveCallForUser({
          db,
          uid: listenerId,
          errorMessage: "Listener is busy",
          reason: "peer_busy",
        }));
      }
      if (liveCallScanTasks.length > 0) {
        await Promise.all(liveCallScanTasks);
      }
      logCallTiming("startCall_v2", "live_call_scan", liveCallScanStartMs, {
        callId: callRef.id,
        attempt: transactionAttempt,
        scanCount: liveCallScanTasks.length,
        skipped: liveCallScanTasks.length === 0,
      });

      const listenerFollowers = intOr(listener.followersCount, 0);
      const visibleRate = sanitizeListenerRateForFollowers(
        intOr(listener.listenerRate, 5),
        listenerFollowers
      );
      const listenerRate = payoutFromVisibleRate(
        visibleRate,
        PLATFORM_PERCENT
      );

      startStage = "wallet_reserve_begin";
      logEvent("call.start.wallet_reserve_begin", {
        callId: callRef.id,
        visibleRate,
      });
      logEvent("wallet_reserve_begin", {
        callId: callRef.id,
        visibleRate,
      });
      const reserved = intOr(caller.reservedCredits, 0);
      const available = availableCreditsForCalls(caller);

      const maxPrepaidMinutes = Math.floor(available / visibleRate);
      const reservedUpfront = maxPrepaidMinutes * visibleRate;
      startLogReservedUpfront = reservedUpfront;
      startLogMaxPrepaidMinutes = maxPrepaidMinutes;
      startLogChatId = chatGate.canonicalChatSessionId;

      if (maxPrepaidMinutes < 1 || reservedUpfront < visibleRate) {
        throw startCallPrecondition(
          "insufficient_credits",
          "insufficient_credits",
          {requiredCredits: visibleRate}
        );
      }
      logEvent("call.start.wallet_reserve_success", {
        callId: callRef.id,
        reservedUpfront,
        maxPrepaidMinutes,
      });
      logEvent("wallet_reserve_ok", {
        callId: callRef.id,
        reservedUpfront,
        maxPrepaidMinutes,
      });

      const callerName = strOr(caller.displayName, "Friendify User");
      const listenerName = strOr(listener.displayName, "Listener");
      const notificationParticipantIds = normalizeParticipantIds(
        chatGate.chat.participantIds,
        [callerId, listenerId]
      );
      const notificationPairKey =
        strOr(chatGate.chat.pairKey) || chatGate.canonicalChatSessionId;
      const notificationPairUserA =
        strOr(chatGate.chat.pairUserA) || notificationParticipantIds[0] || "";
      const notificationPairUserB =
        strOr(chatGate.chat.pairUserB) || notificationParticipantIds[1] || "";

      startStage = "agora_token_build_begin";
      logEvent("call.start.token_build_begin", {
        callId: callRef.id,
        callerAgoraUid,
        calleeAgoraUid,
      });
      logEvent("agora_token_build_begin", {
        callId: callRef.id,
        callerAgoraUid,
        calleeAgoraUid,
      });
      const tokenBuildStartMs = timingNowMs();
      const agoraTokenCaller = buildAgoraTokenOrThrow({
        channelId,
        uidInt: callerAgoraUid,
        expireSeconds: 3600,
      });
      callerAgoraTokenForResponse = agoraTokenCaller;

      const agoraTokenCallee = buildAgoraTokenOrThrow({
        channelId,
        uidInt: calleeAgoraUid,
        expireSeconds: 3600,
      });
      logCallTiming("startCall_v2", "agora_token_build", tokenBuildStartMs, {
        callId: callRef.id,
        attempt: transactionAttempt,
        callerAgoraUid,
        calleeAgoraUid,
      });
      logEvent("call.start.token_build_success", {
        callId: callRef.id,
        callerAgoraUid,
        calleeAgoraUid,
      });
      logEvent("agora_token_build_ok", {
        callId: callRef.id,
        callerAgoraUid,
        calleeAgoraUid,
      });

      const callerTokenRef = callRef.collection("participantTokens").doc(callerId);
      const calleeTokenRef = callRef.collection("participantTokens").doc(listenerId);

      startStage = "call_doc_write_begin";
      const writeScheduleStartMs = timingNowMs();
      tx.update(callerRef, {
        reservedCredits: reserved + reservedUpfront,
        activeCallId: callRef.id,
        isOnCall: true,
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.update(listenerRef, {
        activeCallId: callRef.id,
        isOnCall: true,
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(
        limiterRef,
        {
          minuteKey: mKey,
          minuteCount: minuteCount + 1,
          hourKey: hKey,
          hourCount: hourCount + 1,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      tx.set(
        callerTokenRef,
        buildParticipantTokenDoc({
          userId: callerId,
          channelId,
          agoraUid: callerAgoraUid,
          agoraToken: agoraTokenCaller,
          nowMs,
        })
      );

      tx.set(
        calleeTokenRef,
        buildParticipantTokenDoc({
          userId: listenerId,
          channelId,
          agoraUid: calleeAgoraUid,
          agoraToken: agoraTokenCallee,
          nowMs,
        })
      );

      logEvent("call_doc_write_begin", {
        callId: callRef.id,
      });
      tx.set(callRef, {
        callerId,
        callerName,
        calleeId: listenerId,
        calleeName: listenerName,
        channelId,
        callerAgoraUid,
        calleeAgoraUid,
        status: "ringing",
        speakerRate: visibleRate,
        listenerRate,
        platformPercent: PLATFORM_PERCENT,
        reservedUpfront,
        maxPrepaidMinutes,
        startedAtMs: 0,
        prepaidEndsAtMs: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: nowMs,
        expiresAtMs: nowMs + RINGING_TIMEOUT_SECONDS * 1000,
        reserveReleased: false,
        settled: false,
        listenerCredited: false,
        missedCallPushSent: false,
        incomingPushAttempted: false,
        incomingPushDelivered: false,
        settlementVersion: 2,
        settlementSource: "server",
        currency: "INR",
        chatSessionId: chatGate.canonicalChatSessionId,
        pairKey: notificationPairKey,
        pairUserA: notificationPairUserA,
        pairUserB: notificationPairUserB,
        participantIds: notificationParticipantIds,
        actualListenerId: listenerId,
        requesterId: callerId,
        responderId: listenerId,
        pendingFor: "",
        actionOwner: "",
      });
      logEvent("call.start.call_doc_write_success", {
        callId: callRef.id,
        channelReady: true,
        callerAgoraUid,
        calleeAgoraUid,
      });
      logEvent("call_doc_write_ok", {
        callId: callRef.id,
        channelReady: true,
        callerAgoraUid,
        calleeAgoraUid,
      });

      tx.set(
        chatGate.chatRef,
        {
          status: "accepted",
          callAllowed: false,
          callRequestOpen: false,
          callRequestedBy: "",
          requesterId: "",
          responderId: "",
          pendingFor: "",
          actionOwner: "",
          callAllowedAt: null,
          callAllowedAtMs: 0,
          callRequestAt: null,
          callRequestAtMs: 0,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAtMs: nowMs,
        },
        { merge: true }
      );
      logCallTiming("startCall_v2", "transaction_writes_scheduled", writeScheduleStartMs, {
        callId: callRef.id,
        attempt: transactionAttempt,
      });
      });
      logCallTiming("startCall_v2", "transaction_total", transactionStartMs, {
        callId: callRef.id,
        attempts: transactionAttempt,
      });
    } catch (e) {
      const safeCode = strOr(e && e.code, "internal");
      const safeReason = strOr(e && e.details && e.details.reason).trim();
      logCallTiming("startCall_v2", "failed_total", functionStartMs, {
        callId: callRef.id,
        stage: startStage,
        attempts: transactionAttempt,
        code: safeCode,
        ...(safeReason ? {failureReason: safeReason} : {}),
      });
      logFunctionTrace("startCall_v2", "failed", data, {
        callId: callRef.id,
        stage: startStage,
        code: safeCode,
        ...(safeReason ? {failureReason: safeReason} : {}),
      });
      logEvent("call.start.failed", {
        callId: callRef.id,
        stage: startStage,
        callerId: shortLogId(callerId),
        listenerId: shortLogId(listenerId),
        code: safeCode,
        ...(safeReason ? {failureReason: safeReason} : {}),
        errorName: strOr(e && e.name, "Error"),
        errorMessage: sanitizeErrorMessageForLog(e && e.message),
      });
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      throw new functions.https.HttpsError(
        "internal",
        "Call start failed. Please try again.",
        {
          reason: "start_call_internal",
          stage: startStage,
          category: strOr(e && e.name, "Error"),
          callId: callRef.id,
        }
      );
    }

    logEvent("call.start.created", {
      callId: callRef.id,
      callerId: shortLogId(callerId),
      listenerId: shortLogId(listenerId),
      chatId: startLogChatId,
      reservedUpfront: startLogReservedUpfront,
      maxPrepaidMinutes: startLogMaxPrepaidMinutes,
    });
    logEvent("call.start.return_success", {
      callId: callRef.id,
      channelReady: true,
      callerAgoraUid,
      calleeAgoraUid,
      tokenPresent: !!callerAgoraTokenForResponse,
    });
    logEvent("start_call_return_success", {
      callId: callRef.id,
      channelReady: true,
      callerAgoraUid,
      calleeAgoraUid,
      tokenPresent: !!callerAgoraTokenForResponse,
    });
    logFunctionTrace("startCall_v2", "success", data, {
      callId: callRef.id,
      channelReady: true,
      tokenPresent: !!callerAgoraTokenForResponse,
    });
    logCallTiming("startCall_v2", "success_total", functionStartMs, {
      callId: callRef.id,
      attempts: transactionAttempt,
      reservedUpfront: startLogReservedUpfront,
      maxPrepaidMinutes: startLogMaxPrepaidMinutes,
    });

    return {
      callId: callRef.id,
      channelId,
      callerAgoraUid,
      calleeAgoraUid,
      agoraUid: callerAgoraUid,
      agoraToken: callerAgoraTokenForResponse,
    };
  });

exports.releaseReserve_v2 = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onUpdate(async (change) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const oldStatus = strOr(before.status);
    const newStatus = strOr(after.status);

    if (after.reserveReleased === true) return null;

    const callerId = strOr(after.callerId);
    const reservedUpfront = intOr(after.reservedUpfront, 0);

    if (!callerId || reservedUpfront <= 0) return null;

    const shouldRelease =
      oldStatus === "ringing" &&
      (newStatus === "rejected" || newStatus === "ended");

    if (!shouldRelease) return null;
    if (after.startedAt) return null;

    const db = admin.firestore();
    const callerRef = db.collection("users").doc(callerId);
    const callRef = change.after.ref;

    await db.runTransaction(async (tx) => {
      const [callerSnap, callSnap] = await Promise.all([
        tx.get(callerRef),
        tx.get(callRef),
      ]);

      const callNow = callSnap.data() || {};
      if (callNow.reserveReleased === true) return;

      const caller = callerSnap.data() || {};
      const reserved = intOr(caller.reservedCredits, 0);
      const currentReservedUpfront = intOr(
        callNow.reservedUpfront,
        reservedUpfront
      );
      const newReserved = Math.max(0, reserved - currentReservedUpfront);

      tx.update(callerRef, {
        reservedCredits: newReserved,
        activeCallId:
          strOr(caller.activeCallId).trim() === callRef.id
            ? ""
            : strOr(caller.activeCallId).trim(),
        isOnCall:
          strOr(caller.activeCallId).trim() === callRef.id
            ? false
            : boolOr(caller.isOnCall, false),
        activeCallUpdatedAt:
          strOr(caller.activeCallId).trim() === callRef.id
            ? admin.firestore.FieldValue.serverTimestamp()
            : caller.activeCallUpdatedAt ||
              admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.update(callRef, {
        reserveReleased: true,
        reserveReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    logEvent("wallet.reserve.release", {
      callId: callRef.id,
      callerId: shortLogId(callerId),
      oldStatus,
      newStatus,
      amount: reservedUpfront,
    });

    return null;
  });

exports.markAcceptedPrepaidWindow_v2 = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onUpdate(async (change) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    if (
      strOr(before.status) === strOr(after.status) &&
      intOr(after.prepaidEndsAtMs, 0) > 0
    ) {
      return null;
    }

    const beforeBillableStartedAtMs =
      intOr(before.billableStartedAtMs, 0) ||
      intOr(before.bothJoinedAtMs, 0) ||
      timestampToMs(before.billableStartedAt) ||
      timestampToMs(before.bothJoinedAt) ||
      intOr(before.startedAtMs, 0) ||
      timestampToMs(before.startedAt);
    const afterBillableStartedAtMs =
      intOr(after.billableStartedAtMs, 0) ||
      intOr(after.bothJoinedAtMs, 0) ||
      timestampToMs(after.billableStartedAt) ||
      timestampToMs(after.bothJoinedAt) ||
      intOr(after.startedAtMs, 0) ||
      timestampToMs(after.startedAt);

    if (
      strOr(after.status) !== "accepted" ||
      beforeBillableStartedAtMs > 0 ||
      afterBillableStartedAtMs <= 0
    ) {
      return null;
    }

    const maxPrepaidMinutes = intOr(after.maxPrepaidMinutes, 0);

    if (maxPrepaidMinutes <= 0) return null;

    const prepaidEndsAtMs =
      afterBillableStartedAtMs + maxPrepaidMinutes * 60 * 1000;
    if (intOr(after.prepaidEndsAtMs, 0) === prepaidEndsAtMs) return null;

    const patch = {
      prepaidEndsAtMs,
    };
    if (intOr(after.startedAtMs, 0) !== afterBillableStartedAtMs) {
      patch.startedAtMs = afterBillableStartedAtMs;
    }

    await change.after.ref.set(patch, { merge: true });

    return null;
  });

exports.cleanupAcceptedCreditLimit_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 1 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    const prepaidWindowClosedBeforeMs = nowMs - PREPAID_END_GRACE_MS;

    await forEachCleanupCallQueryBatch({
      buildQuery: () => db
        .collection("calls")
        .where("status", "==", "accepted")
        .where("prepaidEndsAtMs", ">", 0)
        .where("prepaidEndsAtMs", "<=", prepaidWindowClosedBeforeMs)
        .orderBy("prepaidEndsAtMs", "asc"),
      processDoc: async (doc) => {
        try {
          await endAcceptedCallIfStillAccepted({
            db,
            callRef: doc.ref,
            reason: "credit_limit_reached",
            nowMs: currentServerMs(),
            shouldEnd: (callNow) =>
              isAcceptedCreditLimitCleanupCandidate(callNow, currentServerMs()),
          });
        } catch (e) {
          console.log("cleanupAcceptedCreditLimit_v2 error:", doc.ref.id, e);
        }
      },
    });

    await forEachCleanupCallQueryBatch({
      buildQuery: () => db
        .collection("calls")
        .where("status", "==", "accepted")
        .orderBy("createdAtMs", "asc"),
      maxBatchCount: CLEANUP_LEGACY_SCAN_MAX_BATCH_COUNT,
      processDoc: async (doc) => {
        const call = doc.data() || {};
        const needsLegacyCleanup =
          intOr(call.prepaidEndsAtMs, 0) <= 0 &&
          isAcceptedCreditLimitCleanupCandidate(call, nowMs);
        if (!needsLegacyCleanup) return;

        try {
          await endAcceptedCallIfStillAccepted({
            db,
            callRef: doc.ref,
            reason: "credit_limit_reached",
            nowMs: currentServerMs(),
            shouldEnd: (callNow) =>
              intOr(callNow.prepaidEndsAtMs, 0) <= 0 &&
              isAcceptedCreditLimitCleanupCandidate(callNow, currentServerMs()),
          });
        } catch (e) {
          console.log(
            "cleanupAcceptedCreditLimit_v2 legacy error:",
            doc.ref.id,
            e
          );
        }
      },
    });

    return null;
  });

function isEndedUnsettledRepairCandidate(call = {}) {
  return strOr(call.status) === "ended" && boolOr(call.settled, false) !== true;
}

exports._isEndedUnsettledRepairCandidate = isEndedUnsettledRepairCandidate;

async function settleEndedCallIfNeeded({
  db,
  callRef,
  callId = "",
  source = "server",
}) {
  const safeCallId = strOr(callId || (callRef && callRef.id)).trim();
  const settlementSource = strOr(source, "server").trim() || "server";
  if (!db || !callRef || !safeCallId) return false;

  logEvent("call.settlement.attempt", {
    callId: safeCallId,
    source: settlementSource,
  });

  const settlementLockAcquired = await acquireExecutionLock({
    db,
    lockId: "settle_" + safeCallId,
    lockType: "call_settlement",
    resourceId: safeCallId,
    owner: settlementSource,
    ttlMs: 60000,
  });

  if (!settlementLockAcquired) {
    logEvent("call.settlement.duplicate_blocked", {
      callId: safeCallId,
      source: settlementSource,
    });
    return false;
  }

  let didSettle = false;

  await db.runTransaction(async (tx) => {
    const callSnap = await tx.get(callRef);
    if (!callSnap.exists) return;

    const callNow = callSnap.data() || {};
    if (!isEndedUnsettledRepairCandidate(callNow)) return;

    const callerId = strOr(callNow.callerId);
    const calleeId = strOr(callNow.calleeId);
    const callerName = strOr(callNow.callerName, "Caller");
    const calleeName = strOr(callNow.calleeName, "Listener");

    if (!callerId || !calleeId) return;

    const speakerRate = intOr(callNow.speakerRate, 5);
    const listenerRate = intOr(callNow.listenerRate, 4);
    const reservedUpfront = intOr(callNow.reservedUpfront, speakerRate);
    const maxPrepaidMinutes = intOr(callNow.maxPrepaidMinutes, 0);

    const seconds = computeFinalSeconds(callNow);
    const rawBilledMinutes =
      seconds >= BILLING_GRACE_SECONDS ? Math.floor(seconds / 60) : 0;
    const billedMinutes = maxPrepaidMinutes > 0
      ? Math.min(rawBilledMinutes, maxPrepaidMinutes)
      : rawBilledMinutes;

    const users = db.collection("users");
    const platformSummaryRef = db.collection("system").doc("finance_summary");

    const callerRef = users.doc(callerId);
    const calleeRef = users.doc(calleeId);
    const callerChargeTxRef = walletTxRef(
      db,
      buildCallChargeTxId(safeCallId, callerId)
    );
    const listenerEarnTxRef = walletTxRef(
      db,
      buildCallEarningTxId(safeCallId, calleeId)
    );

    const [
      callerSnap,
      calleeSnap,
      callerChargeTxSnap,
      listenerEarnTxSnap,
      platformSummarySnap,
    ] = await Promise.all([
      tx.get(callerRef),
      tx.get(calleeRef),
      tx.get(callerChargeTxRef),
      tx.get(listenerEarnTxRef),
      tx.get(platformSummaryRef),
    ]);

    const caller = callerSnap.data() || {};
    const callee = calleeSnap.data() || {};
    const platformSummary = platformSummarySnap.exists
      ? platformSummarySnap.data() || {}
      : {};

    const credits = intOr(caller.credits, 0);
    const reserved = intOr(caller.reservedCredits, 0);
    const settlement = computeSettlementAmounts({
      billedMinutes,
      speakerRate,
      listenerRate,
      currentCredits: credits,
      currentReservedCredits: reserved,
      reservedUpfront,
      reserveAlreadyReleased: boolOr(callNow.reserveReleased, false),
    });
    const reserveReleasedAfterSettlement =
      boolOr(callNow.reserveReleased, false) ||
      reservedUpfront <= 0 ||
      settlement.shouldReleaseReserve;

    tx.update(callerRef, {
      credits: settlement.newCredits,
      reservedCredits: settlement.newReserved,
      activeCallId:
        strOr(caller.activeCallId).trim() === safeCallId
          ? ""
          : strOr(caller.activeCallId).trim(),
      isOnCall:
        strOr(caller.activeCallId).trim() === safeCallId
          ? false
          : boolOr(caller.isOnCall, false),
      activeCallUpdatedAt:
        strOr(caller.activeCallId).trim() === safeCallId
          ? admin.firestore.FieldValue.serverTimestamp()
          : caller.activeCallUpdatedAt ||
            admin.firestore.FieldValue.serverTimestamp(),
      lastSeen: admin.firestore.FieldValue.serverTimestamp(),
    });

    if (settlement.safeListenerPayout > 0) {
      const calleeCredits = intOr(callee.credits, 0);
      const calleeEarn = intOr(callee.earningsCredits, 0);
      const newCalleeCredits = calleeCredits + settlement.safeListenerPayout;
      const newCalleeEarn = calleeEarn + settlement.safeListenerPayout;

      tx.update(calleeRef, {
        credits: newCalleeCredits,
        earningsCredits: newCalleeEarn,
        activeCallId:
          strOr(callee.activeCallId).trim() === safeCallId
            ? ""
            : strOr(callee.activeCallId).trim(),
        isOnCall:
          strOr(callee.activeCallId).trim() === safeCallId
            ? false
            : boolOr(callee.isOnCall, false),
        activeCallUpdatedAt:
          strOr(callee.activeCallId).trim() === safeCallId
            ? admin.firestore.FieldValue.serverTimestamp()
            : callee.activeCallUpdatedAt ||
              admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      if (!listenerEarnTxSnap.exists) {
        tx.set(
          listenerEarnTxRef,
          createWalletTxDoc({
            userId: calleeId,
            type: "call_earning",
            amount: settlement.safeListenerPayout,
            balanceAfter: newCalleeCredits,
            callId: safeCallId,
            status: "completed",
            method: "system",
            notes: "Earned from call with " + callerName,
            source: "settlement",
            currency: "INR",
            direction: "credit",
            idempotencyKey: buildCallEarningTxId(safeCallId, calleeId),
            metadata: {
              callId: safeCallId,
              settlementVersion: 2,
            },
          })
        );
      }
    } else {
      tx.update(calleeRef, {
        activeCallId:
          strOr(callee.activeCallId).trim() === safeCallId
            ? ""
            : strOr(callee.activeCallId).trim(),
        isOnCall:
          strOr(callee.activeCallId).trim() === safeCallId
            ? false
            : boolOr(callee.isOnCall, false),
        activeCallUpdatedAt:
          strOr(callee.activeCallId).trim() === safeCallId
            ? admin.firestore.FieldValue.serverTimestamp()
            : callee.activeCallUpdatedAt ||
              admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    if (!callerChargeTxSnap.exists) {
      const callerChargeNotes = settlement.safeSpeakerCharge > 0
        ? "Charged for call with " + calleeName
        : billedMinutes > 0
          ? "No charge collected for call with " + calleeName +
            "; available credits were insufficient"
          : "Free call with " + calleeName + " under " +
            BILLING_GRACE_SECONDS + " seconds";
      tx.set(
        callerChargeTxRef,
        createWalletTxDoc({
          userId: callerId,
          type: "call_charge",
          amount: -settlement.safeSpeakerCharge,
          balanceAfter: settlement.newCredits,
          callId: safeCallId,
          status: "completed",
          method: "system",
          notes: callerChargeNotes,
          source: "settlement",
          currency: "INR",
          direction: "debit",
          idempotencyKey: buildCallChargeTxId(safeCallId, callerId),
          metadata: {
            callId: safeCallId,
            settlementVersion: 2,
          },
        })
      );
    }

    if (settlement.safePlatformProfit > 0) {
      tx.set(
        platformSummaryRef,
        {
          totalPlatformRevenueCredits:
            intOr(platformSummary.totalPlatformRevenueCredits, 0) +
            settlement.safePlatformProfit,
          totalCallRevenueCredits:
            intOr(platformSummary.totalCallRevenueCredits, 0) +
            settlement.safePlatformProfit,
          lastCallRevenueAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }

    tx.update(callRef, {
      seconds,
      endedSeconds: seconds,
      billedMinutes,
      paidMinutes: settlement.safePaidMinutes,
      speakerCharge: settlement.safeSpeakerCharge,
      listenerPayout: settlement.safeListenerPayout,
      platformProfit: settlement.safePlatformProfit,
      settled: true,
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      reserveReleased: reserveReleasedAfterSettlement,
      reserveReleasedAt: reserveReleasedAfterSettlement
        ? callNow.reserveReleasedAt ||
          admin.firestore.FieldValue.serverTimestamp()
        : null,
      listenerCredited: settlement.safeListenerPayout > 0,
      listenerCreditedAt:
        settlement.safeListenerPayout > 0
          ? admin.firestore.FieldValue.serverTimestamp()
          : null,
      settlementVersion: 2,
      settlementIdempotencyKey: "settle_" + safeCallId,
      reserveReleaseIdempotencyKey: "release_" + safeCallId,
      callerChargeTxId: callerChargeTxRef.id,
      listenerPayoutTxId:
        settlement.safeListenerPayout > 0 ? listenerEarnTxRef.id : "",
      currency: "INR",
      settlementSource,
      settlementLastAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
      settlementLastAttemptSource: settlementSource,
      settlementRetryCount: admin.firestore.FieldValue.increment(1),
    });

    didSettle = true;
  });

  logEvent("call.settlement.result", {
    callId: safeCallId,
    source: settlementSource,
    settled: didSettle,
  });

  return didSettle;
}

exports.settleCallBilling_v2 = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const oldStatus = strOr(before.status);
    const newStatus = strOr(after.status);

    if (after.settled === true) return null;
    if (!(oldStatus === "accepted" && newStatus === "ended")) return null;

    await settleEndedCallIfNeeded({
      db: admin.firestore(),
      callRef: change.after.ref,
      callId: context.params.callId,
      source: "server",
    });

    return null;
  });

exports.repairUnsettledEndedCalls_v1 = functions
  .region(REGION)
  .pubsub.schedule("every 5 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();
    const snap = await db
      .collection("calls")
      .where("status", "==", "ended")
      .orderBy("endedAtMs", "asc")
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    for (const doc of snap.docs) {
      const call = doc.data() || {};
      if (!isEndedUnsettledRepairCandidate(call)) continue;

      try {
        await settleEndedCallIfNeeded({
          db,
          callRef: doc.ref,
          callId: doc.id,
          source: "scheduled_repair",
        });
      } catch (e) {
        logError("call.settlement.repair_error", e, {
          callId: doc.id,
          source: "scheduled_repair",
        });
        await doc.ref
          .set(
            {
              settlementError: strOr(
                e && e.message,
                "scheduled repair failed"
              ).slice(0, 500),
              settlementLastFailedAt: admin.firestore.FieldValue.serverTimestamp(),
              settlementLastFailedSource: "scheduled_repair",
              settlementLastAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
              settlementLastAttemptSource: "scheduled_repair",
              settlementRetryCount: admin.firestore.FieldValue.increment(1),
            },
            { merge: true }
          )
          .catch((writeError) => {
            console.log(
              "repairUnsettledEndedCalls_v1 error metadata write failed:",
              doc.id,
              writeError
            );
          });
      }
    }

    return null;
  });

exports.clearBusyLock_v2 = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onUpdate(async (change) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const oldStatus = strOr(before.status);
    const newStatus = strOr(after.status);

    if (oldStatus === newStatus) return null;
    if (!(newStatus === "ended" || newStatus === "rejected")) return null;
    if (callNeedsSettlementCleanup(after)) return null;

    const db = admin.firestore();
    const callRef = change.after.ref;

    await db.runTransaction(async (tx) => {
      const callSnap = await tx.get(callRef);
      const callNow = callSnap.data() || {};
      await safeReleaseReserveAndLockTx(tx, { db, callRef, callData: callNow });
    });

    return null;
  });

exports.cleanupExpiredRingingCalls_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 1 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();
    const nowMs = Date.now();

    await forEachCleanupCallQueryBatch({
      buildQuery: () => db
        .collection("calls")
        .where("status", "==", "ringing")
        .where("expiresAtMs", ">", 0)
        .where("expiresAtMs", "<=", nowMs)
        .orderBy("expiresAtMs", "asc"),
      processDoc: async (doc) => {
        try {
          await endCallAsRejectedIfStillRinging({
            db,
            callRef: doc.ref,
            reason: "server_timeout",
            endedBy: "system",
          });
        } catch (e) {
          console.log("cleanupExpiredRingingCalls_v2 error:", doc.ref.id, e);
        }
      },
    });

    await forEachCleanupCallQueryBatch({
      buildQuery: () => db
        .collection("calls")
        .where("status", "==", "ringing")
        .orderBy("createdAtMs", "asc"),
      maxBatchCount: CLEANUP_LEGACY_SCAN_MAX_BATCH_COUNT,
      processDoc: async (doc) => {
        const call = doc.data() || {};
        if (!isMalformedRingingCleanupCandidate(call)) return;

        try {
          await endCallAsRejectedIfStillRinging({
            db,
            callRef: doc.ref,
            reason: "invalid",
            endedBy: "system",
          });
        } catch (e) {
          console.log(
            "cleanupExpiredRingingCalls_v2 malformed error:",
            doc.ref.id,
            e
          );
        }
      },
    });

    return null;
  });

exports.cleanupStaleAcceptedCalls_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 1 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    const staleBeforeMs = nowMs - 5 * 60 * 1000;

    await forEachCleanupCallQueryBatch({
      buildQuery: () => db
        .collection("calls")
        .where("status", "==", "accepted")
        .where("bothJoinedAtMs", "==", 0)
        .where("acceptedAtMs", "<=", staleBeforeMs)
        .orderBy("acceptedAtMs", "asc"),
      processDoc: async (doc) => {
        try {
          await endAcceptedCallIfStillAccepted({
            db,
            callRef: doc.ref,
            reason: "stale_timeout",
            nowMs: currentServerMs(),
            shouldEnd: (callNow) =>
              isAcceptedStaleCleanupCandidate(
                callNow,
                currentServerMs() - 5 * 60 * 1000
              ),
          });
        } catch (e) {
          console.log("cleanupStaleAcceptedCalls_v2 error:", doc.ref.id, e);
        }
      },
    });

    await forEachCleanupCallQueryBatch({
      buildQuery: () => db
        .collection("calls")
        .where("status", "==", "accepted")
        .orderBy("createdAtMs", "asc"),
      maxBatchCount: CLEANUP_LEGACY_SCAN_MAX_BATCH_COUNT,
      processDoc: async (doc) => {
        const call = doc.data() || {};
        const isLegacyStale =
          isAcceptedStaleCleanupCandidate(call, staleBeforeMs);
        const reason = isMalformedAcceptedCleanupCandidate(call)
          ? "invalid"
          : isLegacyStale
            ? "stale_timeout"
            : "";
        if (!reason) return;

        try {
          await endAcceptedCallIfStillAccepted({
            db,
            callRef: doc.ref,
            reason,
            nowMs: currentServerMs(),
            shouldEnd: (callNow) => {
              if (reason === "invalid") {
                return isMalformedAcceptedCleanupCandidate(callNow);
              }
              return isAcceptedStaleCleanupCandidate(
                callNow,
                currentServerMs() - 5 * 60 * 1000
              );
            },
          });
        } catch (e) {
          console.log(
            "cleanupStaleAcceptedCalls_v2 fallback error:",
            doc.ref.id,
            e
          );
        }
      },
    });

    return null;
  });

exports.reconcileReserveAndLocks_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 1 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();

    const usersMap = new Map();

    await forEachUserReconcileQueryBatch({
      buildQuery: () =>
        db
          .collection("users")
          .where("reservedCredits", ">", 0)
          .orderBy("reservedCredits", "desc"),
      processDoc: async (d) => {
        usersMap.set(d.id, d);
      },
    });

    await forEachUserReconcileQueryBatch({
      buildQuery: () =>
        db
          .collection("users")
          .where("activeCallId", "!=", "")
          .orderBy("activeCallId", "asc"),
      processDoc: async (d) => {
        if (!usersMap.has(d.id)) usersMap.set(d.id, d);
      },
    });

    for (const userDoc of usersMap.values()) {
      const userId = userDoc.id;
      const user = userDoc.data() || {};
      const userRef = userDoc.ref;

      try {
        const [trueReservedCredits, liveParticipantCallId] = await Promise.all([
          getTrueReservedCreditsForUser(db, userId),
          getLiveParticipantCallId(db, userId),
        ]);

        const patch = {};
        const currentReservedCredits = intOr(user.reservedCredits, 0);

        if (currentReservedCredits !== trueReservedCredits) {
          patch.reservedCredits = trueReservedCredits;
        }

        const activeCallId = strOr(user.activeCallId).trim();

        if (liveParticipantCallId) {
          if (activeCallId !== liveParticipantCallId) {
            patch.activeCallId = liveParticipantCallId;
            patch.activeCallUpdatedAt =
              admin.firestore.FieldValue.serverTimestamp();
          }
          if (boolOr(user.isOnCall, false) !== true) {
            patch.isOnCall = true;
          }
        } else {
          if (activeCallId) {
            patch.activeCallId = "";
            patch.activeCallUpdatedAt =
              admin.firestore.FieldValue.serverTimestamp();
          }
          if (boolOr(user.isOnCall, false) !== false) {
            patch.isOnCall = false;
          }
        }

        if (Object.keys(patch).length > 0) {
          patch.lastSeen = admin.firestore.FieldValue.serverTimestamp();
          await userRef.update(patch);
        }
      } catch (e) {
        console.log("reconcileReserveAndLocks_v2 error:", userId, e);
      }
    }

    return null;
  });

exports.reconcileCallOnWrite_v2 = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onWrite(async (change) => {
    if (!change.after.exists) return null;

    const after = change.after.data() || {};
    const status = strOr(after.status);

    if (!isFinalStatus(status)) return null;
    if (callNeedsSettlementCleanup(after)) return null;

    const db = admin.firestore();
    const callRef = change.after.ref;

    try {
      await db.runTransaction(async (tx) => {
        const callSnap = await tx.get(callRef);
        const callNow = callSnap.data() || {};
        await safeReleaseReserveAndLockTx(tx, {
          db,
          callRef,
          callData: callNow,
        });
      });
    } catch (e) {
      console.log("reconcileCallOnWrite_v2 error:", callRef.id, e);
    }

    return null;
  });
