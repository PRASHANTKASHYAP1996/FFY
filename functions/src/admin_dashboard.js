const {
  admin,
  functions,
  REGION,
  strOr,
  intOr,
  adminActionCategory,
  assertCallableAppCheck,
  callShouldHoldReserve,
  MAX_INSTANCES,
} = require("./shared");
const { requireAdmin } = require("./admin");

const ADMIN_DASHBOARD_CACHE_ROOT = "admin_dashboard_cache";
const DASHBOARD_TTL_MS = 2 * 60 * 1000;

function numOr(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function round2(value) {
  return Number(numOr(value, 0).toFixed(2));
}

function tsToMillis(value) {
  if (!value) return 0;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (value && typeof value.toMillis === "function") {
    try {
      return value.toMillis();
    } catch (_) {
      return 0;
    }
  }
  if (value instanceof Date) return value.getTime();
  return 0;
}

function sortByCreatedDesc(items) {
  items.sort((a, b) => {
    const aTime = numOr(a.createdAtMs || a.updatedAtMs || 0, 0);
    const bTime = numOr(b.createdAtMs || b.updatedAtMs || 0, 0);
    return bTime - aTime;
  });
  return items;
}

function buildFinanceReconciliation({
  totalCredits = 0,
  totalEarningsCredits = 0,
  totalReservedCredits = 0,
  totalPendingWithdrawalCredits = 0,
  totalActiveCallReservedAmount = 0,
  verifiedPaymentAmount = 0,
  approvedWithdrawalAmount = 0,
  approvedWithdrawalsMissingPaymentReference = 0,
  approvedWithdrawalsMissingLedgerSettlement = 0,
  pendingWithdrawalHeldAmount = 0,
  totalBilledCredits = 0,
  totalListenerPayoutCredits = 0,
  totalPlatformRevenueCredits = 0,
  walletTransactionDocs = [],
}) {
  const walletLedger = {
    totalTransactions: walletTransactionDocs.length,
    completedTransactions: 0,
    nonCompletedTransactions: 0,
    topupCredits: 0,
    callChargeDebits: 0,
    callEarningCredits: 0,
    withdrawalDebits: 0,
    otherCredits: 0,
    otherDebits: 0,
    netMovement: 0,
  };

  for (const tx of walletTransactionDocs) {
    const data = typeof tx.data === "function" ? tx.data() || {} : tx || {};
    const type = strOr(data.type).trim();
    const status = strOr(data.status, "completed").trim().toLowerCase();
    const amount = intOr(data.amount, 0);
    const absoluteAmount = Math.abs(amount);

    if (status === "completed") {
      walletLedger.completedTransactions += 1;
    } else {
      walletLedger.nonCompletedTransactions += 1;
    }

    walletLedger.netMovement += amount;

    if (type === "topup" && amount > 0) {
      walletLedger.topupCredits += amount;
    } else if (type === "call_charge" && amount < 0) {
      walletLedger.callChargeDebits += absoluteAmount;
    } else if (type === "call_earning" && amount > 0) {
      walletLedger.callEarningCredits += amount;
    } else if (type === "withdrawal_debit" && amount < 0) {
      walletLedger.withdrawalDebits += absoluteAmount;
    } else if (amount > 0) {
      walletLedger.otherCredits += amount;
    } else if (amount < 0) {
      walletLedger.otherDebits += absoluteAmount;
    }
  }

  const deltas = {
    verifiedPaymentVsTopupLedger:
      verifiedPaymentAmount - walletLedger.topupCredits,
    callBilledVsChargeLedger:
      totalBilledCredits - walletLedger.callChargeDebits,
    callPayoutVsEarningLedger:
      totalListenerPayoutCredits - walletLedger.callEarningCredits,
    approvedWithdrawalVsLedger:
      approvedWithdrawalAmount - walletLedger.withdrawalDebits,
    pendingWithdrawalHoldsVsUserLiability:
      pendingWithdrawalHeldAmount - totalPendingWithdrawalCredits,
    activeCallReserveVsUserLiability:
      totalActiveCallReservedAmount - totalReservedCredits,
  };

  const warnings = [];
  Object.entries(deltas).forEach(([key, value]) => {
    if (value !== 0) {
      warnings.push({ key, delta: value });
    }
  });
  if (walletLedger.nonCompletedTransactions > 0) {
    warnings.push({
      key: "nonCompletedWalletTransactions",
      count: walletLedger.nonCompletedTransactions,
    });
  }
  if (approvedWithdrawalsMissingPaymentReference > 0) {
    warnings.push({
      key: "approvedWithdrawalsMissingPaymentReference",
      count: approvedWithdrawalsMissingPaymentReference,
    });
  }
  if (approvedWithdrawalsMissingLedgerSettlement > 0) {
    warnings.push({
      key: "approvedWithdrawalsMissingLedgerSettlement",
      count: approvedWithdrawalsMissingLedgerSettlement,
    });
  }

  return {
    readOnly: true,
    sampled: false,
    userLiability: {
      credits: totalCredits,
      earningsCredits: totalEarningsCredits,
      reservedCredits: totalReservedCredits,
      pendingWithdrawalCredits: totalPendingWithdrawalCredits,
      total:
        totalCredits +
        totalEarningsCredits +
        totalReservedCredits +
        totalPendingWithdrawalCredits,
    },
    gateway: {
      verifiedPaymentAmount,
    },
    calls: {
      totalBilledCredits,
      totalListenerPayoutCredits,
      totalPlatformRevenueCredits,
      activeCallReservedAmount: totalActiveCallReservedAmount,
    },
    withdrawals: {
      approvedWithdrawalAmount,
      approvedWithdrawalsMissingPaymentReference,
      approvedWithdrawalsMissingLedgerSettlement,
      pendingWithdrawalHeldAmount,
    },
    walletLedger,
    deltas,
    warnings,
    status: warnings.length === 0 ? "balanced" : "review_required",
  };
}

function buildWithdrawalDashboardRows(withdrawalsDocs = []) {
  let totalWithdrawalRequests = 0;
  let pendingWithdrawalRequests = 0;
  let approvedWithdrawalRequests = 0;
  let rejectedWithdrawalRequests = 0;

  let pendingWithdrawalAmount = 0;
  let pendingWithdrawalHeldAmount = 0;
  let approvedWithdrawalAmount = 0;
  let approvedWithdrawalsMissingPaymentReference = 0;
  let approvedWithdrawalsMissingLedgerSettlement = 0;
  let rejectedWithdrawalAmount = 0;

  const recentWithdrawals = [];
  const withdrawalsMissingPaymentReference = [];
  const withdrawalsMissingLedgerSettlement = [];

  for (const doc of withdrawalsDocs) {
    const data = typeof doc.data === "function" ? doc.data() || {} : doc || {};
    totalWithdrawalRequests += 1;

    const status = strOr(data.status, "pending").toLowerCase();
    const amount = intOr(data.amount, 0);
    let missingPaymentReference = false;
    let missingLedgerSettlement = false;
    const settlementLedgerTxId = strOr(
      data.settlementLedgerTxId ||
        data.ledgerTransactionId ||
        data.ledgerTxId ||
        ""
    ).trim();

    if (status === "pending") {
      pendingWithdrawalRequests += 1;
      pendingWithdrawalAmount += amount;
      const holdStatus = strOr(data.holdStatus).trim().toLowerCase();
      if (holdStatus !== "released") {
        pendingWithdrawalHeldAmount += intOr(data.heldCredits, amount);
      }
    } else if (status === "approved") {
      approvedWithdrawalRequests += 1;
      approvedWithdrawalAmount += amount;
      if (!strOr(data.paymentReference).trim()) {
        approvedWithdrawalsMissingPaymentReference += 1;
        missingPaymentReference = true;
      }
      if (data.settledInLedger !== true || !settlementLedgerTxId) {
        approvedWithdrawalsMissingLedgerSettlement += 1;
        missingLedgerSettlement = true;
      }
    } else if (status === "rejected") {
      rejectedWithdrawalRequests += 1;
      rejectedWithdrawalAmount += amount;
    }

    const withdrawalRow = {
      id: strOr(doc.id || data.id || ""),
      userId: strOr(data.userId || ""),
      status,
      amount,
      currency: strOr(data.currency || "INR"),
      payoutMode: strOr(data.payoutMode || ""),
      paymentReference: strOr(data.paymentReference || ""),
      settledInLedger: data.settledInLedger === true,
      settlementLedgerTxId,
      adminNote: strOr(data.adminNote || ""),
      statusReason: strOr(data.statusReason || ""),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.approvedAt),
        tsToMillis(data.rejectedAt),
        intOr(data.approvedAtMs, 0),
        intOr(data.rejectedAtMs, 0)
      ),
    };

    recentWithdrawals.push(withdrawalRow);
    if (missingPaymentReference) {
      withdrawalsMissingPaymentReference.push(withdrawalRow);
    }
    if (missingLedgerSettlement) {
      withdrawalsMissingLedgerSettlement.push(withdrawalRow);
    }
  }

  sortByCreatedDesc(recentWithdrawals);
  sortByCreatedDesc(withdrawalsMissingPaymentReference);
  sortByCreatedDesc(withdrawalsMissingLedgerSettlement);

  return {
    totalWithdrawalRequests,
    pendingWithdrawalRequests,
    approvedWithdrawalRequests,
    rejectedWithdrawalRequests,
    pendingWithdrawalAmount,
    pendingWithdrawalHeldAmount,
    approvedWithdrawalAmount,
    approvedWithdrawalsMissingPaymentReference,
    approvedWithdrawalsMissingLedgerSettlement,
    rejectedWithdrawalAmount,
    recentWithdrawals,
    withdrawalsMissingPaymentReference,
    withdrawalsMissingLedgerSettlement,
  };
}

function dashboardCacheRef(docId) {
  return admin
    .firestore()
    .collection("system")
    .doc(ADMIN_DASHBOARD_CACHE_ROOT)
    .collection("docs")
    .doc(docId);
}

function adminActionRef() {
  return admin.firestore().collection("admin_actions").doc();
}

async function readFreshCacheOrNull(docId, maxAgeMs) {
  const snap = await dashboardCacheRef(docId).get();
  if (!snap.exists) return null;

  const data = snap.data() || {};
  const refreshedAtMs = intOr(data.refreshedAtMs, 0);
  if (refreshedAtMs <= 0) return null;

  if (Date.now() - refreshedAtMs > maxAgeMs) {
    return null;
  }

  return {
    payload: data.payload || null,
    refreshedAtMs,
  };
}

function withCacheMeta(payload, {
  source = "fresh",
  refreshedAtMs = 0,
} = {}) {
  const now = Date.now();
  const generatedAtMs = intOr(payload && payload.generatedAtMs, now);
  const safeRefreshedAtMs = intOr(refreshedAtMs, generatedAtMs);

  return {
    ...payload,
    cacheMeta: {
      source,
      cacheHit: source === "cache",
      generatedAtMs,
      refreshedAtMs: safeRefreshedAtMs,
      ageMs: Math.max(0, now - safeRefreshedAtMs),
      ttlMs: DASHBOARD_TTL_MS,
    },
  };
}

async function writeCache(docId, payload) {
  await dashboardCacheRef(docId).set(
    {
      refreshedAt: admin.firestore.FieldValue.serverTimestamp(),
      refreshedAtMs: Date.now(),
      payload,
    },
    { merge: true }
  );
}

function buildDashboardCacheRefreshAuditDoc({
  actionId = "",
  adminMeta = {},
  payload = {},
  refreshedAtMs = Date.now(),
  serverTimestamp = () => admin.firestore.FieldValue.serverTimestamp(),
} = {}) {
  const summary = payload.summary || {};
  const users = summary.users || {};
  const withdrawals = summary.withdrawals || {};
  const finance = payload.financeReconciliation || summary.financeReconciliation || {};
  const warningCount = Array.isArray(finance.warnings)
    ? finance.warnings.length
    : 0;
  const note = [
    `Users: ${intOr(users.total, 0)}`,
    `Withdrawals: ${intOr(withdrawals.totalRequests, 0)}`,
    `Finance warnings: ${warningCount}`,
  ].join(" - ");

  return {
    actionId: strOr(actionId),
    actionType: "admin_dashboard_cache_refreshed",
    actionCategory: "cache",
    adminUid: strOr(adminMeta.uid),
    adminSource: strOr(adminMeta.source),
    afterStatus: "refreshed",
    note,
    notePresent: true,
    totalUsers: intOr(users.total, 0),
    totalWithdrawalRequests: intOr(withdrawals.totalRequests, 0),
    financeWarningCount: warningCount,
    financeStatus: strOr(finance.status),
    refreshedAt: serverTimestamp(),
    refreshedAtMs: intOr(refreshedAtMs, 0),
    createdAt: serverTimestamp(),
    createdAtMs: intOr(refreshedAtMs, 0),
  };
}

function buildAdminActionCategoryCounts(adminActionDocs = []) {
  const counts = {};
  for (const doc of adminActionDocs) {
    const data = typeof doc.data === "function" ? doc.data() || {} : doc || {};
    const actionType = strOr(data.actionType || "admin_action");
    const category = strOr(
      data.actionCategory || adminActionCategory(actionType)
    );
    counts[category] = (counts[category] || 0) + 1;
  }
  return counts;
}

function buildAdminActionDashboardRows(adminActionDocs = []) {
  const recentAdminActions = [];
  const adminActionsByCategory = {};
  const categoryCounts = {};

  for (const doc of adminActionDocs) {
    const data = typeof doc.data === "function" ? doc.data() || {} : doc || {};
    const actionType = strOr(data.actionType || "admin_action");
    const actionCategory = strOr(
      data.actionCategory || adminActionCategory(actionType)
    );
    const actionRow = {
      id: strOr(doc.id || data.id || ""),
      actionType,
      actionCategory,
      adminUid: strOr(data.adminUid || ""),
      adminSource: strOr(data.adminSource || ""),
      targetUserId: strOr(data.targetUserId || ""),
      requestId: strOr(data.requestId || ""),
      reportId: strOr(data.reportId || ""),
      beforeStatus: strOr(data.beforeStatus || ""),
      beforeOutcome: strOr(data.beforeOutcome || ""),
      afterStatus: strOr(data.afterStatus || ""),
      afterOutcome: strOr(data.afterOutcome || ""),
      amount: intOr(data.amount, 0),
      currency: strOr(data.currency || ""),
      ledgerTxId: strOr(data.ledgerTxId || ""),
      paymentReference: strOr(data.paymentReference || ""),
      heldCredits: intOr(data.heldCredits, 0),
      pendingWithdrawalCreditsAfter:
        intOr(data.pendingWithdrawalCreditsAfter, 0),
      totalUsers: intOr(data.totalUsers, 0),
      totalWithdrawalRequests: intOr(data.totalWithdrawalRequests, 0),
      financeWarningCount: intOr(data.financeWarningCount, 0),
      financeStatus: strOr(data.financeStatus || ""),
      note: strOr(data.note || ""),
      notePresent: data.notePresent === true,
      retentionPolicyApplied: data.retentionPolicyApplied === true,
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0),
        tsToMillis(data.reviewedAt),
        intOr(data.reviewedAtMs, 0)
      ),
    };

    recentAdminActions.push(actionRow);
    if (!adminActionsByCategory[actionCategory]) {
      adminActionsByCategory[actionCategory] = [];
    }
    adminActionsByCategory[actionCategory].push(actionRow);
    categoryCounts[actionCategory] = (categoryCounts[actionCategory] || 0) + 1;
  }

  sortByCreatedDesc(recentAdminActions);
  Object.values(adminActionsByCategory).forEach(sortByCreatedDesc);

  return {
    recentAdminActions,
    adminActionsByCategory,
    categoryCounts,
  };
}

function paymentOrderStatusCategory(status) {
  const safe = strOr(status || "unknown").trim().toLowerCase();
  if (safe === "verified" || safe === "paid" || safe === "captured") {
    return "verified";
  }
  if (safe === "pending" || safe === "created") {
    return "pending";
  }
  if (safe === "failed" || safe === "cancelled") {
    return "failed";
  }
  return "other";
}

function buildPaymentOrderDashboardRows(paymentOrderDocs = []) {
  let totalPaymentOrders = 0;
  let verifiedPaymentOrders = 0;
  let pendingPaymentOrders = 0;
  let failedPaymentOrders = 0;
  let verifiedPaymentAmount = 0;
  const recentPaymentOrders = [];
  const paymentOrdersByStatus = {};
  const statusCounts = {};

  for (const doc of paymentOrderDocs) {
    const data = typeof doc.data === "function" ? doc.data() || {} : doc || {};
    totalPaymentOrders += 1;

    const status = strOr(data.status || "unknown").toLowerCase();
    const statusCategory = paymentOrderStatusCategory(status);
    const amount = intOr(data.amount, 0);
    if (statusCategory === "verified") {
      verifiedPaymentOrders += 1;
      verifiedPaymentAmount += amount;
    } else if (statusCategory === "pending") {
      pendingPaymentOrders += 1;
    } else if (statusCategory === "failed") {
      failedPaymentOrders += 1;
    }

    const paymentRow = {
      id: strOr(doc.id || data.id || ""),
      userId: strOr(data.userId || ""),
      gateway: strOr(data.gateway || ""),
      status,
      statusCategory,
      amount,
      currency: strOr(data.currency || "INR"),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.verifiedAt),
        intOr(data.verifiedAtMs, 0)
      ),
    };

    recentPaymentOrders.push(paymentRow);
    statusCounts[statusCategory] = (statusCounts[statusCategory] || 0) + 1;
    paymentOrdersByStatus[statusCategory] =
      paymentOrdersByStatus[statusCategory] || [];
    paymentOrdersByStatus[statusCategory].push(paymentRow);
  }

  sortByCreatedDesc(recentPaymentOrders);
  for (const rows of Object.values(paymentOrdersByStatus)) {
    sortByCreatedDesc(rows);
  }

  return {
    totalPaymentOrders,
    verifiedPaymentOrders,
    pendingPaymentOrders,
    failedPaymentOrders,
    verifiedPaymentAmount,
    recentPaymentOrders,
    paymentOrdersByStatus,
    statusCounts,
  };
}

async function buildDashboardPayload(adminMeta) {
  const db = admin.firestore();

  const [
    usersSnap,
    callsSnap,
    reportsSnap,
    withdrawalsSnap,
    accountDeletionRequestsSnap,
    adminActionsSnap,
    reviewsSnap,
    paymentOrdersSnap,
    walletTransactionsSnap,
  ] = await Promise.all([
    db.collection("users").get(),
    db.collection("calls").get(),
    db.collection("reports").get(),
    db.collection("withdrawal_requests").get(),
    db.collection("delete_account_requests").get(),
    db.collection("admin_actions").get(),
    db.collection("reviews").get(),
    db.collection("payment_orders").get(),
    db.collection("wallet_transactions").get(),
  ]);

  const usersDocs = usersSnap.docs;
  const callsDocs = callsSnap.docs;
  const reportsDocs = reportsSnap.docs;
  const withdrawalsDocs = withdrawalsSnap.docs;
  const accountDeletionRequestDocs = accountDeletionRequestsSnap.docs;
  const adminActionDocs = adminActionsSnap.docs;
  const reviewsDocs = reviewsSnap.docs;
  const paymentOrderDocs = paymentOrdersSnap.docs;
  const walletTransactionDocs = walletTransactionsSnap.docs;

  let totalUsers = 0;
  let totalListeners = 0;
  let availableListeners = 0;
  let blockedUsers = 0;

  let totalCredits = 0;
  let totalEarningsCredits = 0;
  let totalReservedCredits = 0;
  let totalPendingWithdrawalCredits = 0;

  const recentUsers = [];

  for (const doc of usersDocs) {
    const data = doc.data() || {};
    totalUsers += 1;

    const isListener = data.isListener === true;
    const isAvailable = data.isAvailable === true;
    const isBlocked = data.adminBlocked === true;
    const hasActiveCall = strOr(data.activeCallId).length > 0;

    if (isListener) totalListeners += 1;
    if (isListener && isAvailable && !hasActiveCall) availableListeners += 1;
    if (isBlocked) blockedUsers += 1;

    totalCredits += intOr(data.credits, 0);
    totalEarningsCredits += intOr(data.earningsCredits, 0);
    totalReservedCredits += intOr(data.reservedCredits, 0);
    totalPendingWithdrawalCredits += intOr(data.pendingWithdrawalCredits, 0);

    recentUsers.push({
      id: doc.id,
      displayName: strOr(data.displayName || data.name || ""),
      email: strOr(data.email || ""),
      photoURL: strOr(data.photoURL || ""),
      isListener,
      isAvailable,
      adminBlocked: isBlocked,
      credits: intOr(data.credits, 0),
      earningsCredits: intOr(data.earningsCredits, 0),
      followersCount: intOr(data.followersCount, 0),
      ratingAvg: round2(numOr(data.ratingAvg, 0)),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.lastSeen),
        intOr(data.lastSeenMs, 0)
      ),
    });
  }

  let totalCalls = 0;
  let ringingCalls = 0;
  let acceptedCalls = 0;
  let endedCalls = 0;
  let rejectedCalls = 0;
  let missedCalls = 0;
  let paidCalls = 0;
  let freeCalls = 0;

  let totalBilledCredits = 0;
  let totalListenerPayoutCredits = 0;
  let totalPlatformRevenueCredits = 0;
  let totalCallDurationSeconds = 0;
  let totalActiveCallReservedAmount = 0;

  const recentCalls = [];

  for (const doc of callsDocs) {
    const data = doc.data() || {};
    totalCalls += 1;

    const status = strOr(data.status, "").toLowerCase();
    if (status === "ringing") ringingCalls += 1;
    if (status === "accepted") acceptedCalls += 1;
    if (status === "ended") endedCalls += 1;
    if (status === "rejected") rejectedCalls += 1;

    const endedReason = strOr(data.endedReason || data.endReason || "").toLowerCase();
    if (
      endedReason === "missed" ||
      endedReason === "timeout" ||
      endedReason === "no_answer" ||
      endedReason === "not_answered"
    ) {
      missedCalls += 1;
    }

    const durationSeconds = intOr(
      data.billableDurationSeconds ||
        data.durationSeconds ||
        data.totalDurationSeconds ||
        data.endedSeconds ||
        data.seconds ||
        0,
      0
    );

    const billedCredits = intOr(
      data.finalChargeCredits ||
        data.totalChargeCredits ||
        data.chargeCredits ||
        data.speakerCharge ||
        0,
      0
    );

    const listenerPayoutCredits = intOr(
      data.listenerPayoutCredits ||
        data.payoutCredits ||
        data.listenerPayout ||
        0,
      0
    );

    const platformRevenueCredits = intOr(
      data.platformRevenueCredits ||
        data.platformFeeCredits ||
        data.platformProfit ||
        0,
      0
    );

    totalCallDurationSeconds += durationSeconds;
    totalBilledCredits += billedCredits;
    totalListenerPayoutCredits += listenerPayoutCredits;
    totalPlatformRevenueCredits += platformRevenueCredits;
    if (callShouldHoldReserve(data)) {
      totalActiveCallReservedAmount += intOr(data.reservedUpfront, 0);
    }

    if (billedCredits > 0) {
      paidCalls += 1;
    } else {
      freeCalls += 1;
    }

    recentCalls.push({
      id: doc.id,
      callerId: strOr(data.callerId || ""),
      calleeId: strOr(data.calleeId || ""),
      callerName: strOr(data.callerName || ""),
      calleeName: strOr(data.calleeName || ""),
      status,
      endedReason,
      durationSeconds,
      billedCredits,
      listenerPayoutCredits,
      platformRevenueCredits,
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.acceptedAt),
        tsToMillis(data.endedAt),
        intOr(data.acceptedAtMs, 0),
        intOr(data.endedAtMs, 0)
      ),
    });
  }

  let totalReports = 0;
  let openReports = 0;
  let reviewedReports = 0;
  const recentReports = [];

  for (const doc of reportsDocs) {
    const data = doc.data() || {};
    totalReports += 1;

    const status = strOr(data.status || "open").toLowerCase();
    if (status === "reviewed" || status === "resolved" || status === "closed") {
      reviewedReports += 1;
    } else {
      openReports += 1;
    }

    recentReports.push({
      id: doc.id,
      type: strOr(data.type || "report"),
      reporterId: strOr(data.reporterId || ""),
      reportedUserId: strOr(data.reportedUserId || ""),
      callId: strOr(data.callId || ""),
      postId: strOr(data.postId || ""),
      commentId: strOr(data.commentId || ""),
      commentText: strOr(data.commentText || ""),
      reason: strOr(data.lastReason || data.reason || data.category || ""),
      status,
      resolution: strOr(data.resolution || ""),
      reportCount: intOr(data.reportCount, 1),
      reviewedAtMs: Math.max(
        tsToMillis(data.reviewedAt),
        intOr(data.reviewedAtMs, 0)
      ),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0)
      ),
    });
  }

  const withdrawalDashboard = buildWithdrawalDashboardRows(withdrawalsDocs);
  const {
    totalWithdrawalRequests,
    pendingWithdrawalRequests,
    approvedWithdrawalRequests,
    rejectedWithdrawalRequests,
    pendingWithdrawalAmount,
    pendingWithdrawalHeldAmount,
    approvedWithdrawalAmount,
    approvedWithdrawalsMissingPaymentReference,
    approvedWithdrawalsMissingLedgerSettlement,
    rejectedWithdrawalAmount,
    recentWithdrawals,
    withdrawalsMissingPaymentReference,
    withdrawalsMissingLedgerSettlement,
  } = withdrawalDashboard;

  let totalReviews = 0;
  let reviewRatingSum = 0;
  let validReviewRatingCount = 0;

  const recentReviews = [];

  for (const doc of reviewsDocs) {
    const data = doc.data() || {};
    totalReviews += 1;

    const rating = numOr(data.rating || data.stars, 0);
    if (rating > 0) {
      reviewRatingSum += rating;
      validReviewRatingCount += 1;
    }

    recentReviews.push({
      id: doc.id,
      reviewerId: strOr(data.reviewerId || ""),
      revieweeId: strOr(data.revieweeId || data.userId || data.reviewedUserId || ""),
      reviewerName: strOr(data.reviewerName || ""),
      revieweeName: strOr(data.revieweeName || ""),
      rating: round2(rating),
      comment: strOr(data.comment || ""),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0)
      ),
    });
  }

  const averageReviewRating =
    validReviewRatingCount > 0
      ? round2(reviewRatingSum / validReviewRatingCount)
      : 0;

  const paymentOrderDashboard =
    buildPaymentOrderDashboardRows(paymentOrderDocs);
  const {
    totalPaymentOrders,
    verifiedPaymentOrders,
    pendingPaymentOrders,
    failedPaymentOrders,
    verifiedPaymentAmount,
    recentPaymentOrders,
    paymentOrdersByStatus,
    statusCounts: paymentOrderStatusCounts,
  } = paymentOrderDashboard;

  let totalAccountDeletionRequests = 0;
  let pendingAccountDeletionRequests = 0;
  let reviewedAccountDeletionRequests = 0;

  const recentAccountDeletionRequests = [];

  for (const doc of accountDeletionRequestDocs) {
    const data = doc.data() || {};
    totalAccountDeletionRequests += 1;

    const status = strOr(data.status, "pending").toLowerCase();
    if (status === "pending") {
      pendingAccountDeletionRequests += 1;
    } else {
      reviewedAccountDeletionRequests += 1;
    }

    recentAccountDeletionRequests.push({
      id: doc.id,
      userId: strOr(data.userId || ""),
      displayName: strOr(data.displayName || ""),
      email: strOr(data.email || ""),
      reason: strOr(data.reason || ""),
      note: strOr(data.note || ""),
      status,
      outcome: strOr(data.outcome || ""),
      adminNote: strOr(data.adminNote || ""),
      reviewedBy: strOr(data.reviewedBy || ""),
      retentionPolicyApplied: data.retentionPolicyApplied === true,
      createdAtMs: Math.max(
        tsToMillis(data.requestedAt),
        intOr(data.requestedAtMs, 0),
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.reviewedAt),
        intOr(data.reviewedAtMs, 0)
      ),
    });
  }

  const adminActionDashboard = buildAdminActionDashboardRows(adminActionDocs);
  const {
    recentAdminActions,
    adminActionsByCategory,
    categoryCounts: adminActionCategoryCounts,
  } = adminActionDashboard;

  sortByCreatedDesc(recentUsers);
  sortByCreatedDesc(recentCalls);
  sortByCreatedDesc(recentReports);
  sortByCreatedDesc(recentAccountDeletionRequests);
  sortByCreatedDesc(recentReviews);

  const financeReconciliation = buildFinanceReconciliation({
    totalCredits,
    totalEarningsCredits,
    totalReservedCredits,
    totalPendingWithdrawalCredits,
    totalActiveCallReservedAmount,
    verifiedPaymentAmount,
    approvedWithdrawalAmount,
    approvedWithdrawalsMissingPaymentReference,
    approvedWithdrawalsMissingLedgerSettlement,
    pendingWithdrawalHeldAmount,
    totalBilledCredits,
    totalListenerPayoutCredits,
    totalPlatformRevenueCredits,
    walletTransactionDocs,
  });

  return {
    ok: true,
    adminUid: adminMeta.uid,
    adminSource: adminMeta.source,
    generatedAtMs: Date.now(),

    summary: {
      users: {
        total: totalUsers,
        listeners: totalListeners,
        availableListeners,
        blockedUsers,
      },
      wallet: {
        totalCredits,
        totalEarningsCredits,
        totalReservedCredits,
      },
      withdrawals: {
        totalRequests: totalWithdrawalRequests,
        pendingRequests: pendingWithdrawalRequests,
        approvedRequests: approvedWithdrawalRequests,
        rejectedRequests: rejectedWithdrawalRequests,
        pendingAmount: pendingWithdrawalAmount,
        approvedAmount: approvedWithdrawalAmount,
        rejectedAmount: rejectedWithdrawalAmount,
      },
      accountDeletionRequests: {
        total: totalAccountDeletionRequests,
        pending: pendingAccountDeletionRequests,
        reviewed: reviewedAccountDeletionRequests,
      },
      calls: {
        total: totalCalls,
        ringing: ringingCalls,
        accepted: acceptedCalls,
        ended: endedCalls,
        rejected: rejectedCalls,
        missed: missedCalls,
        paid: paidCalls,
        free: freeCalls,
        totalDurationSeconds: totalCallDurationSeconds,
        totalBilledCredits,
        totalListenerPayoutCredits,
        totalPlatformRevenueCredits,
      },
      reports: {
        total: totalReports,
        open: openReports,
        reviewed: reviewedReports,
      },
      reviews: {
        total: totalReviews,
        averageRating: averageReviewRating,
      },
      payments: {
        totalOrders: totalPaymentOrders,
        verifiedOrders: verifiedPaymentOrders,
        pendingOrders: pendingPaymentOrders,
        failedOrders: failedPaymentOrders,
        verifiedAmount: verifiedPaymentAmount,
        statusCounts: paymentOrderStatusCounts,
      },
      adminActions: {
        total: adminActionDocs.length,
        categoryCounts: adminActionCategoryCounts,
      },
      financeReconciliation,
    },
    financeReconciliation,

    lists: {
      recentUsers: recentUsers.slice(0, 20),
      recentCalls: recentCalls.slice(0, 20),
      recentReports: recentReports.slice(0, 20),
      recentWithdrawals: recentWithdrawals.slice(0, 20),
      withdrawalsMissingPaymentReference:
        withdrawalsMissingPaymentReference.slice(0, 20),
      withdrawalsMissingLedgerSettlement:
        withdrawalsMissingLedgerSettlement.slice(0, 20),
      recentAccountDeletionRequests: recentAccountDeletionRequests.slice(0, 20),
      recentAdminActions: recentAdminActions.slice(0, 20),
      adminActionsByCategory: Object.fromEntries(
        Object.entries(adminActionsByCategory).map(([key, rows]) => [
          key,
          rows.slice(0, 20),
        ])
      ),
      recentReviews: recentReviews.slice(0, 20),
      recentPaymentOrders: recentPaymentOrders.slice(0, 20),
      paymentOrdersByStatus: Object.fromEntries(
        Object.entries(paymentOrdersByStatus).map(([key, rows]) => [
          key,
          rows.slice(0, 20),
        ])
      ),
    },

    // Backwards-compatible fields for older admin clients.
    totalUsers,
    totalListeners,
    blockedRelationships: blockedUsers,
    totalReports,
    pendingWithdrawals: pendingWithdrawalRequests,
    pendingAccountDeletionRequests,
    totalReviews,
    totalCalls,
    totalPaymentOrders,
    totalTopupAmount: verifiedPaymentAmount,
    latestUsers: recentUsers.slice(0, 20),
    latestReports: recentReports.slice(0, 20),
    latestPendingWithdrawals: recentWithdrawals.slice(0, 20),
    latestAccountDeletionRequests: recentAccountDeletionRequests.slice(0, 20),
    latestAdminActions: recentAdminActions.slice(0, 20),
    latestReviews: recentReviews.slice(0, 20),
    latestCalls: recentCalls.slice(0, 20),
    latestPaymentOrders: recentPaymentOrders.slice(0, 20),
  };
}

exports.adminGetDashboard_v1 = functions
  .region(REGION)
  .runWith({ maxInstances: MAX_INSTANCES, memory: "512MB", timeoutSeconds: 120 })
  .https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "adminGetDashboard_v1");

  const adminMeta = await requireAdmin(context);
  const forceRefresh = data && data.forceRefresh === true;

  if (!forceRefresh) {
    const cached = await readFreshCacheOrNull("dashboard_v1", DASHBOARD_TTL_MS);
    if (cached && cached.payload) {
      return withCacheMeta(cached.payload, {
        source: "cache",
        refreshedAtMs: cached.refreshedAtMs,
      });
    }
  }

  const payload = await buildDashboardPayload(adminMeta);
  await writeCache("dashboard_v1", payload);
  return withCacheMeta(payload, { source: "fresh" });
});

exports.adminRefreshDashboardCache_v1 = functions
  .region(REGION)
  .runWith({ maxInstances: MAX_INSTANCES, memory: "512MB", timeoutSeconds: 120 })
  .https.onCall(async (_data, context) => {
    assertCallableAppCheck(context, "adminRefreshDashboardCache_v1");

    const adminMeta = await requireAdmin(context);
    const payload = await buildDashboardPayload(adminMeta);
    await writeCache("dashboard_v1", payload);
    const refreshedAtMs = Date.now();
    const auditRef = adminActionRef();
    await auditRef.set(
      buildDashboardCacheRefreshAuditDoc({
        actionId: auditRef.id,
        adminMeta,
        payload,
        refreshedAtMs,
      })
    );

    return {
      ok: true,
      actionId: auditRef.id,
      refreshedAtMs,
    };
  });

exports._buildFinanceReconciliation = buildFinanceReconciliation;
exports._buildWithdrawalDashboardRows = buildWithdrawalDashboardRows;
exports._buildDashboardCacheRefreshAuditDoc =
  buildDashboardCacheRefreshAuditDoc;
exports._adminActionCategory = adminActionCategory;
exports._buildAdminActionCategoryCounts = buildAdminActionCategoryCounts;
exports._buildAdminActionDashboardRows = buildAdminActionDashboardRows;
exports._paymentOrderStatusCategory = paymentOrderStatusCategory;
exports._buildPaymentOrderDashboardRows = buildPaymentOrderDashboardRows;
