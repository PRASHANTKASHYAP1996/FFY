const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  _startCallEligibilityError,
  _computeSettlementAmounts,
  _directionalCallApprovalError,
  _buildSpeakerRequestAccessPatch,
  _buildListenerResponsePatch,
  _buildChatSessionContractFields,
  _resolveActualListenerId,
  _chatIdentityCompleteForDirection,
  _chatDirectionCompleteForDirection,
  _getTrueReservedCreditsForCalls,
  _isExpiredRingingCleanupCandidate,
  _isAcceptedCreditLimitCleanupCandidate,
  _isAcceptedStaleCleanupCandidate,
  _isMalformedRingingCleanupCandidate,
  _isMalformedAcceptedCleanupCandidate,
  _drainCallCleanupQueryBatches,
  _buildParticipantTokenDoc,
  _isEndedUnsettledRepairCandidate,
  _rejectIncomingAuthorizationError,
  _availableCreditsForCalls,
  _generateAgoraChannelId,
} = require("../src/calls");
const {
  _buildNotificationChatContract,
  _buildNotificationChatContractPayload,
  _reviewTargetsOtherParticipantFromCallData,
  _buildPublicUserProjection,
  _publicProjectionChanged,
} = require("../src/triggers");
const {
  safeReleaseReserveAndLockTx,
  callShouldKeepBusyLock,
  evaluateAgoraTokenConfig,
  assertAgoraTokenConfigReady,
  normalizedRejectedEndedReason,
} = require("../src/shared");

function makeDirectionalPair({ speakerId = "userA", listenerId = "userB" } = {}) {
  const ids = [speakerId, listenerId].sort();
  return {
    speakerId: ids[0],
    listenerId: ids[1],
    pairUserA: ids[0],
    pairUserB: ids[1],
    participantIds: ids,
    pairKey: `${ids[0]}_${ids[1]}`,
    canonicalDocId: `${ids[0]}_${ids[1]}`,
    reverseDocId: `${ids[1]}_${ids[0]}`,
    actualSpeakerId: speakerId,
    actualListenerId: listenerId,
    requesterId: speakerId,
    responderId: listenerId,
    otherId: listenerId,
  };
}

function createFakeTxHarness({
  callerId = "callerA",
  calleeId = "listenerB",
  callId = "call_123",
  caller = {},
  callee = {},
  call = {},
} = {}) {
  const store = new Map([
    [`users/${callerId}`, { ...caller }],
    [`users/${calleeId}`, { ...callee }],
    [`calls/${callId}`, { ...call }],
  ]);
  const updates = [];

  const db = {
    collection(name) {
      return {
        doc(id) {
          return {
            id,
            path: `${name}/${id}`,
          };
        },
      };
    },
  };

  const tx = {
    async getAll(...refs) {
      return refs.map((ref) => {
        const data = store.get(ref.path);
        return {
          exists: data !== undefined,
          data: () => ({ ...(data || {}) }),
        };
      });
    },
    update(ref, patch) {
      updates.push({ path: ref.path, patch });
      const prev = store.get(ref.path) || {};
      store.set(ref.path, { ...prev, ...patch });
    },
  };

  const callRef = {
    id: callId,
    path: `calls/${callId}`,
  };

  return { db, tx, callRef, store, updates };
}

function createFakeCleanupDoc(call) {
  return {
    id: call.id,
    ref: {
      id: call.id,
      path: `calls/${call.id}`,
    },
    data: () => ({ ...call }),
  };
}

function buildPagedFetchFromCalls({
  calls,
  filter,
  sortBy,
}) {
  const eligible = [...calls]
    .filter(filter)
    .sort((left, right) => {
      const leftValue = left[sortBy];
      const rightValue = right[sortBy];
      if (leftValue !== rightValue) {
        return leftValue < rightValue ? -1 : 1;
      }
      return String(left.id).localeCompare(String(right.id));
    });

  return async (cursor, batchLimit) => {
    let startIndex = 0;
    if (cursor) {
      const cursorIndex = eligible.findIndex((item) => item.id === cursor.id);
      startIndex = cursorIndex >= 0 ? cursorIndex + 1 : 0;
    }

    return eligible
      .slice(startIndex, startIndex + batchLimit)
      .map(createFakeCleanupDoc);
  };
}

test("startCall eligibility rejects non-listener users", () => {
  const error = _startCallEligibilityError({
    caller: {},
    listener: {
      isListener: false,
      isAvailable: true,
    },
  });

  assert.deepEqual(error, {
    code: "failed-precondition",
    reason: "peer_busy",
    message: "Selected user is not available for listener calls",
  });
});

test("startCall eligibility rejects offline listeners", () => {
  const error = _startCallEligibilityError({
    caller: {},
    listener: {
      isListener: true,
      isAvailable: false,
    },
  });

  assert.deepEqual(error, {
    code: "failed-precondition",
    reason: "peer_busy",
    message: "Listener is offline right now",
  });
});

test("startCall eligibility rejects only chat mode participants", () => {
  assert.deepEqual(
    _startCallEligibilityError({
      caller: {
        callAvailability: {onlyChatMode: true},
      },
      listener: {
        isListener: true,
        isAvailable: true,
      },
    }),
    {
      code: "failed-precondition",
      reason: "self_only_chat_mode",
      message: "self_only_chat_mode",
    },
  );

  assert.deepEqual(
    _startCallEligibilityError({
      caller: {},
      listener: {
        isListener: true,
        isAvailable: true,
        callAvailability: {onlyChatMode: true},
      },
    }),
    {
      code: "failed-precondition",
      reason: "peer_only_chat_mode",
      message: "peer_only_chat_mode",
    },
  );
});

test("startCall eligibility rejects deleted callers", () => {
  const error = _startCallEligibilityError({
    caller: {
      deleted: true,
    },
    listener: {
      isListener: true,
      isAvailable: true,
    },
  });

  assert.deepEqual(error, {
    code: "permission-denied",
    reason: "unknown_precondition",
    message: "Your account is not eligible to place calls",
  });
});

test("startCall eligibility precheck ignores stale activeCallId alone", () => {
  const error = _startCallEligibilityError({
    caller: {},
    listener: {
      isListener: true,
      isAvailable: true,
      activeCallId: "call_123",
      isOnCall: true,
    },
  });

  assert.equal(error, null);
});

test("startCall eligibility allows available listeners", () => {
  const error = _startCallEligibilityError({
    caller: {},
    listener: {
      isListener: true,
      isAvailable: true,
      activeCallId: "",
    },
  });

  assert.equal(error, null);
});

test("directional approval rejects opposite direction when approval belongs to A -> B", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userB",
    listenerId: "userA",
    chat: {
      participantIds: ["userA", "userB"],
      actualListenerId: "userB",
      requesterId: "userA",
      responderId: "userB",
      pendingFor: "",
      actionOwner: "userB",
      callRequestedBy: "userA",
      callAllowed: true,
      callRequestOpen: false,
    },
  });

  assert.deepEqual(error, {
    code: "failed-precondition",
    reason: "listener_mismatch",
    message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
  });
});

test("directional approval allows A -> B when approval belongs to A -> B", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userA",
    listenerId: "userB",
    chat: {
      participantIds: ["userA", "userB"],
      actualListenerId: "userB",
      requesterId: "userA",
      responderId: "userB",
      pendingFor: "",
      actionOwner: "userB",
      callRequestedBy: "userA",
      callAllowed: true,
      callRequestOpen: false,
    },
  });

  assert.equal(error, null);
});

test("directional approval allows accepted status with cleared request fields", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userA",
    listenerId: "userB",
    chat: {
      status: "accepted",
      participantIds: ["userA", "userB"],
      actualListenerId: "userB",
      requesterId: "",
      responderId: "",
      pendingFor: "",
      actionOwner: "",
      callRequestedBy: "",
      callAllowed: false,
      callRequestOpen: false,
    },
  });

  assert.equal(error, null);
});

test("directional approval allows stale open request when call is already allowed", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userA",
    listenerId: "userB",
    chat: {
      participantIds: ["userA", "userB"],
      actualListenerId: "userB",
      requesterId: "userA",
      responderId: "userB",
      pendingFor: "userB",
      actionOwner: "userB",
      callRequestedBy: "userA",
      callAllowed: true,
      callRequestOpen: true,
    },
  });

  assert.equal(error, null);
});

test("directional approval rejects open request until listener allows call", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userA",
    listenerId: "userB",
    chat: {
      participantIds: ["userA", "userB"],
      actualListenerId: "userB",
      requesterId: "userA",
      responderId: "userB",
      pendingFor: "userB",
      actionOwner: "userA",
      callRequestedBy: "userA",
      callAllowed: false,
      callRequestOpen: true,
    },
  });

  assert.deepEqual(error, {
    code: "failed-precondition",
    reason: "call_access_not_accepted",
    message: "REQUEST_NOT_APPROVED",
  });
});

test("directional approval rejects when actualListenerId does not match selected listener", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userA",
    listenerId: "userB",
    chat: {
      participantIds: ["userA", "userB"],
      actualListenerId: "userA",
      requesterId: "userA",
      responderId: "userB",
      callRequestedBy: "userA",
      callAllowed: true,
      callRequestOpen: false,
    },
  });

  assert.deepEqual(error, {
    code: "failed-precondition",
    reason: "listener_mismatch",
    message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
  });
});

test("directional approval rejects when requesterId does not match caller", () => {
  const error = _directionalCallApprovalError({
    chatExists: true,
    reverseExists: false,
    speakerId: "userA",
    listenerId: "userB",
    chat: {
      participantIds: ["userA", "userB"],
      actualListenerId: "userB",
      requesterId: "userB",
      responderId: "userB",
      callRequestedBy: "userB",
      callAllowed: true,
      callRequestOpen: false,
    },
  });

  assert.deepEqual(error, {
    code: "failed-precondition",
    reason: "caller_not_speaker",
    message: "CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION",
  });
});

test("speaker request patch writes directional contract fields", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const patch = _buildSpeakerRequestAccessPatch({
    pair,
    chat: {
      status: "accepted",
      actualListenerId: "userZ",
      requesterId: "userA",
      responderId: "userZ",
      callAllowed: true,
    },
    nowMs: 123456,
  });

  assert.equal(patch.requestAction, "request_call_access");
  assert.equal(patch.nextStatus, "accepted");
  assert.equal(patch.update.actualListenerId, "userA");
  assert.equal(patch.update.requesterId, "userZ");
  assert.equal(patch.update.responderId, "userA");
  assert.equal(patch.update.pendingFor, "userA");
  assert.equal(patch.update.actionOwner, "userZ");
  assert.equal(patch.update.callAllowed, false);
  assert.equal(patch.update.callRequestOpen, true);
  assert.equal(patch.update.callRequestedBy, "userZ");
  assert.equal(patch.update.pairKey, "userA_userZ");
  assert.deepEqual(patch.update.participantIds, ["userA", "userZ"]);
});

function assertListenerResponseMatchesStoredFields(result, action) {
  const { update, responsePayload } = result;

  assert.equal(responsePayload.status, update.status);
  assert.equal(responsePayload.callAllowed, update.callAllowed);
  assert.equal(responsePayload.callRequestOpen, update.callRequestOpen);
  assert.equal(responsePayload.callRequestedBy, update.callRequestedBy);
  assert.equal(responsePayload.actualListenerId, update.actualListenerId);
  assert.equal(responsePayload.requesterId, update.requesterId);
  assert.equal(responsePayload.responderId, update.responderId);
  assert.equal(responsePayload.pendingFor, update.pendingFor);
  assert.equal(responsePayload.actionOwner, update.actionOwner);
  assert.equal(responsePayload.speakerBlocked, update.speakerBlocked);
  assert.equal(responsePayload.listenerBlocked, update.listenerBlocked);
  assert.equal(responsePayload.action, action);

  if (update.callRequestOpen === false) {
    assert.equal(responsePayload.pendingFor, "");
  }
}

test("listener allow_chat_only response matches final stored fields", () => {
  const pair = makeDirectionalPair({ speakerId: "speakerA", listenerId: "listenerB" });
  const result = _buildListenerResponsePatch({
    pair,
    speakerId: "speakerA",
    listenerId: "listenerB",
    action: "allow_chat_only",
    nowMs: 123456,
    sessionId: "speakerA_listenerB",
    chat: {
      status: "pending",
      callAllowed: false,
      callRequestOpen: true,
      callRequestedBy: "speakerA",
      requesterId: "speakerA",
      responderId: "listenerB",
      pendingFor: "listenerB",
      actionOwner: "speakerA",
      actualListenerId: "listenerB",
      speakerBlocked: false,
      listenerBlocked: false,
    },
  });

  assertListenerResponseMatchesStoredFields(result, "allow_chat_only");
  assert.equal(result.responsePayload.status, "accepted");
  assert.equal(result.responsePayload.callAllowed, false);
  assert.equal(result.responsePayload.callRequestedBy, "");
});

test("listener allow_call response matches final stored fields", () => {
  const pair = makeDirectionalPair({ speakerId: "speakerA", listenerId: "listenerB" });
  const result = _buildListenerResponsePatch({
    pair,
    speakerId: "speakerA",
    listenerId: "listenerB",
    action: "allow_call",
    nowMs: 123456,
    sessionId: "speakerA_listenerB",
    chat: {
      status: "pending",
      callAllowed: false,
      callRequestOpen: true,
      callRequestedBy: "speakerA",
      requesterId: "speakerA",
      responderId: "listenerB",
      pendingFor: "listenerB",
      actionOwner: "speakerA",
      actualListenerId: "listenerB",
      speakerBlocked: false,
      listenerBlocked: false,
    },
  });

  assertListenerResponseMatchesStoredFields(result, "allow_call");
  assert.equal(result.responsePayload.status, "accepted");
  assert.equal(result.responsePayload.callAllowed, true);
  assert.equal(result.update.callRequestOpen, false);
  assert.equal(result.update.pendingFor, "");
  assert.equal(result.responsePayload.callRequestedBy, "speakerA");
  assert.equal(result.responsePayload.requesterId, "speakerA");
  assert.equal(result.responsePayload.responderId, "listenerB");
  assert.equal(result.update.acceptedAtMs, 123456);
  assert.equal(result.update.acceptedBy, "listenerB");
});

test("listener deny_call response matches final stored fields", () => {
  const pair = makeDirectionalPair({ speakerId: "speakerA", listenerId: "listenerB" });
  const result = _buildListenerResponsePatch({
    pair,
    speakerId: "speakerA",
    listenerId: "listenerB",
    action: "deny_call",
    nowMs: 123456,
    sessionId: "speakerA_listenerB",
    chat: {
      status: "accepted",
      callAllowed: true,
      callRequestOpen: true,
      callRequestedBy: "speakerA",
      requesterId: "speakerA",
      responderId: "listenerB",
      pendingFor: "listenerB",
      actionOwner: "speakerA",
      actualListenerId: "listenerB",
      speakerBlocked: false,
      listenerBlocked: false,
    },
  });

  assertListenerResponseMatchesStoredFields(result, "deny_call");
  assert.equal(result.responsePayload.status, "accepted");
  assert.equal(result.responsePayload.callAllowed, false);
  assert.equal(result.responsePayload.callRequestedBy, "");
});

test("listener block_pair response matches final stored fields", () => {
  const pair = makeDirectionalPair({ speakerId: "speakerA", listenerId: "listenerB" });
  const result = _buildListenerResponsePatch({
    pair,
    speakerId: "speakerA",
    listenerId: "listenerB",
    action: "block_pair",
    nowMs: 123456,
    sessionId: "speakerA_listenerB",
    chat: {
      status: "accepted",
      callAllowed: true,
      callRequestOpen: true,
      callRequestedBy: "speakerA",
      requesterId: "speakerA",
      responderId: "listenerB",
      pendingFor: "listenerB",
      actionOwner: "speakerA",
      actualListenerId: "listenerB",
      speakerBlocked: false,
      listenerBlocked: false,
    },
  });

  assertListenerResponseMatchesStoredFields(result, "block_pair");
  assert.equal(result.responsePayload.status, "blocked");
  assert.equal(result.responsePayload.listenerBlocked, true);
  assert.equal(result.responsePayload.callAllowed, false);
  assert.equal(result.responsePayload.callRequestedBy, "");
});

test("notification chat contract payload includes the directional fields", () => {
  const contract = _buildNotificationChatContract({
    chatSessionId: "userA_userB",
    fallbackSpeakerId: "userA",
    fallbackListenerId: "userB",
    session: {
      participantIds: ["userA", "userB"],
      pairUserA: "userA",
      pairUserB: "userB",
      pairKey: "userA_userB",
      actualListenerId: "userB",
      requesterId: "userA",
      responderId: "userB",
      pendingFor: "userB",
      callRequestOpen: true,
      actionOwner: "userA",
    },
  });
  const payload = _buildNotificationChatContractPayload(contract);

  assert.equal(payload.chatSessionId, "userA_userB");
  assert.equal(payload.chatId, "userA_userB");
  assert.equal(payload.pairKey, "userA_userB");
  assert.equal(payload.participantIds, JSON.stringify(["userA", "userB"]));
  assert.equal(payload.pairUserA, "userA");
  assert.equal(payload.pairUserB, "userB");
  assert.equal(payload.actualListenerId, "userB");
  assert.equal(payload.requesterId, "userA");
  assert.equal(payload.responderId, "userB");
  assert.equal(payload.pendingFor, "userB");
  assert.equal(payload.actionOwner, "userA");
});

test("notification chat contract preserves the stored opposite-direction actual listener", () => {
  const contract = _buildNotificationChatContract({
    chatSessionId: "userA_userB",
    fallbackSpeakerId: "userB",
    fallbackListenerId: "userA",
    session: {
      participantIds: ["userA", "userB"],
      pairUserA: "userA",
      pairUserB: "userB",
      pairKey: "userA_userB",
      actualListenerId: "userA",
      requesterId: "userB",
      responderId: "userA",
      pendingFor: "userA",
      actionOwner: "userB",
    },
  });
  const payload = _buildNotificationChatContractPayload(contract);

  assert.equal(payload.participantIds, JSON.stringify(["userA", "userB"]));
  assert.equal(payload.actualListenerId, "userA");
  assert.equal(payload.requesterId, "userB");
  assert.equal(payload.responderId, "userA");
});

test("notification chat contract leaves actualListenerId empty for ambiguous canonical-only sessions", () => {
  const contract = _buildNotificationChatContract({
    chatSessionId: "userA_userB",
    fallbackSpeakerId: "userA",
    fallbackListenerId: "userB",
    session: {
      participantIds: ["userA", "userB"],
      pairUserA: "userA",
      pairUserB: "userB",
      pairKey: "userA_userB",
      speakerId: "userA",
      listenerId: "userB",
    },
  });
  const payload = _buildNotificationChatContractPayload(contract);

  assert.equal(payload.participantIds, JSON.stringify(["userA", "userB"]));
  assert.equal(payload.actualListenerId, "");
  assert.equal(payload.requesterId, "");
  assert.equal(payload.responderId, "");
  assert.equal(payload.pendingFor, "");
});

test("notification chat contract keeps actualListenerId safe from stored requester direction only", () => {
  const contract = _buildNotificationChatContract({
    chatSessionId: "userA_userB",
    fallbackSpeakerId: "userA",
    fallbackListenerId: "userB",
    session: {
      participantIds: ["userA", "userB"],
      pairUserA: "userA",
      pairUserB: "userB",
      pairKey: "userA_userB",
      requesterId: "userA",
      callRequestedBy: "userA",
      callRequestOpen: true,
    },
  });
  const payload = _buildNotificationChatContractPayload(contract);

  assert.equal(payload.actualListenerId, "userB");
  assert.equal(payload.requesterId, "userA");
  assert.equal(payload.responderId, "");
  assert.equal(payload.pendingFor, "");
  assert.equal(payload.actionOwner, "");
});

test("resolveActualListenerId keeps the selected listener even when canonical listener differs", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const resolved = _resolveActualListenerId({
    pair,
    chat: {
      participantIds: ["userA", "userZ"],
      requesterId: "userZ",
      responderId: "userA",
      pendingFor: "userA",
    },
  });

  assert.equal(resolved, "userA");
});

test("resolveActualListenerId leaves ambiguous canonical sessions unresolved", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const resolved = _resolveActualListenerId({
    pair,
    chat: {
      participantIds: ["userA", "userZ"],
      speakerId: "userA",
      listenerId: "userZ",
    },
  });

  assert.equal(resolved, "");
});

test("resolveActualListenerId leaves requester-only legacy sessions unresolved", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const resolved = _resolveActualListenerId({
    pair,
    chat: {
      participantIds: ["userA", "userZ"],
      requesterId: "userZ",
      callRequestedBy: "userZ",
      callRequestOpen: true,
    },
  });

  assert.equal(resolved, "");
});

test("buildChatSessionContractFields does not backfill guessed direction for existing ambiguous session", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const contract = _buildChatSessionContractFields({
    pair,
    chat: {
      participantIds: ["userA", "userZ"],
      speakerId: "userA",
      listenerId: "userZ",
      pairUserA: "userA",
      pairUserB: "userZ",
      pairKey: "userA_userZ",
    },
  });

  assert.equal(contract.actualListenerId, "");
});

test("buildChatSessionContractFields does not backfill guessed direction from requester-only legacy state", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const contract = _buildChatSessionContractFields({
    pair,
    chat: {
      participantIds: ["userA", "userZ"],
      requesterId: "userZ",
      callRequestedBy: "userZ",
      callRequestOpen: true,
    },
  });

  assert.equal(contract.actualListenerId, "");
});

test("buildChatSessionContractFields can seed new explicit direction when creating a fresh session", () => {
  const pair = makeDirectionalPair({ speakerId: "userZ", listenerId: "userA" });
  const contract = _buildChatSessionContractFields({
    pair,
    allowPairActualListenerFallback: true,
  });

  assert.equal(contract.actualListenerId, "userA");
});

test("chat identity can be complete while direction is stale", () => {
  const chat = {
    participantIds: ["userA", "userZ"],
    speakerId: "userA",
    listenerId: "userZ",
    pairUserA: "userA",
    pairUserB: "userZ",
    pairKey: "userA_userZ",
    chatSessionId: "userA_userZ",
    actualListenerId: "userZ",
    requesterId: "userA",
    responderId: "userZ",
    pendingFor: "",
    actionOwner: "userZ",
    callRequestedBy: "userA",
    callAllowed: true,
    callRequestOpen: false,
  };

  assert.equal(
    _chatIdentityCompleteForDirection({
      chat,
      speakerId: "userZ",
      listenerId: "userA",
    }),
    true
  );
  assert.equal(
    _chatDirectionCompleteForDirection({
      chat,
      speakerId: "userZ",
      listenerId: "userA",
    }),
    false
  );
});

test("direction completion accepts the stored actual listener for reversed lexical order", () => {
  const chat = {
    participantIds: ["userA", "userZ"],
    speakerId: "userA",
    listenerId: "userZ",
    pairUserA: "userA",
    pairUserB: "userZ",
    pairKey: "userA_userZ",
    chatSessionId: "userA_userZ",
    actualListenerId: "userA",
    requesterId: "userZ",
    responderId: "userA",
    pendingFor: "",
    actionOwner: "userA",
    callRequestedBy: "userZ",
    callAllowed: true,
    callRequestOpen: false,
  };

  assert.equal(
    _chatDirectionCompleteForDirection({
      chat,
      speakerId: "userZ",
      listenerId: "userA",
    }),
    true
  );
});

test("accepted call ends and settlement releases reserve exactly once", () => {
  const firstPass = _computeSettlementAmounts({
    billedMinutes: 3,
    speakerRate: 10,
    listenerRate: 8,
    currentCredits: 100,
    currentReservedCredits: 30,
    reservedUpfront: 30,
    reserveAlreadyReleased: false,
  });

  assert.equal(firstPass.shouldReleaseReserve, true);
  assert.equal(firstPass.newReserved, 0);
  assert.equal(firstPass.safeSpeakerCharge, 30);
  assert.equal(firstPass.safeListenerPayout, 24);

  const secondPass = _computeSettlementAmounts({
    billedMinutes: 3,
    speakerRate: 10,
    listenerRate: 8,
    currentCredits: 100,
    currentReservedCredits: firstPass.newReserved,
    reservedUpfront: 30,
    reserveAlreadyReleased: true,
  });

  assert.equal(secondPass.shouldReleaseReserve, false);
  assert.equal(secondPass.newReserved, 0);
});

test("clearBusyLock_v2 running before settlement does not release reserve for unsettled accepted calls", async () => {
  const { db, tx, callRef, updates } = createFakeTxHarness({
    caller: {
      reservedCredits: 20,
      activeCallId: "call_123",
      isOnCall: true,
    },
    callee: {
      activeCallId: "call_123",
      isOnCall: true,
    },
  });

  await safeReleaseReserveAndLockTx(tx, {
    db,
    callRef,
    callData: {
      callerId: "callerA",
      calleeId: "listenerB",
      status: "ended",
      settled: false,
      reservedUpfront: 20,
      reserveReleased: false,
    },
  });

  assert.equal(updates.length, 0);
});

test("reconciliation keeps accepted unsettled reserve and busy lock", () => {
  const total = _getTrueReservedCreditsForCalls([
    { status: "ringing", reservedUpfront: 10, reserveReleased: false },
    { status: "accepted", reservedUpfront: 20, reserveReleased: false },
    {
      status: "ended",
      settled: false,
      reservedUpfront: 30,
      reserveReleased: false,
    },
    { status: "ended", settled: true, reservedUpfront: 40, reserveReleased: false },
    { status: "rejected", reservedUpfront: 50, reserveReleased: false },
    { status: "accepted", reservedUpfront: 60, reserveReleased: true },
  ]);

  assert.equal(total, 60);
  assert.equal(
    callShouldKeepBusyLock({
      status: "ended",
      settled: false,
    }),
    true
  );
});

test("insufficient current credits cannot cause listener payout greater than speaker charge", () => {
  const settlement = _computeSettlementAmounts({
    billedMinutes: 3,
    speakerRate: 10,
    listenerRate: 8,
    currentCredits: 15,
    currentReservedCredits: 30,
    reservedUpfront: 30,
    reserveAlreadyReleased: false,
  });

  assert.equal(settlement.safeSpeakerCharge, 15);
  assert.equal(settlement.safePaidMinutes, 1);
  assert.equal(settlement.safeListenerPayout, 8);
  assert.ok(settlement.safeListenerPayout <= settlement.safeSpeakerCharge);
});

test("ringing timeout/reject still releases reserve and clears locks", async () => {
  const { db, tx, callRef, store } = createFakeTxHarness({
    caller: {
      reservedCredits: 20,
      activeCallId: "call_123",
      isOnCall: true,
    },
    callee: {
      activeCallId: "call_123",
      isOnCall: true,
    },
  });

  await safeReleaseReserveAndLockTx(tx, {
    db,
    callRef,
    callData: {
      callerId: "callerA",
      calleeId: "listenerB",
      status: "rejected",
      reservedUpfront: 20,
      reserveReleased: false,
    },
  });

  assert.equal(store.get("users/callerA").reservedCredits, 0);
  assert.equal(store.get("users/callerA").activeCallId, "");
  assert.equal(store.get("users/callerA").isOnCall, false);
  assert.equal(store.get("users/listenerB").activeCallId, "");
  assert.equal(store.get("users/listenerB").isOnCall, false);
  assert.equal(store.get("calls/call_123").reserveReleased, true);
});

test("cleanup pagination reaches expired ringing calls beyond a full page of newer ringing calls", async () => {
  const nowMs = 50_000;
  const calls = [
    ...Array.from({ length: 5 }, (_, index) => ({
      id: `live_${index}`,
      status: "ringing",
      callerId: "callerA",
      calleeId: "listenerB",
      channelId: "chan_live",
      expiresAtMs: nowMs + 1_000 + index,
    })),
    ...Array.from({ length: 3 }, (_, index) => ({
      id: `expired_${index}`,
      status: "ringing",
      callerId: "callerA",
      calleeId: "listenerB",
      channelId: "chan_expired",
      expiresAtMs: nowMs - (index + 1) * 100,
    })),
  ];
  const seen = [];

  await _drainCallCleanupQueryBatches({
    batchLimit: 2,
    maxBatchCount: 4,
    fetchBatch: buildPagedFetchFromCalls({
      calls,
      filter: (call) => _isExpiredRingingCleanupCandidate(call, nowMs),
      sortBy: "expiresAtMs",
    }),
    processDoc: async (doc) => {
      seen.push(doc.id);
    },
  });

  assert.deepEqual(seen, ["expired_2", "expired_1", "expired_0"]);
});

test("ringing expired cleanup candidate only matches expired ringing calls", () => {
  assert.equal(
    _isExpiredRingingCleanupCandidate(
      {
        status: "ringing",
        expiresAtMs: 1_000,
      },
      1_000
    ),
    true
  );
  assert.equal(
    _isExpiredRingingCleanupCandidate(
      {
        status: "ringing",
        expiresAtMs: 1_001,
      },
      1_000
    ),
    false
  );
  assert.equal(
    _isExpiredRingingCleanupCandidate(
      {
        status: "accepted",
        expiresAtMs: 1_000,
      },
      1_000
    ),
    false
  );
});

test("accepted prepaid credit limit cleanup candidate matches accepted calls past the prepaid window", () => {
  assert.equal(
    _isAcceptedCreditLimitCleanupCandidate(
      {
        status: "accepted",
        prepaidEndsAtMs: 10_000,
      },
      10_000 + 1_500
    ),
    true
  );
  assert.equal(
    _isAcceptedCreditLimitCleanupCandidate(
      {
        status: "accepted",
        prepaidEndsAtMs: 10_000,
      },
      10_000 + 1_499
    ),
    false
  );
});

test("accepted stale cleanup candidate matches old accepted calls without both media joins", () => {
  assert.equal(
    _isAcceptedStaleCleanupCandidate(
      {
        status: "accepted",
        startedAtMs: 0,
        createdAtMs: 20_000,
      },
      20_000
    ),
    true
  );
  assert.equal(
    _isAcceptedStaleCleanupCandidate(
      {
        status: "accepted",
        startedAtMs: 21_000,
        createdAtMs: 20_000,
      },
      20_000
    ),
    true
  );
  assert.equal(
    _isAcceptedStaleCleanupCandidate(
      {
        status: "accepted",
        billableStartedAtMs: 21_000,
        bothJoinedAtMs: 21_000,
        createdAtMs: 20_000,
      },
      20_000
    ),
    false
  );
});

test("malformed call cleanup candidates only flag clearly invalid ringing or accepted calls", () => {
  assert.equal(
    _isMalformedRingingCleanupCandidate({
      status: "ringing",
      callerId: "callerA",
      calleeId: "listenerB",
      channelId: "",
    }),
    true
  );
  assert.equal(
    _isMalformedAcceptedCleanupCandidate({
      status: "accepted",
      callerId: "callerA",
      calleeId: "",
      channelId: "chan_1",
    }),
    true
  );
  assert.equal(
    _isMalformedAcceptedCleanupCandidate({
      status: "accepted",
      callerId: "callerA",
      calleeId: "listenerB",
      channelId: "chan_1",
    }),
    false
  );
});

test("Agora token config evaluation requires both server secrets", () => {
  const readiness = evaluateAgoraTokenConfig({
    appId: "app-id",
    appCertificate: "",
    tokenBuilderAvailable: true,
  });

  assert.equal(readiness.isReady, false);
  assert.deepEqual(readiness.missingRequirements, ["AGORA_APP_CERTIFICATE"]);
});

test("Agora token config rejects placeholder secrets", () => {
  const readiness = evaluateAgoraTokenConfig({
    appId: "<your-agora-app-id>",
    appCertificate: "replace_me",
    tokenBuilderAvailable: true,
  });

  assert.equal(readiness.isReady, false);
  assert.deepEqual(readiness.missingRequirements, [
    "AGORA_APP_ID_PLACEHOLDER",
    "AGORA_APP_CERTIFICATE_PLACEHOLDER",
  ]);
});

test("Agora channel IDs are generated with crypto randomness", () => {
  const first = _generateAgoraChannelId();
  const second = _generateAgoraChannelId();

  assert.match(first, /^[0-9a-f]{32}$/);
  assert.match(second, /^[0-9a-f]{32}$/);
  assert.notEqual(first, second);

  const callsSource = fs.readFileSync(
    path.join(__dirname, "..", "src", "calls.js"),
    "utf8"
  );
  assert.equal(callsSource.includes("Math.random()"), false);
});

test("assertAgoraTokenConfigReady throws a clear error when secrets are missing", () => {
  assert.throws(
    () =>
      assertAgoraTokenConfigReady({
        appId: "",
        appCertificate: "",
        tokenBuilderAvailable: true,
      }),
    (error) => {
      assert.equal(error.code, "failed-precondition");
      assert.equal(error.message, "server_config_missing");
      assert.equal(error.details.reason, "server_config_missing");
      assert.ok(error.details.missingRequirements.includes("AGORA_APP_ID"));
      assert.ok(
        error.details.missingRequirements.includes("AGORA_APP_CERTIFICATE")
      );
      return true;
    }
  );
});


test("participant token doc stores only one actor token", () => {
  const doc = _buildParticipantTokenDoc({
    userId: "callerA",
    channelId: "call_channel",
    agoraUid: 123,
    agoraToken: "caller-token",
    nowMs: 1713916800000,
  });

  assert.equal(doc.userId, "callerA");
  assert.equal(doc.channelId, "call_channel");
  assert.equal(doc.agoraUid, 123);
  assert.equal(doc.agoraToken, "caller-token");
  assert.equal(doc.expiresAtMs, 1713920400000);
  assert.equal(Object.hasOwn(doc, "agoraTokenCaller"), false);
  assert.equal(Object.hasOwn(doc, "agoraTokenCallee"), false);
});


test("review aggregation target validation only accepts the opposite call participant", () => {
  const call = {
    callerId: "callerA",
    calleeId: "calleeB",
    status: "ended",
  };

  assert.equal(_reviewTargetsOtherParticipantFromCallData({
    review: {
      reviewerId: "callerA",
      reviewedUserId: "calleeB",
    },
    call,
  }), true);

  assert.equal(_reviewTargetsOtherParticipantFromCallData({
    review: {
      reviewerId: "callerA",
      reviewedUserId: "strangerC",
    },
    call,
  }), false);

  assert.equal(_reviewTargetsOtherParticipantFromCallData({
    review: {
      reviewerId: "callerA",
      reviewedUserId: "calleeB",
    },
    call: {...call, status: "accepted"},
  }), false);
});


test("ended unsettled repair candidate matches only ended unsettled calls", () => {
  assert.equal(_isEndedUnsettledRepairCandidate({
    status: "ended",
    settled: false,
  }), true);
  assert.equal(_isEndedUnsettledRepairCandidate({
    status: "ended",
  }), true);
  assert.equal(_isEndedUnsettledRepairCandidate({
    status: "ended",
    settled: true,
  }), false);
  assert.equal(_isEndedUnsettledRepairCandidate({
    status: "accepted",
    settled: false,
  }), false);
});


test("reject incoming authorization allows only callee", () => {
  assert.equal(_rejectIncomingAuthorizationError({
    actorUid: "calleeB",
    calleeId: "calleeB",
  }), null);

  const callerError = _rejectIncomingAuthorizationError({
    actorUid: "callerA",
    calleeId: "calleeB",
  });
  assert.equal(callerError.code, "permission-denied");
  assert.match(callerError.message, /Only the callee/);
});

test("rejectIncomingCall_v1 wires callee-only authorization into callable flow", () => {
  const callsSource = fs.readFileSync(
    path.join(__dirname, "..", "src", "calls.js"),
    "utf8",
  );
  const start = callsSource.indexOf("exports.rejectIncomingCall_v1");
  const end = callsSource.indexOf("exports.cancelOutgoingCall_v1");
  assert.ok(start >= 0);
  assert.ok(end > start);

  const rejectCallableSource = callsSource.slice(start, end);
  assert.match(
    rejectCallableSource,
    /const\s*\{\s*callRef,\s*calleeId,\s*status\s*\}/,
  );
  assert.match(
    rejectCallableSource,
    /rejectIncomingAuthorizationError\(\{\s*actorUid,\s*calleeId,\s*\}\)/,
  );
});


test("rejected call reasons normalize timeout variants for missed-call history", () => {
  assert.equal(normalizedRejectedEndedReason("server_timeout"), "missed");
  assert.equal(normalizedRejectedEndedReason("timeout"), "missed");
  assert.equal(normalizedRejectedEndedReason(" callee_timeout "), "missed");
  assert.equal(normalizedRejectedEndedReason("ring_timeout"), "missed");
  assert.equal(normalizedRejectedEndedReason("rejected"), "rejected");
  assert.equal(normalizedRejectedEndedReason(""), "rejected");
});

test("public user projection excludes private active call identifiers", () => {
  const projection = _buildPublicUserProjection("listenerB", {
    uid: "listenerB",
    displayName: "Listener",
    isListener: true,
    isAvailable: true,
    isOnCall: true,
    activeCallId: "call_private_123",
    activeCallUpdatedAt: new Date("2026-04-24T01:00:00.000Z"),
    adminBlocked: false,
    hiddenFromDiscovery: false,
    listenerRate: 10,
    callAvailability: {
      onlyChatMode: true,
      updatedBy: "listenerB",
    },
  });

  assert.equal(projection.uid, "listenerB");
  assert.equal(Object.hasOwn(projection, "isOnCall"), false);
  assert.equal(Object.hasOwn(projection, "activeCallId"), false);
  assert.equal(Object.hasOwn(projection, "activeCallUpdatedAt"), false);
  assert.equal(Object.hasOwn(projection, "adminBlocked"), false);
  assert.equal(Object.hasOwn(projection, "hiddenFromDiscovery"), false);
  assert.deepEqual(projection.callAvailability, {onlyChatMode: true});
  assert.equal(projection.discoverable, true);
  assert.equal(_publicProjectionChanged(
    {isOnCall: false, activeCallId: "old_call"},
    {isOnCall: true, activeCallId: "new_call"},
  ), false);
  assert.equal(_publicProjectionChanged(
    {isOnCall: false, activeCallId: "old_call"},
    {isOnCall: false, activeCallId: "new_call"},
  ), false);
  assert.equal(_publicProjectionChanged(
    {callAvailability: {onlyChatMode: false}},
    {callAvailability: {onlyChatMode: true}},
  ), true);
});

test("call available balance excludes pending withdrawal holds", () => {
  assert.equal(_availableCreditsForCalls({
    credits: 100,
    reservedCredits: 0,
    pendingWithdrawalCredits: 90,
  }), 10);

  assert.equal(_availableCreditsForCalls({
    credits: 100,
    reservedCredits: 20,
    pendingWithdrawalCredits: 30,
  }), 50);

  assert.equal(_availableCreditsForCalls({
    credits: 25,
    reservedCredits: 10,
    pendingWithdrawalCredits: 20,
  }), 0);
});
