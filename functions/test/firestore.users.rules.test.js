const fs = require("fs");
const path = require("path");
const test = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");

const PROJECT_ID = "friendify-user-rules";
const USERS = "users";

const rules = fs.readFileSync(
  path.resolve(__dirname, "..", "..", "firestore.rules"),
  "utf8",
);

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules,
    },
  });
});

test.after(async () => {
  await testEnv.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

function baseUserDoc(uid) {
  return {
    uid,
    email: `${uid}@example.test`,
    displayName: "Friendify User",
    credits: 0,
    reservedCredits: 0,
    earningsCredits: 0,
    platformRevenueCredits: 0,
    photoURL: "",
    bio: "",
    gender: "",
    city: "",
    state: "",
    country: "",
    topics: [],
    languages: [],
    isListener: false,
    isAvailable: false,
    isOnCall: false,
    callAvailability: {
      onlyChatMode: false,
      updatedAt: new Date("2026-04-24T00:00:00.000Z"),
      updatedBy: uid,
    },
    followersCount: 0,
    level: 1,
    listenerRate: 5,
    following: [],
    blocked: [],
    fcmTokens: [],
    favoriteListeners: [],
    activeCallId: "",
    ratingAvg: 0,
    ratingCount: 0,
    ratingSum: 0,
    createdAt: new Date("2026-04-24T00:00:00.000Z"),
    lastSeen: new Date("2026-04-24T00:00:00.000Z"),
  };
}

function legacyPartialUserDoc(uid) {
  const doc = baseUserDoc(uid);
  delete doc.credits;
  delete doc.reservedCredits;
  delete doc.earningsCredits;
  delete doc.platformRevenueCredits;
  delete doc.followersCount;
  delete doc.level;
  delete doc.ratingAvg;
  delete doc.ratingCount;
  delete doc.ratingSum;
  doc.callAvailability = {
    onlyChatMode: false,
  };
  return doc;
}

async function seedUser(uid, data = baseUserDoc(uid)) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection(USERS).doc(uid).set(data);
  });
}

async function seedPublicUser(uid, data = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection("public_users").doc(uid).set({
      uid,
      displayName: "Public User",
      ...data,
    });
  });
}

test("normal user can update allowed profile fields", async () => {
  const uid = "safe_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    displayName: "Updated User",
    bio: "Still just a normal profile edit.",
  });

  await assertSucceeds(write);
});

test("normal user can create only a safe default own user document", async () => {
  const uid = "new_safe_user";
  const db = testEnv.authenticatedContext(uid).firestore();

  await assertSucceeds(db.collection(USERS).doc(uid).set(baseUserDoc(uid)));
});

test("normal user cannot add admin flag to own user document", async () => {
  const uid = "admin_escalation_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({admin: true});

  await assertFails(write);
});

test("normal user cannot add isAdmin flag to own user document", async () => {
  const uid = "is_admin_escalation_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({isAdmin: true});

  await assertFails(write);
});

test("normal user cannot add role admin to own user document", async () => {
  const uid = "role_escalation_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({role: "admin"});

  await assertFails(write);
});

test("normal user cannot add userRole admin to own user document", async () => {
  const uid = "user_role_escalation_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({userRole: "admin"});

  await assertFails(write);
});

test("normal user cannot change protected call or moderation fields", async () => {
  const uid = "call_lock_escalation_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  await assertFails(db.collection(USERS).doc(uid).update({
    credits: 999999,
  }));
  await assertFails(db.collection(USERS).doc(uid).update({
    activeCallId: "fake_call_lock",
  }));
  await assertFails(db.collection(USERS).doc(uid).update({
    adminBlocked: false,
  }));
});

test("normal user cannot remove protected wallet fields", async () => {
  const uid = "wallet_field_removal_user";
  const replacement = baseUserDoc(uid);
  delete replacement.credits;
  replacement.displayName = "Replacement Doc";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).set(replacement);

  await assertFails(write);
});

test("normal user cannot create unsafe admin or call-lock defaults", async () => {
  const uid = "unsafe_create_user";
  const db = testEnv.authenticatedContext(uid).firestore();

  await assertFails(db.collection(USERS).doc(uid).set({
    ...baseUserDoc(uid),
    admin: true,
  }));

  await assertFails(db.collection(USERS).doc(uid).set({
    ...baseUserDoc(uid),
    isAdmin: true,
  }));

  await assertFails(db.collection(USERS).doc(uid).set({
    ...baseUserDoc(uid),
    role: "admin",
  }));

  await assertFails(db.collection(USERS).doc(uid).set({
    ...baseUserDoc(uid),
    activeCallId: "fake_call_lock",
  }));
});

test("owner can update call availability and lastSeen only for self", async () => {
  const uid = "call_availability_owner";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: true,
      updatedAt: new Date("2026-04-24T00:05:00.000Z"),
      updatedBy: uid,
    },
    lastSeen: new Date("2026-04-24T00:05:00.000Z"),
  });

  await assertSucceeds(write);
});

test("owner can update only allowed call availability fields", async () => {
  const uid = "call_availability_minimal_owner";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  await assertSucceeds(db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: true,
    },
  }));

  await assertSucceeds(db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: false,
      updatedAt: new Date("2026-04-24T00:05:00.000Z"),
      updatedBy: uid,
    },
  }));
});

test("owner can replace stale call availability map with clean shape", async () => {
  const uid = "stale_call_availability_owner";
  await seedUser(uid, {
    ...baseUserDoc(uid),
    callAvailability: {
      onlyChatMode: false,
      staleLegacyFlag: true,
    },
  });

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: true,
      updatedAt: new Date("2026-04-24T00:05:00.000Z"),
      updatedBy: uid,
    },
    lastSeen: new Date("2026-04-24T00:05:00.000Z"),
  });

  await assertSucceeds(write);
});

test("owner cannot spoof call availability updater", async () => {
  const uid = "call_availability_spoof";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: true,
      updatedAt: new Date("2026-04-24T00:05:00.000Z"),
      updatedBy: "other_user",
    },
  });

  await assertFails(write);
});

test("owner cannot mix call availability with protected fields", async () => {
  const uid = "call_availability_protected_mix";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: true,
      updatedAt: new Date("2026-04-24T00:05:00.000Z"),
      updatedBy: uid,
    },
    activeCallId: "fake_active_call",
  });

  await assertFails(write);
});

test("non-owner cannot update another user's call availability", async () => {
  const uid = "call_availability_owner_only";
  const otherUid = "call_availability_other_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(otherUid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    callAvailability: {
      onlyChatMode: true,
      updatedAt: new Date("2026-04-24T00:05:00.000Z"),
      updatedBy: otherUid,
    },
  });

  await assertFails(write);
});

test("owner can update intended fcm and presence fields", async () => {
  const uid = "fcm_presence_owner";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  await assertSucceeds(db.collection(USERS).doc(uid).update({
    fcmTokens: ["token-placeholder"],
    lastSeen: new Date("2026-04-24T00:05:00.000Z"),
  }));

  await assertSucceeds(db.collection(USERS).doc(uid).update({
    isAvailable: true,
    lastSeen: new Date("2026-04-24T00:06:00.000Z"),
  }));
});

test("owner can update safe fields on legacy partial user doc", async () => {
  const uid = "legacy_partial_user";
  await seedUser(uid, legacyPartialUserDoc(uid));

  const db = testEnv.authenticatedContext(uid).firestore();
  await assertSucceeds(db.collection(USERS).doc(uid).update({
    fcmTokens: ["token-placeholder"],
    lastSeen: new Date("2026-04-24T00:07:00.000Z"),
  }));
});

test("legacy partial user doc still cannot add protected fields", async () => {
  const uid = "legacy_protected_user";
  await seedUser(uid, legacyPartialUserDoc(uid));

  const db = testEnv.authenticatedContext(uid).firestore();
  await assertFails(db.collection(USERS).doc(uid).update({
    credits: 999999,
  }));
});

test("non-owner cannot update users document", async () => {
  const uid = "owned_user";
  const otherUid = "other_user";
  await seedUser(uid);

  const db = testEnv.authenticatedContext(otherUid).firestore();
  const write = db.collection(USERS).doc(uid).update({
    displayName: "Not allowed",
  });

  await assertFails(write);
});

test("public users remain client read-only", async () => {
  const uid = "public_read_only_user";
  await seedPublicUser(uid);

  const db = testEnv.authenticatedContext(uid).firestore();
  await assertSucceeds(db.collection("public_users").doc(uid).get());
  await assertFails(db.collection("public_users").doc(uid).update({
    displayName: "Client write blocked",
  }));
  await assertFails(db.collection("public_users").doc("new_public_user").set({
    uid: "new_public_user",
    displayName: "Client create blocked",
  }));
});
