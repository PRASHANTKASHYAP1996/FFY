class WalletTransactionModel {
  final String id;
  final String userId;
  final String type;
  final int amount;
  final int balanceAfter;
  final String callId;
  final String status;
  final String method;
  final String notes;
  final DateTime? createdAt;

  const WalletTransactionModel({
    required this.id,
    required this.userId,
    required this.type,
    required this.amount,
    required this.balanceAfter,
    required this.callId,
    required this.status,
    required this.method,
    required this.notes,
    required this.createdAt,
  });

  static String _asString(dynamic value) {
    if (value is String) return value.trim();
    return '';
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return 0;
  }

  static DateTime? _timestampToDate(dynamic ts) {
    if (ts == null) return null;

    if (ts is DateTime) return ts;

    if (ts.runtimeType.toString() == 'Timestamp') {
      return ts.toDate();
    }

    return null;
  }

  factory WalletTransactionModel.fromMap(
    String id,
    Map<String, dynamic> data,
  ) {
    return WalletTransactionModel(
      id: id,
      userId: _asString(data['userId']),
      type: _asString(data['type']),
      amount: _asInt(data['amount']),
      balanceAfter: _asInt(data['balanceAfter']),
      callId: _asString(data['callId']),
      status: _asString(data['status']),
      method: _asString(data['method']),
      notes: _asString(data['notes']),
      createdAt: _timestampToDate(data['createdAt']),
    );
  }

  bool get isCredit => amount > 0;
  bool get isDebit => amount < 0;
}