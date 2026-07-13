"use strict";

const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const auth = admin.auth();

// Every top-level collection the app writes. recursiveDelete also removes each
// document's sub-collections (saved_posts, notifications, participantTokens,
// messages, likes/comments/shares, followers, system/.../docs caches).
const FIRESTORE_COLLECTIONS = [
  "users",
  "public_users",
  "calls",
  "reviews",
  "reports",
  "rate_limits",
  "wallet_transactions",
  "withdrawal_requests",
  "payment_orders",
  "wallet_locks",
  "chat_sessions",
  "social_posts",
  "delete_account_requests",
  "admin_actions",
  "user_followers",
  "system",
  // Defensive: legacy collections that may hold old data even though current
  // code no longer writes them.
  "analytics",
  "admin_logs",
];

// Cloud Storage prefixes the app writes (per storage.rules everything else is
// denied, so these cover all app-uploaded files).
const STORAGE_PREFIXES = [
  "profile_photos/",
  "social_uploads/",
];

const CONFIRM_TOKEN = "RESET_FRIENDIFY";

function hasFlag(flag) {
  return process.argv.includes(flag);
}

function readOption(name) {
  const prefix = `${name}=`;
  const match = process.argv.find((arg) => arg.startsWith(prefix));
  return match ? match.slice(prefix.length) : "";
}

function formatCount(value) {
  return Number(value).toLocaleString("en-IN");
}

async function listAllAuthUsers() {
  const users = [];
  let nextPageToken;

  do {
    const result = await auth.listUsers(1000, nextPageToken);
    users.push(...result.users);
    nextPageToken = result.pageToken;
  } while (nextPageToken);

  return users;
}

async function countCollectionDocs(collectionName) {
  const snapshot = await db.collection(collectionName).count().get();
  return snapshot.data().count || 0;
}

function resolveBucketName() {
  const explicit =
    readOption("--bucket") ||
    process.env.FIREBASE_STORAGE_BUCKET ||
    process.env.STORAGE_BUCKET ||
    (admin.app().options && admin.app().options.storageBucket) ||
    "";
  if (explicit) return explicit.trim();

  const projectId =
    (admin.app().options && admin.app().options.projectId) ||
    process.env.GCLOUD_PROJECT ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    "";
  return projectId ? `${projectId}.firebasestorage.app` : "";
}

function getBucket() {
  const name = resolveBucketName();
  return name ? admin.storage().bucket(name) : admin.storage().bucket();
}

async function countStorageFiles(prefix) {
  try {
    const [files] = await getBucket().getFiles({ prefix });
    return files.length;
  } catch (error) {
    console.warn(`[storage] could not list "${prefix}": ${error.message}`);
    return 0;
  }
}

async function previewState() {
  const authUsers = await listAllAuthUsers();
  const firestoreCounts = {};

  for (const collectionName of FIRESTORE_COLLECTIONS) {
    firestoreCounts[collectionName] = await countCollectionDocs(collectionName);
  }

  const storageCounts = {};
  for (const prefix of STORAGE_PREFIXES) {
    storageCounts[prefix] = await countStorageFiles(prefix);
  }

  return {
    authUsers,
    firestoreCounts,
    storageCounts,
  };
}

async function deleteAuthUsers(users) {
  let deleted = 0;

  for (let index = 0; index < users.length; index += 1000) {
    const batch = users.slice(index, index + 1000);
    const uids = batch.map((user) => user.uid);
    if (!uids.length) continue;
    await auth.deleteUsers(uids);
    deleted += uids.length;
    console.log(`[auth] deleted ${formatCount(deleted)} user(s) so far`);
  }

  return deleted;
}

async function deleteFirestoreCollections() {
  const deletedCollections = [];

  for (const collectionName of FIRESTORE_COLLECTIONS) {
    const ref = db.collection(collectionName);
    console.log(`[firestore] deleting ${collectionName} ...`);
    await db.recursiveDelete(ref);
    deletedCollections.push(collectionName);
  }

  return deletedCollections;
}

async function deleteStorageFiles() {
  const cleared = [];

  for (const prefix of STORAGE_PREFIXES) {
    console.log(`[storage] deleting ${prefix} ...`);
    try {
      await getBucket().deleteFiles({ prefix, force: true });
      cleared.push(prefix);
    } catch (error) {
      console.warn(`[storage] failed to delete "${prefix}": ${error.message}`);
    }
  }

  return cleared;
}

function printPreview(preview) {
  console.log("");
  console.log("Friendify reset preview");
  console.log("-----------------------");
  console.log(`Firebase Auth users: ${formatCount(preview.authUsers.length)}`);

  for (const collectionName of FIRESTORE_COLLECTIONS) {
    const count = preview.firestoreCounts[collectionName] || 0;
    console.log(`${collectionName}: ${formatCount(count)} doc(s)`);
  }

  console.log("");
  console.log(`Storage bucket: ${resolveBucketName() || "(SDK default)"}`);
  for (const prefix of STORAGE_PREFIXES) {
    const count = preview.storageCounts[prefix] || 0;
    console.log(`storage ${prefix}: ${formatCount(count)} file(s)`);
  }

  console.log("");
  console.log(
    `Run with --confirm=${CONFIRM_TOKEN} to permanently delete all of the above.`
  );
  console.log("This DELETES Firestore data, Auth users, AND Cloud Storage files.");
}

async function main() {
  const preview = await previewState();
  printPreview(preview);

  const confirm = readOption("--confirm");
  if (confirm !== CONFIRM_TOKEN) {
    console.log("");
    console.log("No destructive action taken.");
    process.exit(0);
  }

  if (hasFlag("--preview-only")) {
    console.log("");
    console.log("Preview requested. No destructive action taken.");
    process.exit(0);
  }

  console.log("");
  console.log("Starting full Friendify reset...");

  const deletedAuthUsers = await deleteAuthUsers(preview.authUsers);
  const deletedCollections = await deleteFirestoreCollections();
  const clearedStoragePrefixes = await deleteStorageFiles();

  console.log("");
  console.log("Friendify reset complete");
  console.log("------------------------");
  console.log(`Deleted Firebase Auth users: ${formatCount(deletedAuthUsers)}`);
  console.log(
    `Deleted Firestore collections: ${deletedCollections.join(", ")}`
  );
  console.log(
    `Cleared Cloud Storage prefixes: ${
      clearedStoragePrefixes.length
        ? clearedStoragePrefixes.join(", ")
        : "(none)"
    }`
  );
}

main().catch((error) => {
  console.error("");
  console.error("Friendify reset failed.");
  console.error(error);
  process.exit(1);
});
