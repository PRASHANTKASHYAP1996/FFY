const fs = require("fs");
const path = require("path");
const test = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");

const PROJECT_ID = "friendify-call-token-rules";
const CALLS = "calls";
const PARTICIPANT_TOKENS = "participantTokens";

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

async function seedCallWithTokens() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const callRef = db.collection(CALLS).doc("call_1");
    await callRef.set({
      callerId: "caller_a",
      calleeId: "callee_b",
      channelId: "channel_1",
      status: "accepted",
    });
    await callRef.collection(PARTICIPANT_TOKENS).doc("caller_a").set({
      userId: "caller_a",
      channelId: "channel_1",
      agoraUid: 101,
      agoraToken: "caller-token",
    });
    await callRef.collection(PARTICIPANT_TOKENS).doc("callee_b").set({
      userId: "callee_b",
      channelId: "channel_1",
      agoraUid: 202,
      agoraToken: "callee-token",
    });
  });
}

function tokenDoc(db, userId) {
  return db
    .collection(CALLS)
    .doc("call_1")
    .collection(PARTICIPANT_TOKENS)
    .doc(userId);
}

test("caller can read only the caller Agora token", async () => {
  await seedCallWithTokens();

  const callerDb = testEnv.authenticatedContext("caller_a").firestore();
  await assertSucceeds(tokenDoc(callerDb, "caller_a").get());
  await assertFails(tokenDoc(callerDb, "callee_b").get());
});

test("callee can read only the callee Agora token", async () => {
  await seedCallWithTokens();

  const calleeDb = testEnv.authenticatedContext("callee_b").firestore();
  await assertSucceeds(tokenDoc(calleeDb, "callee_b").get());
  await assertFails(tokenDoc(calleeDb, "caller_a").get());
});

test("non-participant cannot read participant token docs", async () => {
  await seedCallWithTokens();

  const strangerDb = testEnv.authenticatedContext("stranger_c").firestore();
  await assertFails(tokenDoc(strangerDb, "caller_a").get());
  await assertFails(tokenDoc(strangerDb, "callee_b").get());
});