import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/constants/firestore_paths.dart';
import '../services/call_session_manager.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/call_model.dart';

class WalletRepository {
  WalletRepository._();

  static final WalletRepository instance = WalletRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final CallSessionManager _callSession = CallSessionManager.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection(FirestorePaths.users);

  CollectionReference<Map<String, dynamic>> get _calls =>
      _db.collection(FirestorePaths.calls);

  CollectionReference<Map<String, dynamic>> get _walletTransactions =>
      _db.collection(FirestorePaths.walletTransactions);

  CollectionReference<Map<String, dynamic>> get _withdrawalRequests =>
      _db.collection(FirestorePaths.withdrawalRequests);

  CollectionReference<Map<String, dynamic>> get _paymentOrders =>
      _db.collection(FirestorePaths.paymentOrders);

  String? get myUidOrNull {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid.trim();
    if (uid == null || uid.isEmpty) return null;
    return uid;
  }

  String get myUid {
    final uid = myUidOrNull;
    if (uid == null) {
      throw StateError('User not logged in');
    }
    return uid;
  }

  bool get hasBlockingCallState {
    return _callSession.active ||
        _callSession.state == CallState.preparing ||
        _callSession.state == CallState.joining ||
        _callSession.state == CallState.reconnecting ||
        _callSession.state == CallState.ending;
  }

  int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;

    try {
      final converted = value.toDate();
      if (converted is DateTime) return converted;
    } catch (_) {
      // ignore malformed timestamp-like values
    }

    return null;
  }

  int _createdAtMsFromMap(Map<String, dynamic> data) {
    final createdAt = _asDateTime(
      data[FirestorePaths.fieldTransactionCreatedAt] ??
          data[FirestorePaths.fieldWithdrawalRequestedAt] ??
          data[FirestorePaths.fieldPaymentOrderCreatedAt] ??
          data[FirestorePaths.fieldCreatedAt],
    );
    if (createdAt != null) {
      return createdAt.millisecondsSinceEpoch;
    }

    final createdAtMs = _asInt(
      data[FirestorePaths.fieldCreatedAtMs],
      fallback: _asInt(
        data[FirestorePaths.fieldWithdrawalRequestedAtMs],
      ),
    );

    return createdAtMs;
  }

  int _callSortKey(CallModel call) {
    if (call.createdAtMs > 0) return call.createdAtMs;
    if (call.createdAt != null) return call.createdAt!.millisecondsSinceEpoch;
    return 0;
  }

  List<CallModel> _safeSortedCalls(
    QuerySnapshot<Map<String, dynamic>> query,
  ) {
    final out = <CallModel>[];

    for (final doc in query.docs) {
      try {
        out.add(CallModel.fromMap(doc.id, doc.data()));
      } catch (_) {
        // ignore malformed call documents
      }
    }

    out.sort((a, b) => _callSortKey(b).compareTo(_callSortKey(a)));
    return out;
  }

  List<Map<String, dynamic>> _safeDocMaps(
    QuerySnapshot<Map<String, dynamic>> query,
  ) {
    final out = <Map<String, dynamic>>[];

    for (final doc in query.docs) {
      try {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        out.add(data);
      } catch (_) {
        // ignore malformed docs
      }
    }

    out.sort((a, b) => _createdAtMsFromMap(b).compareTo(_createdAtMsFromMap(a)));
    return out;
  }

  String _withdrawalStatusValue(Map<String, dynamic> doc) {
    return _asString(
      doc[FirestorePaths.fieldTransactionStatus] ?? doc['status'],
      fallback: FirestorePaths.withdrawalStatusPending,
    ).toLowerCase();
  }

  Stream<AppUserModel?> watchMyWallet() {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<AppUserModel?>.value(null);
    }

    return _users.doc(uid).snapshots().map((snap) {
      if (!snap.exists) return null;

      final data = snap.data();
      if (data == null) return null;

      try {
        return AppUserModel.fromMap(data);
      } catch (_) {
        return null;
      }
    });
  }

  Future<AppUserModel?> getMyWallet() async {
    final uid = myUidOrNull;
    if (uid == null) return null;

    final snap = await _users.doc(uid).get();
    if (!snap.exists) return null;

    final data = snap.data();
    if (data == null) return null;

    try {
      return AppUserModel.fromMap(data);
    } catch (_) {
      return null;
    }
  }

  int totalCredits(AppUserModel user) => user.credits;

  int reservedCredits(AppUserModel user) => user.reservedCredits;

  int earningsCredits(AppUserModel user) => user.earningsCredits;

  int usableCredits(AppUserModel user) => user.usableCredits;

  Stream<List<CallModel>> watchMyListenerCalls({int limit = 200}) {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<List<CallModel>>.value(const <CallModel>[]);
    }

    return _calls
        .where(FirestorePaths.fieldCalleeId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(limit)
        .snapshots()
        .map(_safeSortedCalls);
  }

  Stream<List<CallModel>> watchMyCallerCalls({int limit = 200}) {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<List<CallModel>>.value(const <CallModel>[]);
    }

    return _calls
        .where(FirestorePaths.fieldCallerId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(limit)
        .snapshots()
        .map(_safeSortedCalls);
  }

  List<CallModel> endedCalls(List<CallModel> calls) {
    return calls.where((call) => call.isEnded).toList();
  }

  List<CallModel> settledCalls(List<CallModel> calls) {
    return calls.where((call) => call.settled).toList();
  }

  List<CallModel> freeCalls(List<CallModel> calls) {
    return calls.where((call) => call.listenerPayout <= 0).toList();
  }

  List<CallModel> paidCalls(List<CallModel> calls) {
    return calls.where((call) => call.listenerPayout > 0).toList();
  }

  int totalListenerCredited(List<CallModel> calls) {
    int total = 0;

    for (final call in calls) {
      if (!isListenerCredited(call)) continue;
      if (call.listenerPayout <= 0) continue;
      total += call.listenerPayout;
    }

    return total;
  }

  int totalListenerPending(List<CallModel> calls) {
    int total = 0;

    for (final call in calls) {
      if (call.listenerPayout <= 0) continue;
      if (!call.isEnded) continue;
      if (isListenerCredited(call)) continue;
      total += call.listenerPayout;
    }

    return total;
  }

  Map<String, int> creditedByCaller(List<CallModel> calls) {
    final result = <String, int>{};

    for (final call in calls) {
      if (!isListenerCredited(call)) continue;
      if (call.listenerPayout <= 0) continue;

      final callerName = safeDisplayName(call.callerName);

      result.update(
        callerName,
        (value) => value + call.listenerPayout,
        ifAbsent: () => call.listenerPayout,
      );
    }

    return result;
  }

  Map<String, int> pendingByCaller(List<CallModel> calls) {
    final result = <String, int>{};

    for (final call in calls) {
      if (call.listenerPayout <= 0) continue;
      if (!call.isEnded) continue;
      if (isListenerCredited(call)) continue;

      final callerName = safeDisplayName(call.callerName);

      result.update(
        callerName,
        (value) => value + call.listenerPayout,
        ifAbsent: () => call.listenerPayout,
      );
    }

    return result;
  }

  bool isListenerCredited(CallModel call) {
    if (call.listenerPayout <= 0) return true;
    if (call.settled) return true;
    return call.listenerCredited;
  }

  String safeDisplayName(String value, {String fallback = 'Unknown'}) {
    final safe = value.trim();
    return safe.isEmpty ? fallback : safe;
  }

  Stream<List<Map<String, dynamic>>> watchMyTransactions({int limit = 100}) {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return _walletTransactions
        .where(FirestorePaths.fieldTransactionUserId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldTransactionCreatedAt, descending: true)
        .limit(limit)
        .snapshots()
        .map(_safeDocMaps);
  }

  Stream<List<Map<String, dynamic>>> watchMyWithdrawals({int limit = 50}) {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return _withdrawalRequests
        .where(FirestorePaths.fieldWithdrawalUserId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldWithdrawalRequestedAt, descending: true)
        .limit(limit)
        .snapshots()
        .map(_safeDocMaps);
  }

  Stream<List<Map<String, dynamic>>> watchMyPaymentOrders({int limit = 50}) {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return _paymentOrders
        .where(FirestorePaths.fieldPaymentOrderUserId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldPaymentOrderCreatedAt, descending: true)
        .limit(limit)
        .snapshots()
        .map(_safeDocMaps);
  }

  List<Map<String, dynamic>> topupTransactions(
    List<Map<String, dynamic>> ledgerDocs,
  ) {
    return ledgerDocs.where((doc) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      return type == FirestorePaths.txTypeTopup;
    }).toList();
  }

  List<Map<String, dynamic>> earningTransactions(
    List<Map<String, dynamic>> ledgerDocs,
  ) {
    return ledgerDocs.where((doc) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      return type == FirestorePaths.txTypeCallEarning;
    }).toList();
  }

  List<Map<String, dynamic>> chargeTransactions(
    List<Map<String, dynamic>> ledgerDocs,
  ) {
    return ledgerDocs.where((doc) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      return type == FirestorePaths.txTypeCallCharge;
    }).toList();
  }

  List<Map<String, dynamic>> refundTransactions(
    List<Map<String, dynamic>> ledgerDocs,
  ) {
    return ledgerDocs.where((doc) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      return type == FirestorePaths.txTypeRefund;
    }).toList();
  }

  int totalTopupAmount(List<Map<String, dynamic>> ledgerDocs) {
    int total = 0;

    for (final doc in ledgerDocs) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      if (type != FirestorePaths.txTypeTopup) continue;
      total += _asInt(doc[FirestorePaths.fieldTransactionAmount]);
    }

    return total;
  }

  int totalChargedAmount(List<Map<String, dynamic>> ledgerDocs) {
    int total = 0;

    for (final doc in ledgerDocs) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      if (type != FirestorePaths.txTypeCallCharge) continue;
      total += _asInt(doc[FirestorePaths.fieldTransactionAmount]);
    }

    return total;
  }

  int totalRefundAmount(List<Map<String, dynamic>> ledgerDocs) {
    int total = 0;

    for (final doc in ledgerDocs) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      if (type != FirestorePaths.txTypeRefund) continue;
      total += _asInt(doc[FirestorePaths.fieldTransactionAmount]);
    }

    return total;
  }

  bool isWithdrawalPending(Map<String, dynamic> doc) {
    final status = _withdrawalStatusValue(doc);
    return status == FirestorePaths.withdrawalStatusPending;
  }

  bool isWithdrawalPaid(Map<String, dynamic> doc) {
    final status = _withdrawalStatusValue(doc);
    return status == FirestorePaths.withdrawalStatusPaid ||
        status == 'completed';
  }

  bool isPaymentOrderVerified(Map<String, dynamic> doc) {
    final status = _asString(
      doc[FirestorePaths.fieldPaymentOrderStatus],
    ).toLowerCase();
    return status == FirestorePaths.paymentOrderStatusVerified;
  }

  bool isPaymentOrderPending(Map<String, dynamic> doc) {
    final status = _asString(
      doc[FirestorePaths.fieldPaymentOrderStatus],
    ).toLowerCase();
    return status == FirestorePaths.paymentOrderStatusCreated ||
        status == FirestorePaths.paymentOrderStatusPending;
  }

  String transactionDirection(Map<String, dynamic> doc) {
    final direction = _asString(
      doc[FirestorePaths.fieldTransactionDirection],
    ).toLowerCase();

    if (direction == FirestorePaths.txDirectionCredit ||
        direction == FirestorePaths.txDirectionDebit) {
      return direction;
    }

    final amount = _asInt(doc[FirestorePaths.fieldTransactionAmount]);
    return amount >= 0
        ? FirestorePaths.txDirectionCredit
        : FirestorePaths.txDirectionDebit;
  }

  String transactionCurrency(Map<String, dynamic> doc) {
    final currency = _asString(
      doc[FirestorePaths.fieldTransactionCurrency],
      fallback: 'INR',
    );
    return currency.isEmpty ? 'INR' : currency;
  }

  String transactionSource(Map<String, dynamic> doc) {
    final source = _asString(
      doc[FirestorePaths.fieldTransactionSource],
      fallback: FirestorePaths.txSourceSystem,
    );
    return source.isEmpty ? FirestorePaths.txSourceSystem : source;
  }

  String transactionGateway(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldTransactionGateway]);
  }

  String transactionCallId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldTransactionCallId]);
  }

  String transactionPaymentId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldTransactionPaymentId]);
  }

  String transactionPaymentOrderId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldTransactionPaymentOrderId]);
  }

  String transactionWithdrawalRequestId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldTransactionWithdrawalRequestId]);
  }

  String transactionIdempotencyKey(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldTransactionIdempotencyKey]);
  }

  Map<String, dynamic> transactionMetadata(Map<String, dynamic> doc) {
    final value = doc[FirestorePaths.fieldTransactionMetadata];
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return value.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return <String, dynamic>{};
  }

  String withdrawalCurrency(Map<String, dynamic> doc) {
    final currency = _asString(
      doc[FirestorePaths.fieldWithdrawalCurrency],
      fallback: 'INR',
    );
    return currency.isEmpty ? 'INR' : currency;
  }

  String withdrawalStatusReason(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldWithdrawalStatusReason]);
  }

  String withdrawalAdminNote(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldWithdrawalAdminNote]);
  }

  String withdrawalPaymentReference(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldWithdrawalPaymentReference]);
  }

  String withdrawalLedgerTransactionId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldWithdrawalLedgerTransactionId]);
  }

  String withdrawalIdempotencyKey(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldWithdrawalIdempotencyKey]);
  }

  DateTime? withdrawalApprovedAt(Map<String, dynamic> doc) {
    return _asDateTime(doc[FirestorePaths.fieldWithdrawalApprovedAt]);
  }

  DateTime? withdrawalRejectedAt(Map<String, dynamic> doc) {
    return _asDateTime(doc[FirestorePaths.fieldWithdrawalRejectedAt]);
  }

  DateTime? withdrawalPaidAt(Map<String, dynamic> doc) {
    return _asDateTime(doc[FirestorePaths.fieldWithdrawalPaidAt]);
  }

  String paymentOrderGateway(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldPaymentOrderGateway]);
  }

  String paymentOrderStatus(Map<String, dynamic> doc) {
    return _asString(
      doc[FirestorePaths.fieldPaymentOrderStatus],
      fallback: FirestorePaths.paymentOrderStatusCreated,
    );
  }

  String paymentOrderId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldPaymentOrderOrderId]);
  }

  String paymentId(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldPaymentOrderPaymentId]);
  }

  int paymentOrderAmount(Map<String, dynamic> doc) {
    return _asInt(doc[FirestorePaths.fieldPaymentOrderAmount]);
  }

  String paymentOrderCurrency(Map<String, dynamic> doc) {
    final currency = _asString(
      doc[FirestorePaths.fieldPaymentOrderCurrency],
      fallback: 'INR',
    );
    return currency.isEmpty ? 'INR' : currency;
  }

  String paymentOrderIdempotencyKey(Map<String, dynamic> doc) {
    return _asString(doc[FirestorePaths.fieldPaymentOrderIdempotencyKey]);
  }

  Map<String, dynamic> paymentOrderMetadata(Map<String, dynamic> doc) {
    final value = doc[FirestorePaths.fieldPaymentOrderMetadata];
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return value.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return <String, dynamic>{};
  }

  bool isCommercialWalletReadyFromLedger(List<Map<String, dynamic>> ledgerDocs) {
    for (final doc in ledgerDocs) {
      final type = _asString(doc[FirestorePaths.fieldTransactionType]);
      if (type == FirestorePaths.txTypeTopup) {
        return true;
      }
    }
    return false;
  }
}