class AdminDashboardModel {
  final int totalUsers;
  final int totalListeners;
  final int blockedRelationships;
  final int totalReports;
  final int pendingWithdrawals;
  final int totalReviews;
  final List<AdminReportItem> latestReports;
  final List<AdminWithdrawalItem> latestPendingWithdrawals;
  final List<AdminReviewItem> latestReviews;
  final List<AdminUserItem> latestUsers;

  const AdminDashboardModel({
    required this.totalUsers,
    required this.totalListeners,
    required this.blockedRelationships,
    required this.totalReports,
    required this.pendingWithdrawals,
    required this.totalReviews,
    required this.latestReports,
    required this.latestPendingWithdrawals,
    required this.latestReviews,
    required this.latestUsers,
  });

  factory AdminDashboardModel.empty() {
    return const AdminDashboardModel(
      totalUsers: 0,
      totalListeners: 0,
      blockedRelationships: 0,
      totalReports: 0,
      pendingWithdrawals: 0,
      totalReviews: 0,
      latestReports: <AdminReportItem>[],
      latestPendingWithdrawals: <AdminWithdrawalItem>[],
      latestReviews: <AdminReviewItem>[],
      latestUsers: <AdminUserItem>[],
    );
  }
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
  final String reportedUserId;
  final String callId;
  final String reason;
  final DateTime? createdAt;

  const AdminReportItem({
    required this.id,
    required this.reportedUserId,
    required this.callId,
    required this.reason,
    required this.createdAt,
  });
}

class AdminWithdrawalItem {
  final String id;
  final String userId;
  final int amount;
  final String status;
  final String note;
  final DateTime? requestedAt;

  const AdminWithdrawalItem({
    required this.id,
    required this.userId,
    required this.amount,
    required this.status,
    required this.note,
    required this.requestedAt,
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