import 'package:cloud_functions/cloud_functions.dart';

import '../shared/models/admin_dashboard_model.dart';

class AdminRepository {
  AdminRepository._();

  static final AdminRepository instance = AdminRepository._();

  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'us-central1');

  int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return fallback;
  }

  DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is num) {
      final millis = value.toInt();
      if (millis > 0) {
        return DateTime.fromMillisecondsSinceEpoch(millis);
      }
      return null;
    }

    final type = value.runtimeType.toString();
    if (type == 'Timestamp') {
      try {
        return value.toDate() as DateTime;
      } catch (_) {
        return null;
      }
    }

    try {
      final converted = value.toDate();
      if (converted is DateTime) return converted;
    } catch (_) {
      // ignore malformed timestamp-like values
    }

    if (value is String) {
      return DateTime.tryParse(value.trim());
    }

    return null;
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _nestedMap(
    Map<String, dynamic> source,
    String key,
  ) {
    return _asMap(source[key]);
  }

  List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];

    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<String, int> _asIntMap(dynamic raw) {
    if (raw is! Map) return const <String, int>{};
    return raw.map(
      (key, value) => MapEntry(_asString(key), _asInt(value)),
    )..removeWhere((key, value) => key.isEmpty);
  }

  Map<String, List<Map<String, dynamic>>> _asMapListMap(dynamic raw) {
    if (raw is! Map) return const <String, List<Map<String, dynamic>>>{};
    final result = <String, List<Map<String, dynamic>>>{};
    raw.forEach((key, value) {
      final safeKey = _asString(key);
      if (safeKey.isEmpty) return;
      result[safeKey] = _asMapList(value);
    });
    return result;
  }

  AdminFinanceReconciliation _mapFinanceReconciliation(
    Map<String, dynamic> data,
  ) {
    final userLiability = _nestedMap(data, 'userLiability');
    final gateway = _nestedMap(data, 'gateway');
    final calls = _nestedMap(data, 'calls');
    final withdrawals = _nestedMap(data, 'withdrawals');
    final walletLedger = _nestedMap(data, 'walletLedger');
    final deltas = _nestedMap(data, 'deltas');
    final warnings = _asMapList(data['warnings'])
        .map(
          (warning) => AdminFinanceWarning(
            key: _asString(warning['key']),
            delta: _asInt(warning['delta']),
            count: _asInt(warning['count']),
          ),
        )
        .toList();

    return AdminFinanceReconciliation(
      status: _asString(data['status'], fallback: 'unknown'),
      readOnly: _asBool(data['readOnly'], fallback: true),
      sampled: _asBool(data['sampled']),
      userLiability: AdminFinanceUserLiability(
        credits: _asInt(userLiability['credits']),
        earningsCredits: _asInt(userLiability['earningsCredits']),
        reservedCredits: _asInt(userLiability['reservedCredits']),
        pendingWithdrawalCredits:
            _asInt(userLiability['pendingWithdrawalCredits']),
        total: _asInt(userLiability['total']),
      ),
      gateway: AdminFinanceGateway(
        verifiedPaymentAmount: _asInt(gateway['verifiedPaymentAmount']),
      ),
      calls: AdminFinanceCalls(
        totalBilledCredits: _asInt(calls['totalBilledCredits']),
        totalListenerPayoutCredits: _asInt(calls['totalListenerPayoutCredits']),
        totalPlatformRevenueCredits:
            _asInt(calls['totalPlatformRevenueCredits']),
        activeCallReservedAmount: _asInt(calls['activeCallReservedAmount']),
      ),
      withdrawals: AdminFinanceWithdrawals(
        approvedWithdrawalAmount:
            _asInt(withdrawals['approvedWithdrawalAmount']),
        approvedWithdrawalsMissingPaymentReference: _asInt(
          withdrawals['approvedWithdrawalsMissingPaymentReference'],
        ),
        approvedWithdrawalsMissingLedgerSettlement: _asInt(
          withdrawals['approvedWithdrawalsMissingLedgerSettlement'],
        ),
        pendingWithdrawalHeldAmount:
            _asInt(withdrawals['pendingWithdrawalHeldAmount']),
      ),
      walletLedger: AdminFinanceWalletLedger(
        totalTransactions: _asInt(walletLedger['totalTransactions']),
        completedTransactions: _asInt(walletLedger['completedTransactions']),
        nonCompletedTransactions:
            _asInt(walletLedger['nonCompletedTransactions']),
        topupCredits: _asInt(walletLedger['topupCredits']),
        callChargeDebits: _asInt(walletLedger['callChargeDebits']),
        callEarningCredits: _asInt(walletLedger['callEarningCredits']),
        withdrawalDebits: _asInt(walletLedger['withdrawalDebits']),
        otherCredits: _asInt(walletLedger['otherCredits']),
        otherDebits: _asInt(walletLedger['otherDebits']),
        netMovement: _asInt(walletLedger['netMovement']),
      ),
      deltas: AdminFinanceDeltas(
        verifiedPaymentVsTopupLedger:
            _asInt(deltas['verifiedPaymentVsTopupLedger']),
        callBilledVsChargeLedger: _asInt(deltas['callBilledVsChargeLedger']),
        callPayoutVsEarningLedger: _asInt(deltas['callPayoutVsEarningLedger']),
        approvedWithdrawalVsLedger:
            _asInt(deltas['approvedWithdrawalVsLedger']),
        pendingWithdrawalHoldsVsUserLiability:
            _asInt(deltas['pendingWithdrawalHoldsVsUserLiability']),
        activeCallReserveVsUserLiability:
            _asInt(deltas['activeCallReserveVsUserLiability']),
      ),
      warnings: warnings,
    );
  }

  AdminUserItem _mapUserItem(Map<String, dynamic> data) {
    return AdminUserItem(
      id: _asString(data['id']),
      displayName: _asString(data['displayName']),
      isListener: _asBool(data['isListener']),
      adminBlocked: _asBool(data['adminBlocked']),
      adminBlockReason: _asString(data['adminBlockReason']),
      adminBlockedAt: _asDateTime(data['adminBlockedAt']),
    );
  }

  AdminReportItem _mapReportItem(Map<String, dynamic> data) {
    return AdminReportItem(
      id: _asString(data['id']),
      type: _asString(data['type'], fallback: 'report'),
      reporterId: _asString(data['reporterId']),
      reportedUserId: _asString(data['reportedUserId']),
      callId: _asString(data['callId']),
      postId: _asString(data['postId']),
      commentId: _asString(data['commentId']),
      commentText: _asString(data['commentText']),
      reason: _asString(data['reason']),
      status: _asString(data['status'], fallback: 'open'),
      resolution: _asString(data['resolution']),
      reportCount: _asInt(data['reportCount']),
      createdAt: _asDateTime(data['createdAt'] ?? data['createdAtMs']),
      reviewedAt: _asDateTime(data['reviewedAt'] ?? data['reviewedAtMs']),
    );
  }

  AdminCallItem _mapCallItem(Map<String, dynamic> data) {
    return AdminCallItem(
      id: _asString(data['id']),
      callerId: _asString(data['callerId']),
      calleeId: _asString(data['calleeId']),
      status: _asString(data['status'], fallback: 'unknown'),
      endedReason: _asString(data['endedReason']),
      durationSeconds: _asInt(data['durationSeconds']),
      billedCredits: _asInt(data['billedCredits']),
      updatedAt: _asDateTime(
        data['updatedAt'] ?? data['updatedAtMs'] ?? data['createdAtMs'],
      ),
    );
  }

  AdminPaymentOrderItem _mapPaymentOrderItem(Map<String, dynamic> data) {
    return AdminPaymentOrderItem(
      id: _asString(data['id']),
      userId: _asString(data['userId']),
      gateway: _asString(data['gateway'], fallback: 'unknown'),
      status: _asString(data['status'], fallback: 'unknown'),
      statusCategory: _asString(data['statusCategory']),
      amount: _asInt(data['amount']),
      currency: _asString(data['currency'], fallback: 'INR'),
      updatedAt: _asDateTime(
        data['updatedAt'] ?? data['updatedAtMs'] ?? data['createdAtMs'],
      ),
    );
  }

  AdminWithdrawalItem _mapWithdrawalItem(Map<String, dynamic> data) {
    return AdminWithdrawalItem(
      id: _asString(data['id']),
      userId: _asString(data['userId']),
      amount: _asInt(data['amount']),
      status: _asString(data['status'], fallback: 'pending'),
      note: _asString(data['note']),
      adminNote: _asString(data['adminNote']),
      statusReason: _asString(data['statusReason']),
      paymentReference: _asString(data['paymentReference']),
      settledInLedger: _asBool(data['settledInLedger']),
      settlementLedgerTxId: _asString(data['settlementLedgerTxId']),
      requestedAt: _asDateTime(data['requestedAt'] ?? data['updatedAtMs']),
    );
  }

  AdminAccountDeletionRequestItem _mapAccountDeletionRequestItem(
    Map<String, dynamic> data,
  ) {
    return AdminAccountDeletionRequestItem(
      id: _asString(data['id']),
      userId: _asString(data['userId']),
      displayName: _asString(data['displayName']),
      email: _asString(data['email']),
      reason: _asString(data['reason']),
      note: _asString(data['note']),
      status: _asString(data['status'], fallback: 'pending'),
      outcome: _asString(data['outcome']),
      adminNote: _asString(data['adminNote']),
      reviewedBy: _asString(data['reviewedBy']),
      retentionPolicyApplied: _asBool(data['retentionPolicyApplied']),
      requestedAt: _asDateTime(
        data['requestedAt'] ?? data['requestedAtMs'] ?? data['createdAtMs'],
      ),
      updatedAt: _asDateTime(
        data['updatedAt'] ?? data['updatedAtMs'] ?? data['reviewedAtMs'],
      ),
    );
  }

  AdminActionItem _mapAdminActionItem(Map<String, dynamic> data) {
    return AdminActionItem(
      id: _asString(data['id']),
      actionType: _asString(data['actionType'], fallback: 'admin_action'),
      actionCategory: _asString(data['actionCategory']),
      adminUid: _asString(data['adminUid']),
      adminSource: _asString(data['adminSource']),
      targetUserId: _asString(data['targetUserId']),
      requestId: _asString(data['requestId']),
      reportId: _asString(data['reportId']),
      beforeStatus: _asString(data['beforeStatus']),
      beforeOutcome: _asString(data['beforeOutcome']),
      afterStatus: _asString(data['afterStatus']),
      afterOutcome: _asString(data['afterOutcome']),
      amount: _asInt(data['amount']),
      currency: _asString(data['currency']),
      ledgerTxId: _asString(data['ledgerTxId']),
      paymentReference: _asString(data['paymentReference']),
      heldCredits: _asInt(data['heldCredits']),
      pendingWithdrawalCreditsAfter:
          _asInt(data['pendingWithdrawalCreditsAfter']),
      totalUsers: _asInt(data['totalUsers']),
      totalWithdrawalRequests: _asInt(data['totalWithdrawalRequests']),
      financeWarningCount: _asInt(data['financeWarningCount']),
      financeStatus: _asString(data['financeStatus']),
      note: _asString(data['note']),
      notePresent: _asBool(data['notePresent']),
      retentionPolicyApplied: _asBool(data['retentionPolicyApplied']),
      createdAt: _asDateTime(
        data['createdAt'] ?? data['createdAtMs'] ?? data['reviewedAtMs'],
      ),
    );
  }

  AdminReviewItem _mapReviewItem(Map<String, dynamic> data) {
    return AdminReviewItem(
      id: _asString(data['id']),
      callId: _asString(data['callId']),
      reviewedUserId: _asString(data['reviewedUserId']),
      stars: _asInt(data['stars']),
      text: _asString(data['text']),
      createdAt: _asDateTime(data['createdAt'] ?? data['createdAtMs']),
    );
  }

  Future<bool> isCurrentUserAdmin() async {
    try {
      await _functions
          .httpsCallable('adminGetDashboard_v1')
          .call(<String, dynamic>{});
      return true;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'permission-denied' ||
          e.code == 'unauthenticated' ||
          e.code == 'failed-precondition') {
        return false;
      }
      rethrow;
    }
  }

  Future<AdminDashboardModel> loadDashboard({bool forceRefresh = false}) async {
    final result = await _functions
        .httpsCallable('adminGetDashboard_v1')
        .call(<String, dynamic>{
      if (forceRefresh) 'forceRefresh': true,
    });

    final data = _asMap(result.data);
    if (data.isEmpty) {
      throw StateError('adminGetDashboard_v1 returned invalid response.');
    }

    final summary = _nestedMap(data, 'summary');
    final userSummary = _nestedMap(summary, 'users');
    final withdrawalSummary = _nestedMap(summary, 'withdrawals');
    final callSummary = _nestedMap(summary, 'calls');
    final reviewSummary = _nestedMap(summary, 'reviews');
    final paymentSummary = _nestedMap(summary, 'payments');
    final reportSummary = _nestedMap(summary, 'reports');
    final adminActionSummary = _nestedMap(summary, 'adminActions');
    final cacheMeta = _nestedMap(data, 'cacheMeta');
    final financeReconciliation = _nestedMap(
      data,
      'financeReconciliation',
    ).isNotEmpty
        ? _nestedMap(data, 'financeReconciliation')
        : _nestedMap(summary, 'financeReconciliation');
    final lists = _nestedMap(data, 'lists');

    final latestUsersRaw = _asMapList(
      lists['recentUsers'] ?? data['latestUsers'],
    );
    final latestReportsRaw = _asMapList(
      lists['recentReports'] ?? data['latestReports'],
    );
    final latestWithdrawalsRaw = _asMapList(
      lists['recentWithdrawals'] ?? data['latestPendingWithdrawals'],
    );
    final withdrawalsMissingPaymentReferenceRaw = _asMapList(
      lists['withdrawalsMissingPaymentReference'],
    );
    final withdrawalsMissingLedgerSettlementRaw = _asMapList(
      lists['withdrawalsMissingLedgerSettlement'],
    );
    final latestAccountDeletionRequestsRaw = _asMapList(
      lists['recentAccountDeletionRequests'] ??
          data['latestAccountDeletionRequests'],
    );
    final latestAdminActionsRaw = _asMapList(
      lists['recentAdminActions'] ?? data['latestAdminActions'],
    );
    final adminActionsByCategoryRaw = _asMapListMap(
      lists['adminActionsByCategory'],
    );
    final latestReviewsRaw = _asMapList(
      lists['recentReviews'] ?? data['latestReviews'],
    );
    final latestCallsRaw = _asMapList(
      lists['recentCalls'] ?? data['latestCalls'],
    );
    final latestPaymentOrdersRaw = _asMapList(
      lists['recentPaymentOrders'] ?? data['latestPaymentOrders'],
    );
    final paymentOrdersByStatusRaw = _asMapListMap(
      lists['paymentOrdersByStatus'],
    );

    return AdminDashboardModel(
      totalUsers: _asInt(userSummary['total'] ?? data['totalUsers']),
      totalListeners: _asInt(
        userSummary['listeners'] ?? data['totalListeners'],
      ),
      blockedRelationships: _asInt(
        data['blockedRelationships'] ?? userSummary['blockedUsers'],
      ),
      totalReports: _asInt(reportSummary['total'] ?? data['totalReports']),
      pendingWithdrawals: _asInt(
        withdrawalSummary['pendingRequests'] ?? data['pendingWithdrawals'],
      ),
      totalReviews: _asInt(reviewSummary['total'] ?? data['totalReviews']),
      totalCalls: _asInt(callSummary['total'] ?? data['totalCalls']),
      totalPaymentOrders: _asInt(
        paymentSummary['totalOrders'] ?? data['totalPaymentOrders'],
      ),
      totalTopupAmount: _asInt(
        paymentSummary['verifiedAmount'] ?? data['totalTopupAmount'],
      ),
      pendingAccountDeletionRequests: _asInt(
        _nestedMap(summary, 'accountDeletionRequests')['pending'] ??
            data['pendingAccountDeletionRequests'],
      ),
      cacheSource: _asString(cacheMeta['source'], fallback: 'unknown'),
      cacheHit: _asBool(cacheMeta['cacheHit']),
      cacheAgeMs: _asInt(cacheMeta['ageMs']),
      cacheTtlMs: _asInt(cacheMeta['ttlMs']),
      generatedAt: _asDateTime(
        cacheMeta['generatedAtMs'] ?? data['generatedAtMs'],
      ),
      financeReconciliation: _mapFinanceReconciliation(financeReconciliation),
      latestReports: latestReportsRaw.map(_mapReportItem).toList(),
      latestPendingWithdrawals:
          latestWithdrawalsRaw.map(_mapWithdrawalItem).toList(),
      withdrawalsMissingPaymentReference: withdrawalsMissingPaymentReferenceRaw
          .map(_mapWithdrawalItem)
          .toList(),
      withdrawalsMissingLedgerSettlement: withdrawalsMissingLedgerSettlementRaw
          .map(_mapWithdrawalItem)
          .toList(),
      latestAccountDeletionRequests: latestAccountDeletionRequestsRaw
          .map(_mapAccountDeletionRequestItem)
          .toList(),
      latestAdminActions:
          latestAdminActionsRaw.map(_mapAdminActionItem).toList(),
      adminActionCategoryCounts:
          _asIntMap(adminActionSummary['categoryCounts']),
      adminActionsByCategory: adminActionsByCategoryRaw.map(
        (key, value) => MapEntry(
          key,
          value.map(_mapAdminActionItem).toList(),
        ),
      ),
      latestReviews: latestReviewsRaw.map(_mapReviewItem).toList(),
      latestUsers: latestUsersRaw.map(_mapUserItem).toList(),
      latestCalls: latestCallsRaw.map(_mapCallItem).toList(),
      latestPaymentOrders:
          latestPaymentOrdersRaw.map(_mapPaymentOrderItem).toList(),
      paymentOrderStatusCounts: _asIntMap(paymentSummary['statusCounts']),
      paymentOrdersByStatus: paymentOrdersByStatusRaw.map(
        (key, value) => MapEntry(
          key,
          value.map(_mapPaymentOrderItem).toList(),
        ),
      ),
    );
  }

  Future<void> refreshDashboardCache() async {
    await _functions
        .httpsCallable('adminRefreshDashboardCache_v1')
        .call(<String, dynamic>{});
  }

  Future<Map<String, dynamic>> backfillPublicUsers() async {
    final result = await _functions
        .httpsCallable('backfillPublicUsers_v1')
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> backfillFollowersCount() async {
    final result = await _functions
        .httpsCallable('backfillFollowersCount_v1')
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<void> approveWithdrawal(
    String requestId, {
    String adminNote = '',
    String paymentReference = '',
  }) async {
    final safeRequestId = requestId.trim();
    if (safeRequestId.isEmpty) {
      throw ArgumentError('requestId cannot be empty');
    }

    await _functions.httpsCallable('adminApproveWithdrawal_v1').call({
      'requestId': safeRequestId,
      'adminNote': adminNote.trim(),
      'paymentReference': paymentReference.trim(),
    });
  }

  Future<void> repairWithdrawalLedgerProof(
    String requestId, {
    String paymentReference = '',
  }) async {
    final safeRequestId = requestId.trim();
    if (safeRequestId.isEmpty) {
      throw ArgumentError('requestId cannot be empty');
    }

    await _functions.httpsCallable('adminApproveWithdrawal_v1').call({
      'requestId': safeRequestId,
      'adminNote': 'Repair approved withdrawal ledger proof',
      'paymentReference': paymentReference.trim(),
    });
  }

  Future<void> rejectWithdrawal(
    String requestId, {
    String reason = 'Rejected by admin',
  }) async {
    final safeRequestId = requestId.trim();
    if (safeRequestId.isEmpty) {
      throw ArgumentError('requestId cannot be empty');
    }

    await _functions.httpsCallable('adminRejectWithdrawal_v1').call({
      'requestId': safeRequestId,
      'reason': reason.trim().isEmpty ? 'Rejected by admin' : reason.trim(),
    });
  }

  Future<void> updateWithdrawalPayoutProof(
    String requestId, {
    required String paymentReference,
    String adminNote = '',
  }) async {
    final safeRequestId = requestId.trim();
    if (safeRequestId.isEmpty) {
      throw ArgumentError('requestId cannot be empty');
    }
    final safePaymentReference = paymentReference.trim();
    if (safePaymentReference.isEmpty) {
      throw ArgumentError('paymentReference cannot be empty');
    }

    await _functions.httpsCallable('adminUpdateWithdrawalPayoutProof_v1').call({
      'requestId': safeRequestId,
      'paymentReference': safePaymentReference,
      'adminNote': adminNote.trim(),
    });
  }

  Future<void> reviewAccountDeletionRequest(
    String requestId, {
    required String outcome,
    String note = '',
    bool retentionPolicyApplied = false,
  }) async {
    final safeRequestId = requestId.trim();
    if (safeRequestId.isEmpty) {
      throw ArgumentError('requestId cannot be empty');
    }

    await _functions
        .httpsCallable('adminReviewAccountDeletionRequest_v1')
        .call({
      'requestId': safeRequestId,
      'outcome': outcome.trim().isEmpty ? 'completed' : outcome.trim(),
      'note': note.trim(),
      'retentionPolicyApplied': retentionPolicyApplied,
    });
  }

  Future<void> blockUser(
    String userId, {
    String reason = 'Blocked by admin',
  }) async {
    final safeUserId = userId.trim();
    if (safeUserId.isEmpty) {
      throw ArgumentError('userId cannot be empty');
    }

    await _functions.httpsCallable('adminBlockUser_v1').call({
      'userId': safeUserId,
      'reason': reason.trim().isEmpty ? 'Blocked by admin' : reason.trim(),
    });
  }

  Future<void> unblockUser(String userId) async {
    final safeUserId = userId.trim();
    if (safeUserId.isEmpty) {
      throw ArgumentError('userId cannot be empty');
    }

    await _functions.httpsCallable('adminUnblockUser_v1').call({
      'userId': safeUserId,
    });
  }

  Future<void> resolveReport(
    String reportId, {
    String resolution = 'dismissed',
    String note = '',
  }) async {
    final safeReportId = reportId.trim();
    if (safeReportId.isEmpty) {
      throw ArgumentError('reportId cannot be empty');
    }

    await _functions.httpsCallable('adminResolveReport_v1').call({
      'reportId': safeReportId,
      'resolution': resolution.trim().isEmpty ? 'dismissed' : resolution.trim(),
      'note': note.trim(),
    });
  }

  Future<void> deleteReportedContent(
    String reportId, {
    String note = '',
  }) async {
    final safeReportId = reportId.trim();
    if (safeReportId.isEmpty) {
      throw ArgumentError('reportId cannot be empty');
    }

    await _functions.httpsCallable('adminDeleteReportedContent_v1').call({
      'reportId': safeReportId,
      'note': note.trim(),
    });
  }

  Future<Map<String, dynamic>> checkAgoraServerConfig() async {
    final result = await _functions
        .httpsCallable('checkAgoraServerConfig_v1')
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }
}
