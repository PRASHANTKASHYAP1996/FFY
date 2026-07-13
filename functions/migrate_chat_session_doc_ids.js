const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

const projectId =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.FIREBASE_PROJECT_ID ||
  "friendify-ef682";

const CHAT_SESSIONS = "chat_sessions";
const MESSAGES = "messages";
const APPLY_CONFIRM = "MIGRATE_CHAT_SESSION_DOCIDS";
const BATCH_SIZE = 100;

function asString(value, fallback = "") {
  return typeof value === "string" ? value.trim() : fallback;
}

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
    console.error("");
    console.error("Missing Firebase Admin credentials for local chat-session migration.");
    console.error(
      "Set GOOGLE_APPLICATION_CREDENTIALS (or FIREBASE_SERVICE_ACCOUNT_PATH) to a service-account JSON file,"
    );
    console.error(
      `or place a service-account JSON inside ${__dirname} named service-account.json.`
    );
    console.error("");
    console.error("Example PowerShell:");
    console.error(
      '$env:GOOGLE_APPLICATION_CREDENTIALS="C:\\path\\to\\friendify-service-account.json"'
    );
    console.error("node migrate_chat_session_doc_ids.js --dry-run");
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

function looksLikeLegacyRedirect(data) {
  return (
    asBool(data.chatArchived, false) &&
    !!asString(data.migratedToDocId) &&
    !!asString(data.redirectToChatSessionId)
  );
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

function lastMessageAtMs(data) {
  return (
    asInt(data.lastMessageAtMs, 0) ||
    timestampMs(data.lastMessageAt) ||
    asInt(data.updatedAtMs, 0) ||
    timestampMs(data.updatedAt) ||
    0
  );
}

function updatedAtMs(data) {
  return (
    asInt(data.updatedAtMs, 0) ||
    asInt(data.lastMessageAtMs, 0) ||
    timestampMs(data.updatedAt) ||
    timestampMs(data.lastMessageAt) ||
    0
  );
}

function firstNonEmpty(values) {
  for (const value of values) {
    const safe = asString(value);
    if (safe) return safe;
  }
  return "";
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

function emptyDirectionalConflictReport({ sourceDocId, canonicalDocId, participantIds }) {
  return {
    sourceDocId,
    canonicalDocId,
    participantIds,
    conflictingFields: [],
    sourceValues: {},
    targetValues: {},
    recommendedAction: "",
  };
}

function buildDirectionalConflictReport({
  sourceDocId,
  canonicalDocId,
  participantIds,
  sourceData,
  targetData,
}) {
  const report = emptyDirectionalConflictReport({
    sourceDocId,
    canonicalDocId,
    participantIds,
  });

  for (const key of DIRECTIONAL_FIELDS) {
    const sourceValue = participantFieldValue(sourceData[key], participantIds);
    const targetValue = participantFieldValue(targetData[key], participantIds);
    if (!sourceValue || !targetValue || sourceValue === targetValue) {
      continue;
    }

    report.conflictingFields.push(key);
    report.sourceValues[key] = sourceValue;
    report.targetValues[key] = targetValue;
  }

  if (report.conflictingFields.length > 0) {
    report.recommendedAction =
      "Manual review required. Keep the canonical document's existing direction fields until the pair is reviewed.";
  }

  return report;
}

function buildCanonicalDocData({ sourceId, data, canonicalId, participantIds }) {
  const next = {
    ...data,
    sessionId: canonicalId,
    speakerId: participantIds[0],
    listenerId: participantIds[1],
    pairUserA: participantIds[0],
    pairUserB: participantIds[1],
    participantIds,
    pairKey: canonicalId,
    migratedFromDocId: sourceId,
    migratedAtMs: Date.now(),
  };

  if (!asString(next.actualListenerId)) {
    const direct = [
      data.actualListenerId,
      data.listenerUserId,
      data.responderId,
      data.pendingFor,
      data.listenerId,
    ].map((value) => asString(value)).find((value) => participantIds.includes(value));
    if (direct) {
      next.actualListenerId = direct;
    }
  }

  return next;
}

function mergeCanonicalDocData({
  sourceId,
  sourceData,
  canonicalData,
  canonicalId,
  participantIds,
}) {
  const sourceCanonical = buildCanonicalDocData({
    sourceId,
    data: sourceData,
    canonicalId,
    participantIds,
  });
  const targetCanonical = buildCanonicalDocData({
    sourceId: canonicalId,
    data: canonicalData,
    canonicalId,
    participantIds,
  });

  const conflictReport = buildDirectionalConflictReport({
    sourceDocId: sourceId,
    canonicalDocId: canonicalId,
    participantIds,
    sourceData: sourceCanonical,
    targetData: targetCanonical,
  });

  const sourceLastMessageMs = lastMessageAtMs(sourceCanonical);
  const targetLastMessageMs = lastMessageAtMs(targetCanonical);
  const sourceUpdatedMs = updatedAtMs(sourceCanonical);
  const targetUpdatedMs = updatedAtMs(targetCanonical);
  const newerLastMessageDoc =
    sourceLastMessageMs > targetLastMessageMs ? sourceCanonical : targetCanonical;
  const newerUpdatedDoc =
    sourceUpdatedMs > targetUpdatedMs ? sourceCanonical : targetCanonical;

  const merged = {
    ...targetCanonical,
    participantIds,
    pairUserA: participantIds[0],
    pairUserB: participantIds[1],
    pairKey: canonicalId,
    sessionId: canonicalId,
    speakerId: participantIds[0],
    listenerId: participantIds[1],
    migratedFromDocId: sourceId,
    migratedAtMs: Date.now(),
  };

  for (const key of DIRECTIONAL_FIELDS) {
    const sourceValue = participantFieldValue(sourceCanonical[key], participantIds);
    const targetValue = participantFieldValue(targetCanonical[key], participantIds);

    if (conflictReport.conflictingFields.includes(key)) {
      if (targetValue) {
        merged[key] = targetValue;
      } else if (sourceValue) {
        merged[key] = sourceValue;
      }
      continue;
    }

    const chosen = firstNonEmpty([targetValue, sourceValue]);
    if (chosen && participantIds.includes(chosen)) {
      merged[key] = chosen;
    }
  }

  for (const key of [
    "status",
    "callAllowed",
    "callRequestOpen",
    "speakerBlocked",
    "listenerBlocked",
    "archived",
    "chatArchived",
  ]) {
    if (key in targetCanonical) {
      merged[key] = targetCanonical[key];
    } else if (key in sourceCanonical) {
      merged[key] = sourceCanonical[key];
    }
  }

  for (const key of [
    "callRequestAtMs",
    "callAllowedAtMs",
    "createdAtMs",
    "speakerUnreadCount",
    "listenerUnreadCount",
  ]) {
    const sourceValue = asInt(sourceCanonical[key], 0);
    const targetValue = asInt(targetCanonical[key], 0);
    const nextValue = Math.max(sourceValue, targetValue);
    if (nextValue > 0 || key in targetCanonical || key in sourceCanonical) {
      merged[key] = nextValue;
    }
  }

  merged.lastMessageAtMs = Math.max(sourceLastMessageMs, targetLastMessageMs);
  merged.updatedAtMs = Math.max(sourceUpdatedMs, targetUpdatedMs);

  if (newerLastMessageDoc.lastMessageAt) {
    merged.lastMessageAt = newerLastMessageDoc.lastMessageAt;
  }
  if (newerUpdatedDoc.updatedAt) {
    merged.updatedAt = newerUpdatedDoc.updatedAt;
  }

  for (const key of ["lastMessageText", "lastMessageSenderId", "lastMessageType"]) {
    const chosen = newerLastMessageDoc[key];
    if (chosen !== undefined && chosen !== null && `${chosen}` !== "") {
      merged[key] = chosen;
    }
  }

  return { merged, conflictReport };
}

function buildLegacyRedirectData({ sourceId, canonicalId, data, conflictReport }) {
  const redirect = {
    ...data,
    participantIds: [],
    chatArchived: true,
    migratedToDocId: canonicalId,
    redirectToChatSessionId: canonicalId,
    migratedFromDocId: sourceId,
    legacyDocId: sourceId,
    migratedAtMs: Date.now(),
  };

  if (conflictReport && conflictReport.conflictingFields.length > 0) {
    redirect.migrationDirectionConflict = true;
    redirect.migrationDirectionConflictFields = conflictReport.conflictingFields;
    redirect.migrationDirectionConflictSourceValues = conflictReport.sourceValues;
    redirect.migrationDirectionConflictTargetValues = conflictReport.targetValues;
    redirect.migrationDirectionConflictRecommendedAction =
      conflictReport.recommendedAction;
  }

  return redirect;
}

async function copyMessagesToTarget({ sourceRef, targetRef, apply }) {
  const sourceMessagesSnap = await sourceRef.collection(MESSAGES).get();
  const targetMessagesSnap = await targetRef.collection(MESSAGES).get();
  const sourceCount = sourceMessagesSnap.size;
  const targetIds = new Set(targetMessagesSnap.docs.map((doc) => doc.id));
  let missingMessages = 0;

  for (const doc of sourceMessagesSnap.docs) {
    if (!targetIds.has(doc.id)) {
      missingMessages += 1;
    }
  }

  if (!apply || sourceCount === 0 || missingMessages === 0) {
    return {
      copiedMessages: apply ? missingMessages : 0,
      sourceMessages: sourceCount,
      targetMessages: targetMessagesSnap.size,
      missingMessages,
    };
  }

  let batch = db.batch();
  let ops = 0;
  let copiedMessages = 0;

  for (const doc of sourceMessagesSnap.docs) {
    if (targetIds.has(doc.id)) {
      continue;
    }
    batch.set(targetRef.collection(MESSAGES).doc(doc.id), doc.data(), { merge: true });
    ops += 1;
    copiedMessages += 1;

    if (ops >= BATCH_SIZE) {
      await batch.commit();
      batch = db.batch();
      ops = 0;
    }
  }

  if (ops > 0) {
    await batch.commit();
  }

  return {
    copiedMessages,
    sourceMessages: sourceCount,
    targetMessages: targetMessagesSnap.size,
    missingMessages,
  };
}

async function main() {
  const apply = process.argv.includes(`--confirm=${APPLY_CONFIRM}`);
  console.log(apply ? "APPLY MODE" : "DRY RUN MODE");
  console.log(`Project: ${projectId}`);

  const snap = await db.collection(CHAT_SESSIONS).get();
  let scanned = 0;
  let changed = 0;
  let migrated = 0;
  let mergedIntoExistingCanonical = 0;
  let ambiguousDirectionalSessions = 0;

  for (const doc of snap.docs) {
    scanned += 1;
    const data = doc.data() || {};
    if (looksLikeLegacyRedirect(data)) {
      console.log("SKIP legacy redirect:", doc.id);
      continue;
    }
    const participantIds = pairFromDoc(doc.id, data);
    const canonicalId = canonicalSessionId(participantIds);

    if (!canonicalId || canonicalId === doc.id) {
      continue;
    }

    changed += 1;
    const sourceRef = doc.ref;
    const targetRef = db.collection(CHAT_SESSIONS).doc(canonicalId);
    const targetSnap = await targetRef.get();
    let targetData;
    let conflictReport = emptyDirectionalConflictReport({
      sourceDocId: doc.id,
      canonicalDocId: canonicalId,
      participantIds,
    });
    if (targetSnap.exists) {
      const mergeResult = mergeCanonicalDocData({
        sourceId: doc.id,
        sourceData: data,
        canonicalData: targetSnap.data() || {},
        canonicalId,
        participantIds,
      });
      targetData = mergeResult.merged;
      conflictReport = mergeResult.conflictReport;
    } else {
      targetData = buildCanonicalDocData({
        sourceId: doc.id,
        data,
        canonicalId,
        participantIds,
      });
    }
    const legacyRedirectData = buildLegacyRedirectData({
      sourceId: doc.id,
      canonicalId,
      data,
      conflictReport,
    });
    const messageStats = await copyMessagesToTarget({
      sourceRef,
      targetRef,
      apply,
    });
    if (targetSnap.exists) {
      mergedIntoExistingCanonical += 1;
    }

    console.log(
      targetSnap.exists ? "MERGE_INTO_CANONICAL" : "MIGRATE_DOC_ID",
      doc.id,
      JSON.stringify({
        canonicalId,
        participantIds,
        actualListenerId: asString(targetData.actualListenerId),
        sourceMessages: messageStats.sourceMessages,
        targetMessages: messageStats.targetMessages,
        missingMessages: messageStats.missingMessages,
        copiedMessages: messageStats.copiedMessages,
        targetAlreadyExisted: targetSnap.exists,
      })
    );

    if (conflictReport.conflictingFields.length > 0) {
      ambiguousDirectionalSessions += 1;
      console.log(
        "AMBIGUOUS_DIRECTION",
        doc.id,
        JSON.stringify(conflictReport)
      );
    }

    if (!asString(targetData.actualListenerId)) {
      console.log(
        "AMBIGUOUS actualListenerId",
        doc.id,
        JSON.stringify({ canonicalId, participantIds })
      );
    }

    if (!apply) {
      continue;
    }

    await targetRef.set(targetData, { merge: true });
    await sourceRef.set(legacyRedirectData, { merge: true });
    migrated += 1;
  }

  console.log(
    JSON.stringify(
      {
        scanned,
        changed,
        migrated,
        mergedIntoExistingCanonical,
        ambiguousDirectionalSessions,
        applied: apply,
      },
      null,
      2
    )
  );

  if (!apply) {
    console.log(`To apply, run with --confirm=${APPLY_CONFIRM}`);
  }
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});




