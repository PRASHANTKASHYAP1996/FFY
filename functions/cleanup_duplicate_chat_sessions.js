const admin = require("firebase-admin");

const projectId =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.FIREBASE_PROJECT_ID ||
  "friendify-ef682";

const serviceAccount = require("./friendify-ef682-firebase-adminsdk-fbsvc-965c1f3b1a.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

const CHAT_SESSIONS = "chat_sessions";
const USERS = "users";
const BACKUPS = "chat_sessions_cleanup_backups";
const MESSAGES = "messages";

function asString(value, fallback = "") {
  return typeof value === "string" ? value.trim() : fallback;
}

function asBool(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function asInt(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.floor(n) : fallback;
}

function timestampMs(value) {
  if (value && typeof value.toDate === "function") {
    return value.toDate().getTime();
  }
  if (value instanceof Date) {
    return value.getTime();
  }
  return 0;
}

function createdAtMs(data) {
  return (
    asInt(data.createdAtMs, 0) ||
    asInt(data.chatCreatedAtMs, 0) ||
    timestampMs(data.createdAt) ||
    timestampMs(data.chatCreatedAt) ||
    0
  );
}

function updatedAtMs(data) {
  return (
    asInt(data.updatedAtMs, 0) ||
    asInt(data.chatUpdatedAtMs, 0) ||
    asInt(data.lastMessageAtMs, 0) ||
    timestampMs(data.updatedAt) ||
    timestampMs(data.lastMessageAt) ||
    0
  );
}

function lastMessageAtMs(data) {
  return (
    asInt(data.lastMessageAtMs, 0) ||
    timestampMs(data.lastMessageAt) ||
    updatedAtMs(data)
  );
}

function sessionScore(data) {
  const callAllowedBoost = asBool(data.callAllowed, false) ? 1000000000000 : 0;
  return callAllowedBoost + updatedAtMs(data);
}

function pairKeyFromDocData(docId, data) {
  const speakerId = asString(data.speakerId);
  const listenerId = asString(data.listenerId);

  if (speakerId && listenerId && speakerId !== listenerId) {
    return [speakerId, listenerId].sort().join("__");
  }

  const parts = String(docId)
    .split("_")
    .map((v) => v.trim())
    .filter(Boolean);

  if (parts.length === 2 && parts[0] !== parts[1]) {
    return [parts[0], parts[1]].sort().join("__");
  }

  return "";
}

async function getUserRoleHints(userIds) {
  const out = {};
  const refs = userIds
    .filter((v, i, a) => v && a.indexOf(v) === i)
    .map((uid) => db.collection(USERS).doc(uid));

  if (refs.length === 0) return out;

  const snaps = await db.getAll(...refs);
  for (const snap of snaps) {
    const data = snap.exists ? snap.data() || {} : {};
    out[snap.id] = {
      isListener: asBool(data.isListener, false),
    };
  }
  return out;
}

function chooseWinner(groupDocs) {
  return [...groupDocs].sort((a, b) => {
    const diff = sessionScore(b.data) - sessionScore(a.data);
    if (diff !== 0) return diff;
    return String(a.id).localeCompare(String(b.id));
  })[0];
}

function normalizeOrientation(groupDocs, roleHints) {
  let chosen = null;

  for (const item of groupDocs) {
    const speakerId = asString(item.data.speakerId);
    const listenerId = asString(item.data.listenerId);
    if (!speakerId || !listenerId || speakerId === listenerId) continue;

    const speakerIsListener = !!(roleHints[speakerId] && roleHints[speakerId].isListener);
    const listenerIsListener = !!(roleHints[listenerId] && roleHints[listenerId].isListener);

    if (!speakerIsListener && listenerIsListener) {
      chosen = { speakerId, listenerId };
      break;
    }
  }

  if (chosen) return chosen;

  if (groupDocs.length > 0) {
    const best = chooseWinner(groupDocs);
    const speakerId = asString(best.data.speakerId);
    const listenerId = asString(best.data.listenerId);
    if (speakerId && listenerId && speakerId !== listenerId) {
      return { speakerId, listenerId };
    }
  }

  const pair = pairKeyFromDocData(groupDocs[0].id, groupDocs[0].data).split("__");
  if (pair.length === 2 && pair[0] && pair[1]) {
    const aIsListener = !!(roleHints[pair[0]] && roleHints[pair[0]].isListener);
    const bIsListener = !!(roleHints[pair[1]] && roleHints[pair[1]].isListener);

    if (!aIsListener && bIsListener) {
      return { speakerId: pair[0], listenerId: pair[1] };
    }
    if (!bIsListener && aIsListener) {
      return { speakerId: pair[1], listenerId: pair[0] };
    }

    return { speakerId: pair[0], listenerId: pair[1] };
  }

  return { speakerId: "", listenerId: "" };
}

function statusPriority(status) {
  switch (asString(status).toLowerCase()) {
    case "blocked":
      return 5;
    case "active":
      return 4;
    case "accepted":
      return 3;
    case "pending":
      return 2;
    case "closed":
      return 1;
    default:
      return 0;
  }
}

function remapFlagsToCanonical(data, canonicalSpeakerId, canonicalListenerId) {
  const rawSpeakerId = asString(data.speakerId);
  const rawListenerId = asString(data.listenerId);

  const rawSpeakerBlocked = asBool(data.speakerBlocked, false);
  const rawListenerBlocked = asBool(data.listenerBlocked, false);

  let canonicalSpeakerBlocked = false;
  let canonicalListenerBlocked = false;

  if (rawSpeakerId === canonicalSpeakerId) {
    canonicalSpeakerBlocked = rawSpeakerBlocked;
  }
  if (rawListenerId === canonicalSpeakerId) {
    canonicalSpeakerBlocked = canonicalSpeakerBlocked || rawListenerBlocked;
  }

  if (rawSpeakerId === canonicalListenerId) {
    canonicalListenerBlocked = rawSpeakerBlocked;
  }
  if (rawListenerId === canonicalListenerId) {
    canonicalListenerBlocked = canonicalListenerBlocked || rawListenerBlocked;
  }

  return {
    speakerBlocked: canonicalSpeakerBlocked,
    listenerBlocked: canonicalListenerBlocked,
  };
}

function buildMergedSession(groupDocs, canonicalSpeakerId, canonicalListenerId, canonicalDocId) {
  const winner = chooseWinner(groupDocs);
  const bestStatusDoc = [...groupDocs].sort((a, b) => {
    const diff = statusPriority(b.data.status) - statusPriority(a.data.status);
    if (diff !== 0) return diff;
    return updatedAtMs(b.data) - updatedAtMs(a.data);
  })[0];

  let speakerBlocked = false;
  let listenerBlocked = false;
  let maxSpeakerUnread = 0;
  let maxListenerUnread = 0;
  let callAllowed = false;
  let callRequestOpen = false;
  let callRequestedBy = "";
  let callRequestAtMs = 0;
  let callAllowedAtMs = 0;
  let archived = false;

  for (const item of groupDocs) {
    const flags = remapFlagsToCanonical(
      item.data,
      canonicalSpeakerId,
      canonicalListenerId,
    );

    speakerBlocked = speakerBlocked || flags.speakerBlocked;
    listenerBlocked = listenerBlocked || flags.listenerBlocked;
    callAllowed = callAllowed || asBool(item.data.callAllowed, false);
    callRequestOpen = callRequestOpen || asBool(item.data.callRequestOpen, false);
    archived = archived || asBool(item.data.archived, false);

    maxSpeakerUnread = Math.max(
      maxSpeakerUnread,
      asInt(item.data.speakerUnreadCount, 0),
    );
    maxListenerUnread = Math.max(
      maxListenerUnread,
      asInt(item.data.listenerUnreadCount, 0),
    );

    const requestedBy = asString(item.data.callRequestedBy);
    if (requestedBy && !callRequestedBy) {
      callRequestedBy = requestedBy;
    }

    callRequestAtMs = Math.max(callRequestAtMs, asInt(item.data.callRequestAtMs, 0));
    callAllowedAtMs = Math.max(callAllowedAtMs, asInt(item.data.callAllowedAtMs, 0));
  }

  const winnerData = winner.data || {};
  const lastMessageSource = [...groupDocs].sort(
    (a, b) => lastMessageAtMs(b.data) - lastMessageAtMs(a.data),
  )[0];

  const validCreatedAtValues = groupDocs
    .map((item) => createdAtMs(item.data))
    .filter((v) => v > 0);

  return {
    sessionId: canonicalDocId,
    speakerId: canonicalSpeakerId,
    listenerId: canonicalListenerId,
    status: asString(bestStatusDoc.data.status, "accepted"),
    callAllowed,
    speakerBlocked,
    listenerBlocked,
    callRequestedBy,
    callRequestOpen,
    callRequestAtMs,
    callAllowedAtMs,
    lastMessageText: asString(lastMessageSource.data.lastMessageText),
    lastMessageSenderId: asString(lastMessageSource.data.lastMessageSenderId),
    lastMessageType: asString(lastMessageSource.data.lastMessageType),
    lastMessageAtMs: lastMessageAtMs(lastMessageSource.data),
    speakerUnreadCount: maxSpeakerUnread,
    listenerUnreadCount: maxListenerUnread,
    archived,
    createdAtMs:
      validCreatedAtValues.length > 0
        ? Math.min(...validCreatedAtValues)
        : Date.now(),
    updatedAtMs: Math.max(...groupDocs.map((item) => updatedAtMs(item.data))),
    cleanupMergedFromDocIds: groupDocs.map((item) => item.id),
    cleanupMergedAt: admin.firestore.FieldValue.serverTimestamp(),
    cleanupMergedAtMs: Date.now(),
    cleanupVersion: 1,
    createdAt:
      winnerData.createdAt ||
      winnerData.chatCreatedAt ||
      admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function readAllMessages(docRef) {
  const snap = await docRef.collection(MESSAGES).get();
  return snap.docs.map((doc) => ({
    id: doc.id,
    data: doc.data() || {},
  }));
}

async function copyMissingMessages(targetRef, sourceRef) {
  const [targetMessages, sourceMessages] = await Promise.all([
    readAllMessages(targetRef),
    readAllMessages(sourceRef),
  ]);

  const existingIds = new Set(targetMessages.map((m) => m.id));
  const sourceSorted = [...sourceMessages].sort((a, b) => {
    const aMs = asInt(a.data.createdAtMs, 0) || timestampMs(a.data.createdAt) || 0;
    const bMs = asInt(b.data.createdAtMs, 0) || timestampMs(b.data.createdAt) || 0;
    return aMs - bMs;
  });

  let copied = 0;
  let batch = db.batch();
  let opCount = 0;

  for (const msg of sourceSorted) {
    if (existingIds.has(msg.id)) continue;

    batch.set(targetRef.collection(MESSAGES).doc(msg.id), msg.data, {
      merge: true,
    });
    copied += 1;
    opCount += 1;

    if (opCount >= 400) {
      await batch.commit();
      batch = db.batch();
      opCount = 0;
    }
  }

  if (opCount > 0) {
    await batch.commit();
  }

  return copied;
}

async function deleteSubcollectionDocs(docRef, subcollectionName) {
  while (true) {
    const snap = await docRef.collection(subcollectionName).limit(300).get();
    if (snap.empty) break;

    const batch = db.batch();
    for (const doc of snap.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();
  }
}

async function backupOriginalDoc(docId, data, canonicalDocId) {
  const backupRef = db.collection(BACKUPS).doc(`${docId}__${Date.now()}`);
  await backupRef.set({
    originalDocId: docId,
    canonicalDocId,
    backedUpAt: admin.firestore.FieldValue.serverTimestamp(),
    backedUpAtMs: Date.now(),
    data,
  });
}

async function cleanupDuplicateChatSessions() {
  console.log(`Using Firebase project: ${projectId}`);
  console.log("Reading all chat sessions...");

  const sessionsSnap = await db.collection(CHAT_SESSIONS).get();
  if (sessionsSnap.empty) {
    console.log("No chat sessions found.");
    return;
  }

  const grouped = new Map();

  for (const doc of sessionsSnap.docs) {
    const data = doc.data() || {};
    const key = pairKeyFromDocData(doc.id, data);
    if (!key) continue;

    if (!grouped.has(key)) {
      grouped.set(key, []);
    }

    grouped.get(key).push({
      id: doc.id,
      ref: doc.ref,
      data,
    });
  }

  let groupsScanned = 0;
  let groupsCleaned = 0;
  let docsDeleted = 0;
  let docsMerged = 0;
  let messagesCopied = 0;

  for (const [pairKey, docs] of grouped.entries()) {
    groupsScanned += 1;

    if (!Array.isArray(docs) || docs.length <= 1) {
      continue;
    }

    const userIds = pairKey.split("__").filter(Boolean);
    const roleHints = await getUserRoleHints(userIds);

    const { speakerId, listenerId } = normalizeOrientation(docs, roleHints);
    if (!speakerId || !listenerId || speakerId === listenerId) {
      console.log(`Skipping invalid pair ${pairKey}`);
      continue;
    }

    const canonicalDocId = `${speakerId}_${listenerId}`;
    const canonicalRef = db.collection(CHAT_SESSIONS).doc(canonicalDocId);
    const canonicalSnap = await canonicalRef.get();

    const workingDocs = [...docs];

    if (
      canonicalSnap.exists &&
      !workingDocs.some((item) => item.id === canonicalDocId)
    ) {
      workingDocs.push({
        id: canonicalSnap.id,
        ref: canonicalSnap.ref,
        data: canonicalSnap.data() || {},
      });
    }

    const merged = buildMergedSession(
      workingDocs,
      speakerId,
      listenerId,
      canonicalDocId,
    );

    console.log(
      `Cleaning pair ${pairKey} -> canonical ${canonicalDocId} from docs: ${workingDocs
        .map((d) => d.id)
        .join(", ")}`
    );

    for (const item of workingDocs) {
      if (item.id !== canonicalDocId) {
        await backupOriginalDoc(item.id, item.data, canonicalDocId);
      }
    }

    await canonicalRef.set(merged, { merge: true });
    docsMerged += workingDocs.length;

    for (const item of workingDocs) {
      if (item.id === canonicalDocId) continue;

      const copiedNow = await copyMissingMessages(canonicalRef, item.ref);
      messagesCopied += copiedNow;

      await deleteSubcollectionDocs(item.ref, MESSAGES);
      await item.ref.delete();
      docsDeleted += 1;
    }

    groupsCleaned += 1;
  }

  console.log("Cleanup finished.");
  console.log({
    groupsScanned,
    groupsCleaned,
    docsDeleted,
    docsMerged,
    messagesCopied,
  });
}

cleanupDuplicateChatSessions()
  .then(() => {
    console.log("DONE");
    process.exit(0);
  })
  .catch((error) => {
    console.error("CLEANUP FAILED", error);
    process.exit(1);
  });