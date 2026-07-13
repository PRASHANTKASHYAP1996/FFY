const fs = require("fs");
const path = require("path");
const test = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");

const PROJECT_ID = "friendify-chat-message-rules";
const CHAT_SESSIONS = "chat_sessions";
const MESSAGES = "messages";

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

async function seedSession(sessionId, data) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection(CHAT_SESSIONS).doc(sessionId).set(data);
  });
}

function canonicalSessionDoc({ speakerId, listenerId }) {
  return {
    sessionId: `${speakerId}_${listenerId}`,
    speakerId,
    listenerId,
    pairUserA: speakerId,
    pairUserB: listenerId,
    participantIds: [speakerId, listenerId],
    pairKey: `${speakerId}_${listenerId}`,
  };
}

function messagePayload({ senderId, receiverId, overrides = {} }) {
  return {
    text: "hello",
    type: "text",
    senderId,
    receiverId,
    createdAt: new Date("2026-04-24T00:00:00.000Z"),
    createdAtMs: 1713916800000,
    seen: false,
    ...overrides,
  };
}

test("valid canonical parent session allows legitimate message create", async () => {
  const sessionId = "speaker_a_listener_b";
  await seedSession(
    sessionId,
    canonicalSessionDoc({
      speakerId: "speaker_a",
      listenerId: "listener_b",
    }),
  );

  const senderDb = testEnv.authenticatedContext("speaker_a").firestore();
  const write = senderDb
    .collection(CHAT_SESSIONS)
    .doc(sessionId)
    .collection(MESSAGES)
    .doc("message_1")
    .set(
      messagePayload({
        senderId: "speaker_a",
        receiverId: "listener_b",
      }),
    );

  await assertSucceeds(write);
});

test("non-participant cannot create a chat message", async () => {
  const sessionId = "speaker_a_listener_b";
  await seedSession(
    sessionId,
    canonicalSessionDoc({
      speakerId: "speaker_a",
      listenerId: "listener_b",
    }),
  );

  const outsiderDb = testEnv.authenticatedContext("outsider_c").firestore();
  const write = outsiderDb
    .collection(CHAT_SESSIONS)
    .doc(sessionId)
    .collection(MESSAGES)
    .doc("message_outsider")
    .set(
      messagePayload({
        senderId: "outsider_c",
        receiverId: "listener_b",
      }),
    );

  await assertFails(write);
});

test("participant cannot spoof senderId or receiverId", async () => {
  const sessionId = "speaker_a_listener_b";
  await seedSession(
    sessionId,
    canonicalSessionDoc({
      speakerId: "speaker_a",
      listenerId: "listener_b",
    }),
  );

  const speakerDb = testEnv.authenticatedContext("speaker_a").firestore();
  const messagesRef = speakerDb
    .collection(CHAT_SESSIONS)
    .doc(sessionId)
    .collection(MESSAGES);

  await assertFails(
    messagesRef.doc("spoof_sender").set(
      messagePayload({
        senderId: "listener_b",
        receiverId: "speaker_a",
      }),
    ),
  );

  await assertFails(
    messagesRef.doc("spoof_receiver").set(
      messagePayload({
        senderId: "speaker_a",
        receiverId: "outsider_c",
      }),
    ),
  );
});

test("legacy parent session shape with canonical doc id still denies message create", async () => {
  const sessionId = "speaker_a_listener_b";
  await seedSession(sessionId, {
    sessionId,
    speakerId: "listener_b",
    listenerId: "speaker_a",
    pairUserA: "speaker_a",
    pairUserB: "listener_b",
    participantIds: ["speaker_a", "listener_b"],
    pairKey: sessionId,
  });

  const senderDb = testEnv.authenticatedContext("speaker_a").firestore();
  const write = senderDb
    .collection(CHAT_SESSIONS)
    .doc(sessionId)
    .collection(MESSAGES)
    .doc("message_legacy")
    .set(
      messagePayload({
        senderId: "speaker_a",
        receiverId: "listener_b",
      }),
    );

  await assertFails(write);
});

test("message create rejects empty, oversized, non-text, and missing timestamp payloads", async () => {
  const sessionId = "speaker_a_listener_b";
  await seedSession(
    sessionId,
    canonicalSessionDoc({
      speakerId: "speaker_a",
      listenerId: "listener_b",
    }),
  );

  const senderDb = testEnv.authenticatedContext("speaker_a").firestore();
  const messagesRef = senderDb
    .collection(CHAT_SESSIONS)
    .doc(sessionId)
    .collection(MESSAGES);

  async function assertRejected(messageId, overrides, omittedKeys = []) {
    const payload = messagePayload({
      senderId: "speaker_a",
      receiverId: "listener_b",
      overrides,
    });
    for (const key of omittedKeys) {
      delete payload[key];
    }

    await assertFails(messagesRef.doc(messageId).set(payload));
  }

  await assertRejected("empty_text", { text: "" });
  await assertRejected("huge_text", { text: "x".repeat(2001) });
  await assertRejected("system_type", { type: "system" });
  await assertRejected("missing_created_at", {}, ["createdAt"]);
  await assertRejected("missing_created_at_ms", {}, ["createdAtMs"]);
  await assertRejected("invalid_created_at_ms", { createdAtMs: 0 });
});
