class AdminDashboardModel {
  final int totalUsers;
  final int totalListeners;
  final int blockedRelationships;
  final int totalReports;
  final int pendingWithdrawals;
  final int totalReviews;
  final int totalCalls;
  final int totalPaymentOrders;
  final int totalTopupAmount;
  final int pendingAccountDeletionRequests;
  final String cacheSource;
  final bool cacheHit;
  final int cacheAgeMs;
  final int cacheTtlMs;
  final DateTime? generatedAt;
  final AdminFinanceReconciliation financeReconciliation;
  final List<AdminReportItem> latestReports;
  final List<AdminWithdrawalItem> latestPendingWithdrawals;
  final List<AdminWithdrawalItem> withdrawalsMissingPaymentReference;
  final List<AdminWithdrawalItem> withdrawalsMissingLedgerSettlement;
  final List<AdminAccountDeletionRequestItem> latestAccountDeletionRequests;
  final List<AdminActionItem> latestAdminActions;
  final Map<String, int> adminActionCategoryCounts;
  final Map<String, List<AdminActionItem>> adminActionsByCategory;
  final List<AdminReviewItem> latestReviews;
  final List<AdminUserItem> latestUsers;
  final List<AdminCallItem> latestCalls;
  final List<AdminPaymentOrderItem> latestPaymentOrders;
  final Map<String, int> paymentOrderStatusCounts;
  final Map<String, List<AdminPaymentOrderItem>> paymentOrdersByStatus;

  const AdminDashboardModel({
    required this.totalUsers,
    required this.totalListeners,
    required this.blockedRelationships,
    required this.totalReports,
    required this.pendingWithdrawals,
    required this.totalReviews,
    required this.totalCalls,
    required this.totalPaymentOrders,
    required this.totalTopupAmount,
    required this.pendingAccountDeletionRequests,
    required this.cacheSource,
    required this.cacheHit,
    required this.cacheAgeMs,
    required this.cacheTtlMs,
    required this.generatedAt,
    required this.financeReconciliation,
    required this.latestReports,
    required this.latestPendingWithdrawals,
    required this.withdrawalsMissingPaymentReference,
    required this.withdrawalsMissingLedgerSettlement,
    required this.latestAccountDeletionRequests,
    required this.latestAdminActions,
    required this.adminActionCategoryCounts,
    required this.adminActionsByCategory,
    required this.latestReviews,
    required this.latestUsers,
    required this.latestCalls,
    required this.latestPaymentOrders,
    required this.paymentOrderStatusCounts,
    required this.paymentOrdersByStatus,
  });

  factory AdminDashboardModel.empty() {
    return const AdminDashboardModel(
      totalUsers: 0,
      totalListeners: 0,
      blockedRelationships: 0,
      totalReports: 0,
      pendingWithdrawals: 0,
      totalReviews: 0,
      totalCalls: 0,
      totalPaymentOrders: 0,
      totalTopupAmount: 0,
      pendingAccountDeletionRequests: 0,
      cacheSource: 'unknown',
      cacheHit: false,
      cacheAgeMs: 0,
      cacheTtlMs: 0,
      generatedAt: null,
      financeReconciliation: AdminFinanceReconciliation.empty(),
      latestReports: <AdminReportItem>[],
      latestPendingWithdrawals: <AdminWithdrawalItem>[],
      withdrawalsMissingPaymentReference: <AdminWithdrawalItem>[],
      withdrawalsMissingLedgerSettlement: <AdminWithdrawalItem>[],
      latestAccountDeletionRequests: <AdminAccountDeletionRequestItem>[],
      latestAdminActions: <AdminActionItem>[],
      adminActionCategoryCounts: <String, int>{},
      adminActionsByCategory: <String, List<AdminActionItem>>{},
      latestReviews: <AdminReviewItem>[],
      latestUsers: <AdminUserItem>[],
      latestCalls: <AdminCallItem>[],
      latestPaymentOrders: <AdminPaymentOrderItem>[],
      paymentOrderStatusCounts: <String, int>{},
      paymentOrdersByStatus: <String, List<AdminPaymentOrderItem>>{},
    );
  }
}

class AdminFinanceReconciliation {
  final String status;
  final bool readOnly;
  final bool sampled;
  final AdminFinanceUserLiability userLiability;
  final AdminFinanceGateway gateway;
  final AdminFinanceCalls calls;
  final AdminFinanceWithdrawals withdrawals;
  final AdminFinanceWalletLedger walletLedger;
  final AdminFinanceDeltas deltas;
  final List<AdminFinanceWarning> warnings;

  const AdminFinanceReconciliation({
    required this.status,
    required this.readOnly,
    required this.sampled,
    required this.userLiability,
    required this.gateway,
    required this.calls,
    required this.withdrawals,
    required this.walletLedger,
    required this.deltas,
    required this.warnings,
  });

  const AdminFinanceReconciliation.empty()
      : status = 'unknown',
        readOnly = true,
        sampled = false,
        userLiability = const AdminFinanceUserLiability.empty(),
        gateway = const AdminFinanceGateway.empty(),
        calls = const AdminFinanceCalls.empty(),
        withdrawals = const AdminFinanceWithdrawals.empty(),
        walletLedger = const AdminFinanceWalletLedger.empty(),
        deltas = const AdminFinanceDeltas.empty(),
        warnings = const <AdminFinanceWarning>[];

  bool get needsReview => status.trim().toLowerCase() == 'review_required';
  bool get isBalanced => status.trim().toLowerCase() == 'balanced';
}

class AdminFinanceUserLiability {
  final int credits;
  final int earningsCredits;
  final int reservedCredits;
  final int pendingWithdrawalCredits;
  final int total;

  const AdminFinanceUserLiability({
    required this.credits,
    required this.earningsCredits,
    required this.reservedCredits,
    required this.pendingWithdrawalCredits,
    required this.total,
  });

  const AdminFinanceUserLiability.empty()
      : credits = 0,
        earningsCredits = 0,
        reservedCredits = 0,
        pendingWithdrawalCredits = 0,
        total = 0;
}

class AdminFinanceGateway {
  final int verifiedPaymentAmount;

  const AdminFinanceGateway({required this.verifiedPaymentAmount});

  const AdminFinanceGateway.empty() : verifiedPaymentAmount = 0;
}

class AdminFinanceCalls {
  final int totalBilledCredits;
  final int totalListenerPayoutCredits;
  final int totalPlatformRevenueCredits;
  final int activeCallReservedAmount;

  const AdminFinanceCalls({
    required this.totalBilledCredits,
    required this.totalListenerPayoutCredits,
    required this.totalPlatformRevenueCredits,
    required this.activeCallReservedAmount,
  });

  const AdminFinanceCalls.empty()
      : totalBilledCredits = 0,
        totalListenerPayoutCredits = 0,
        totalPlatformRevenueCredits = 0,
        activeCallReservedAmount = 0;
}

class AdminFinanceWithdrawals {
  final int approvedWithdrawalAmount;
  final int approvedWithdrawalsMissingPaymentReference;
  final int approvedWithdrawalsMissingLedgerSettlement;
  final int pendingWithdrawalHeldAmount;

  const AdminFinanceWithdrawals({
    required this.approvedWithdrawalAmount,
    required this.approvedWithdrawalsMissingPaymentReference,
    required this.approvedWithdrawalsMissingLedgerSettlement,
    required this.pendingWithdrawalHeldAmount,
  });

  const AdminFinanceWithdrawals.empty()
      : approvedWithdrawalAmount = 0,
        approvedWithdrawalsMissingPaymentReference = 0,
        approvedWithdrawalsMissingLedgerSettlement = 0,
        pendingWithdrawalHeldAmount = 0;
}

class AdminFinanceWalletLedger {
  final int totalTransactions;
  final int completedTransactions;
  final int nonCompletedTransactions;
  final int topupCredits;
  final int callChargeDebits;
  final int callEarningCredits;
  final int withdrawalDebits;
  final int otherCredits;
  final int otherDebits;
  final int netMovement;

  const AdminFinanceWalletLedger({
    required this.totalTransactions,
    required this.completedTransactions,
    required this.nonCompletedTransactions,
    required this.topupCredits,
    required this.callChargeDebits,
    required this.callEarningCredits,
    required this.withdrawalDebits,
    required this.otherCredits,
    required this.otherDebits,
    required this.netMovement,
  });

  const AdminFinanceWalletLedger.empty()
      : totalTransactions = 0,
        completedTransactions = 0,
        nonCompletedTransactions = 0,
        topupCredits = 0,
        callChargeDebits = 0,
        callEarningCredits = 0,
        withdrawalDebits = 0,
        otherCredits = 0,
        otherDebits = 0,
        netMovement = 0;
}

class AdminFinanceDeltas {
  final int verifiedPaymentVsTopupLedger;
  final int callBilledVsChargeLedger;
  final int callPayoutVsEarningLedger;
  final int approvedWithdrawalVsLedger;
  final int pendingWithdrawalHoldsVsUserLiability;
  final int activeCallReserveVsUserLiability;

  const AdminFinanceDeltas({
    required this.verifiedPaymentVsTopupLedger,
    required this.callBilledVsChargeLedger,
    required this.callPayoutVsEarningLedger,
    required this.approvedWithdrawalVsLedger,
    required this.pendingWithdrawalHoldsVsUserLiability,
    required this.activeCallReserveVsUserLiability,
  });

  const AdminFinanceDeltas.empty()
      : verifiedPaymentVsTopupLedger = 0,
        callBilledVsChargeLedger = 0,
        callPayoutVsEarningLedger = 0,
        approvedWithdrawalVsLedger = 0,
        pendingWithdrawalHoldsVsUserLiability = 0,
        activeCallReserveVsUserLiability = 0;

  bool get hasAnyMismatch =>
      verifiedPaymentVsTopupLedger != 0 ||
      callBilledVsChargeLedger != 0 ||
      callPayoutVsEarningLedger != 0 ||
      approvedWithdrawalVsLedger != 0 ||
      pendingWithdrawalHoldsVsUserLiability != 0 ||
      activeCallReserveVsUserLiability != 0;
}

class AdminFinanceWarning {
  final String key;
  final int delta;
  final int count;

  const AdminFinanceWarning({
    required this.key,
    required this.delta,
    required this.count,
  });
}

class AdminUserItem {
  final String id;
  final String displayName;
  final bool isListener;
  final bool adminBlocked;
  final String adminBlockReason;
  final DateTime? adminBlockedAt;

  const AdminUserItem({
    required this.id,
    required this.displayName,
    required this.isListener,
    required this.adminBlocked,
    required this.adminBlockReason,
    required this.adminBlockedAt,
  });
}

class AdminReportItem {
  final String id;
  final String type;
  final String reporterId;
  final String reportedUserId;
  final String callId;
  final String postId;
  final String commentId;
  final String commentText;
  final String reason;
  final String status;
  final String resolution;
  final int reportCount;
  final DateTime? createdAt;
  final DateTime? reviewedAt;

  const AdminReportItem({
    required this.id,
    required this.type,
    required this.reporterId,
    required this.reportedUserId,
    required this.callId,
    required this.postId,
    required this.commentId,
    required this.commentText,
    required this.reason,
    required this.status,
    required this.resolution,
    required this.reportCount,
    required this.createdAt,
    required this.reviewedAt,
  });

  bool get isOpen {
    final safe = status.trim().toLowerCase();
    return safe.isEmpty || safe == 'open' || safe == 'pending';
  }

  bool get canDeleteReportedContent =>
      type == 'social_post' || type == 'social_comment';
}

class AdminWithdrawalItem {
  final String id;
  final String userId;
  final int amount;
  final String status;
  final String note;
  final String adminNote;
  final String statusReason;
  final String paymentReference;
  final bool settledInLedger;
  final String settlementLedgerTxId;
  final DateTime? requestedAt;

  const AdminWithdrawalItem({
    required this.id,
    required this.userId,
    required this.amount,
    required this.status,
    required this.note,
    required this.adminNote,
    required this.statusReason,
    required this.paymentReference,
    required this.settledInLedger,
    required this.settlementLedgerTxId,
    required this.requestedAt,
  });
}

class AdminAccountDeletionRequestItem {
  final String id;
  final String userId;
  final String displayName;
  final String email;
  final String reason;
  final String note;
  final String status;
  final String outcome;
  final String adminNote;
  final String reviewedBy;
  final bool retentionPolicyApplied;
  final DateTime? requestedAt;
  final DateTime? updatedAt;

  const AdminAccountDeletionRequestItem({
    required this.id,
    required this.userId,
    required this.displayName,
    required this.email,
    required this.reason,
    required this.note,
    required this.status,
    required this.outcome,
    required this.adminNote,
    required this.reviewedBy,
    required this.retentionPolicyApplied,
    required this.requestedAt,
    required this.updatedAt,
  });

  bool get isPending => status.trim().toLowerCase() == 'pending';
}

class AdminActionItem {
  final String id;
  final String actionType;
  final String actionCategory;
  final String adminUid;
  final String adminSource;
  final String targetUserId;
  final String requestId;
  final String reportId;
  final String beforeStatus;
  final String beforeOutcome;
  final String afterStatus;
  final String afterOutcome;
  final int amount;
  final String currency;
  final String ledgerTxId;
  final String paymentReference;
  final int heldCredits;
  final int pendingWithdrawalCreditsAfter;
  final int totalUsers;
  final int totalWithdrawalRequests;
  final int financeWarningCount;
  final String financeStatus;
  final String note;
  final bool notePresent;
  final bool retentionPolicyApplied;
  final DateTime? createdAt;

  const AdminActionItem({
    required this.id,
    required this.actionType,
    required this.actionCategory,
    required this.adminUid,
    required this.adminSource,
    required this.targetUserId,
    required this.requestId,
    required this.reportId,
    required this.beforeStatus,
    required this.beforeOutcome,
    required this.afterStatus,
    required this.afterOutcome,
    required this.amount,
    required this.currency,
    required this.ledgerTxId,
    required this.paymentReference,
    required this.heldCredits,
    required this.pendingWithdrawalCreditsAfter,
    required this.totalUsers,
    required this.totalWithdrawalRequests,
    required this.financeWarningCount,
    required this.financeStatus,
    required this.note,
    required this.notePresent,
    required this.retentionPolicyApplied,
    required this.createdAt,
  });
}

class AdminReviewItem {
  final String id;
  final String callId;
  final String reviewedUserId;
  final int stars;
  final String text;
  final DateTime? createdAt;

  const AdminReviewItem({
    required this.id,
    required this.callId,
    required this.reviewedUserId,
    required this.stars,
    required this.text,
    required this.createdAt,
  });
}

class AdminCallItem {
  final String id;
  final String callerId;
  final String calleeId;
  final String status;
  final String endedReason;
  final int durationSeconds;
  final int billedCredits;
  final DateTime? updatedAt;

  const AdminCallItem({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.status,
    required this.endedReason,
    required this.durationSeconds,
    required this.billedCredits,
    required this.updatedAt,
  });
}

class AdminPaymentOrderItem {
  final String id;
  final String userId;
  final String gateway;
  final String status;
  final String statusCategory;
  final int amount;
  final String currency;
  final DateTime? updatedAt;

  const AdminPaymentOrderItem({
    required this.id,
    required this.userId,
    required this.gateway,
    required this.status,
    required this.statusCategory,
    required this.amount,
    required this.currency,
    required this.updatedAt,
  });
}
