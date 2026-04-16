class ReportModel {
  final String id;
  final String reporterId;
  final String reportedUserId;
  final String callId;
  final String reason;
  final DateTime? createdAt;

  const ReportModel({
    required this.id,
    required this.reporterId,
    required this.reportedUserId,
    required this.callId,
    required this.reason,
    required this.createdAt,
  });

  factory ReportModel.fromMap(String id, Map<String, dynamic> data) {
    return ReportModel(
      id: id,
      reporterId: (data['reporterId'] ?? '').toString(),
      reportedUserId: (data['reportedUserId'] ?? '').toString(),
      callId: (data['callId'] ?? '').toString(),
      reason: (data['reason'] ?? '').toString(),
      createdAt: _timestampToDate(data['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'reporterId': reporterId,
      'reportedUserId': reportedUserId,
      'callId': callId,
      'reason': reason,
      'createdAt': createdAt,
    };
  }

  static DateTime? _timestampToDate(dynamic ts) {
    if (ts == null) return null;

    if (ts is DateTime) return ts;

    if (ts.runtimeType.toString() == 'Timestamp') {
      return ts.toDate();
    }

    return null;
  }

  bool get hasReason => reason.trim().isNotEmpty;

  bool get isValid =>
      reporterId.trim().isNotEmpty &&
      reportedUserId.trim().isNotEmpty &&
      callId.trim().isNotEmpty &&
      reason.trim().isNotEmpty;
}