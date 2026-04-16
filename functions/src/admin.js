const {
  admin,
  functions,
  REGION,
  strOr,
  intOr,
  walletTxRef,
  createWalletTxDoc,
} = require("./shared");

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

exports.requestAccountDeletion_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
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
      const existing = existingPendingSnap.docs.first;
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

    await requestRef.set({
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

    return {
      ok: true,
      requestId: requestRef.id,
      status: "pending",
      alreadyPending: false,
    };
  });

exports.adminApproveWithdrawal_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    const adminMeta = await requireAdmin(context);

    const requestId = strOr(data && data.requestId).trim();
    const adminNote = strOr(data && data.adminNote).trim();

    if (!requestId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "requestId required"
      );
    }

    const db = admin.firestore();
    const requestRef = db.collection("withdrawal_requests").doc(requestId);

    await db.runTransaction(async (tx) => {
      const requestSnap = await tx.get(requestRef);
      if (!requestSnap.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Withdrawal request not found"
        );
      }

      const req = requestSnap.data() || {};
      const status = strOr(req.status, "pending").toLowerCase();
      const userId = strOr(req.userId).trim();
      const amount = intOr(req.amount, 0);

      if (!userId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Withdrawal request user missing"
        );
      }

      if (amount <= 0) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Withdrawal request amount invalid"
        );
      }

      if (status === "approved") {
        return;
      }

      if (status !== "pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only pending withdrawal requests can be approved"
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
      const credits = intOr(user.credits, 0);
      const earningsCredits = intOr(user.earningsCredits, 0);

      if (amount > earningsCredits) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Insufficient earningsCredits. Current earningsCredits: ₹${earningsCredits}`
        );
      }

      const newCredits = Math.max(0, credits - amount);
      const newEarningsCredits = Math.max(0, earningsCredits - amount);

      tx.update(userRef, {
        credits: newCredits,
        earningsCredits: newEarningsCredits,
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });

      if (!existingLedgerSnap.exists) {
        tx.set(
          ledgerRef,
          createWalletTxDoc({
            userId,
            type: "withdrawal_debit",
            amount: -amount,
            balanceAfter: newCredits,
            status: "completed",
            method: "manual_test",
            notes: `Withdrawal approved by admin${adminNote ? `: ${adminNote}` : ""}`,
            source: "admin_withdrawal",
            currency: strOr(req.currency, "INR"),
            direction: "debit",
            withdrawalRequestId: requestId,
            idempotencyKey: `withdrawal_debit_${requestId}`,
            metadata: {
              requestId,
              approvedBy: adminMeta.uid,
              adminSource: adminMeta.source,
              payoutMode: strOr(req.payoutMode, "manual_test"),
              realMoneyEnabled: req.realMoneyEnabled === true,
            },
          })
        );
      }

      tx.update(requestRef, {
        status: "approved",
        adminNote,
        approvedAt: admin.firestore.FieldValue.serverTimestamp(),
        approvedAtMs: Date.now(),
        approvedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: Date.now(),
        statusReason: "",
        settledInLedger: true,
        settlementLedgerTxId: ledgerRef.id,
        remainingEarningsAfterApproval: newEarningsCredits,
      });
    });

    return { ok: true, requestId, status: "approved" };
  });

exports.adminRejectWithdrawal_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
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

      if (status === "rejected") {
        return;
      }

      if (status !== "pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Only pending withdrawal requests can be rejected"
        );
      }

      tx.update(requestRef, {
        status: "rejected",
        adminNote: reason || "Rejected by admin",
        rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
        rejectedAtMs: Date.now(),
        rejectedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: Date.now(),
        statusReason: reason || "Rejected by admin",
        settledInLedger: false,
      });
    });

    return { ok: true, requestId, status: "rejected" };
  });

// ---------- ADMIN USER MODERATION ----------
exports.adminBlockUser_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
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

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "User not found");
      }

      tx.update(userRef, {
        adminBlocked: true,
        adminBlockReason: reason || "Blocked by admin",
        adminBlockedAt: admin.firestore.FieldValue.serverTimestamp(),
        adminBlockedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return { ok: true, userId, status: "blocked" };
  });

exports.adminUnblockUser_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
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

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "User not found");
      }

      tx.update(userRef, {
        adminBlocked: false,
        adminBlockReason: "",
        adminBlockedAt: null,
        adminBlockedBy: "",
        adminUnblockedAt: admin.firestore.FieldValue.serverTimestamp(),
        adminUnblockedBy: adminMeta.uid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return { ok: true, userId, status: "active" };
  });