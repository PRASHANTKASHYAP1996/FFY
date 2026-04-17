const {
  admin,
  functions,
  REGION,
  PLATFORM_PERCENT,
  RINGING_TIMEOUT_SECONDS,
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
  buildAgoraTokenIfPossible,
  timestampToMs,
  computeFinalSeconds,
  isFinalStatus,
  isLiveStatus,
  walletTxRef,
  buildCallChargeTxId,
  buildCallEarningTxId,
  acquireExecutionLock,
  createWalletTxDoc,
  safeReleaseReserveAndLockTx,
  endCallAsRejectedIfStillRinging,
} = require("./shared");

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

function chatDocIdForPair({ speakerId, listenerId }) {
  const a = strOr(speakerId).trim();
  const b = strOr(listenerId).trim();
  if (!a || !b || a === b) return "";
  const ids = [a, b].sort();
  return `${ids[0]}_${ids[1]}`;
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
    canonicalDocId,
    reverseDocId: directDocId === canonicalDocId ? oppositeDocId : directDocId,
    requesterId: safeSpeakerId,
    otherId: safeListenerId,
  };
}

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
      sessionId: pair.canonicalDocId,
      speakerId: pair.speakerId,
      listenerId: pair.listenerId,
      pairUserA: pair.speakerId,
      pairUserB: pair.listenerId,
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
  return {
    ref,
    data: existing,
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

  if (!gate.chatExists) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Chat session missing. Open chat first."
    );
  }

  if (gate.reverseExists) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Duplicate legacy chat session exists. Run admin cleanup before starting calls for this pair."
    );
  }

  if (gate.speakerBlocked || gate.listenerBlocked) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "This chat pair is blocked."
    );
  }

  if (gate.callAllowed !== true || gate.callRequestedBy !== speakerId) {
    if (gate.callRequestOpen === true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Call request is still pending approval."
      );
    }

    throw new functions.https.HttpsError(
      "failed-precondition",
      "Call is not allowed for this chat yet."
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

function currentServerMs() {
  return Date.now();
}

async function assertNoLiveCallForUser({ db, uid, errorMessage }) {
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
    throw new functions.https.HttpsError(
      "failed-precondition",
      errorMessage
    );
  }
}

async function getLiveParticipantCallId(db, userId) {
  const [asCaller, asCallee] = await Promise.all([
    db
      .collection("calls")
      .where("callerId", "==", userId)
      .where("status", "in", ["ringing", "accepted"])
      .limit(1)
      .get(),
    db
      .collection("calls")
      .where("calleeId", "==", userId)
      .where("status", "in", ["ringing", "accepted"])
      .limit(1)
      .get(),
  ]);

  if (!asCaller.empty) return asCaller.docs[0].id;
  if (!asCallee.empty) return asCallee.docs[0].id;
  return "";
}

async function getTrueReservedCreditsForUser(db, userId) {
  const ringingCallerSnap = await db
    .collection("calls")
    .where("callerId", "==", userId)
    .where("status", "==", "ringing")
    .limit(10)
    .get();

  let total = 0;
  for (const doc of ringingCallerSnap.docs) {
    const call = doc.data() || {};
    const reserveReleased = call.reserveReleased === true;
    const reservedUpfront = intOr(call.reservedUpfront, 0);
    if (!reserveReleased && reservedUpfront > 0) {
      total += reservedUpfront;
    }
  }

  return total;
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

      responsePayload = {
        ok: true,
        sessionId: normalized.ref.id,
        existed: normalized.existed === true,
        speakerId,
        listenerId,
        status: strOr(chat.status, "pending"),
        callAllowed: boolOr(chat.callAllowed, false),
        callRequestOpen: boolOr(chat.callRequestOpen, false),
        callRequestedBy: strOr(chat.callRequestedBy),
        speakerBlocked: boolOr(chat.speakerBlocked, false),
        listenerBlocked: boolOr(chat.listenerBlocked, false),
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

      const currentStatus = strOr(chat.status, "pending");
      const chatAlreadyAccepted = currentStatus === "accepted" || currentStatus === "active";
      const requestAction = chatAlreadyAccepted
        ? "request_call_access"
        : "request_chat_access";
      const nextStatus = chatAlreadyAccepted ? "accepted" : "pending";

      const messageRef = chatRef.collection("messages").doc();
      const preview = messagePreviewFromAction(requestAction);

      tx.set(
        chatRef,
        {
          sessionId: pairContext.canonicalDocId,
          speakerId: pairContext.speakerId,
          listenerId: pairContext.listenerId,
          status: nextStatus,
          callAllowed: false,
          callRequestedBy: speakerId,
          requesterId: speakerId,
          responderId: listenerId,
          pendingFor: listenerId,
          actionOwner: speakerId,
          callRequestOpen: true,
          callAllowedAt: null,
          callAllowedAtMs: 0,
          callRequestAt: admin.firestore.FieldValue.serverTimestamp(),
          callRequestAtMs: nowMs,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAtMs: nowMs,
        },
        { merge: true }
      );

      tx.set(
        messageRef,
        buildChatSystemMessage({
          senderId: speakerId,
          receiverId: listenerId,
          type: preview.type,
          text: preview.text,
          systemAction: requestAction,
          metadata: {
            action: requestAction,
            requesterId: speakerId,
            receiverId: listenerId,
            sessionId: chatRef.id,
          },
        })
      );

      responsePayload = {
        ok: true,
        sessionId: chatRef.id,
        status: nextStatus,
        callAllowed: false,
        callRequestOpen: true,
        callRequestedBy: speakerId,
        speakerBlocked: false,
        listenerBlocked: false,
        action: requestAction,
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

      if (currentSpeakerBlocked || currentListenerBlocked) {
        if (action !== "block_pair") {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Chat is already blocked"
          );
        }
      }

      const update = {
        sessionId: pairContext.canonicalDocId,
        speakerId: pairContext.speakerId,
        listenerId: pairContext.listenerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
      };

      let nextStatus = strOr(chat.status, "pending");
      let nextCallAllowed = boolOr(chat.callAllowed, false);
      let nextCallRequestOpen = boolOr(chat.callRequestOpen, false);
      let nextCallRequestedBy = strOr(chat.callRequestedBy);
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
        nextCallRequestedBy = strOr(chat.callRequestedBy, speakerId);
        update.callAllowedAt = admin.firestore.FieldValue.serverTimestamp();
        update.callAllowedAtMs = nowMs;
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

      update.status = nextStatus;
      update.callAllowed = nextCallAllowed;
      update.callRequestOpen = nextCallRequestOpen;
      update.pendingFor = nextCallRequestOpen
        ? (nextCallRequestedBy == speakerId ? listenerId : (nextCallRequestedBy == listenerId ? speakerId : ""))
        : "";
      update.callRequestedBy = nextCallRequestedBy;
      update.requesterId = nextCallRequestedBy;
      update.responderId = nextCallRequestedBy == speakerId ? listenerId : (nextCallRequestedBy == listenerId ? speakerId : "");
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

      const messageRef = chatRef.collection("messages").doc();
      const preview = messagePreviewFromAction(action);

      tx.set(chatRef, update, { merge: true });
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
            callAllowed: nextCallAllowed,
            listenerBlocked: nextListenerBlocked,
          },
        })
      );

      responsePayload = {
        ok: true,
        sessionId: chatRef.id,
        status: nextStatus,
        callAllowed: nextCallAllowed,
        callRequestOpen: nextCallRequestOpen,
        callRequestedBy: nextCallRequestedBy,
        speakerBlocked: nextSpeakerBlocked,
        listenerBlocked: nextListenerBlocked,
        action,
      };
    });

    return responsePayload;
  });

exports.acceptIncomingCall_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "acceptIncomingCall_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const actorUid = strOr(context.auth.uid).trim();
    const callId = strOr(data && data.callId).trim();

    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const { callRef, call, calleeId, status } = await getCallForTransitionTx({
        tx,
        db,
        callId,
        actorUid,
      });

      if (calleeId !== actorUid) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only callee can accept this call"
        );
      }

      if (status === "accepted") {
        responsePayload = {
          ok: true,
          callId,
          status: "accepted",
          alreadyAccepted: true,
        };
        return;
      }

      if (isFinalStatus(status)) {
        responsePayload = {
          ok: true,
          callId,
          status,
          alreadyFinal: true,
        };
        return;
      }

      if (status !== "ringing") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only ringing calls can be accepted"
        );
      }

      const expiresAtMs = intOr(call.expiresAtMs, 0);
      const nowMs = currentServerMs();
      if (expiresAtMs > 0 && expiresAtMs <= nowMs) {
        tx.update(callRef, {
          status: "rejected",
          endedAt: admin.firestore.FieldValue.serverTimestamp(),
          endedAtMs: nowMs,
          endedSeconds: 0,
          endedBy: "system",
          endedReason: "callee_timeout",
          rejectedReason: "callee_timeout",
        });

        responsePayload = {
          ok: true,
          callId,
          status: "rejected",
          alreadyExpired: true,
        };
        return;
      }

      tx.update(callRef, {
        status: "accepted",
        startedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      responsePayload = {
        ok: true,
        callId,
        status: "accepted",
      };
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

    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const { callRef, status } = await getCallForTransitionTx({
        tx,
        db,
        callId,
        actorUid,
      });

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

      tx.update(callRef, {
        status: "rejected",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endedAtMs: currentServerMs(),
        endedSeconds: 0,
        endedBy: actorUid,
        rejectedReason: rejectedReason || "rejected",
      });

      responsePayload = {
        ok: true,
        callId,
        status: "rejected",
      };
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

    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const { callRef, callerId, status } = await getCallForTransitionTx({
        tx,
        db,
        callId,
        actorUid,
      });

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

    if (!callId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "callId required"
      );
    }

    const db = admin.firestore();
    let responsePayload = null;

    await db.runTransaction(async (tx) => {
      const { callRef, status, call } = await getCallForTransitionTx({
        tx,
        db,
        callId,
        actorUid,
      });

      if (status === "ended") {
        responsePayload = {
          ok: true,
          callId,
          status: "ended",
          alreadyEnded: true,
          endedSeconds: intOr(call.endedSeconds, endedSeconds),
        };
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
        return;
      }

      if (status !== "accepted" && status !== "ringing") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only live calls can be ended"
        );
      }

      tx.update(callRef, {
        status: "ended",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endedAtMs: currentServerMs(),
        endedReason: reason || "user_end",
        endedBy: actorUid,
        endedSeconds: status === "accepted" ? endedSeconds : 0,
      });

      responsePayload = {
        ok: true,
        callId,
        status: "ended",
        endedSeconds: status === "accepted" ? endedSeconds : 0,
      };
    });

    return responsePayload;
  });

exports.startCall_v2 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "startCall_v2");
    
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const callerId = strOr(context.auth.uid).trim();
    const listenerId = strOr(data && data.listenerId).trim();

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

    const db = admin.firestore();
    const users = db.collection("users");
    const calls = db.collection("calls");
    const rateLimits = db.collection("rate_limits");

    const callerRef = users.doc(callerId);
    const listenerRef = users.doc(listenerId);
    const limiterRef = rateLimits.doc(callerId);

    const nowMs = Date.now();
    const callRef = calls.doc();
    const channelId = Math.random().toString(36).slice(2, 18);

    const { callerAgoraUid, calleeAgoraUid } = buildDistinctAgoraUids({
      callerId,
      listenerId,
      channelId,
    });

    const mKey = minuteKey(nowMs);
    const hKey = hourKey(nowMs);

    await db.runTransaction(async (tx) => {
      const [callerSnap, listenerSnap, limiterSnap] = await Promise.all([
        tx.get(callerRef),
        tx.get(listenerRef),
        tx.get(limiterRef),
      ]);

      if (!callerSnap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Caller profile missing"
        );
      }

      if (!listenerSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Listener not found");
      }

      const caller = callerSnap.data() || {};
      const listener = listenerSnap.data() || {};

      if (caller.adminBlocked === true) {
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

      const listenerIsAvailable = !strOr(listener.activeCallId).trim();
      if (!listenerIsAvailable) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Listener is busy"
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

      const chatGate = await assertCanonicalChatAllowsCallTx({
        tx,
        db,
        speakerId: callerId,
        listenerId,
      });

      const callerActiveCallId = strOr(caller.activeCallId).trim();
      if (callerActiveCallId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "You already have an active call"
        );
      }

      const listenerActiveCallId = strOr(listener.activeCallId).trim();
      if (listenerActiveCallId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Listener is busy"
        );
      }

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

      await assertNoLiveCallForUser({
        db,
        uid: callerId,
        errorMessage: "You already have an active call",
      });

      await assertNoLiveCallForUser({
        db,
        uid: listenerId,
        errorMessage: "Listener is busy",
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

      const credits = intOr(caller.credits, 0);
      const reserved = intOr(caller.reservedCredits, 0);
      const available = Math.max(0, credits - reserved);

      const maxPrepaidMinutes = Math.floor(available / visibleRate);
      const reservedUpfront = maxPrepaidMinutes * visibleRate;

      if (maxPrepaidMinutes < 1 || reservedUpfront < visibleRate) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Insufficient credits. Need at least ${visibleRate}`
        );
      }

      const callerName = strOr(caller.displayName, "Friendify User");
      const listenerName = strOr(listener.displayName, "Listener");

      const agoraTokenCaller = buildAgoraTokenIfPossible({
        channelId,
        uidInt: callerAgoraUid,
        expireSeconds: 3600,
      });

      const agoraTokenCallee = buildAgoraTokenIfPossible({
        channelId,
        uidInt: calleeAgoraUid,
        expireSeconds: 3600,
      });

      tx.update(callerRef, {
        reservedCredits: reserved + reservedUpfront,
        activeCallId: callRef.id,
        activeCallUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.update(listenerRef, {
        activeCallId: callRef.id,
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

      tx.set(callRef, {
        callerId,
        callerName,
        calleeId: listenerId,
        calleeName: listenerName,
        channelId,
        agoraTokenCaller: agoraTokenCaller || "",
        agoraTokenCallee: agoraTokenCallee || "",
        callerAgoraUid,
        calleeAgoraUid,
        status: "ringing",
        speakerRate: visibleRate,
        listenerRate,
        platformPercent: PLATFORM_PERCENT,
        reservedUpfront,
        maxPrepaidMinutes,
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
    });

    return {
      callId: callRef.id,
      channelId,
      callerAgoraUid,
      calleeAgoraUid,
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

    if (
      !(strOr(before.status) === "ringing" && strOr(after.status) === "accepted")
    ) {
      return null;
    }

    const startedAtMs = timestampToMs(after.startedAt);
    const maxPrepaidMinutes = intOr(after.maxPrepaidMinutes, 0);

    if (startedAtMs <= 0 || maxPrepaidMinutes <= 0) return null;

    const prepaidEndsAtMs = startedAtMs + maxPrepaidMinutes * 60 * 1000;
    if (intOr(after.prepaidEndsAtMs, 0) === prepaidEndsAtMs) return null;

    await change.after.ref.set(
      {
        prepaidEndsAtMs,
      },
      { merge: true }
    );

    return null;
  });

exports.cleanupAcceptedCreditLimit_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 1 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();
    const nowMs = Date.now();

    const q = await db
      .collection("calls")
      .where("status", "==", "accepted")
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    if (q.empty) return null;

    for (const doc of q.docs) {
      const call = doc.data() || {};
      const callRef = doc.ref;

      const startedAtMs = timestampToMs(call.startedAt);
      const maxPrepaidMinutes = intOr(call.maxPrepaidMinutes, 0);

      if (startedAtMs <= 0 || maxPrepaidMinutes <= 0) continue;

      const prepaidEndsAtMs =
        intOr(call.prepaidEndsAtMs, 0) > 0
          ? intOr(call.prepaidEndsAtMs, 0)
          : startedAtMs + maxPrepaidMinutes * 60 * 1000;

      if (nowMs < prepaidEndsAtMs + PREPAID_END_GRACE_MS) continue;

      try {
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(callRef);
          if (!snap.exists) return;

          const callNow = snap.data() || {};
          const statusNow = strOr(callNow.status);
          if (statusNow !== "accepted") return;

          tx.update(callRef, {
            status: "ended",
            endedAt: admin.firestore.FieldValue.serverTimestamp(),
            endedAtMs: Date.now(),
            endedReason: "credit_limit_reached",
            endedBy: "system",
            endedSeconds: 0,
          });
        });
      } catch (e) {
        console.log("cleanupAcceptedCreditLimit_v2 error:", callRef.id, e);
      }
    }

    return null;
  });

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

    const callId = context.params.callId;
    const callerId = strOr(after.callerId);
    const calleeId = strOr(after.calleeId);
    const callerName = strOr(after.callerName, "Caller");
    const calleeName = strOr(after.calleeName, "Listener");

    if (!callerId || !calleeId) return null;

    const db = admin.firestore();

    const settlementLockAcquired = await acquireExecutionLock({
      db,
      lockId: `settle_${callId}`,
      lockType: "call_settlement",
      resourceId: callId,
      owner: "server",
      ttlMs: 60000,
    });

    if (!settlementLockAcquired) {
      console.log("settleCallBilling_v2 duplicate blocked:", callId);
      return null;
    }

    const speakerRate = intOr(after.speakerRate, 5);
    const listenerRate = intOr(after.listenerRate, 4);
    const reservedUpfront = intOr(after.reservedUpfront, speakerRate);
    const maxPrepaidMinutes = intOr(after.maxPrepaidMinutes, 0);

    const seconds = computeFinalSeconds(after);
    const rawBilledMinutes = seconds >= 60 ? Math.floor(seconds / 60) : 0;
    const billedMinutes =
      maxPrepaidMinutes > 0
        ? Math.min(rawBilledMinutes, maxPrepaidMinutes)
        : rawBilledMinutes;

    const speakerCharge = billedMinutes * speakerRate;
    const listenerPayout = billedMinutes * listenerRate;
    const platformProfit = Math.max(0, speakerCharge - listenerPayout);

    const users = db.collection("users");
    const platformSummaryRef = db.collection("system").doc("finance_summary");

    const callerRef = users.doc(callerId);
    const calleeRef = users.doc(calleeId);
    const callRef = change.after.ref;

    const callerChargeTxRef = walletTxRef(
      db,
      buildCallChargeTxId(callId, callerId)
    );
    const listenerEarnTxRef = walletTxRef(
      db,
      buildCallEarningTxId(callId, calleeId)
    );

    await db.runTransaction(async (tx) => {
      const [
        callerSnap,
        calleeSnap,
        callSnap,
        callerChargeTxSnap,
        listenerEarnTxSnap,
        platformSummarySnap,
      ] = await Promise.all([
        tx.get(callerRef),
        tx.get(calleeRef),
        tx.get(callRef),
        tx.get(callerChargeTxRef),
        tx.get(listenerEarnTxRef),
        tx.get(platformSummaryRef),
      ]);

      const callNow = callSnap.data() || {};
      if (callNow.settled === true) return;

      const caller = callerSnap.data() || {};
      const callee = calleeSnap.data() || {};
      const platformSummary = platformSummarySnap.exists
        ? platformSummarySnap.data() || {}
        : {};

      const credits = intOr(caller.credits, 0);
      const reserved = intOr(caller.reservedCredits, 0);

      const newReserved = Math.max(0, reserved - reservedUpfront);
      const maxChargeAllowed = Math.max(0, credits);
      const safeSpeakerCharge = Math.min(speakerCharge, maxChargeAllowed);
      const safePlatformProfit = Math.max(
        0,
        safeSpeakerCharge - listenerPayout
      );
      const newCredits = Math.max(0, credits - safeSpeakerCharge);

      tx.update(callerRef, {
        credits: newCredits,
        reservedCredits: newReserved,
        activeCallId:
          strOr(caller.activeCallId).trim() === callId
            ? ""
            : strOr(caller.activeCallId).trim(),
        activeCallUpdatedAt:
          strOr(caller.activeCallId).trim() === callId
            ? admin.firestore.FieldValue.serverTimestamp()
            : caller.activeCallUpdatedAt ||
              admin.firestore.FieldValue.serverTimestamp(),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      if (listenerPayout > 0) {
        const calleeCredits = intOr(callee.credits, 0);
        const calleeEarn = intOr(callee.earningsCredits, 0);
        const newCalleeCredits = calleeCredits + listenerPayout;
        const newCalleeEarn = calleeEarn + listenerPayout;

        tx.update(calleeRef, {
          credits: newCalleeCredits,
          earningsCredits: newCalleeEarn,
          activeCallId:
            strOr(callee.activeCallId).trim() === callId
              ? ""
              : strOr(callee.activeCallId).trim(),
          activeCallUpdatedAt:
            strOr(callee.activeCallId).trim() === callId
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
              amount: listenerPayout,
              balanceAfter: newCalleeCredits,
              callId,
              status: "completed",
              method: "system",
              notes: `Earned from call with ${callerName}`,
              source: "settlement",
              currency: "INR",
              direction: "credit",
              idempotencyKey: buildCallEarningTxId(callId, calleeId),
              metadata: {
                callId,
                settlementVersion: 2,
              },
            })
          );
        }
      } else {
        tx.update(calleeRef, {
          activeCallId:
            strOr(callee.activeCallId).trim() === callId
              ? ""
              : strOr(callee.activeCallId).trim(),
          activeCallUpdatedAt:
            strOr(callee.activeCallId).trim() === callId
              ? admin.firestore.FieldValue.serverTimestamp()
              : callee.activeCallUpdatedAt ||
                admin.firestore.FieldValue.serverTimestamp(),
          lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      if (!callerChargeTxSnap.exists) {
        tx.set(
          callerChargeTxRef,
          createWalletTxDoc({
            userId: callerId,
            type: "call_charge",
            amount: -safeSpeakerCharge,
            balanceAfter: newCredits,
            callId,
            status: "completed",
            method: "system",
            notes:
              safeSpeakerCharge > 0
                ? `Charged for call with ${calleeName}`
                : `Free call with ${calleeName} under 60 seconds`,
            source: "settlement",
            currency: "INR",
            direction: "debit",
            idempotencyKey: buildCallChargeTxId(callId, callerId),
            metadata: {
              callId,
              settlementVersion: 2,
            },
          })
        );
      }

      if (safePlatformProfit > 0) {
        tx.set(
          platformSummaryRef,
          {
            totalPlatformRevenueCredits:
              intOr(platformSummary.totalPlatformRevenueCredits, 0) +
              safePlatformProfit,
            totalCallRevenueCredits:
              intOr(platformSummary.totalCallRevenueCredits, 0) +
              safePlatformProfit,
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
        paidMinutes: billedMinutes,
        speakerCharge: safeSpeakerCharge,
        listenerPayout,
        platformProfit: safePlatformProfit,
        settled: true,
        settledAt: admin.firestore.FieldValue.serverTimestamp(),
        reserveReleased: true,
        reserveReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
        listenerCredited: listenerPayout > 0,
        listenerCreditedAt:
          listenerPayout > 0
            ? admin.firestore.FieldValue.serverTimestamp()
            : null,
        settlementVersion: 2,
        settlementIdempotencyKey: `settle_${callId}`,
        reserveReleaseIdempotencyKey: `release_${callId}`,
        callerChargeTxId: callerChargeTxRef.id,
        listenerPayoutTxId: listenerPayout > 0 ? listenerEarnTxRef.id : "",
        currency: "INR",
        settlementSource: "server",
      });
    });

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

    const q = await db
      .collection("calls")
      .where("status", "==", "ringing")
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    if (q.empty) return null;

    for (const doc of q.docs) {
      const call = doc.data() || {};
      const callRef = doc.ref;

      const expiresAtMs = intOr(call.expiresAtMs, 0);
      const callerId = strOr(call.callerId);
      const calleeId = strOr(call.calleeId);
      const channelId = strOr(call.channelId);

      const invalid = !callerId || !calleeId || !channelId;
      const expired = expiresAtMs > 0 && expiresAtMs <= nowMs;

      if (!invalid && !expired) continue;

      try {
        await endCallAsRejectedIfStillRinging({
          db,
          callRef,
          reason: invalid ? "invalid" : "server_timeout",
          endedBy: "system",
        });
      } catch (e) {
        console.log("cleanupExpiredRingingCalls_v2 error:", callRef.id, e);
      }
    }

    return null;
  });

exports.cleanupStaleAcceptedCalls_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 5 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    const staleBeforeMs = nowMs - 5 * 60 * 1000;

    const q = await db
      .collection("calls")
      .where("status", "==", "accepted")
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    if (q.empty) return null;

    for (const doc of q.docs) {
      const call = doc.data() || {};
      const callRef = doc.ref;

      const startedAtMs = timestampToMs(call.startedAt);
      const createdAtMs =
        intOr(call.createdAtMs, 0) || timestampToMs(call.createdAt);
      const callerId = strOr(call.callerId);
      const calleeId = strOr(call.calleeId);
      const channelId = strOr(call.channelId);

      const malformed = !callerId || !calleeId || !channelId;
      const acceptedWithoutStartTooOld =
        startedAtMs <= 0 && createdAtMs > 0 && createdAtMs <= staleBeforeMs;

      if (!malformed && !acceptedWithoutStartTooOld) continue;

      try {
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(callRef);
          if (!snap.exists) return;

          const callNow = snap.data() || {};
          const statusNow = strOr(callNow.status);
          if (statusNow !== "accepted") return;

          tx.update(callRef, {
            status: "ended",
            endedAt: admin.firestore.FieldValue.serverTimestamp(),
            endedAtMs: Date.now(),
            endedReason: malformed ? "invalid" : "stale_timeout",
            endedBy: "system",
            endedSeconds: 0,
          });
        });
      } catch (e) {
        console.log("cleanupStaleAcceptedCalls_v2 error:", callRef.id, e);
      }
    }

    return null;
  });

exports.reconcileReserveAndLocks_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 5 minutes")
  .timeZone("UTC")
  .onRun(async () => {
    const db = admin.firestore();

    const reservedUsersSnap = await db
      .collection("users")
      .where("reservedCredits", ">", 0)
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    const lockedUsersSnap = await db
      .collection("users")
      .where("activeCallId", "!=", "")
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    const usersMap = new Map();

    for (const d of reservedUsersSnap.docs) {
      usersMap.set(d.id, d);
    }

    for (const d of lockedUsersSnap.docs) {
      if (!usersMap.has(d.id)) usersMap.set(d.id, d);
    }

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
        } else if (activeCallId) {
          patch.activeCallId = "";
          patch.activeCallUpdatedAt =
            admin.firestore.FieldValue.serverTimestamp();
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
