const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

const projectId =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.FIREBASE_PROJECT_ID ||
  "friendify-ef682";

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function findLocalServiceAccountPath() {
  const functionsDir = __dirname;
  const explicitPath = asString(
    process.env.FIREBASE_SERVICE_ACCOUNT_PATH ||
      process.env.GOOGLE_APPLICATION_CREDENTIALS,
  );

  const candidates = [
    explicitPath,
    path.join(functionsDir, "service-account.json"),
    path.join(functionsDir, `${projectId}-service-account.json`),
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return path.resolve(candidate);
    }
  }

  const discovered = fs
    .readdirSync(functionsDir)
    .filter((name) => name.toLowerCase().endsWith(".json"))
    .find((name) => {
      const lower = name.toLowerCase();
      return lower.includes("firebase-adminsdk") || lower.includes("service-account");
    });

  if (!discovered) return "";
  return path.join(functionsDir, discovered);
}

function initializeAdmin() {
  const serviceAccountPath = findLocalServiceAccountPath();

  if (!serviceAccountPath) {
    const functionsDir = __dirname;
    console.error("");
    console.error("Missing Firebase Admin credentials for local backfill.");
    console.error(
      "Set GOOGLE_APPLICATION_CREDENTIALS (or FIREBASE_SERVICE_ACCOUNT_PATH) to a service-account JSON file,"
    );
    console.error(
      `or place a service-account JSON inside ${functionsDir} named service-account.json.`
    );
    console.error("");
    console.error("Example PowerShell:");
    console.error(
      '$env:GOOGLE_APPLICATION_CREDENTIALS="C:\\path\\to\\friendify-service-account.json"'
    );
    console.error("npm run backfill:chat-contract");
    console.error("");
    process.exit(1);
  }

  const serviceAccount = readJsonFile(serviceAccountPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    projectId: serviceAccount.project_id || projectId,
  });
}

initializeAdmin();

const db = admin.firestore();
const CHAT_SESSIONS = "chat_sessions";
const USERS = "users";
const BATCH_SIZE = 100;
const APPLY_CONFIRM = "BACKFILL_CHAT_CONTRACT";

function asString(value, fallback = "") {
  return typeof value === "string" ? value.trim() : fallback;
}

function asBool(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function uniqueSortedIds(ids) {
  const out = [];
  const seen = new Set();
  for (const raw of ids || []) {
    const safe = asString(raw);
    if (!safe || seen.has(safe)) continue;
    seen.add(safe);
    out.push(safe);
  }
  out.sort();
  return out;
}

function pairFromDoc(docId, data) {
  const participantIds = uniqueSortedIds(data.participantIds);
  if (participantIds.length === 2 && participantIds[0] !== participantIds[1]) {
    return participantIds;
  }

  const fromFields = uniqueSortedIds([
    data.pairUserA,
    data.pairUserB,
    data.speakerId,
    data.listenerId,
    data.requesterId,
    data.responderId,
    data.pendingFor,
  ]);
  if (fromFields.length === 2 && fromFields[0] !== fromFields[1]) {
    return fromFields;
  }

  const parts = String(docId)
    .split("_")
    .map((v) => v.trim())
    .filter(Boolean);
  const fromDocId = uniqueSortedIds(parts);
  if (fromDocId.length === 2 && fromDocId[0] !== fromDocId[1]) {
    return fromDocId;
  }

  return [];
}

function canonicalSessionId(ids) {
  return ids.length === 2 ? `${ids[0]}_${ids[1]}` : "";
}

const DIRECTIONAL_FIELDS = [
  "actualListenerId",
  "requesterId",
  "responderId",
  "pendingFor",
  "actionOwner",
  "callRequestedBy",
];

function participantFieldValue(value, participantIds) {
  const safe = asString(value);
  return participantIds.includes(safe) ? safe : "";
}

function addActualListenerCandidate(candidateSources, source, value, participantIds) {
  const safe = participantFieldValue(value, participantIds);
  if (!safe) return;
  if (!candidateSources[safe]) {
    candidateSources[safe] = [];
  }
  if (!candidateSources[safe].includes(source)) {
    candidateSources[safe].push(source);
  }
}

function buildDirectionalAmbiguityReport({
  docId,
  canonicalDocId,
  participantIds,
  data,
  resolvedActualListener,
}) {
  const currentValues = {};
  for (const key of DIRECTIONAL_FIELDS) {
    const safe = participantFieldValue(data[key], participantIds);
    if (safe) {
      currentValues[key] = safe;
    }
  }

  const conflictingFields = [];
  const sourceValues = {};
  const targetValues = currentValues;

  const actualFields = ["actualListenerId", "responderId", "pendingFor"];
  const actualFieldValues = {};
  for (const key of actualFields) {
    if (currentValues[key]) {
      actualFieldValues[key] = currentValues[key];
    }
  }
  const distinctActualValues = [...new Set(Object.values(actualFieldValues))];
  if (distinctActualValues.length > 1) {
    conflictingFields.push(...Object.keys(actualFieldValues));
    sourceValues.actualListenerCandidates = resolvedActualListener.candidateSources;
  }

  const requesterId = currentValues.requesterId || "";
  const callRequestedBy = currentValues.callRequestedBy || "";
  if (requesterId && callRequestedBy && requesterId !== callRequestedBy) {
    conflictingFields.push("requesterId", "callRequestedBy");
    sourceValues.requesterId = requesterId;
    sourceValues.callRequestedBy = callRequestedBy;
  }

  const responderId = currentValues.responderId || "";
  const pendingFor = currentValues.pendingFor || "";
  if (responderId && pendingFor && responderId !== pendingFor) {
    conflictingFields.push("responderId", "pendingFor");
    sourceValues.responderId = responderId;
    sourceValues.pendingFor = pendingFor;
  }

  const candidateValues = Object.keys(resolvedActualListener.candidateSources);
  if (candidateValues.length > 1) {
    conflictingFields.push("actualListenerId");
    sourceValues.actualListenerCandidates = resolvedActualListener.candidateSources;
  }

  const uniqueFields = [...new Set(conflictingFields)];
  if (uniqueFields.length == 0) {
    return null;
  }

  return {
    sourceDocId: docId,
    canonicalDocId,
    participantIds,
    conflictingFields: uniqueFields,
    sourceValues,
    targetValues,
    recommendedAction:
      "Manual review required. Repair pair identity only and inspect directional fields before changing them.",
  };
}

function looksLikeLegacyRedirect(data) {
  return (
    asBool(data.chatArchived, false) &&
    !!asString(data.migratedToDocId) &&
    !!asString(data.redirectToChatSessionId)
  );
}

async function getRoleHints(ids) {
  const uniqueIds = uniqueSortedIds(ids);
  if (uniqueIds.length === 0) return {};
  const refs = uniqueIds.map((uid) => db.collection(USERS).doc(uid));
  const snaps = await db.getAll(...refs);
  const hints = {};
  for (const snap of snaps) {
    const data = snap.exists ? snap.data() || {} : {};
    hints[snap.id] = {
      isListener: asBool(data.isListener, false),
    };
  }
  return hints;
}

async function resolveActualListenerId({ docRef, data, participantIds, roleHints }) {
  const candidateSources = {};

  const directCandidates = [
    ["actualListenerId", data.actualListenerId],
    ["listenerUserId", data.listenerUserId],
    ["responderId", data.responderId],
    ["pendingFor", data.pendingFor],
  ];

  for (const [source, raw] of directCandidates) {
    addActualListenerCandidate(candidateSources, source, raw, participantIds);
  }

  const callRequestedBy = asString(data.callRequestedBy);
  if (participantIds.includes(callRequestedBy)) {
    const other = participantIds.find((uid) => uid !== callRequestedBy);
    if (other) {
      addActualListenerCandidate(
        candidateSources,
        "callRequestedBy->otherParticipant",
        other,
        participantIds,
      );
    }
  }

  try {
    const messagesSnap = await docRef
      .collection("messages")
      .orderBy("createdAtMs", "asc")
      .limit(50)
      .get();

    for (const msgDoc of messagesSnap.docs) {
      const msg = msgDoc.data() || {};
      const metadata = msg.metadata && typeof msg.metadata === "object"
        ? msg.metadata
        : {};
      const messageCandidates = [
        ["message.metadata.actualListenerId", metadata.actualListenerId],
        ["message.metadata.listenerId", metadata.listenerId],
        ["message.metadata.responderId", metadata.responderId],
        ["message.metadata.pendingFor", metadata.pendingFor],
      ];

      for (const [source, raw] of messageCandidates) {
        addActualListenerCandidate(candidateSources, source, raw, participantIds);
      }

      const systemAction = asString(msg.systemAction).toLowerCase();
      if (systemAction.startsWith("request_")) {
        const receiverId = asString(metadata.receiverId || msg.receiverId);
        addActualListenerCandidate(
          candidateSources,
          "message.request.receiverId",
          receiverId,
          participantIds,
        );
      }
    }
  } catch (error) {
    console.log("message scan skipped:", docRef.id, error.message || error);
  }

  const listenerCandidates = participantIds.filter(
    (uid) => roleHints[uid] && roleHints[uid].isListener === true
  );
  if (listenerCandidates.length === 1) {
    addActualListenerCandidate(
      candidateSources,
      "roleHint.isListener",
      listenerCandidates[0],
      participantIds,
    );
  }



  const distinctCandidates = Object.keys(candidateSources);
  return {
    actualListenerId: distinctCandidates.length === 1 ? distinctCandidates[0] : "",
    candidateSources,
  };
}

function buildPatch({ data, participantIds, actualListenerId }) {
  const sessionId = canonicalSessionId(participantIds);
  if (!sessionId) return {};

  const patch = {
    sessionId,
    speakerId: participantIds[0],
    listenerId: participantIds[1],
    pairUserA: participantIds[0],
    pairUserB: participantIds[1],
    participantIds,
    pairKey: sessionId,
  };

  if (actualListenerId) {
    patch.actualListenerId = actualListenerId;
  }

  return patch;
}

function patchDiffers(data, patch) {
  return Object.entries(patch).some(([key, nextValue]) => {
    const currentValue = data[key];
    if (Array.isArray(nextValue)) {
      const current = Array.isArray(currentValue) ? currentValue : [];
      if (current.length !== nextValue.length) return true;
      return current.some((item, index) => asString(item) !== asString(nextValue[index]));
    }
    return asString(currentValue, String(currentValue ?? "")) !== asString(nextValue, String(nextValue ?? ""));
  });
}

async function run() {
  const shouldApply = process.argv.includes(`--confirm=${APPLY_CONFIRM}`);
  console.log(shouldApply ? "APPLY MODE" : "DRY RUN MODE");
  console.log("Project:", projectId);

  let cursor = null;
  let scanned = 0;
  let changed = 0;
  let ambiguousDirectionalSessions = 0;

  while (true) {
    let query = db.collection(CHAT_SESSIONS).orderBy(admin.firestore.FieldPath.documentId()).limit(BATCH_SIZE);
    if (cursor) {
      query = query.startAfter(cursor);
    }

    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      scanned += 1;
      const data = doc.data() || {};
      if (looksLikeLegacyRedirect(data)) {
        console.log("SKIP legacy redirect:", doc.id);
        continue;
      }
      const participantIds = pairFromDoc(doc.id, data);
      if (participantIds.length !== 2) {
        console.log("SKIP invalid pair:", doc.id);
        continue;
      }

      const roleHints = await getRoleHints(participantIds);
      const resolvedActualListener = await resolveActualListenerId({
        docRef: doc.ref,
        data,
        participantIds,
        roleHints,
      });
      const actualListenerId = resolvedActualListener.actualListenerId;

      const patch = buildPatch({
        data,
        participantIds,
        actualListenerId,
      });

      const ambiguityReport = buildDirectionalAmbiguityReport({
        docId: doc.id,
        canonicalDocId: canonicalSessionId(participantIds),
        participantIds,
        data,
        resolvedActualListener,
      });
      if (ambiguityReport) {
        ambiguousDirectionalSessions += 1;
        console.log(
          "AMBIGUOUS_DIRECTION",
          doc.id,
          JSON.stringify(ambiguityReport)
        );
      }

      if (!actualListenerId) {
        console.log(
          "AMBIGUOUS actualListenerId:",
          doc.id,
          JSON.stringify({ participantIds })
        );
      }

      if (!patchDiffers(data, patch)) {
        continue;
      }

      changed += 1;
      console.log("PATCH", doc.id, JSON.stringify(patch));
      if (shouldApply) {
        await doc.ref.set(patch, { merge: true });
      }
    }

    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < BATCH_SIZE) break;
  }

  console.log(JSON.stringify({ scanned, changed, ambiguousDirectionalSessions, applied: shouldApply }, null, 2));
  if (!shouldApply) {
    console.log(`To apply, run with --confirm=${APPLY_CONFIRM}`);
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});



