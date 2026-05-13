const {
  admin,
  functions,
  REGION,
  strOr,
  intOr,
  adminActionCategory,
  assertCallableAppCheck,
  evaluateAgoraTokenConfig,
  walletTxRef,
  createWalletTxDoc,
  deleteStoragePathIfSafe,
  deleteCollectionGroupDocsByField,
  reviewReportsForDeletedPost,
  reviewReportsForDeletedComment,
} = require("./shared");
const {
  computeWithdrawalUsableBalance,
  releaseWithdrawalHoldBalance,
} = require("./withdrawals");

async function requireAdmin(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const uid = strOr(context.auth.uid).trim();
  if (!uid) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Invalid auth context"
    );
  }

  const token = context.auth.token || {};
  const customClaimAdmin =
    token.admin === true ||
    token.isAdmin === true ||
    strOr(token.role).toLowerCase() === "admin";

  if (customClaimAdmin) {
    return {
      uid,
      source: "custom_claim",
    };
  }

  const adminSnap = await admin.firestore().collection("users").doc(uid).get();
  if (!adminSnap.exists) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Admin access required"
    );
  }

  const adminData = adminSnap.data() || {};
  const firestoreAdmin =
    adminData.isAdmin === true ||
    adminData.admin === true ||
    strOr(adminData.role).toLowerCase() === "admin" ||
    strOr(adminData.userRole).toLowerCase() === "admin";

  if (!firestoreAdmin) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Admin access required"
    );
  }

  return {
    uid,
    source: "firestore",
  };
}

exports.requireAdmin = requireAdmin;

function reportRefFor(reportId) {
  const safeReportId = strOr(reportId).trim();
  if (!safeReportId || safeReportId.includes("/") || safeReportId.length > 512) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "reportId required"
    );
  }
  return admin.firestore().collection("reports").doc(safeReportId);
}

function accountDeletionRequestRefFor(requestId) {
  const safeRequestId = strOr(requestId).trim();
  if (!safeRequestId || safeRequestId.includes("/") || safeRequestId.length > 512) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "requestId required"
    );
  }
  return admin
    .firestore()
    .collection("delete_account_requests")
    .doc(safeRequestId);
}

function adminActionRef() {
  return admin.firestore().collection("admin_actions").doc();
}

async function deleteCollectionDocs(collectionRef, batchSize = 250) {
  let deleted = 0;
  while (true) {
    const snap = await collectionRef.limit(batchSize).get();
    if (snap.empty) return deleted;
    const batch = admin.firestore().batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deleted += snap.size;
  }
}

async function deleteSavedPostRefs(postId, batchSize = 250) {
  let deleted = 0;
  while (true) {
    const snap = await admin.firestore()
      .collectionGroup("saved_posts")
      .where("postId", "==", postId)
      .limit(batchSize)
      .get();
    if (snap.empty) return deleted;
    const batch = admin.firestore().batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deleted += snap.size;
  }
}

function moderationNotificationRef(userId) {
  return admin.firestore()
    .collection("users")
    .doc(userId)
    .collection("notifications")
    .doc();
}

function moderationNotificationDoc({
  ref,
  type,
  actorId = "",
  postId = "",
  postImageURL = "",
  text = "",
  now,
}) {
  return {
    notificationId: ref.id,
    type,
    actorId,
    actorName: "Friendify",
    actorPhotoURL: "",
    postId,
    postImageURL,
    text: strOr(text).trim().slice(0, 180),
    read: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: now,
  };
}

function planWithdrawalApproval({
  request = {},
  user = {},
  adminMeta = {},
  adminNote = "",
  paymentReference = "",
  requestId = "",
}) {
  const status = strOr(request.status, "pending").toLowerCase();
  const userId = strOr(request.userId).trim();
  const amount = intOr(request.amount, 0);

  if (!userId) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Withdrawal request user missing",
    };
  }

  if (amount <= 0) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Withdrawal request amount invalid",
    };
  }

  if (status === "approved") {
    return { kind: "noop" };
  }

  if (status !== "pending") {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Only pending withdrawal requests can be approved",
    };
  }

  const credits = intOr(user.credits, 0);
  const earningsCredits = intOr(user.earningsCredits, 0);
  const reservedCredits = intOr(user.reservedCredits, 0);
  const pendingWithdrawalCredits = intOr(user.pendingWithdrawalCredits, 0);
  const heldCredits = intOr(request.heldCredits, 0);
  const usableCredits = computeWithdrawalUsableBalance({
    credits,
    reservedCredits,
    pendingWithdrawalCredits,
    currentRequestHeldCredits: heldCredits,
  });
  if (amount > earningsCredits) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: `Insufficient earningsCredits. Current earningsCredits: INR ${earningsCredits}`,
    };
  }

  if (amount > usableCredits) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: `Insufficient usable balance. Current usable balance: INR ${usableCredits}`,
    };
  }

  return {
    kind: "apply",
    userId,
    amount,
    heldCredits,
    newCredits: credits - amount,
    newEarningsCredits: earningsCredits - amount,
    newPendingWithdrawalCredits: releaseWithdrawalHoldBalance({
      currentPendingWithdrawalCredits: pendingWithdrawalCredits,
      heldCredits,
    }),
    currency: strOr(request.currency, "INR"),
    payoutMode: strOr(request.payoutMode, "manual_test"),
    realMoneyEnabled: request.realMoneyEnabled === true,
    adminNote,
    paymentReference: strOr(paymentReference).trim().slice(0, 120),
    adminUid: strOr(adminMeta.uid),
    adminSource: strOr(adminMeta.source),
  };
}

exports._planWithdrawalApproval = planWithdrawalApproval;

function planApprovedWithdrawalLedgerRepair({
  request = {},
  user = {},
  adminMeta = {},
  paymentReference = "",
  requestId = "",
  existingLedgerExists = false,
}) {
  const status = strOr(request.status, "pending").toLowerCase();
  const userId = strOr(request.userId).trim();
  const amount = intOr(request.amount, 0);
  const settlementLedgerTxId = strOr(
    request.settlementLedgerTxId ||
      request.ledgerTransactionId ||
      request.ledgerTxId ||
      ""
  ).trim();
  const settlementProofMissing =
    request.settledInLedger !== true || !settlementLedgerTxId;

  if (
    status !== "approved" ||
    (existingLedgerExists && !settlementProofMissing)
  ) {
    return { kind: "noop" };
  }

  if (!userId) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Approved withdrawal cannot be repaired: user missing",
    };
  }

  if (amount <= 0) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Approved withdrawal cannot be repaired: amount invalid",
    };
  }

  return {
    kind: existingLedgerExists ? "mark_settled" : "repair",
    userId,
    requestId: strOr(requestId).trim(),
    amount,
    balanceAfter: intOr(user.credits, 0),
    currency: strOr(request.currency, "INR"),
    payoutMode: strOr(request.payoutMode, "manual_test"),
    realMoneyEnabled: request.realMoneyEnabled === true,
    adminUid: strOr(adminMeta.uid),
    adminSource: strOr(adminMeta.source),
    paymentReference: strOr(paymentReference).trim().slice(0, 120),
    approvedBy: strOr(request.approvedBy),
    approvedAtMs: intOr(request.approvedAtMs, 0),
  };
}

exports._planApprovedWithdrawalLedgerRepair =
  planApprovedWithdrawalLedgerRepair;

function buildApprovedWithdrawalLedgerRepairMutation({
  repairPlan = {},
  requestId = "",
  ledgerTxId = "",
  currentStatus = "approved",
  now = Date.now(),
  auditActionId = "",
  serverTimestamp = () => admin.firestore.FieldValue.serverTimestamp(),
}) {
  const timestamp = serverTimestamp();
  const safeRequestId = strOr(requestId || repairPlan.requestId).trim();
  const safeLedgerTxId = strOr(ledgerTxId).trim();

  if (repairPlan.kind === "repair") {
    const ledgerDoc = createWalletTxDoc({
      userId: repairPlan.userId,
      type: "withdrawal_debit",
      amount: -repairPlan.amount,
      balanceAfter: repairPlan.balanceAfter,
      status: "completed",
      method: "manual_test",
      notes: "Approved withdrawal ledger repaired by admin",
      source: "admin_withdrawal_repair",
      currency: repairPlan.currency,
      direction: "debit",
      withdrawalRequestId: safeRequestId,
      idempotencyKey: `withdrawal_debit_${safeRequestId}`,
      metadata: {
        requestId: safeRequestId,
        repairedBy: repairPlan.adminUid,
        adminSource: repairPlan.adminSource,
        paymentReference: repairPlan.paymentReference,
        originalApprovedBy: repairPlan.approvedBy,
        approvedAtMs: repairPlan.approvedAtMs,
        payoutMode: repairPlan.payoutMode,
        realMoneyEnabled: repairPlan.realMoneyEnabled,
      },
    });
    ledgerDoc.createdAt = timestamp;

    return {
      ledgerDoc,
      requestPatch: {
        settledInLedger: true,
        settlementLedgerTxId: safeLedgerTxId,
        paymentReference: strOr(repairPlan.paymentReference),
        ledgerRepairedAt: timestamp,
        ledgerRepairedAtMs: now,
        ledgerRepairedBy: strOr(repairPlan.adminUid),
        updatedAt: timestamp,
        updatedAtMs: now,
      },
      auditDoc: {
        actionId: strOr(auditActionId),
        actionType: "withdrawal_request_ledger_repaired",
        actionCategory: "finance",
        requestId: safeRequestId,
        targetUserId: strOr(repairPlan.userId),
        adminUid: strOr(repairPlan.adminUid),
        adminSource: strOr(repairPlan.adminSource),
        beforeStatus: strOr(currentStatus),
        afterStatus: "approved",
        amount: intOr(repairPlan.amount, 0),
        currency: strOr(repairPlan.currency, "INR"),
        paymentReference: strOr(repairPlan.paymentReference),
        ledgerTxId: safeLedgerTxId,
        originalApprovedBy: strOr(repairPlan.approvedBy),
        originalApprovedAtMs: intOr(repairPlan.approvedAtMs, 0),
        createdAt: timestamp,
        createdAtMs: now,
      },
    };
  }

  if (repairPlan.kind === "mark_settled") {
    return {
      ledgerDoc: null,
      requestPatch: {
        settledInLedger: true,
        settlementLedgerTxId: safeLedgerTxId,
        ledgerProofRepairedAt: timestamp,
        ledgerProofRepairedAtMs: now,
        ledgerProofRepairedBy: strOr(repairPlan.adminUid),
        updatedAt: timestamp,
        updatedAtMs: now,
      },
      auditDoc: {
        actionId: strOr(auditActionId),
        actionType: "withdrawal_request_ledger_proof_repaired",
        actionCategory: "finance",
        requestId: safeRequestId,
        targetUserId: strOr(repairPlan.userId),
        adminUid: strOr(repairPlan.adminUid),
        adminSource: strOr(repairPlan.adminSource),
        beforeStatus: strOr(currentStatus),
        afterStatus: "approved",
        amount: intOr(repairPlan.amount, 0),
        currency: strOr(repairPlan.currency, "INR"),
        ledgerTxId: safeLedgerTxId,
        originalApprovedBy: strOr(repairPlan.approvedBy),
        originalApprovedAtMs: intOr(repairPlan.approvedAtMs, 0),
        createdAt: timestamp,
        createdAtMs: now,
      },
    };
  }

  return {
    ledgerDoc: null,
    requestPatch: null,
    auditDoc: null,
  };
}

exports._buildApprovedWithdrawalLedgerRepairMutation =
  buildApprovedWithdrawalLedgerRepairMutation;

function planRejectedWithdrawalHoldRepair({
  request = {},
  user = {},
  adminMeta = {},
  requestId = "",
}) {
  const status = strOr(request.status, "pending").toLowerCase();
  const holdStatus = strOr(request.holdStatus).toLowerCase();
  const userId = strOr(request.userId).trim();
  const heldCredits = intOr(request.heldCredits, 0);

  if (status !== "rejected" || heldCredits <= 0 || holdStatus === "released") {
    return { kind: "noop" };
  }

  if (!userId) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Rejected withdrawal hold cannot be repaired: user missing",
    };
  }

  const pendingWithdrawalCredits = intOr(user.pendingWithdrawalCredits, 0);

  return {
    kind: "repair",
    userId,
    requestId: strOr(requestId).trim(),
    heldCredits,
    newPendingWithdrawalCredits: releaseWithdrawalHoldBalance({
      currentPendingWithdrawalCredits: pendingWithdrawalCredits,
      heldCredits,
    }),
    adminUid: strOr(adminMeta.uid),
    adminSource: strOr(adminMeta.source),
    rejectedBy: strOr(request.rejectedBy),
    rejectedAtMs: intOr(request.rejectedAtMs, 0),
  };
}

exports._planRejectedWithdrawalHoldRepair = planRejectedWithdrawalHoldRepair;

function planWithdrawalPayoutProofUpdate({
  request = {},
  adminMeta = {},
  paymentReference = "",
  adminNote = "",
  requestId = "",
}) {
  const status = strOr(request.status, "pending").toLowerCase();
  const userId = strOr(request.userId).trim();
  const safePaymentReference = strOr(paymentReference).trim().slice(0, 120);

  if (!safePaymentReference) {
    return {
      kind: "error",
      code: "invalid-argument",
      message: "paymentReference required",
    };
  }

  if (!userId) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Withdrawal request user missing",
    };
  }

  if (status !== "approved") {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Only approved withdrawal requests can receive payout proof",
    };
  }

  return {
    kind: "apply",
    requestId: strOr(requestId).trim(),
    userId,
    amount: intOr(request.amount, 0),
    currency: strOr(request.currency, "INR"),
    beforePaymentReference: strOr(request.paymentReference).trim(),
    paymentReference: safePaymentReference,
    adminNote: strOr(adminNote).trim().slice(0, 1000),
    adminUid: strOr(adminMeta.uid),
    adminSource: strOr(adminMeta.source),
    settlementLedgerTxId: strOr(
      request.settlementLedgerTxId ||
        request.ledgerTransactionId ||
        request.ledgerTxId ||
        ""
    ).trim(),
  };
}

exports._planWithdrawalPayoutProofUpdate =
  planWithdrawalPayoutProofUpdate;

function buildWithdrawalPayoutProofMutation({
  proofPlan = {},
  now = Date.now(),
  auditActionId = "",
  serverTimestamp = () => admin.firestore.FieldValue.serverTimestamp(),
}) {
  const timestamp = serverTimestamp();
  const requestPatch = {
    paymentReference: strOr(proofPlan.paymentReference).trim(),
    payoutProofUpdatedAt: timestamp,
    payoutProofUpdatedAtMs: now,
    payoutProofUpdatedBy: strOr(proofPlan.adminUid),
    payoutProofAdminNote: strOr(proofPlan.adminNote),
    updatedAt: timestamp,
    updatedAtMs: now,
  };

  const ledgerPatch = proofPlan.settlementLedgerTxId
    ? {
        metadata: {
          paymentReference: strOr(proofPlan.paymentReference).trim(),
          payoutProofUpdatedBy: strOr(proofPlan.adminUid),
          payoutProofUpdatedAtMs: now,
        },
        updatedAt: timestamp,
        updatedAtMs: now,
      }
    : null;

  const auditDoc = {
    actionId: strOr(auditActionId),
    actionType: "withdrawal_payout_proof_updated",
    actionCategory: "finance",
    requestId: strOr(proofPlan.requestId),
    targetUserId: strOr(proofPlan.userId),
    adminUid: strOr(proofPlan.adminUid),
    adminSource: strOr(proofPlan.adminSource),
    beforeStatus: "approved",
    afterStatus: "approved",
    amount: intOr(proofPlan.amount, 0),
    currency: strOr(proofPlan.currency, "INR"),
    beforePaymentReference: strOr(proofPlan.beforePaymentReference),
    paymentReference: strOr(proofPlan.paymentReference).trim(),
    note: strOr(proofPlan.adminNote),
    notePresent: strOr(proofPlan.adminNote).length > 0,
    ledgerTxId: strOr(proofPlan.settlementLedgerTxId),
    createdAt: timestamp,
    createdAtMs: now,
  };

  return {
    requestPatch,
    ledgerPatch,
    ledgerOptions: { merge: true },
    auditDoc,
  };
}

exports._buildWithdrawalPayoutProofMutation =
  buildWithdrawalPayoutProofMutation;

exports.requestAccountDeletion_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "requestAccountDeletion_v1");

    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "Login required");
    }

    const userId = strOr(context.auth.uid).trim();
    if (!userId) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Invalid auth context"
      );
    }

    const reason = strOr(data && data.reason, "").trim().slice(0, 500);
    const note = strOr(data && data.note, "").trim().slice(0, 500);

    const db = admin.firestore();
    const userRef = db.collection("users").doc(userId);

    const [userSnap, existingPendingSnap] = await Promise.all([
      userRef.get(),
      db
        .collection("delete_account_requests")
        .where("userId", "==", userId)
        .where("status", "==", "pending")
        .limit(1)
        .get(),
    ]);

    if (!userSnap.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "User profile missing"
      );
    }

    if (!existingPendingSnap.empty) {
      const existing = existingPendingSnap.docs[0];
      return {
        ok: true,
        requestId: existing.id,
        status: "pending",
        alreadyPending: true,
      };
    }

    const user = userSnap.data() || {};
    const displayName = strOr(user.displayName, "Friendify User");
    const email = strOr(user.email, "");
    const nowMs = Date.now();

    const requestRef = db.collection("delete_account_requests").doc();

    await db.runTransaction(async (tx) => {
      tx.set(requestRef, {
        userId,
        displayName,
        email,
        reason,
        note,
        status: "pending",
        requestedAt: admin.firestore.FieldValue.serverTimestamp(),
        requestedAtMs: nowMs,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
        adminNote: "",
        reviewedBy: "",
        reviewedAt: null,
        reviewedAtMs: 0,
        outcome: "",
        requestSource: "in_app",
        retentionPolicyApplied: false,
      });

      tx.set(userRef, {
        accountDeletionRequestId: requestRef.id,
        accountDeletionRequestStatus: "pending",
        accountDeletionRequestOutcome: "",
        accountDeletionRequestRequestedAt:
          admin.firestore.FieldValue.serverTimestamp(),
        accountDeletionRequestRequestedAtMs: nowMs,
        accountDeletionRequestReviewedAt: null,
        accountDeletionRequestReviewedAtMs: 0,
        accountDeletionRequestReviewedBy: "",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    return {
      ok: true,
      requestId: requestRef.id,
      status: "pending",
      alreadyPending: false,
    };
  });

exports.adminReviewAccountDeletionRequest_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminReviewAccountDeletionRequest_v1");
    const adminMeta = await requireAdmin(context);
    const requestRef = accountDeletionRequestRefFor(data && data.requestId);
    const requestedOutcome = strOr(data && data.outcome, "completed")
      .trim()
      .toLowerCase();
    const outcome = requestedOutcome === "rejected" ? "rejected" : "completed";
    const note = strOr(data && data.note).trim().slice(0, 1000);
    const retentionPolicyApplied = data && data.retentionPolicyApplied === true;
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const requestSnap = await tx.get(requestRef);
      if (!requestSnap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Delete-account request not found"
        );
      }

      const request = requestSnap.data() || {};
      const userId = strOr(request.userId).trim();
      const currentStatus = strOr(request.status, "pending").toLowerCase();
      const currentOutcome = strOr(request.outcome).trim();

      if (currentStatus !== "pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Delete-account request is already reviewed"
        );
      }

      tx.update(requestRef, {
        status: "reviewed",
        outcome,
        adminNote: note,
        reviewedBy: adminMeta.uid,
        reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewedAtMs: now,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: now,
        retentionPolicyApplied,
      });

      if (userId) {
        const userRef = admin.firestore().collection("users").doc(userId);
        const notificationRef = moderationNotificationRef(userId);
        tx.set(
          userRef,
          {
            accountDeletionRequestId: requestRef.id,
            accountDeletionRequestStatus: "reviewed",
            accountDeletionRequestOutcome: outcome,
            accountDeletionRequestReviewedAt:
              admin.firestore.FieldValue.serverTimestamp(),
            accountDeletionRequestReviewedAtMs: now,
            accountDeletionRequestReviewedBy: adminMeta.uid,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        tx.set(notificationRef, moderationNotificationDoc({
          ref: notificationRef,
          type: "account_deletion_request_reviewed",
          actorId: adminMeta.uid,
          text: outcome === "completed"
            ? "Your delete-account request has been marked complete by the Friendify team."
            : (note || "Your delete-account request was reviewed by the Friendify team."),
          now,
        }));
      }

      const auditRef = adminActionRef();
      tx.set(auditRef, {
        actionId: auditRef.id,
        actionType: "account_deletion_request_reviewed",
        actionCategory: adminActionCategory("account_deletion_request_reviewed"),
        requestId: requestRef.id,
        targetUserId: userId,
        adminUid: adminMeta.uid,
        adminSource: adminMeta.source,
        beforeStatus: currentStatus,
        beforeOutcome: currentOutcome,
        afterStatus: "reviewed",
        afterOutcome: outcome,
        note: note,
        notePresent: note.length > 0,
        retentionPolicyApplied,
        requestedAtMs: intOr(request.requestedAtMs, 0),
        reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewedAtMs: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
    });

    return {
      ok: true,
      requestId: requestRef.id,
      status: "reviewed",
      outcome,
      retentionPolicyApplied,
      auditLogged: true,
    };
  });
exports.adminApproveWithdrawal_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminApproveWithdrawal_v1");

    const adminMeta = await requireAdmin(context);

    const requestId = strOr(data && data.requestId).trim();
    const adminNote = strOr(data && data.adminNote).trim().slice(0, 1000);
    const paymentReference = strOr(data && (
      data.paymentReference || data.payoutReference
    )).trim().slice(0, 120);

    if (!requestId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "requestId required"
      );
    }

    const db = admin.firestore();
    const requestRef = db.collection("withdrawal_requests").doc(requestId);
    const now = Date.now();

    await db.runTransaction(async (tx) => {
      const requestSnap = await tx.get(requestRef);
      if (!requestSnap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Withdrawal request not found"
        );
      }

      const req = requestSnap.data() || {};
      const userId = strOr(req.userId).trim();
      const currentStatus = strOr(req.status, "pending").trim().toLowerCase();
      if (!userId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Withdrawal request user missing"
        );
      }
      const userRef = db.collection("users").doc(userId);
      const ledgerRef = walletTxRef(db, `withdrawal_${requestId}_debit`);

      const [userSnap, existingLedgerSnap] = await Promise.all([
        tx.get(userRef),
        tx.get(ledgerRef),
      ]);

      if (!userSnap.exists) {
        throw new functions.https.HttpsError("not-found", "User not found");
      }

      const user = userSnap.data() || {};
      const approvalPlan = planWithdrawalApproval({
        request: req,
        user,
        adminMeta,
        adminNote,
        paymentReference,
        requestId,
      });

      if (approvalPlan.kind === "noop") {
        const repairPlan = planApprovedWithdrawalLedgerRepair({
          request: req,
          user,
          adminMeta,
          paymentReference,
          requestId,
          existingLedgerExists: existingLedgerSnap.exists,
        });

        if (repairPlan.kind === "error") {
          throw new functions.https.HttpsError(
            repairPlan.code,
            repairPlan.message
          );
        }

        if (repairPlan.kind === "repair") {
          const auditRef = adminActionRef();
          const mutation = buildApprovedWithdrawalLedgerRepairMutation({
            repairPlan,
            requestId,
            ledgerTxId: ledgerRef.id,
            currentStatus,
            now,
            auditActionId: auditRef.id,
          });

          tx.set(ledgerRef, mutation.ledgerDoc);
          tx.update(requestRef, mutation.requestPatch);
          tx.set(auditRef, mutation.auditDoc);
        }

        if (repairPlan.kind === "mark_settled") {
          const auditRef = adminActionRef();
          const mutation = buildApprovedWithdrawalLedgerRepairMutation({
            repairPlan,
            requestId,
            ledgerTxId: ledgerRef.id,
            currentStatus,
            now,
            auditActionId: auditRef.id,
          });

          tx.update(requestRef, mutation.requestPatch);
          tx.set(auditRef, mutation.auditDoc);
        }

        return;
      }

      if (approvalPlan.kind === "error") {
        throw new functions.https.HttpsError(
          approvalPlan.code,
          approvalPlan.message
        );
      }

      tx.update(userRef, {
        credits: approvalPlan.newCredits,
        earningsCredits: approvalPlan.newEarningsCredits,
        pendingWithdrawalCredits: approvalPlan.newPendingWithdrawalCredits,
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      if (!existingLedgerSnap.exists) {
        tx.set(
          ledgerRef,
          createWalletTxDoc({
            userId: approvalPlan.userId,
            type: "withdrawal_debit",
            amount: -approvalPlan.amount,
            balanceAfter: approvalPlan.newCredits,
            status: "completed",
            method: "manual_test",
            notes: `Withdrawal approved by admin${adminNote ? `: ${adminNote}` : ""}`,
            source: "admin_withdrawal",
            currency: approvalPlan.currency,
            direction: "debit",
            withdrawalRequestId: requestId,
            idempotencyKey: `withdrawal_debit_${requestId}`,
            metadata: {
              requestId,
              approvedBy: approvalPlan.adminUid,
              adminSource: approvalPlan.adminSource,
              paymentReference: approvalPlan.paymentReference,
              payoutMode: approvalPlan.payoutMode,
              realMoneyEnabled: approvalPlan.realMoneyEnabled,
            },
          })
        );
      }

      tx.update(requestRef, {
        status: "approved",
        adminNote,
        approvedAt: admin.firestore.FieldValue.serverTimestamp(),
        approvedAtMs: now,
        approvedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: now,
        statusReason: "",
        settledInLedger: true,
        settlementLedgerTxId: ledgerRef.id,
        paymentReference: approvalPlan.paymentReference,
        remainingEarningsAfterApproval: approvalPlan.newEarningsCredits,
        holdStatus: approvalPlan.heldCredits > 0
          ? "consumed"
          : strOr(req.holdStatus),
        holdReleasedAt: approvalPlan.heldCredits > 0
          ? admin.firestore.FieldValue.serverTimestamp()
          : req.holdReleasedAt || null,
        holdReleaseReason: approvalPlan.heldCredits > 0
          ? "consumed_on_approval"
          : strOr(req.holdReleaseReason),
      });

      const notificationRef = moderationNotificationRef(userId);
      tx.set(notificationRef, moderationNotificationDoc({
        ref: notificationRef,
        type: "withdrawal_request_approved",
        actorId: adminMeta.uid,
        text: adminNote
          ? `Your withdrawal request was approved. Admin note: ${adminNote}`
          : "Your withdrawal request was approved.",
        now,
      }));

      const auditRef = adminActionRef();
      tx.set(auditRef, {
        actionId: auditRef.id,
        actionType: "withdrawal_request_approved",
        actionCategory: adminActionCategory("withdrawal_request_approved"),
        requestId,
        targetUserId: userId,
        adminUid: adminMeta.uid,
        adminSource: adminMeta.source,
        beforeStatus: currentStatus,
        afterStatus: "approved",
        afterOutcome: approvalPlan.payoutMode,
        amount: approvalPlan.amount,
        currency: approvalPlan.currency,
        paymentReference: approvalPlan.paymentReference,
        note: adminNote,
        notePresent: adminNote.length > 0,
        ledgerTxId: ledgerRef.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
    });

    return { ok: true, requestId, status: "approved", auditLogged: true };
  });

exports.adminRejectWithdrawal_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminRejectWithdrawal_v1");

    const adminMeta = await requireAdmin(context);

    const requestId = strOr(data && data.requestId).trim();
    const reason = strOr(data && data.reason, "Rejected by admin").trim();

    if (!requestId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "requestId required"
      );
    }

    const db = admin.firestore();
    const requestRef = db.collection("withdrawal_requests").doc(requestId);
    const now = Date.now();

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(requestRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Withdrawal request not found"
        );
      }

      const req = snap.data() || {};
      const status = strOr(req.status, "pending").toLowerCase();
      const userId = strOr(req.userId).trim();
      const heldCredits = intOr(req.heldCredits, 0);
      const userRef = userId ? db.collection("users").doc(userId) : null;
      const userSnap = userRef ? await tx.get(userRef) : null;

      if (status === "rejected") {
        const repairPlan = planRejectedWithdrawalHoldRepair({
          request: req,
          user: userSnap && userSnap.exists ? userSnap.data() || {} : {},
          adminMeta,
          requestId,
        });

        if (repairPlan.kind === "error") {
          throw new functions.https.HttpsError(
            repairPlan.code,
            repairPlan.message
          );
        }

        if (repairPlan.kind === "repair") {
          if (!userRef || !userSnap || !userSnap.exists) {
            throw new functions.https.HttpsError(
              "not-found",
              "User not found"
            );
          }

          tx.update(userRef, {
            pendingWithdrawalCredits: repairPlan.newPendingWithdrawalCredits,
            lastSeen: admin.firestore.FieldValue.serverTimestamp(),
          });

          tx.update(requestRef, {
            holdStatus: "released",
            holdReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
            holdReleasedAtMs: now,
            holdReleaseReason: "rejected_hold_repair",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAtMs: now,
          });

          const auditRef = adminActionRef();
          tx.set(auditRef, {
            actionId: auditRef.id,
            actionType: "withdrawal_request_hold_repaired",
            actionCategory: adminActionCategory("withdrawal_request_hold_repaired"),
            requestId,
            targetUserId: repairPlan.userId,
            adminUid: adminMeta.uid,
            adminSource: adminMeta.source,
            beforeStatus: status,
            afterStatus: "rejected",
            afterOutcome: "hold_released",
            heldCredits: repairPlan.heldCredits,
            pendingWithdrawalCreditsAfter:
              repairPlan.newPendingWithdrawalCredits,
            originalRejectedBy: repairPlan.rejectedBy,
            originalRejectedAtMs: repairPlan.rejectedAtMs,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdAtMs: now,
          });
        }

        return;
      }

      if (status !== "pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only pending withdrawal requests can be rejected"
        );
      }

      if (userRef && userSnap && userSnap.exists && heldCredits > 0) {
        const user = userSnap.data() || {};
        const pendingWithdrawalCredits = intOr(user.pendingWithdrawalCredits, 0);
        tx.update(userRef, {
          pendingWithdrawalCredits: releaseWithdrawalHoldBalance({
            currentPendingWithdrawalCredits: pendingWithdrawalCredits,
            heldCredits,
          }),
          lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      tx.update(requestRef, {
        status: "rejected",
        adminNote: reason || "Rejected by admin",
        rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
        rejectedAtMs: now,
        rejectedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: now,
        statusReason: reason || "Rejected by admin",
        settledInLedger: false,
        holdStatus: "released",
        holdReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
        holdReleaseReason: "rejected_by_admin",
      });

      if (userId) {
        const notificationRef = moderationNotificationRef(userId);
        tx.set(notificationRef, moderationNotificationDoc({
          ref: notificationRef,
          type: "withdrawal_request_rejected",
          actorId: adminMeta.uid,
          text: reason
            ? `Your withdrawal request was rejected. Reason: ${reason}`
            : "Your withdrawal request was rejected.",
          now,
        }));
      }

      const auditRef = adminActionRef();
      tx.set(auditRef, {
        actionId: auditRef.id,
        actionType: "withdrawal_request_rejected",
        actionCategory: adminActionCategory("withdrawal_request_rejected"),
        requestId,
        targetUserId: userId,
        adminUid: adminMeta.uid,
        adminSource: adminMeta.source,
        beforeStatus: status,
        afterStatus: "rejected",
        afterOutcome: "rejected_by_admin",
        amount: intOr(req.amount, 0),
        currency: strOr(req.currency, "INR"),
        note: reason || "Rejected by admin",
        notePresent: true,
        heldCredits,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
    });

    return { ok: true, requestId, status: "rejected", auditLogged: true };
  });

exports.adminUpdateWithdrawalPayoutProof_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminUpdateWithdrawalPayoutProof_v1");

    const adminMeta = await requireAdmin(context);
    const requestId = strOr(data && data.requestId).trim();
    const paymentReference = strOr(data && (
      data.paymentReference || data.payoutReference
    )).trim();
    const adminNote = strOr(data && data.adminNote).trim();

    if (!requestId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "requestId required"
      );
    }

    const db = admin.firestore();
    const requestRef = db.collection("withdrawal_requests").doc(requestId);
    const now = Date.now();

    await db.runTransaction(async (tx) => {
      const requestSnap = await tx.get(requestRef);
      if (!requestSnap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Withdrawal request not found"
        );
      }

      const req = requestSnap.data() || {};
      const proofPlan = planWithdrawalPayoutProofUpdate({
        request: req,
        adminMeta,
        paymentReference,
        adminNote,
        requestId,
      });

      if (proofPlan.kind === "error") {
        throw new functions.https.HttpsError(
          proofPlan.code,
          proofPlan.message
        );
      }

      const auditRef = adminActionRef();
      const mutation = buildWithdrawalPayoutProofMutation({
        proofPlan,
        now,
        auditActionId: auditRef.id,
      });

      tx.update(requestRef, mutation.requestPatch);

      if (proofPlan.settlementLedgerTxId) {
        const ledgerRef = walletTxRef(db, proofPlan.settlementLedgerTxId);
        tx.set(
          ledgerRef,
          mutation.ledgerPatch,
          mutation.ledgerOptions
        );
      }

      tx.set(auditRef, mutation.auditDoc);
    });

    return {
      ok: true,
      requestId,
      paymentReference: paymentReference.slice(0, 120).trim(),
      auditLogged: true,
    };
  });

// ---------- ADMIN USER MODERATION ----------
exports.adminBlockUser_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminBlockUser_v1");

    const adminMeta = await requireAdmin(context);

    const userId = strOr(data && data.userId).trim();
    const reason = strOr(data && data.reason, "Blocked by admin").trim();

    if (!userId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "userId required"
      );
    }

    const db = admin.firestore();
    const userRef = db.collection("users").doc(userId);
    const now = Date.now();

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "User not found");
      }

      const user = snap.data() || {};
      const wasBlocked = user.adminBlocked === true;
      const previousReason = strOr(user.adminBlockReason).trim();

      tx.update(userRef, {
        adminBlocked: true,
        adminBlockReason: reason || "Blocked by admin",
        adminBlockedAt: admin.firestore.FieldValue.serverTimestamp(),
        adminBlockedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const notificationRef = moderationNotificationRef(userId);
      tx.set(notificationRef, moderationNotificationDoc({
        ref: notificationRef,
        type: "account_blocked_by_admin",
        actorId: adminMeta.uid,
        text: reason
          ? `Your account was restricted. Reason: ${reason}`
          : "Your account was restricted by the Friendify team.",
        now,
      }));

      const auditRef = adminActionRef();
      tx.set(auditRef, {
        actionId: auditRef.id,
        actionType: "user_blocked",
        actionCategory: adminActionCategory("user_blocked"),
        targetUserId: userId,
        adminUid: adminMeta.uid,
        adminSource: adminMeta.source,
        beforeStatus: wasBlocked ? "blocked" : "active",
        beforeOutcome: previousReason,
        afterStatus: "blocked",
        afterOutcome: reason || "Blocked by admin",
        note: reason || "Blocked by admin",
        notePresent: true,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
    });

    return { ok: true, userId, status: "blocked", auditLogged: true };
  });

exports.adminUnblockUser_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminUnblockUser_v1");

    const adminMeta = await requireAdmin(context);

    const userId = strOr(data && data.userId).trim();

    if (!userId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "userId required"
      );
    }

    const db = admin.firestore();
    const userRef = db.collection("users").doc(userId);
    const now = Date.now();

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "User not found");
      }

      const user = snap.data() || {};
      const wasBlocked = user.adminBlocked === true;
      const previousReason = strOr(user.adminBlockReason).trim();

      tx.update(userRef, {
        adminBlocked: false,
        adminBlockReason: "",
        adminBlockedAt: null,
        adminBlockedBy: "",
        adminUnblockedAt: admin.firestore.FieldValue.serverTimestamp(),
        adminUnblockedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const notificationRef = moderationNotificationRef(userId);
      tx.set(notificationRef, moderationNotificationDoc({
        ref: notificationRef,
        type: "account_unblocked_by_admin",
        actorId: adminMeta.uid,
        text: "Your account restriction was lifted by the Friendify team.",
        now,
      }));

      const auditRef = adminActionRef();
      tx.set(auditRef, {
        actionId: auditRef.id,
        actionType: "user_unblocked",
        actionCategory: adminActionCategory("user_unblocked"),
        targetUserId: userId,
        adminUid: adminMeta.uid,
        adminSource: adminMeta.source,
        beforeStatus: wasBlocked ? "blocked" : "active",
        beforeOutcome: previousReason,
        afterStatus: "active",
        note: "",
        notePresent: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
    });

    return { ok: true, userId, status: "active", auditLogged: true };
  });

exports.adminResolveReport_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminResolveReport_v1");
    const adminMeta = await requireAdmin(context);
    const reportRef = reportRefFor(data && data.reportId);
    const resolution = strOr(data && data.resolution, "dismissed").trim() ||
      "dismissed";
    const note = strOr(data && data.note).trim();
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const reportSnap = await tx.get(reportRef);
      if (!reportSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Report not found");
      }
      const report = reportSnap.data() || {};
      const currentStatus = strOr(report.status, "open").trim().toLowerCase();
      const currentResolution = strOr(report.resolution).trim();
      tx.update(reportRef, {
        status: "reviewed",
        resolution,
        adminNote: note,
        reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewedAtMs: now,
        reviewedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: now,
      });
      const reporterId = strOr(report.reporterId).trim();
      if (reporterId) {
        const notificationRef = moderationNotificationRef(reporterId);
        tx.set(notificationRef, moderationNotificationDoc({
          ref: notificationRef,
          type: "moderation_report_reviewed",
          actorId: adminMeta.uid,
          postId: strOr(report.postId).trim(),
          text: note || "Your report was reviewed by the Friendify team.",
          now,
        }));
      }

      const auditRef = adminActionRef();
      tx.set(auditRef, {
        actionId: auditRef.id,
        actionType: "moderation_report_resolved",
        actionCategory: adminActionCategory("moderation_report_resolved"),
        reportId: reportRef.id,
        targetUserId: strOr(report.reportedUserId).trim(),
        reporterId: reporterId,
        postId: strOr(report.postId).trim(),
        commentId: strOr(report.commentId).trim(),
        adminUid: adminMeta.uid,
        adminSource: adminMeta.source,
        beforeStatus: currentStatus,
        beforeOutcome: currentResolution,
        afterStatus: "reviewed",
        afterOutcome: resolution,
        note: note,
        notePresent: note.length > 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
    });

    return {
      ok: true,
      reportId: reportRef.id,
      status: "reviewed",
      auditLogged: true,
    };
  });

exports.adminDeleteReportedContent_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "adminDeleteReportedContent_v1");
    const adminMeta = await requireAdmin(context);
    const db = admin.firestore();
    const reportRef = reportRefFor(data && data.reportId);
    const reportSnap = await reportRef.get();
    if (!reportSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Report not found");
    }

    const report = reportSnap.data() || {};
    const type = strOr(report.type).trim();
    const postId = strOr(report.postId).trim();
    const commentId = strOr(report.commentId).trim();
    const note = strOr(data && data.note).trim();
    const beforeStatus = strOr(report.status, "open").trim().toLowerCase();
    const beforeResolution = strOr(report.resolution).trim();
    const now = Date.now();
    let action = "";
    const deleted = {};

    if (type === "social_post") {
      if (!postId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Report post missing"
        );
      }
      const postRef = db.collection("social_posts").doc(postId);
      const postSnap = await postRef.get();
      const post = postSnap.exists ? postSnap.data() || {} : {};
      const ownerId = strOr(post.ownerId).trim();
      const imagePath = strOr(post.imagePath).trim();
      for (const childName of ["likes", "comments", "shares"]) {
        deleted[childName] = await deleteCollectionDocs(
          postRef.collection(childName)
        );
      }
      deleted.saved_posts = await deleteSavedPostRefs(postId);
      deleted.notifications = await deleteCollectionGroupDocsByField({
        collectionId: "notifications",
        field: "postId",
        value: postId,
      });
      deleted.reports = await reviewReportsForDeletedPost({
        postId,
        resolution: "post_deleted",
        reviewedBy: adminMeta.uid,
        note: "Post removed by moderation.",
      });
      await postRef.delete();
      deleted.storage = await deleteStoragePathIfSafe(imagePath, {
        allowedPrefixes: [
          ownerId ? `social_uploads/${ownerId}/` : "social_uploads/",
        ],
      });
      action = "post_deleted";
    } else if (type === "social_comment") {
      if (!postId || !commentId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Report comment missing"
        );
      }
      const postRef = db.collection("social_posts").doc(postId);
      const commentRef = postRef.collection("comments").doc(commentId);
      await db.runTransaction(async (tx) => {
        const postSnap = await tx.get(postRef);
        const commentSnap = await tx.get(commentRef);
        if (!commentSnap.exists) return;
        tx.delete(commentRef);
        if (postSnap.exists) {
          const post = postSnap.data() || {};
          const currentCount = intOr(post.commentCount, 0);
          tx.update(postRef, {
            commentCount: Math.max(0, currentCount - 1),
          });
        }
      });
      deleted.reports = await reviewReportsForDeletedComment({
        postId,
        commentId,
        resolution: "comment_deleted",
        reviewedBy: adminMeta.uid,
        note: "Comment removed by moderation.",
      });
      action = "comment_deleted";
    } else {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Unsupported report type"
      );
    }

    const batch = db.batch();
    batch.update(reportRef, {
      status: "reviewed",
      resolution: action,
      adminNote: note,
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
      reviewedAtMs: now,
      reviewedBy: adminMeta.uid,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: now,
    });

    const reporterId = strOr(report.reporterId).trim();
    const reportedUserId = strOr(report.reportedUserId).trim();
    if (reporterId) {
      const reporterNotificationRef = moderationNotificationRef(reporterId);
      batch.set(reporterNotificationRef, moderationNotificationDoc({
        ref: reporterNotificationRef,
        type: "moderation_report_reviewed",
        actorId: adminMeta.uid,
        postId,
        text: "Thanks for reporting. The content was removed after review.",
        now,
      }));
    }

    if (reportedUserId && reportedUserId !== reporterId) {
      const ownerNotificationRef = moderationNotificationRef(reportedUserId);
      batch.set(ownerNotificationRef, moderationNotificationDoc({
        ref: ownerNotificationRef,
        type: "moderation_content_removed",
        actorId: adminMeta.uid,
        postId,
        text: type === "social_comment"
          ? "Your comment was removed after moderation review."
          : "Your post was removed after moderation review.",
        now,
      }));
    }

    const auditRef = adminActionRef();
    batch.set(auditRef, {
      actionId: auditRef.id,
      actionType: "moderation_content_deleted",
      actionCategory: adminActionCategory("moderation_content_deleted"),
      reportId: reportRef.id,
      targetUserId: reportedUserId,
      reporterId: reporterId,
      postId,
      commentId,
      contentType: type,
      adminUid: adminMeta.uid,
      adminSource: adminMeta.source,
      beforeStatus,
      beforeOutcome: beforeResolution,
      afterStatus: "reviewed",
      afterOutcome: action,
      note,
      notePresent: note.length > 0,
      deleted,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAtMs: now,
    });

    await batch.commit();

    return {
      ok: true,
      reportId: reportRef.id,
      action,
      deleted,
      auditLogged: true,
    };
  });

exports.checkAgoraServerConfig_v1 = functions
  .region(REGION)
  .runWith({ secrets: ["AGORA_APP_ID", "AGORA_APP_CERTIFICATE"] })
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "checkAgoraServerConfig_v1");
    await requireAdmin(context);

    const readiness = evaluateAgoraTokenConfig();
    const missing = new Set(readiness.missingRequirements);

    return {
      ok: true,
      appIdPresent:
        Boolean(readiness.appId) && !missing.has("AGORA_APP_ID_PLACEHOLDER"),
      certificatePresent:
        Boolean(readiness.appCertificate) &&
        !missing.has("AGORA_APP_CERTIFICATE_PLACEHOLDER"),
      tokenBuilderAvailable: readiness.tokenBuilderAvailable === true,
      ready: readiness.isReady === true,
    };
  });
