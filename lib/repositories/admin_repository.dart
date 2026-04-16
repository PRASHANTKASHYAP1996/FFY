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

  List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];

    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
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
      reportedUserId: _asString(data['reportedUserId']),
      callId: _asString(data['callId']),
      reason: _asString(data['reason']),
      createdAt: _asDateTime(data['createdAt']),
    );
  }

  AdminWithdrawalItem _mapWithdrawalItem(Map<String, dynamic> data) {
    return AdminWithdrawalItem(
      id: _asString(data['id']),
      userId: _asString(data['userId']),
      amount: _asInt(data['amount']),
      status: _asString(data['status'], fallback: 'pending'),
      note: _asString(data['note']),
      requestedAt: _asDateTime(data['requestedAt']),
    );
  }

  AdminReviewItem _mapReviewItem(Map<String, dynamic> data) {
    return AdminReviewItem(
      id: _asString(data['id']),
      callId: _asString(data['callId']),
      reviewedUserId: _asString(data['reviewedUserId']),
      stars: _asInt(data['stars']),
      text: _asString(data['text']),
      createdAt: _asDateTime(data['createdAt']),
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

  Future<AdminDashboardModel> loadDashboard() async {
    final result = await _functions
        .httpsCallable('adminGetDashboard_v1')
        .call(<String, dynamic>{});

    final data = _asMap(result.data);
    if (data.isEmpty) {
      throw StateError('adminGetDashboard_v1 returned invalid response.');
    }

    final latestUsersRaw = _asMapList(data['latestUsers']);
    final latestReportsRaw = _asMapList(data['latestReports']);
    final latestWithdrawalsRaw = _asMapList(data['latestPendingWithdrawals']);
    final latestReviewsRaw = _asMapList(data['latestReviews']);

    return AdminDashboardModel(
      totalUsers: _asInt(data['totalUsers']),
      totalListeners: _asInt(data['totalListeners']),
      blockedRelationships: _asInt(data['blockedRelationships']),
      totalReports: _asInt(data['totalReports']),
      pendingWithdrawals: _asInt(data['pendingWithdrawals']),
      totalReviews: _asInt(data['totalReviews']),
      latestReports: latestReportsRaw.map(_mapReportItem).toList(),
      latestPendingWithdrawals:
          latestWithdrawalsRaw.map(_mapWithdrawalItem).toList(),
      latestReviews: latestReviewsRaw.map(_mapReviewItem).toList(),
      latestUsers: latestUsersRaw.map(_mapUserItem).toList(),
    );
  }

  Future<void> approveWithdrawal(
    String requestId, {
    String adminNote = '',
  }) async {
    final safeRequestId = requestId.trim();
    if (safeRequestId.isEmpty) {
      throw ArgumentError('requestId cannot be empty');
    }

    await _functions.httpsCallable('adminApproveWithdrawal_v1').call({
      'requestId': safeRequestId,
      'adminNote': adminNote.trim(),
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
}