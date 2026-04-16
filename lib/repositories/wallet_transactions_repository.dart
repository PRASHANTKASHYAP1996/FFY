import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants/firestore_paths.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../shared/models/wallet_transaction_model.dart';

class WalletTransactionsRepository {
  WalletTransactionsRepository._();

  static final WalletTransactionsRepository instance =
      WalletTransactionsRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final CallSessionManager _callSession = CallSessionManager.instance;

  CollectionReference<Map<String, dynamic>> get _tx =>
      _db.collection(FirestorePaths.walletTransactions);

  String get myUid => FirestoreService.uid();

  bool get hasBlockingCallState {
    return _callSession.active ||
        _callSession.state == CallState.preparing ||
        _callSession.state == CallState.joining ||
        _callSession.state == CallState.reconnecting ||
        _callSession.state == CallState.ending;
  }

  Stream<List<WalletTransactionModel>> watchMyTransactions({
    int limit = 100,
  }) {
    return _tx
        .where(FirestorePaths.fieldTransactionUserId, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldTransactionCreatedAt, descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (query) => query.docs
              .map(
                (doc) => WalletTransactionModel.fromMap(doc.id, doc.data()),
              )
              .toList(),
        );
  }

  Future<List<WalletTransactionModel>> getMyTransactions({
    int limit = 100,
  }) async {
    final snap = await _tx
        .where(FirestorePaths.fieldTransactionUserId, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldTransactionCreatedAt, descending: true)
        .limit(limit)
        .get();

    return snap.docs
        .map((doc) => WalletTransactionModel.fromMap(doc.id, doc.data()))
        .toList();
  }

  String amountLabel(int amount) {
    if (amount == 0) return '₹0';
    if (amount > 0) return '+₹$amount';
    return '-₹${amount.abs()}';
  }

  String typeLabel(String type) {
    switch (type.trim()) {
      case FirestorePaths.txTypeTopup:
        return 'Top-up';
      case FirestorePaths.txTypeCallCharge:
        return 'Call charge';
      case FirestorePaths.txTypeCallEarning:
        return 'Call earning';
      case FirestorePaths.txTypeWithdrawal:
        return 'Withdrawal';
      case 'withdrawal_debit':
        return 'Withdrawal debit';
      case FirestorePaths.txTypeRefund:
        return 'Refund';
      case FirestorePaths.txTypeCallReserveHold:
        return 'Reserve hold';
      case FirestorePaths.txTypeCallReserveRelease:
        return 'Reserve release';
      case FirestorePaths.txTypeWithdrawalRequest:
        return 'Withdrawal request';
      case FirestorePaths.txTypeWithdrawalPaid:
        return 'Withdrawal paid';
      case FirestorePaths.txTypeWithdrawalRejected:
        return 'Withdrawal rejected';
      case FirestorePaths.txTypeWithdrawalCancelled:
        return 'Withdrawal cancelled';
      case FirestorePaths.txTypeAdminAdjustmentCredit:
        return 'Admin credit';
      case FirestorePaths.txTypeAdminAdjustmentDebit:
        return 'Admin debit';
      default:
        return type.trim().isEmpty ? 'Transaction' : type.replaceAll('_', ' ');
    }
  }

  String subtitleFor(WalletTransactionModel tx) {
    final notes = tx.notes.trim();
    final status = tx.status.trim();
    final callId = tx.callId.trim();
    final type = tx.type.trim();

    if (notes.isNotEmpty) return notes;
    if (callId.isNotEmpty) return 'Call: $callId';

    switch (type) {
      case FirestorePaths.txTypeTopup:
        return status.isNotEmpty ? 'Top-up $status' : 'Wallet top-up';
      case FirestorePaths.txTypeCallCharge:
        return status.isNotEmpty ? 'Call charge $status' : 'Charged for call';
      case FirestorePaths.txTypeCallEarning:
        return status.isNotEmpty ? 'Call earning $status' : 'Listener earning';
      case FirestorePaths.txTypeRefund:
        return status.isNotEmpty ? 'Refund $status' : 'Wallet refund';
      case FirestorePaths.txTypeWithdrawalRequest:
        return status.isNotEmpty
            ? 'Withdrawal request $status'
            : 'Withdrawal requested';
      case FirestorePaths.txTypeWithdrawalPaid:
      case 'withdrawal_debit':
        return status.isNotEmpty ? 'Withdrawal $status' : 'Withdrawal processed';
      case FirestorePaths.txTypeWithdrawalRejected:
        return status.isNotEmpty ? 'Withdrawal $status' : 'Withdrawal rejected';
      case FirestorePaths.txTypeWithdrawalCancelled:
        return status.isNotEmpty
            ? 'Withdrawal $status'
            : 'Withdrawal cancelled';
      default:
        if (status.isNotEmpty) return 'Status: $status';
        return 'Balance after: ₹${tx.balanceAfter}';
    }
  }

  bool isCredit(WalletTransactionModel tx) {
    return tx.amount >= 0;
  }

  bool isDebit(WalletTransactionModel tx) {
    return !isCredit(tx);
  }

  bool isTopup(WalletTransactionModel tx) {
    return tx.type.trim() == FirestorePaths.txTypeTopup;
  }

  bool isCallCharge(WalletTransactionModel tx) {
    return tx.type.trim() == FirestorePaths.txTypeCallCharge;
  }

  bool isCallEarning(WalletTransactionModel tx) {
    return tx.type.trim() == FirestorePaths.txTypeCallEarning;
  }

  bool isRefund(WalletTransactionModel tx) {
    return tx.type.trim() == FirestorePaths.txTypeRefund;
  }

  bool isWithdrawal(WalletTransactionModel tx) {
    final type = tx.type.trim();
    return type == FirestorePaths.txTypeWithdrawal ||
        type == 'withdrawal_debit' ||
        type == FirestorePaths.txTypeWithdrawalPaid ||
        type == FirestorePaths.txTypeWithdrawalRequest;
  }

  int totalCreditsFromTransactions(List<WalletTransactionModel> items) {
    int total = 0;
    for (final tx in items) {
      if (!isCredit(tx)) continue;
      total += tx.amount.abs();
    }
    return total;
  }

  int totalDebitsFromTransactions(List<WalletTransactionModel> items) {
    int total = 0;
    for (final tx in items) {
      if (!isDebit(tx)) continue;
      total += tx.amount.abs();
    }
    return total;
  }

  int totalTopups(List<WalletTransactionModel> items) {
    int total = 0;
    for (final tx in items) {
      if (!isTopup(tx)) continue;
      total += tx.amount.abs();
    }
    return total;
  }

  int totalCallCharges(List<WalletTransactionModel> items) {
    int total = 0;
    for (final tx in items) {
      if (!isCallCharge(tx)) continue;
      total += tx.amount.abs();
    }
    return total;
  }

  int totalCallEarnings(List<WalletTransactionModel> items) {
    int total = 0;
    for (final tx in items) {
      if (!isCallEarning(tx)) continue;
      total += tx.amount.abs();
    }
    return total;
  }

  int totalRefunds(List<WalletTransactionModel> items) {
    int total = 0;
    for (final tx in items) {
      if (!isRefund(tx)) continue;
      total += tx.amount.abs();
    }
    return total;
  }

  List<WalletTransactionModel> topupTransactions(
    List<WalletTransactionModel> items,
  ) {
    return items.where(isTopup).toList();
  }

  List<WalletTransactionModel> chargeTransactions(
    List<WalletTransactionModel> items,
  ) {
    return items.where(isCallCharge).toList();
  }

  List<WalletTransactionModel> earningTransactions(
    List<WalletTransactionModel> items,
  ) {
    return items.where(isCallEarning).toList();
  }

  List<WalletTransactionModel> refundTransactions(
    List<WalletTransactionModel> items,
  ) {
    return items.where(isRefund).toList();
  }
}