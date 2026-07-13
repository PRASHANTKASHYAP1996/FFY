const {
  admin,
  functions,
  db,
  Timestamp,
  REGION,
  CLEANUP_BATCH_LIMIT,
  RINGING_TIMEOUT_SECONDS,
  intOr,
  strOr,
  boolOr,
  shortLogId,
  logEvent,
  assertCallableAppCheck,
  stringArray,
  levelFromFollowers,
  sanitizeListenerRateForFollowers,
  shouldSendMissedCall,
  endCallAsRejectedIfStillRinging,
} = require("./shared");
const { requireAdmin } = require("./admin");

function timingNowMs() {
  return Date.now();
}

function elapsedSinceMs(startMs) {
  return Math.max(0, Date.now() - intOr(startMs, Date.now()));
}

function logTriggerTiming(functionName, phase, startMs, fields = {}) {
  logEvent("CALL_TIMING", {
    functionName,
    phase,
    elapsedMs: elapsedSinceMs(startMs),
    ...fields,
  });
}

function validTokens(raw) {
  return Array.isArray(raw)
    ? raw.filter((t) => typeof t === "string" && t.trim())
    : [];
}

function invalidFcmTokensFromResponse(tokens, response) {
  const invalid = [];
  if (!response || !Array.isArray(response.responses)) return invalid;

  response.responses.forEach((r, idx) => {
    if (!r || r.success) return;
    const code = strOr(r.error && r.error.code);
    if (
      code === "messaging/invalid-registration-token" ||
      code === "messaging/registration-token-not-registered"
    ) {
      invalid.push(tokens[idx]);
    }
  });

  return invalid;
}

function canonicalChatSessionIdForPair(speakerId, listenerId) {
  const safeSpeakerId = strOr(speakerId);
  const safeListenerId = strOr(listenerId);

  if (!safeSpeakerId || !safeListenerId) return "";
  if (safeSpeakerId === safeListenerId) return "";

  const ids = [safeSpeakerId, safeListenerId].sort();
  return `${ids[0]}_${ids[1]}`;
}

function normalizeNotificationParticipantIds({
  session = {},
  fallbackSpeakerId = "",
  fallbackListenerId = "",
}) {
  const seen = new Set();
  const ids = [];

  function addId(value) {
    const safe = strOr(value).trim();
    if (!safe || seen.has(safe)) return;
    seen.add(safe);
    ids.push(safe);
  }

  const rawParticipantIds = Array.isArray(session.participantIds)
    ? session.participantIds
    : [];
  rawParticipantIds.forEach(addId);

  if (ids.length !== 2) {
    ids.length = 0;
    seen.clear();
    addId(session.pairUserA);
    addId(session.pairUserB);
    addId(session.speakerId);
    addId(session.listenerId);
    addId(fallbackSpeakerId);
    addId(fallbackListenerId);
  }

  ids.sort();
  if (ids.length === 2 && ids[0] !== ids[1]) return ids;
  return [];
}

function resolveNotificationActualListenerId({
  session = {},
  participantIds = [],
}) {
  const requesterId = strOr(session.requesterId || session.callRequestedBy);
  const directCandidates = [
    strOr(session.responderId),
    strOr(session.pendingFor),
    strOr(session.actualListenerId),
  ];
  for (const candidate of directCandidates) {
    if (participantIds.includes(candidate) && candidate !== requesterId) {
      return candidate;
    }
  }

  if (participantIds.length === 2 && participantIds.includes(requesterId)) {
    const otherParticipant = participantIds.find((uid) => uid !== requesterId);
    if (otherParticipant) return otherParticipant;
  }

  return "";
}

function buildNotificationChatContract({
  session = {},
  chatSessionId = "",
  fallbackSpeakerId = "",
  fallbackListenerId = "",
}) {
  const participantIds = normalizeNotificationParticipantIds({
    session,
    fallbackSpeakerId,
    fallbackListenerId,
  });
  const pairUserA = participantIds[0] || "";
  const pairUserB = participantIds[1] || "";
  const fallbackPairKey =
    chatSessionId || canonicalChatSessionIdForPair(fallbackSpeakerId, fallbackListenerId);
  const pairKey = strOr(session.pairKey) || fallbackPairKey;
  let requesterId = strOr(session.requesterId || session.callRequestedBy);
  if (requesterId && !participantIds.includes(requesterId)) {
    requesterId = "";
  }

  let responderId = strOr(session.responderId);
  if (responderId && !participantIds.includes(responderId)) {
    responderId = "";
  }

  let pendingFor = strOr(session.pendingFor);
  if (pendingFor && !participantIds.includes(pendingFor)) {
    pendingFor = "";
  }
  if (!boolOr(session.callRequestOpen, false)) {
    pendingFor = "";
  }

  let actionOwner = strOr(session.actionOwner);
  if (actionOwner && !participantIds.includes(actionOwner)) {
    actionOwner = "";
  }

  const actualListenerId = resolveNotificationActualListenerId({
    session: {
      actualListenerId: strOr(session.actualListenerId),
      responderId,
      pendingFor,
      requesterId,
      callRequestedBy: requesterId,
    },
    participantIds,
  });

  return {
    chatSessionId: strOr(chatSessionId || session.sessionId || pairKey),
    pairKey,
    participantIds,
    pairUserA,
    pairUserB,
    speakerId: pairUserA || strOr(session.speakerId || fallbackSpeakerId),
    listenerId: pairUserB || strOr(session.listenerId || fallbackListenerId),
    actualListenerId,
    requesterId,
    responderId,
    pendingFor,
    actionOwner,
  };
}

function buildNotificationChatContractPayload(contract = {}) {
  const participantIds = Array.isArray(contract.participantIds)
    ? contract.participantIds
    : [];

  return {
    chatSessionId: String(strOr(contract.chatSessionId)),
    chatId: String(strOr(contract.chatSessionId)),
    pairKey: String(strOr(contract.pairKey)),
    participantIds: JSON.stringify(participantIds),
    pairUserA: String(strOr(contract.pairUserA)),
    pairUserB: String(strOr(contract.pairUserB)),
    actualListenerId: String(strOr(contract.actualListenerId)),
    requesterId: String(strOr(contract.requesterId)),
    responderId: String(strOr(contract.responderId)),
    pendingFor: String(strOr(contract.pendingFor)),
    actionOwner: String(strOr(contract.actionOwner)),
    speakerId: String(strOr(contract.speakerId)),
    listenerId: String(strOr(contract.listenerId)),
  };
}

exports._buildNotificationChatContract = buildNotificationChatContract;
exports._buildNotificationChatContractPayload = buildNotificationChatContractPayload;

function buildNotificationChatContractFromCallData(callData = {}) {
  const participantIds = normalizeNotificationParticipantIds({
    session: callData,
    fallbackSpeakerId: strOr(callData.callerId),
    fallbackListenerId: strOr(callData.calleeId),
  });

  if (participantIds.length !== 2) return null;

  return buildNotificationChatContract({
    session: {
      chatSessionId: strOr(callData.chatSessionId),
      pairKey: strOr(callData.pairKey || callData.chatSessionId),
      participantIds,
      pairUserA: strOr(callData.pairUserA),
      pairUserB: strOr(callData.pairUserB),
      actualListenerId: strOr(callData.actualListenerId || callData.calleeId),
      requesterId: strOr(callData.requesterId || callData.callerId),
      responderId: strOr(callData.responderId || callData.calleeId),
      pendingFor: strOr(callData.pendingFor),
      actionOwner: strOr(callData.actionOwner),
    },
    chatSessionId: strOr(callData.chatSessionId),
    fallbackSpeakerId: strOr(callData.callerId),
    fallbackListenerId: strOr(callData.calleeId),
  });
}

async function loadNotificationChatContract({
  chatSessionId = "",
  fallbackSpeakerId = "",
  fallbackListenerId = "",
}) {
  const safeChatSessionId = strOr(chatSessionId).trim();
  if (safeChatSessionId) {
    const snap = await admin
      .firestore()
      .collection("chat_sessions")
      .doc(safeChatSessionId)
      .get();
    if (snap.exists) {
      return buildNotificationChatContract({
        session: snap.data() || {},
        chatSessionId: safeChatSessionId,
        fallbackSpeakerId,
        fallbackListenerId,
      });
    }
  }

  return buildNotificationChatContract({
    session: {},
    chatSessionId: safeChatSessionId,
    fallbackSpeakerId,
    fallbackListenerId,
  });
}

function messageTextForRoot(message) {
  return (
    strOr(message.text) ||
    strOr(message.message) ||
    strOr(message.content) ||
    "New message"
  );
}

function messageTypeForRoot(message) {
  return strOr(message.type) || strOr(message.messageType) || "text";
}

function isCallSystemPreviewType(type) {
  const safeType = strOr(type);
  return (
    safeType === "access_request" ||
    safeType === "access_approved" ||
    safeType === "access_denied"
  );
}

function buildChatRootPatchFromMessage({ session, message, nowMs }) {
  const speakerId = strOr(session.speakerId);
  const listenerId = strOr(session.listenerId);
  const senderId = strOr(message.senderId);
  const chatContract = buildNotificationChatContract({
    session,
    chatSessionId: canonicalChatSessionIdForPair(speakerId, listenerId),
    fallbackSpeakerId: speakerId,
    fallbackListenerId: listenerId,
  });

  const messageType = messageTypeForRoot(message);
  const existingLastMessageType = strOr(session.lastMessageType);
  const suppressSystemPreview =
    isCallSystemPreviewType(messageType) && existingLastMessageType === "text";

  if (suppressSystemPreview) {
    console.log("recent_chats.system_event_preview_suppressed", {
      messageType,
    });
  }

  const patch = {
    sessionId: strOr(chatContract.chatSessionId),
    speakerId: strOr(chatContract.speakerId),
    listenerId: strOr(chatContract.listenerId),
    pairUserA: strOr(chatContract.pairUserA),
    pairUserB: strOr(chatContract.pairUserB),
    participantIds: Array.isArray(chatContract.participantIds)
      ? chatContract.participantIds
      : [],
    pairKey: strOr(chatContract.pairKey),
    actualListenerId: strOr(chatContract.actualListenerId),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };

  if (!suppressSystemPreview) {
    patch.lastMessageText = messageTextForRoot(message);
    patch.lastMessageSenderId = senderId;
    patch.lastMessageType = messageType;
    patch.lastMessageAt = admin.firestore.FieldValue.serverTimestamp();
    patch.lastMessageAtMs = nowMs;
  }

  const preserveRequestState =
    boolOr(session.callRequestOpen, false) ||
    boolOr(session.callAllowed, false) ||
    strOr(session.callRequestedBy).trim().length > 0 ||
    strOr(session.requesterId).trim().length > 0 ||
    strOr(session.responderId).trim().length > 0 ||
    strOr(session.pendingFor).trim().length > 0 ||
    strOr(session.actionOwner).trim().length > 0;

  if (preserveRequestState) {
    patch.requesterId = strOr(chatContract.requesterId);
    patch.responderId = strOr(chatContract.responderId);
    patch.pendingFor = strOr(chatContract.pendingFor);
    patch.actionOwner = strOr(chatContract.actionOwner);
  }

  return patch;
}

function unreadFieldForUser({ session, targetUserId }) {
  const speakerId = strOr(session.speakerId);
  const listenerId = strOr(session.listenerId);

  if (targetUserId === speakerId) {
    return "speakerUnreadCount";
  }
  if (targetUserId === listenerId) {
    return "listenerUnreadCount";
  }
  return "";
}

async function incrementUnreadForReceiver({
  sessionRef,
  session,
  receiverId,
  rootPatch,
}) {
  const unreadField = unreadFieldForUser({
    session,
    targetUserId: receiverId,
  });
  if (!unreadField) return null;

  await sessionRef.set(
    {
      ...rootPatch,
      [unreadField]: admin.firestore.FieldValue.increment(1),
    },
    { merge: true }
  );

  return null;
}

async function decrementUnreadForReceiver({
  sessionRef,
  session,
  receiverId,
}) {
  const unreadField = unreadFieldForUser({
    session,
    targetUserId: receiverId,
  });
  if (!unreadField) return null;

  await db.runTransaction(async (tx) => {
    const sessionSnap = await tx.get(sessionRef);
    if (!sessionSnap.exists) return;

    const current = sessionSnap.data() || {};
    const currentCount = intOr(current[unreadField], 0);
    const nextCount = currentCount > 0 ? currentCount - 1 : 0;

    tx.set(
      sessionRef,
      {
        [unreadField]: nextCount,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: Date.now(),
      },
      { merge: true }
    );
  });

  return null;
}

function buildIncomingCallPushData(callId, callData, chatContract = {}) {
  return {
    type: "incoming_call",
    callId: String(callId),
    callerId: strOr(callData.callerId),
    calleeId: strOr(callData.calleeId),
    receiverId: strOr(callData.calleeId),
    callerName: strOr(callData.callerName, "Someone"),
    expiresAtMs: String(intOr(callData.expiresAtMs, 0)),
    channelId: strOr(callData.channelId),
    ...buildNotificationChatContractPayload(chatContract),
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  };
}

/**
 * PUBLIC USER PROJECTION
 * Backend-owned safe mirror of users/{uid} -> public_users/{uid}
 */

function shouldProjectUserPublicly(data) {
  return !(
    data.deleted === true ||
    data.disabled === true ||
    data.adminDeleted === true ||
    data.adminBlocked === true ||
    data.hiddenFromDiscovery === true
  );
}

function buildPublicUserProjection(userId, raw) {
  const data = raw || {};
  const isListener = boolOr(data.isListener, false);
  const isAvailable = boolOr(data.isAvailable, false);
  const callAvailability =
    data.callAvailability && typeof data.callAvailability === "object"
      ? data.callAvailability
      : {};
  const onlyChatMode = boolOr(
    callAvailability.onlyChatMode,
    boolOr(data.onlyChatMode, false)
  );

  const visibleRate = sanitizeListenerRateForFollowers(
    intOr(data.listenerRate, 5),
    intOr(data.followersCount, 0)
  );

  return {
    uid: strOr(data.uid || userId),
    displayName: strOr(data.displayName),
    photoURL: strOr(data.photoURL),
    bio: strOr(data.bio),
    gender: strOr(data.gender),
    city: strOr(data.city),
    state: strOr(data.state),
    country: strOr(data.country),
    topics: stringArray(data.topics),
    languages: stringArray(data.languages),
    isListener,
    isAvailable,
    callAvailability: {
      onlyChatMode,
    },
    followersCount: intOr(data.followersCount, 0),
    level: intOr(data.level, levelFromFollowers(intOr(data.followersCount, 0))),
    listenerRate: visibleRate,
    ratingAvg: Number(data.ratingAvg || 0),
    ratingCount: intOr(data.ratingCount, 0),
    ratingSum: Number(data.ratingSum || 0),
    discoverable: isListener && !boolOr(data.adminBlocked, false) && !boolOr(data.hiddenFromDiscovery, false),
    createdAt:
      data.createdAt instanceof Timestamp ||
      data.createdAt instanceof Date ||
      data.createdAt === null
        ? data.createdAt || null
        : null,
    lastSeen:
      data.lastSeen instanceof Timestamp ||
      data.lastSeen instanceof Date ||
      data.lastSeen === null
        ? data.lastSeen || null
        : null,
    lastPublicUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function publicProjectionChanged(before, after) {
  const keys = [
    "uid",
    "displayName",
    "photoURL",
    "bio",
    "gender",
    "city",
    "state",
    "country",
    "topics",
      "languages",
      "isListener",
      "isAvailable",
      "callAvailability",
      "onlyChatMode",
      "adminBlocked",
    "hiddenFromDiscovery",
    "discoverable",
    "followersCount",
    "level",
    "listenerRate",
    "ratingAvg",
    "ratingCount",
    "ratingSum",
    "createdAt",
    "lastSeen",
  ];

  for (const key of keys) {
    const a = before ? before[key] : undefined;
    const b = after ? after[key] : undefined;

    if (Array.isArray(a) || Array.isArray(b)) {
      const aJson = JSON.stringify(Array.isArray(a) ? a : []);
      const bJson = JSON.stringify(Array.isArray(b) ? b : []);
      if (aJson !== bJson) return true;
      continue;
    }

    const aPlainObject =
      a &&
      typeof a === "object" &&
      typeof a.toMillis !== "function" &&
      !(a instanceof Date);
    const bPlainObject =
      b &&
      typeof b === "object" &&
      typeof b.toMillis !== "function" &&
      !(b instanceof Date);
    if (aPlainObject || bPlainObject) {
      const aJson = JSON.stringify(aPlainObject ? a : {});
      const bJson = JSON.stringify(bPlainObject ? b : {});
      if (aJson !== bJson) return true;
      continue;
    }

    const aMs =
      a && typeof a.toMillis === "function"
        ? a.toMillis()
        : a instanceof Date
          ? a.getTime()
          : a;
    const bMs =
      b && typeof b.toMillis === "function"
        ? b.toMillis()
        : b instanceof Date
          ? b.getTime()
          : b;

    if (aMs !== bMs) return true;
  }

  return false;
}

exports._buildPublicUserProjection = buildPublicUserProjection;
exports._publicProjectionChanged = publicProjectionChanged;

async function syncPublicUserProjectionById(userId, userDataOrNull) {
  const safeUserId = strOr(userId).trim();
  if (!safeUserId) return null;

  const publicRef = admin.firestore().collection("public_users").doc(safeUserId);

  if (!userDataOrNull || !shouldProjectUserPublicly(userDataOrNull)) {
    await publicRef.delete().catch(() => null);
    return null;
  }

  const projection = buildPublicUserProjection(safeUserId, userDataOrNull);
  await publicRef.set(projection, { merge: false });
  return null;
}

exports.syncPublicUserProjection_v1 = functions
  .region(REGION)
  .firestore.document("users/{userId}")
  .onWrite(async (change, context) => {
    const userId = strOr(context.params.userId).trim();
    if (!userId) return null;

    const beforeExists = change.before.exists;
    const afterExists = change.after.exists;

    if (!afterExists) {
      await syncPublicUserProjectionById(userId, null);
      return null;
    }

    const before = beforeExists ? change.before.data() || {} : null;
    const after = change.after.data() || {};

    if (beforeExists && !publicProjectionChanged(before, after)) {
      return null;
    }

    await syncPublicUserProjectionById(userId, after);
    return null;
  });

exports.backfillPublicUsers_v1 = functions
  .region(REGION)
  .https.onCall(async (_data, context) => {
    assertCallableAppCheck(context, "backfillPublicUsers_v1");
    await requireAdmin(context);

    const usersSnap = await admin.firestore().collection("users").get();

    let processed = 0;
    let deleted = 0;

    for (const doc of usersSnap.docs) {
      const userId = strOr(doc.id).trim();
      const data = doc.data() || {};

      if (!userId) continue;

      const shouldDelete = !shouldProjectUserPublicly(data);

      if (shouldDelete) {
        await admin
          .firestore()
          .collection("public_users")
          .doc(userId)
          .delete()
          .catch(() => null);
        deleted += 1;
        continue;
      }

      await syncPublicUserProjectionById(userId, data);
      processed += 1;
    }

    return {
      ok: true,
      processed,
      deleted,
    };
  });

exports.syncFollowersCount_v2 = functions
  .region(REGION)
  .firestore.document("users/{userId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};
    const userId = strOr(context.params.userId).trim();
    if (!userId) return null;

    const beforeFollowing = new Set(stringArray(before.following));
    const afterFollowing = new Set(stringArray(after.following));

    const added = [...afterFollowing].filter((id) => !beforeFollowing.has(id));
    const removed = [...beforeFollowing].filter((id) => !afterFollowing.has(id));

    if (added.length === 0 && removed.length === 0) return null;

    const followersRoot = admin.firestore().collection("user_followers");
    const batch = admin.firestore().batch();

    for (const targetIdRaw of added) {
      const targetId = strOr(targetIdRaw).trim();
      if (!targetId || targetId === userId) continue;
      batch.set(
        followersRoot.doc(targetId).collection("followers").doc(userId),
        {
          followerId: userId,
          targetUserId: targetId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }

    for (const targetIdRaw of removed) {
      const targetId = strOr(targetIdRaw).trim();
      if (!targetId || targetId === userId) continue;
      batch.delete(followersRoot.doc(targetId).collection("followers").doc(userId));
    }

    await batch.commit();

    const touchedUsers = new Set([...added, ...removed].map((id) => strOr(id).trim()).filter(Boolean));

    for (const targetId of touchedUsers) {
      if (!targetId || targetId === userId) continue;
      const targetRef = admin.firestore().collection("users").doc(targetId);
      const countSnapshot = await followersRoot.doc(targetId).collection("followers").count().get();
      const followerCount = intOr(countSnapshot.data().count, 0);

      await admin.firestore().runTransaction(async (tx) => {
        const targetSnap = await tx.get(targetRef);
        if (!targetSnap.exists) return;
        const target = targetSnap.data() || {};
        const level = levelFromFollowers(followerCount);
        const listenerRate = sanitizeListenerRateForFollowers(
          intOr(target.listenerRate, 5),
          followerCount
        );

        tx.set(
          targetRef,
          {
            followersCount: followerCount,
            level,
            listenerRate,
            lastSeen: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      });
    }

    return null;
  });

exports.backfillFollowersCount_v1 = functions
  .region(REGION)
  .https.onCall(async (_data, context) => {
    assertCallableAppCheck(context, "backfillFollowersCount_v1");
    await requireAdmin(context);

    const usersSnap = await admin.firestore().collection("users").get();
    const followersRoot = admin.firestore().collection("user_followers");
    let processed = 0;

    for (const userDoc of usersSnap.docs) {
      const targetId = strOr(userDoc.id).trim();
      if (!targetId) continue;

      const countSnapshot = await followersRoot
        .doc(targetId)
        .collection("followers")
        .count()
        .get();
      const followerCount = intOr(countSnapshot.data().count, 0);
      const user = userDoc.data() || {};
      const level = levelFromFollowers(followerCount);
      const listenerRate = sanitizeListenerRateForFollowers(
        intOr(user.listenerRate, 5),
        followerCount
      );

      await userDoc.ref.set(
        {
          followersCount: followerCount,
          level,
          listenerRate,
          lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      processed += 1;
    }

    return { ok: true, processed };
  });


function reviewTargetsOtherParticipantFromCallData({ review = {}, call = {} }) {
  const reviewerId = strOr(review.reviewerId).trim();
  const reviewedUserId = strOr(review.reviewedUserId).trim();
  const callerId = strOr(call.callerId).trim();
  const calleeId = strOr(call.calleeId).trim();
  const status = strOr(call.status).trim();

  if (!reviewerId || !reviewedUserId) return false;
  if (!callerId || !calleeId) return false;
  if (reviewerId === reviewedUserId) return false;
  if (status !== "ended") return false;

  return (callerId === reviewerId && calleeId === reviewedUserId) ||
    (calleeId === reviewerId && callerId === reviewedUserId);
}

exports._reviewTargetsOtherParticipantFromCallData =
  reviewTargetsOtherParticipantFromCallData;

async function reviewTargetsOtherParticipant(review) {
  const callId = strOr(review.callId).trim();
  if (!callId) return false;

  const callSnap = await db.collection("calls").doc(callId).get();
  if (!callSnap.exists) return false;

  return reviewTargetsOtherParticipantFromCallData({
    review,
    call: callSnap.data() || {},
  });
}

exports.aggregateReviewToUser_v2 = functions
  .region(REGION)
  .firestore.document("reviews/{reviewId}")
  .onCreate(async (snap) => {
    const data = snap.data() || {};
    const userId = strOr(data.reviewedUserId).trim();
    const stars = intOr(data.stars, 0);

    if (!userId || stars < 1 || stars > 5) return null;

    if (!(await reviewTargetsOtherParticipant(data))) {
      await snap.ref.set(
        {
          invalid: true,
          invalidReason: "review_invalid_target",
          aggregationSkipped: true,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      return null;
    }

    const userRef = admin.firestore().collection("users").doc(userId);

    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) return;

      const user = userSnap.data() || {};

      const oldCount = intOr(user.ratingCount, 0);
      const oldSum = Number(user.ratingSum || 0);
      const newCount = oldCount + 1;
      const newSum = oldSum + stars;
      const newAvg = newCount > 0 ? Number((newSum / newCount).toFixed(2)) : 0;

      tx.update(userRef, {
        ratingCount: newCount,
        ratingSum: newSum,
        ratingAvg: newAvg,
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    // Mirror an anonymized copy to the listener's public profile so anyone can
    // read reviews without exposing who left them (no reviewerId / callId).
    await admin.firestore()
      .collection("public_users")
      .doc(userId)
      .collection("reviews")
      .doc(snap.id)
      .set(
        {
          stars,
          comment: strOr(data.comment).trim().slice(0, 1000),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          createdAtMs: Date.now(),
        },
        { merge: true }
      );

    return null;
  });

exports.onChatMessageCreated = functions
  .region(REGION)
  .firestore.document("chat_sessions/{chatSessionId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    const message = snap.data() || {};

    const chatSessionId = strOr(context.params.chatSessionId);
    const messageId = strOr(context.params.messageId);

    const senderId = strOr(message.senderId);
  if (!chatSessionId || !messageId) return null;
    if (!senderId) return null;

    try {
      const sessionRef = admin
        .firestore()
        .collection("chat_sessions")
        .doc(chatSessionId);

      const sessionSnap = await sessionRef.get();

      if (!sessionSnap.exists) {
        console.log("onChatMessageCreated: session missing", {
          chatSessionId,
          messageId,
        });
        return null;
      }

      const session = sessionSnap.data() || {};
      const speakerId = strOr(session.speakerId);
      const listenerId = strOr(session.listenerId);
      const expectedSessionId = canonicalChatSessionIdForPair(
        speakerId,
        listenerId
      );

      if (!speakerId || !listenerId || speakerId === listenerId) {
        console.log("onChatMessageCreated: invalid session roles", {
          chatSessionId,
          messageId,
          speakerId,
          listenerId,
        });
        return null;
      }

      if (chatSessionId !== expectedSessionId) {
        console.log("onChatMessageCreated: noncanonical session id", {
          chatSessionId,
          expectedSessionId,
          messageId,
        });
        return null;
      }

      if (senderId !== speakerId && senderId !== listenerId) {
        console.log("onChatMessageCreated: sender not in session pair", {
          chatSessionId,
          messageId,
          senderId,
          speakerId,
          listenerId,
        });
        return null;
      }

      const receiverId = senderId === speakerId ? listenerId : speakerId;
      if (!receiverId || receiverId === senderId) {
        console.log("onChatMessageCreated: invalid receiver resolution", {
          chatSessionId,
          messageId,
          senderId,
          receiverId,
        });
        return null;
      }

      const messageReceiverId = strOr(message.receiverId);
      if (messageReceiverId && messageReceiverId !== receiverId) {
        console.log("onChatMessageCreated: receiver mismatch", {
          chatSessionId,
          messageId,
          senderId,
          receiverId,
          messageReceiverId,
        });
        return null;
      }

      const nowMs = Date.now();
      const rootPatch = buildChatRootPatchFromMessage({
        session,
        message,
        nowMs,
      });

      await incrementUnreadForReceiver({
        sessionRef,
        session,
        receiverId,
        rootPatch,
      });

      const senderRole = senderId === speakerId ? "speaker" : "listener";
      const receiverRole = receiverId === speakerId ? "speaker" : "listener";
      const chatContract = buildNotificationChatContract({
        session,
        chatSessionId,
        fallbackSpeakerId: speakerId,
        fallbackListenerId: listenerId,
      });

      const senderSnap = await admin
        .firestore()
        .collection("users")
        .doc(senderId)
        .get();
      const sender = senderSnap.data() || {};

      const senderName =
        strOr(sender.displayName) ||
        strOr(sender.name) ||
        strOr(message.senderName) ||
        "New message";

      const receiverSnap = await admin
        .firestore()
        .collection("users")
        .doc(receiverId)
        .get();

      const receiver = receiverSnap.data() || {};
      const tokens = validTokens(receiver.fcmTokens);

      if (tokens.length === 0) {
        console.log("onChatMessageCreated: no tokens for receiver", {
          chatSessionId,
          messageId,
          receiverId,
        });
        return null;
      }

      const genericChatBody = "You received a new message";
      const res = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: senderName,
          body: genericChatBody,
        },
        data: {
          type: "chat_message",
          ...buildNotificationChatContractPayload(chatContract),
          messageId: String(messageId),
          senderId: String(senderId),
          receiverId: String(receiverId),
          senderRole: String(senderRole),
          receiverRole: String(receiverRole),
          senderName: String(senderName),
          text: "",
          body: genericChatBody,
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        android: {
          priority: "high",
          ttl: 3600 * 1000,
          notification: {
            channelId: "chat_messages",
            priority: "high",
            sound: "default",
          },
        },
        apns: {
          payload: {
            aps: {
              sound: "default",
            },
          },
        },
      });

      const invalid = invalidFcmTokensFromResponse(tokens, res);

      if (invalid.length > 0) {
        const cleaned = tokens.filter((t) => !invalid.includes(t));
        await admin.firestore().collection("users").doc(receiverId).update({
          fcmTokens: cleaned,
        });
      }

      console.log("onChatMessageCreated success", {
        chatSessionId,
        messageId,
        senderId,
        receiverId,
        senderRole,
        receiverRole,
        successCount: intOr(res.successCount, 0),
        failureCount: intOr(res.failureCount, 0),
      });
    } catch (e) {
      console.log("onChatMessageCreated error:", e);
    }

    return null;
  });

exports.onChatMessageSeenUpdated = functions
  .region(REGION)
  .firestore.document("chat_sessions/{chatSessionId}/messages/{messageId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};
    const chatSessionId = strOr(context.params.chatSessionId);

    const seenBecameTrue = before.seen !== true && after.seen === true;

    if (!seenBecameTrue) return null;
    if (!chatSessionId) return null;

    try {
      const sessionRef = admin
        .firestore()
        .collection("chat_sessions")
        .doc(chatSessionId);

      const sessionSnap = await sessionRef.get();
      if (!sessionSnap.exists) return null;

      const session = sessionSnap.data() || {};
      const receiverId = strOr(after.receiverId);

      if (!receiverId) return null;

      await decrementUnreadForReceiver({
        sessionRef,
        session,
        receiverId,
      });
    } catch (e) {
      console.log("onChatMessageSeenUpdated error:", e);
    }

    return null;
  });

exports.notifyIncomingCall = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onCreate(async (snap, context) => {
    const functionStartMs = timingNowMs();
    const callId = strOr(context.params.callId).trim();
    if (!callId) return null;

    const callData = snap.data() || {};
    const status = strOr(callData.status);
    const calleeId = strOr(callData.calleeId).trim();

    if (status !== "ringing") return null;
    if (!calleeId) return null;

    const userReadStartMs = timingNowMs();
    const userSnap = await admin.firestore().collection("users").doc(calleeId).get();
    const user = userSnap.data() || {};
    const tokens = validTokens(user.fcmTokens);
    logTriggerTiming("notifyIncomingCall", "callee_user_read", userReadStartMs, {
      callId,
      calleeId: shortLogId(calleeId),
      tokenCount: tokens.length,
    });

    const attemptedPatch = {
      incomingPushAttempted: true,
      incomingPushAttemptedAt: admin.firestore.FieldValue.serverTimestamp(),
      incomingPushAttemptedAtMs: Date.now(),
    };

    if (tokens.length === 0) {
      const noTokenPatchStartMs = timingNowMs();
      await snap.ref.set(
        {
          ...attemptedPatch,
          incomingPushDelivered: false,
          incomingPushSuccessCount: 0,
          incomingPushFailureCount: 0,
          incomingPushNoTokens: true,
          incomingPushError: "",
        },
        { merge: true }
      );
      logTriggerTiming("notifyIncomingCall", "no_token_metadata_write", noTokenPatchStartMs, {
        callId,
      });
      logTriggerTiming("notifyIncomingCall", "success_total", functionStartMs, {
        callId,
        noTokens: true,
      });
      return null;
    }

    try {
      const chatContractStartMs = timingNowMs();
      const callDataChatContract =
        buildNotificationChatContractFromCallData(callData);
      const chatContract =
        callDataChatContract ||
        await loadNotificationChatContract({
          chatSessionId: strOr(callData.chatSessionId),
          fallbackSpeakerId: strOr(callData.callerId),
          fallbackListenerId: strOr(callData.calleeId),
        });
      logTriggerTiming("notifyIncomingCall", "chat_contract_load", chatContractStartMs, {
        callId,
        source: callDataChatContract ? "call_doc" : "chat_session",
      });

      logEvent("call.fcm_send_begin", {
        callId,
        callerId: strOr(callData.callerId),
        calleeId,
        tokenCount: tokens.length,
        timestampMs: Date.now(),
      });

      const fcmSendStartMs = timingNowMs();
      const res = await admin.messaging().sendEachForMulticast({
        tokens,
        data: buildIncomingCallPushData(callId, callData, chatContract),
        android: {
          collapseKey: callId,
          priority: "high",
          ttl: RINGING_TIMEOUT_SECONDS * 1000,
        },
        apns: {
          headers: {
            "apns-priority": "10",
          },
          payload: {
            aps: {
              sound: "default",
              contentAvailable: true,
            },
          },
        },
      });
      logTriggerTiming("notifyIncomingCall", "fcm_send", fcmSendStartMs, {
        callId,
        successCount: intOr(res.successCount, 0),
        failureCount: intOr(res.failureCount, 0),
      });

      const invalid = invalidFcmTokensFromResponse(tokens, res);
      logEvent("call.fcm_send_success", {
        callId,
        calleeId,
        successCount: intOr(res.successCount, 0),
        failureCount: intOr(res.failureCount, 0),
        timestampMs: Date.now(),
      });

      if (invalid.length > 0) {
        const tokenCleanupStartMs = timingNowMs();
        const cleaned = tokens.filter((t) => !invalid.includes(t));
        await admin.firestore().collection("users").doc(calleeId).update({
          fcmTokens: cleaned,
        });
        logTriggerTiming("notifyIncomingCall", "invalid_token_cleanup", tokenCleanupStartMs, {
          callId,
          invalidCount: invalid.length,
        });
      }

      const metadataWriteStartMs = timingNowMs();
      await snap.ref.set(
        {
          ...attemptedPatch,
          incomingPushDelivered: intOr(res.successCount, 0) > 0,
          incomingPushSuccessCount: intOr(res.successCount, 0),
          incomingPushFailureCount: intOr(res.failureCount, 0),
          incomingPushNoTokens: false,
          incomingPushError: "",
        },
        { merge: true }
      );
      logTriggerTiming("notifyIncomingCall", "delivery_metadata_write", metadataWriteStartMs, {
        callId,
      });
      logTriggerTiming("notifyIncomingCall", "success_total", functionStartMs, {
        callId,
        successCount: intOr(res.successCount, 0),
        failureCount: intOr(res.failureCount, 0),
      });
    } catch (e) {
      logEvent("call.fcm_send_failed", {
        callId,
        calleeId,
        errorMessage: strOr(e && e.message, "unknown"),
        timestampMs: Date.now(),
      });
      const failureMetadataStartMs = timingNowMs();
      await snap.ref.set(
        {
          ...attemptedPatch,
          incomingPushDelivered: false,
          incomingPushSuccessCount: 0,
          incomingPushFailureCount: tokens.length,
          incomingPushNoTokens: false,
          incomingPushError: String(e),
        },
        { merge: true }
      );
      logTriggerTiming("notifyIncomingCall", "failure_metadata_write", failureMetadataStartMs, {
        callId,
      });
      logTriggerTiming("notifyIncomingCall", "failed_total", functionStartMs, {
        callId,
        errorMessage: strOr(e && e.message, "unknown").slice(0, 120),
      });
    }

    return null;
  });

exports.notifyMissedCall_v2 = functions
  .region(REGION)
  .firestore.document("calls/{callId}")
  .onWrite(async (change, context) => {
    const callId = strOr(context.params.callId).trim();
    if (!callId) return null;
    if (!change.after.exists) return null;

    const after = change.after.data() || {};
    const before = change.before.exists ? change.before.data() || {} : {};

    const shouldSend = shouldSendMissedCall(before, after);
    if (!shouldSend) return null;

    const calleeId = strOr(after.calleeId).trim();
    if (!calleeId) return null;

    if (boolOr(after.missedCallPushSent, false)) return null;

    // Atomically claim the missed-call push so two near-simultaneous writes
    // can't both pass the "already sent?" check and double-notify.
    const claimedMissedPush = await admin.firestore().runTransaction(
      async (tx) => {
        const snap = await tx.get(change.after.ref);
        if (!snap.exists) return false;
        if (boolOr((snap.data() || {}).missedCallPushSent, false)) return false;
        tx.set(
          change.after.ref,
          {
            missedCallPushSent: true,
            missedCallPushSentAt: admin.firestore.FieldValue.serverTimestamp(),
            missedCallPushSentAtMs: Date.now(),
          },
          { merge: true }
        );
        return true;
      }
    );
    if (!claimedMissedPush) return null;

    const userSnap = await admin.firestore().collection("users").doc(calleeId).get();
    const user = userSnap.data() || {};
    const tokens = validTokens(user.fcmTokens);

    if (tokens.length === 0) {
      await change.after.ref.set(
        {
          missedCallPushSent: true,
          missedCallPushSentAt: admin.firestore.FieldValue.serverTimestamp(),
          missedCallPushSentAtMs: Date.now(),
        },
        { merge: true }
      );
      return null;
    }

    const callerName =
      strOr(after.callerName) ||
      strOr(after.displayName) ||
      "Missed call";

    const chatContract = await loadNotificationChatContract({
      chatSessionId: strOr(after.chatSessionId),
      fallbackSpeakerId: strOr(after.callerId),
      fallbackListenerId: calleeId,
    });

    const res = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: {
        title: callerName,
        body: "You missed a call",
      },
      data: {
        type: "missed_call",
        callId,
        callerId: strOr(after.callerId),
        calleeId,
        callerName,
        ...buildNotificationChatContractPayload(chatContract),
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: {
        priority: "high",
        ttl: 3600 * 1000,
        notification: {
          channelId: "missed_calls",
          priority: "high",
          sound: "default",
        },
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    });

    const invalid = invalidFcmTokensFromResponse(tokens, res);

    if (invalid.length > 0) {
      const cleaned = tokens.filter((t) => !invalid.includes(t));
      await admin.firestore().collection("users").doc(calleeId).update({
        fcmTokens: cleaned,
      });
    }

    await change.after.ref.set(
      {
        missedCallPushSent: true,
        missedCallPushSentAt: admin.firestore.FieldValue.serverTimestamp(),
        missedCallPushSentAtMs: Date.now(),
      },
      { merge: true }
    );

    return null;
  });

exports.cleanupCallRateLimits_v1 = functions
  .region(REGION)
  .pubsub.schedule("every 24 hours")
  .onRun(async () => {
    // rate_limits holds one doc per user (id = uid), written by startCall_v2 with
    // { minuteKey, minuteCount, hourKey, hourCount, updatedAt }. Prune docs not
    // touched in 48h; they are recreated on the user's next call attempt.
    const cutoff = Timestamp.fromMillis(Date.now() - 48 * 3600 * 1000);

    const staleSnap = await db
      .collection("rate_limits")
      .where("updatedAt", "<", cutoff)
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    if (staleSnap.empty) return null;

    const batch = db.batch();
    staleSnap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();

    return null;
  });

// cleanupExpiredStories_v1 was removed: stories were dropped from the product
// (createSocialPost_v1 now rejects isStory). Deploying this change deletes the
// scheduled function; any leftover story docs are removed by the reset script.
