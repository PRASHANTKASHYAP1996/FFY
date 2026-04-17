const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

function strOr(value, fallback = "") {
  return typeof value === "string" ? value.trim() : fallback;
}

function intOr(value, fallback = 0) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.floor(value);
  }
  return fallback;
}

function boolOr(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function stringArray(value) {
  if (!Array.isArray(value)) return [];
  const out = [];
  const seen = new Set();

  for (const item of value) {
    const safe = strOr(item);
    if (!safe) continue;
    const key = safe.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(safe);
  }

  return out;
}

function sanitizeListenerRateForFollowers(rate, _followersCount) {
  const allowed = [5, 10, 20, 50, 100];
  return allowed.includes(rate) ? rate : 5;
}

function shouldProjectUserPublicly(data) {
  return !(
    data.deleted === true ||
    data.disabled === true ||
    data.adminDeleted === true ||
    data.adminBlocked === true ||
    data.hiddenFromDiscovery === true
  );
}

function levelFromFollowers(followersCount) {
  if (followersCount >= 100000) return 5;
  if (followersCount >= 10000) return 4;
  if (followersCount >= 1000) return 3;
  if (followersCount >= 100) return 2;
  return 1;
}

function buildPublicUserProjection(userId, raw) {
  const data = raw || {};
  const followersCount = intOr(data.followersCount, 0);

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
    isListener: boolOr(data.isListener, false),
    isAvailable: boolOr(data.isAvailable, false),
    followersCount,
    level: intOr(data.level, levelFromFollowers(followersCount)),
    listenerRate: sanitizeListenerRateForFollowers(
      intOr(data.listenerRate, 5),
      followersCount
    ),
    ratingAvg: Number(data.ratingAvg || 0),
    ratingCount: intOr(data.ratingCount, 0),
    ratingSum: Number(data.ratingSum || 0),
    activeCallId: strOr(data.activeCallId),
    adminBlocked: boolOr(data.adminBlocked, false),
    hiddenFromDiscovery: boolOr(data.hiddenFromDiscovery, false),
    discoverable: boolOr(data.isListener, false) && !boolOr(data.adminBlocked, false) && !boolOr(data.hiddenFromDiscovery, false),
    createdAt: data.createdAt || null,
    lastSeen: data.lastSeen || null,
    lastPublicUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function main() {
  const db = admin.firestore();

  console.log("Reading users...");
  const usersSnap = await db.collection("users").get();

  let batch = db.batch();
  let ops = 0;
  let written = 0;

  for (const doc of usersSnap.docs) {
    const data = doc.data() || {};
    const ref = db.collection("public_users").doc(doc.id);

    if (!shouldProjectUserPublicly(data)) {
      batch.delete(ref);
      ops += 1;
      continue;
    }

    const projection = buildPublicUserProjection(doc.id, data);
    batch.set(ref, projection, { merge: false });
    ops += 1;
    written += 1;

    if (ops >= 400) {
      await batch.commit();
      console.log(`Committed batch. written=${written}`);
      batch = db.batch();
      ops = 0;
    }
  }

  if (ops > 0) {
    await batch.commit();
  }

  console.log(`Done. public_users written=${written}`);
}

main()
  .then(() => {
    console.log("Backfill completed.");
    process.exit(0);
  })
  .catch((error) => {
    console.error("Backfill failed:", error);
    process.exit(1);
  });