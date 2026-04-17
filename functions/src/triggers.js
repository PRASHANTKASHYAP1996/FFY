const {
  admin,
  functions,
  db,
  Timestamp,
  REGION,
  CLEANUP_BATCH_LIMIT,
  intOr,
  strOr,
  boolOr,
  stringArray,
  levelFromFollowers,
  sanitizeListenerRateForFollowers,
  minuteKey,
  hourKey,
  shouldSendMissedCall,
  endCallAsRejectedIfStillRinging,
} = require("./shared");

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

function buildChatRootPatchFromMessage({ session, message, nowMs }) {
  const speakerId = strOr(session.speakerId);
  const listenerId = strOr(session.listenerId);
  const senderId = strOr(message.senderId);

  return {
    sessionId: canonicalChatSessionIdForPair(speakerId, listenerId),
    speakerId,
    listenerId,
    lastMessageText: messageTextForRoot(message),
    lastMessageSenderId: senderId,
    lastMessageType: messageTypeForRoot(message),
    lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
    lastMessageAtMs: nowMs,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };
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

function buildIncomingCallPushData(callId, callData) {
  return {
    type: "incoming_call",
    callId: String(callId),
    callerId: strOr(callData.callerId),
    calleeId: strOr(callData.calleeId),
    callerName: strOr(callData.callerName, "Someone"),
    channelId: strOr(callData.channelId),
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
    followersCount: intOr(data.followersCount, 0),
    level: intOr(data.level, levelFromFollowers(intOr(data.followersCount, 0))),
    listenerRate: visibleRate,
    ratingAvg: Number(data.ratingAvg || 0),
    ratingCount: intOr(data.ratingCount, 0),
    ratingSum: Number(data.ratingSum || 0),
    activeCallId: strOr(data.activeCallId),
    adminBlocked: boolOr(data.adminBlocked, false),
    hiddenFromDiscovery: boolOr(data.hiddenFromDiscovery, false),
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
    "activeCallId",
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
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const token = context.auth.token || {};
    const uid = strOr(context.auth.uid).trim();

    const customClaimAdmin =
      token.admin === true ||
      token.isAdmin === true ||
      strOr(token.role).toLowerCase() === "admin";

    let firestoreAdmin = false;
    if (!customClaimAdmin && uid) {
      const adminSnap = await admin.firestore().collection("users").doc(uid).get();
      const adminData = adminSnap.data() || {};
      firestoreAdmin =
        adminData.isAdmin === true ||
        adminData.admin === true ||
        strOr(adminData.role).toLowerCase() === "admin" ||
        strOr(adminData.userRole).toLowerCase() === "admin";
    }

    if (!customClaimAdmin && !firestoreAdmin) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Admin access required"
      );
    }

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
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const token = context.auth.token || {};
    const isAdmin =
      token.admin === true ||
      token.isAdmin === true ||
      strOr(token.role).toLowerCase() === "admin";

    if (!isAdmin) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Admin access required"
      );
    }

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

exports.aggregateReviewToUser_v2 = functions
  .region(REGION)
  .firestore.document("reviews/{reviewId}")
  .onCreate(async (snap) => {
    const data = snap.data() || {};
    const userId = strOr(data.reviewedUserId).trim();
    const stars = intOr(data.stars, 0);

    if (!userId || stars < 1 || stars > 5) return null;

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
    const text = messageTextForRoot(message);

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

      const res = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: senderName,
          body: text,
        },
        data: {
          type: "chat_message",
          chatSessionId: String(chatSessionId),
          messageId: String(messageId),
          speakerId: String(speakerId),
          listenerId: String(listenerId),
          senderId: String(senderId),
          receiverId: String(receiverId),
          senderRole: String(senderRole),
          receiverRole: String(receiverRole),
          senderName: String(senderName),
          text: String(text),
          body: String(text),
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
    const callId = strOr(context.params.callId).trim();
    if (!callId) return null;

    const callData = snap.data() || {};
    const status = strOr(callData.status);
    const calleeId = strOr(callData.calleeId).trim();

    if (status !== "ringing") return null;
    if (!calleeId) return null;

    const userSnap = await admin.firestore().collection("users").doc(calleeId).get();
    const user = userSnap.data() || {};
    const tokens = validTokens(user.fcmTokens);

    const attemptedPatch = {
      incomingPushAttempted: true,
      incomingPushAttemptedAt: admin.firestore.FieldValue.serverTimestamp(),
      incomingPushAttemptedAtMs: Date.now(),
    };

    if (tokens.length === 0) {
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
      return null;
    }

    try {
      const res = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: strOr(callData.callerName, "Incoming call"),
          body: "Tap to answer",
        },
        data: buildIncomingCallPushData(callId, callData),
        android: {
          priority: "high",
          ttl: 45 * 1000,
          notification: {
            channelId: "incoming_calls",
            priority: "high",
            sound: "default",
          },
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

      const invalid = invalidFcmTokensFromResponse(tokens, res);

      if (invalid.length > 0) {
        const cleaned = tokens.filter((t) => !invalid.includes(t));
        await admin.firestore().collection("users").doc(calleeId).update({
          fcmTokens: cleaned,
        });
      }

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
    } catch (e) {
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

    const alreadySent = boolOr(after.missedCallPushSent, false);
    if (alreadySent) return null;

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

exports.cleanupExpiredRingingCalls_v2 = functions
  .region(REGION)
  .pubsub.schedule("every 1 minutes")
  .timeZone("UTC")
  .onRun(async () => {
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

exports.cleanupCallRateLimits_v1 = functions
  .region(REGION)
  .pubsub.schedule("every 24 hours")
  .onRun(async () => {
    const cutoffMinute = minuteKey(Date.now() - 48 * 3600 * 1000);
    const cutoffHour = hourKey(Date.now() - 48 * 3600 * 1000);

    const minuteSnap = await db
      .collection("rate_limits")
      .where("type", "==", "call_start_minute")
      .where("key", "<", cutoffMinute)
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    const hourSnap = await db
      .collection("rate_limits")
      .where("type", "==", "call_start_hour")
      .where("key", "<", cutoffHour)
      .limit(CLEANUP_BATCH_LIMIT)
      .get();

    const batch = db.batch();

    minuteSnap.docs.forEach((doc) => batch.delete(doc.ref));
    hourSnap.docs.forEach((doc) => batch.delete(doc.ref));

    if (!minuteSnap.empty || !hourSnap.empty) {
      await batch.commit();
    }

    return null;
  });
