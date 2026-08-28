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


// ---------- public review mirror (public_users/{uid}/reviews/{reviewId}) ----------
// The mirror is written only by aggregateReviewToUser_v2 with an anonymous
// schema (stars, comment, createdAt, createdAtMs). It must be world-readable
// and completely client-write-denied.

const PUBLIC_REVIEW = {
  stars: 5,
  comment: "Kind and easy to talk to.",
  createdAtMs: 1770000000000,
};

async function seedPublicReview(uid, reviewId = "review_1", data = PUBLIC_REVIEW) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context
      .firestore()
      .collection("public_users")
      .doc(uid)
      .collection("reviews")
      .doc(reviewId)
      .set(data);
  });
}

test("public review mirror is readable by unauthenticated clients", async () => {
  const uid = "reviewed_listener";
  await seedPublicUser(uid);
  await seedPublicReview(uid);

  const db = testEnv.unauthenticatedContext().firestore();
  await assertSucceeds(
    db.collection("public_users").doc(uid).collection("reviews").doc("review_1").get()
  );
});

test("public review mirror is listable by unauthenticated clients", async () => {
  const uid = "reviewed_listener_list";
  await seedPublicUser(uid);
  await seedPublicReview(uid, "review_1");
  await seedPublicReview(uid, "review_2");

  const db = testEnv.unauthenticatedContext().firestore();
  await assertSucceeds(
    db.collection("public_users").doc(uid).collection("reviews").get()
  );
  await assertSucceeds(
    db
      .collection("public_users")
      .doc(uid)
      .collection("reviews")
      .orderBy("createdAtMs", "desc")
      .limit(20)
      .get()
  );
});

test("public review mirror is readable and listable by authenticated clients", async () => {
  const uid = "reviewed_listener_auth";
  await seedPublicUser(uid);
  await seedPublicReview(uid);

  const db = testEnv.authenticatedContext("some_other_user").firestore();
  await assertSucceeds(
    db.collection("public_users").doc(uid).collection("reviews").doc("review_1").get()
  );
  await assertSucceeds(
    db.collection("public_users").doc(uid).collection("reviews").get()
  );
});

test("public review mirror rejects client creates from every role", async () => {
  const uid = "reviewed_listener_create";
  await seedPublicUser(uid);

  const payload = { stars: 5, comment: "forged", createdAtMs: 1 };
  const contexts = [
    ["unauthenticated", testEnv.unauthenticatedContext()],
    ["authenticated", testEnv.authenticatedContext("random_user")],
    ["profile owner", testEnv.authenticatedContext(uid)],
  ];

  for (const [, ctx] of contexts) {
    await assertFails(
      ctx
        .firestore()
        .collection("public_users")
        .doc(uid)
        .collection("reviews")
        .doc("forged_review")
        .set(payload)
    );
  }
});

test("public review mirror rejects client updates from every role", async () => {
  const uid = "reviewed_listener_update";
  await seedPublicUser(uid);
  await seedPublicReview(uid);

  const contexts = [
    testEnv.unauthenticatedContext(),
    testEnv.authenticatedContext("random_user"),
    testEnv.authenticatedContext(uid),
  ];

  for (const ctx of contexts) {
    await assertFails(
      ctx
        .firestore()
        .collection("public_users")
        .doc(uid)
        .collection("reviews")
        .doc("review_1")
        .update({ stars: 1 })
    );
  }
});

test("public review mirror rejects client deletes from every role", async () => {
  const uid = "reviewed_listener_delete";
  await seedPublicUser(uid);
  await seedPublicReview(uid);

  const contexts = [
    testEnv.unauthenticatedContext(),
    testEnv.authenticatedContext("random_user"),
    testEnv.authenticatedContext(uid),
  ];

  for (const ctx of contexts) {
    await assertFails(
      ctx
        .firestore()
        .collection("public_users")
        .doc(uid)
        .collection("reviews")
        .doc("review_1")
        .delete()
    );
  }
});

test("parent public_users doc keeps public read and denies client writes", async () => {
  const uid = "parent_public_user";
  await seedPublicUser(uid);

  const anon = testEnv.unauthenticatedContext().firestore();
  await assertSucceeds(anon.collection("public_users").doc(uid).get());
  await assertFails(
    anon.collection("public_users").doc(uid).update({ displayName: "nope" })
  );
  await assertFails(
    anon.collection("public_users").doc("brand_new").set({ uid: "brand_new" })
  );
});

test("raw top-level reviews stay private despite the public mirror", async () => {
  const reviewId = "raw_review_1";
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection("reviews").doc(reviewId).set({
      reviewerId: "reviewer_uid",
      reviewedUserId: "listener_uid",
      stars: 5,
      comment: "raw review with identity",
      callId: "call_123",
    });
  });

  const anon = testEnv.unauthenticatedContext().firestore();
  await assertFails(anon.collection("reviews").doc(reviewId).get());

  const stranger = testEnv.authenticatedContext("unrelated_user").firestore();
  await assertFails(stranger.collection("reviews").doc(reviewId).get());
});

test("money, call and chat rules remain closed to clients", async () => {
  const uid = "unaffected_rules_user";
  const anon = testEnv.unauthenticatedContext().firestore();
  const user = testEnv.authenticatedContext(uid).firestore();

  await assertFails(anon.collection("wallet_transactions").doc("wt1").get());
  await assertFails(
    user.collection("wallet_transactions").doc("wt1").set({ userId: uid, amount: 1 })
  );
  await assertFails(
    user.collection("payment_orders").doc("po1").set({ userId: uid, amount: 1 })
  );
  await assertFails(
    user.collection("withdrawal_requests").doc("wr1").set({ userId: uid, amount: 1 })
  );
  await assertFails(user.collection("wallet_locks").doc("wl1").get());
  await assertFails(user.collection("admin_logs").doc("al1").get());
  await assertFails(user.collection("calls").doc("c1").set({ callerId: uid }));
  await assertFails(
    user.collection("chat_sessions").doc("cs1").set({ speakerId: uid })
  );
  await assertFails(
    user.collection("users").doc(uid).collection("notifications").doc("n1").set({ seen: true })
  );
});
