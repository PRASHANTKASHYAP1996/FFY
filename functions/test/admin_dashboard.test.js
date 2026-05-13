const test = require("node:test");
const assert = require("node:assert/strict");

const {
  _buildFinanceReconciliation,
  _buildWithdrawalDashboardRows,
  _buildDashboardCacheRefreshAuditDoc,
  _adminActionCategory,
  _buildAdminActionCategoryCounts,
  _buildAdminActionDashboardRows,
  _paymentOrderStatusCategory,
  _buildPaymentOrderDashboardRows,
} = require("../src/admin_dashboard");

test("finance reconciliation reports balanced ledger totals", () => {
  const result = _buildFinanceReconciliation({
    totalCredits: 1000,
    totalEarningsCredits: 250,
    totalReservedCredits: 50,
    totalPendingWithdrawalCredits: 80,
    totalActiveCallReservedAmount: 50,
    verifiedPaymentAmount: 1500,
    approvedWithdrawalAmount: 200,
    approvedWithdrawalsMissingPaymentReference: 0,
    approvedWithdrawalsMissingLedgerSettlement: 0,
    pendingWithdrawalHeldAmount: 80,
    totalBilledCredits: 300,
    totalListenerPayoutCredits: 240,
    totalPlatformRevenueCredits: 60,
    walletTransactionDocs: [
      { type: "topup", amount: 1500, status: "completed" },
      { type: "call_charge", amount: -300, status: "completed" },
      { type: "call_earning", amount: 240, status: "completed" },
      { type: "withdrawal_debit", amount: -200, status: "completed" },
    ],
  });

  assert.equal(result.status, "balanced");
  assert.deepEqual(result.warnings, []);
  assert.equal(result.userLiability.total, 1380);
  assert.equal(result.userLiability.pendingWithdrawalCredits, 80);
  assert.equal(result.walletLedger.netMovement, 1240);
  assert.deepEqual(result.deltas, {
    verifiedPaymentVsTopupLedger: 0,
    callBilledVsChargeLedger: 0,
    callPayoutVsEarningLedger: 0,
    approvedWithdrawalVsLedger: 0,
    pendingWithdrawalHoldsVsUserLiability: 0,
    activeCallReserveVsUserLiability: 0,
  });
});

test("finance reconciliation flags ledger deltas", () => {
  const result = _buildFinanceReconciliation({
    verifiedPaymentAmount: 1500,
    approvedWithdrawalAmount: 300,
    approvedWithdrawalsMissingPaymentReference: 2,
    approvedWithdrawalsMissingLedgerSettlement: 1,
    pendingWithdrawalHeldAmount: 90,
    totalPendingWithdrawalCredits: 70,
    totalReservedCredits: 40,
    totalActiveCallReservedAmount: 25,
    totalBilledCredits: 400,
    totalListenerPayoutCredits: 250,
    walletTransactionDocs: [
      { type: "topup", amount: 1400, status: "completed" },
      { type: "call_charge", amount: -350, status: "completed" },
      { type: "call_earning", amount: 240, status: "completed" },
      { type: "withdrawal_debit", amount: -200, status: "pending" },
    ],
  });

  assert.equal(result.status, "review_required");
  assert.equal(result.deltas.verifiedPaymentVsTopupLedger, 100);
  assert.equal(result.deltas.callBilledVsChargeLedger, 50);
  assert.equal(result.deltas.callPayoutVsEarningLedger, 10);
  assert.equal(result.deltas.approvedWithdrawalVsLedger, 100);
  assert.equal(result.deltas.pendingWithdrawalHoldsVsUserLiability, 20);
  assert.equal(result.deltas.activeCallReserveVsUserLiability, -15);
  assert.equal(result.withdrawals.approvedWithdrawalsMissingPaymentReference, 2);
  assert.equal(result.withdrawals.approvedWithdrawalsMissingLedgerSettlement, 1);
  assert.equal(result.walletLedger.nonCompletedTransactions, 1);
  assert.equal(result.warnings.length, 9);
  assert.equal(
    result.warnings.some(
      (warning) => warning.key === "approvedWithdrawalsMissingPaymentReference"
    ),
    true
  );
  assert.equal(
    result.warnings.some(
      (warning) => warning.key === "approvedWithdrawalsMissingLedgerSettlement"
    ),
    true
  );
});

test("withdrawal dashboard rows expose targeted finance warning drilldowns", () => {
  const docs = [
    {
      id: "old_missing_both",
      data: () => ({
        status: "approved",
        userId: "userA",
        amount: 80,
        paymentReference: "",
        settledInLedger: false,
        createdAtMs: 1000,
        approvedAtMs: 1000,
      }),
    },
    {
      id: "missing_payout_only",
      data: () => ({
        status: "approved",
        userId: "userB",
        amount: 90,
        paymentReference: "",
        settledInLedger: true,
        settlementLedgerTxId: "withdrawal_missing_payout_only_debit",
        createdAtMs: 4000,
        approvedAtMs: 4000,
      }),
    },
    {
      id: "missing_ledger_only",
      data: () => ({
        status: "approved",
        userId: "userC",
        amount: 70,
        paymentReference: "payout-ref",
        settledInLedger: false,
        createdAtMs: 3000,
        approvedAtMs: 3000,
      }),
    },
    {
      id: "clean_approved",
      data: () => ({
        status: "approved",
        userId: "userD",
        amount: 60,
        paymentReference: "clean-ref",
        settledInLedger: true,
        settlementLedgerTxId: "withdrawal_clean_approved_debit",
        createdAtMs: 5000,
        approvedAtMs: 5000,
      }),
    },
    {
      id: "pending_hold",
      data: () => ({
        status: "pending",
        userId: "userE",
        amount: 50,
        heldCredits: 50,
        holdStatus: "held",
        createdAtMs: 6000,
      }),
    },
  ];

  const result = _buildWithdrawalDashboardRows(docs);

  assert.equal(result.totalWithdrawalRequests, 5);
  assert.equal(result.pendingWithdrawalRequests, 1);
  assert.equal(result.pendingWithdrawalHeldAmount, 50);
  assert.equal(result.approvedWithdrawalRequests, 4);
  assert.equal(result.approvedWithdrawalAmount, 300);
  assert.equal(result.approvedWithdrawalsMissingPaymentReference, 2);
  assert.equal(result.approvedWithdrawalsMissingLedgerSettlement, 2);

  assert.deepEqual(
    result.recentWithdrawals.map((item) => item.id),
    [
      "pending_hold",
      "clean_approved",
      "missing_payout_only",
      "missing_ledger_only",
      "old_missing_both",
    ]
  );
  assert.deepEqual(
    result.withdrawalsMissingPaymentReference.map((item) => item.id),
    ["missing_payout_only", "old_missing_both"]
  );
  assert.deepEqual(
    result.withdrawalsMissingLedgerSettlement.map((item) => item.id),
    ["missing_ledger_only", "old_missing_both"]
  );
});

test("payment order dashboard rows expose status filter drilldowns", () => {
  const docs = [
    {
      id: "old_verified",
      data: () => ({
        status: "verified",
        userId: "userA",
        amount: 120,
        gateway: "razorpay",
        createdAtMs: 1000,
        verifiedAtMs: 2000,
      }),
    },
    {
      id: "latest_pending",
      data: () => ({
        status: "created",
        userId: "userB",
        amount: 250,
        gateway: "razorpay",
        createdAtMs: 5000,
      }),
    },
    {
      id: "failed_order",
      data: () => ({
        status: "cancelled",
        userId: "userC",
        amount: 80,
        createdAtMs: 3000,
      }),
    },
    {
      id: "manual_review",
      data: () => ({
        status: "manual_review",
        userId: "userD",
        amount: 60,
        createdAtMs: 4000,
      }),
    },
  ];

  const result = _buildPaymentOrderDashboardRows(docs);

  assert.equal(_paymentOrderStatusCategory("captured"), "verified");
  assert.equal(_paymentOrderStatusCategory("created"), "pending");
  assert.equal(_paymentOrderStatusCategory("cancelled"), "failed");
  assert.equal(_paymentOrderStatusCategory("manual_review"), "other");

  assert.equal(result.totalPaymentOrders, 4);
  assert.equal(result.verifiedPaymentOrders, 1);
  assert.equal(result.pendingPaymentOrders, 1);
  assert.equal(result.failedPaymentOrders, 1);
  assert.equal(result.verifiedPaymentAmount, 120);
  assert.deepEqual(result.statusCounts, {
    verified: 1,
    pending: 1,
    failed: 1,
    other: 1,
  });
  assert.deepEqual(
    result.recentPaymentOrders.map((item) => item.id),
    ["latest_pending", "manual_review", "failed_order", "old_verified"]
  );
  assert.deepEqual(
    result.paymentOrdersByStatus.pending.map((item) => item.id),
    ["latest_pending"]
  );
  assert.deepEqual(
    result.paymentOrdersByStatus.verified.map((item) => item.id),
    ["old_verified"]
  );
  assert.equal(
    result.paymentOrdersByStatus.pending[0].statusCategory,
    "pending"
  );
});

test("dashboard cache refresh audit doc captures admin and summary context", () => {
  const auditDoc = _buildDashboardCacheRefreshAuditDoc({
    actionId: "audit_cache_1",
    adminMeta: {
      uid: "admin_1",
      source: "custom_claim",
    },
    payload: {
      summary: {
        users: {
          total: 42,
        },
        withdrawals: {
          totalRequests: 7,
        },
      },
      financeReconciliation: {
        status: "review_required",
        warnings: [
          { key: "approvedWithdrawalsMissingPaymentReference", count: 2 },
          { key: "approvedWithdrawalsMissingLedgerSettlement", count: 1 },
        ],
      },
    },
    refreshedAtMs: 12345,
    serverTimestamp: () => "SERVER_TIMESTAMP",
  });

  assert.deepEqual(auditDoc, {
    actionId: "audit_cache_1",
    actionType: "admin_dashboard_cache_refreshed",
    actionCategory: "cache",
    adminUid: "admin_1",
    adminSource: "custom_claim",
    afterStatus: "refreshed",
    note: "Users: 42 - Withdrawals: 7 - Finance warnings: 2",
    notePresent: true,
    totalUsers: 42,
    totalWithdrawalRequests: 7,
    financeWarningCount: 2,
    financeStatus: "review_required",
    refreshedAt: "SERVER_TIMESTAMP",
    refreshedAtMs: 12345,
    createdAt: "SERVER_TIMESTAMP",
    createdAtMs: 12345,
  });
});

test("admin action category classifies dashboard action filters", () => {
  assert.equal(
    _adminActionCategory("admin_dashboard_cache_refreshed"),
    "cache"
  );
  assert.equal(_adminActionCategory("withdrawal_request_approved"), "finance");
  assert.equal(_adminActionCategory("withdrawal_payout_proof_updated"), "finance");
  assert.equal(_adminActionCategory("moderation_report_resolved"), "moderation");
  assert.equal(
    _adminActionCategory("account_deletion_request_reviewed"),
    "accountDeletion"
  );
  assert.equal(_adminActionCategory("user_blocked"), "userAccess");
  assert.equal(_adminActionCategory("unknown_action"), "other");
});

test("admin action category counts include stored and inferred categories", () => {
  const counts = _buildAdminActionCategoryCounts([
    {
      data: () => ({
        actionType: "withdrawal_request_approved",
      }),
    },
    {
      data: () => ({
        actionType: "admin_dashboard_cache_refreshed",
      }),
    },
    {
      data: () => ({
        actionType: "custom_action",
        actionCategory: "moderation",
      }),
    },
    {
      data: () => ({
        actionType: "user_unblocked",
      }),
    },
  ]);

  assert.deepEqual(counts, {
    finance: 1,
    cache: 1,
    moderation: 1,
    userAccess: 1,
  });
});

test("admin action dashboard rows expose sorted category drilldowns", () => {
  const result = _buildAdminActionDashboardRows([
    {
      id: "finance_old",
      data: () => ({
        actionType: "withdrawal_request_approved",
        adminUid: "admin_1",
        amount: 80,
        createdAtMs: 1000,
      }),
    },
    {
      id: "cache_new",
      data: () => ({
        actionType: "admin_dashboard_cache_refreshed",
        adminUid: "admin_2",
        financeWarningCount: 2,
        createdAtMs: 4000,
      }),
    },
    {
      id: "finance_new",
      data: () => ({
        actionType: "withdrawal_payout_proof_updated",
        adminUid: "admin_1",
        amount: 90,
        createdAtMs: 3000,
      }),
    },
    {
      id: "stored_moderation",
      data: () => ({
        actionType: "custom_action",
        actionCategory: "moderation",
        adminUid: "admin_3",
        createdAtMs: 2000,
      }),
    },
  ]);

  assert.deepEqual(
    result.recentAdminActions.map((item) => item.id),
    ["cache_new", "finance_new", "stored_moderation", "finance_old"]
  );
  assert.deepEqual(
    result.adminActionsByCategory.finance.map((item) => item.id),
    ["finance_new", "finance_old"]
  );
  assert.deepEqual(
    result.adminActionsByCategory.cache.map((item) => item.id),
    ["cache_new"]
  );
  assert.deepEqual(
    result.adminActionsByCategory.moderation.map((item) => item.id),
    ["stored_moderation"]
  );
  assert.deepEqual(result.categoryCounts, {
    finance: 2,
    cache: 1,
    moderation: 1,
  });
});
