const fs = require("fs");
const path = require("path");
const test = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");

const PROJECT_ID = "friendify-review-report-rules";
const CALLS = "calls";
const REVIEWS = "reviews";
const REPORTS = "reports";

const rules = fs.readFileSync(
  path.resolve(__dirname, "..", "..", "firestore.rules"),
  "utf8",
);

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {rules},
  });
});

test.after(async () => {
  await testEnv.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

async function seedEndedCall() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection(CALLS).doc("call_1").set({
      callerId: "caller_a",
      calleeId: "callee_b",
      status: "ended",
    });
  });
}

function reviewPayload({reviewedUserId}) {
  return {
    callId: "call_1",
    reviewerId: "caller_a",
    reviewedUserId,
    stars: 5,
    comment: "Helpful listener.",
    createdAt: new Date("2026-04-24T00:00:00.000Z"),
  };
}

function reportPayload({reportedUserId, reason = "abuse"}) {
  return {
    callId: "call_1",
    reporterId: "caller_a",
    reportedUserId,
    reason,
    createdAt: new Date("2026-04-24T00:00:00.000Z"),
  };
}

test("review can target only the other call participant", async () => {
  await seedEndedCall();
  const db = testEnv.authenticatedContext("caller_a").firestore();

  await assertSucceeds(db.collection(REVIEWS).doc("call_1_caller_a").set(
    reviewPayload({reviewedUserId: "callee_b"}),
  ));

  await assertFails(db.collection(REVIEWS).doc("call_1_caller_a_2").set(
    reviewPayload({reviewedUserId: "stranger_c"}),
  ));
});

test("review comment is capped", async () => {
  await seedEndedCall();
  const db = testEnv.authenticatedContext("caller_a").firestore();

  await assertFails(db.collection(REVIEWS).doc("call_1_caller_a").set({
    ...reviewPayload({reviewedUserId: "callee_b"}),
    comment: "x".repeat(1001),
  }));
});

test("raw reviews are readable only by reviewer, reviewed user, or admin", async () => {
  await seedEndedCall();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection(REVIEWS).doc("call_1_caller_a").set(
      reviewPayload({reviewedUserId: "callee_b"}),
    );
  });

  await assertSucceeds(
    testEnv.authenticatedContext("caller_a").firestore()
      .collection(REVIEWS).doc("call_1_caller_a").get(),
  );
  await assertSucceeds(
    testEnv.authenticatedContext("callee_b").firestore()
      .collection(REVIEWS).doc("call_1_caller_a").get(),
  );
  await assertFails(
    testEnv.authenticatedContext("stranger_c").firestore()
      .collection(REVIEWS).doc("call_1_caller_a").get(),
  );
});

test("report can target only the other call participant", async () => {
  await seedEndedCall();
  const db = testEnv.authenticatedContext("caller_a").firestore();

  await assertSucceeds(db.collection(REPORTS).doc("report_1").set(
    reportPayload({reportedUserId: "callee_b"}),
  ));

  await assertFails(db.collection(REPORTS).doc("report_2").set(
    reportPayload({reportedUserId: "stranger_c"}),
  ));
});

test("report reason is capped", async () => {
  await seedEndedCall();
  const db = testEnv.authenticatedContext("caller_a").firestore();
  const oversizedReason = "x".repeat(1001);

  await assertFails(db.collection(REPORTS).doc("report_oversized").set(
    reportPayload({reportedUserId: "callee_b", reason: oversizedReason}),
  ));
});

test("raw reports are not readable by the reported user", async () => {
  await seedEndedCall();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection(REPORTS).doc("report_1").set(
      reportPayload({reportedUserId: "callee_b"}),
    );
  });

  await assertSucceeds(
    testEnv.authenticatedContext("caller_a").firestore()
      .collection(REPORTS).doc("report_1").get(),
  );
  await assertFails(
    testEnv.authenticatedContext("callee_b").firestore()
      .collection(REPORTS).doc("report_1").get(),
  );
  await assertFails(
    testEnv.authenticatedContext("stranger_c").firestore()
      .collection(REPORTS).doc("report_1").get(),
  );
});
