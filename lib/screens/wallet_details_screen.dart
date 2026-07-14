import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../core/constants/firestore_paths.dart';
import '../core/theme/app_palette.dart';
import '../repositories/wallet_repository.dart';
import '../services/app_log.dart';
import '../shared/models/app_user_model.dart';
import '../shared/wallet_amount_formatter.dart';

const bool _razorpayTopupEnabled =
    bool.fromEnvironment('FRIENDIFY_RAZORPAY_TOPUP');

String walletStatusLabel(String status) {
  final safe = status.trim().toLowerCase();
  switch (safe) {
    case 'approved':
    case 'paid':
    case 'completed':
    case 'verified':
      return 'Completed';
    case 'rejected':
    case 'cancelled':
    case 'failed':
      return 'Failed';
    case 'pending':
    case 'created':
    default:
      return 'Pending';
  }
}

String walletTransactionTitle(String type) {
  switch (type.trim()) {
    case 'call_earning':
      return 'Earnings credit';
    case 'call_charge':
      return 'Call charge';
    case 'withdraw_request':
    case 'withdrawal_request':
    case 'withdraw_complete':
    case 'withdrawal_paid':
    case 'withdrawal_debit':
    case 'withdrawal_rejected':
    case 'withdrawal_cancelled':
      return 'Withdrawal request';
    case 'refund':
      return 'Refund';
    case 'topup':
      return 'Top-up';
    case 'call_reserve_hold':
      return 'Pending';
    case 'call_reserve_release':
      return 'Refund';
    case 'admin_adjustment_credit':
      return 'Earnings credit';
    case 'admin_adjustment_debit':
      return 'Call charge';
    default:
      return type.trim().isEmpty ? 'Transaction' : type.trim();
  }
}

enum _WalletStatementFilter {
  all,
  earnings,
  spent,
}

class WalletDetailsScreen extends StatefulWidget {
  const WalletDetailsScreen({super.key});

  @override
  State<WalletDetailsScreen> createState() => _WalletDetailsScreenState();
}

class _WalletDetailsScreenState extends State<WalletDetailsScreen> {
  late final Razorpay _razorpay;

  String? _currentOrderId;
  String? _currentGatewayOrderId;
  bool _topupBusy = false;
  bool _withdrawSheetOpen = false;
  int _walletRetryToken = 0;
  int _ledgerRetryToken = 0;
  _WalletStatementFilter _statementFilter = _WalletStatementFilter.all;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handleRazorpaySuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handleRazorpayError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleRazorpayExternalWallet);
  }

  @override
  void dispose() {
    _razorpay.clear();
    super.dispose();
  }

  void _retryWalletLoad() {
    setState(() {
      _walletRetryToken++;
      _ledgerRetryToken++;
    });
  }

  void _retryLedgerLoad() {
    setState(() => _ledgerRetryToken++);
  }

  String _safeString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  int _safeInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  DateTime? _safeDateTime(dynamic value) {
    if (value == null) {
      return null;
    }

    try {
      if (value is DateTime) return value;
      final converted = value.toDate();
      if (converted is DateTime) return converted;
    } catch (_) {
      // ignore malformed timestamp-like values
    }

    return null;
  }

  String _dateTimeLabel(DateTime? dt) {
    if (dt == null) return 'Unknown';

    final hour24 = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;

    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    final month = months[dt.month - 1];
    return '${dt.day} $month ${dt.year}, $hour12:$minute $amPm';
  }

  void _showInfoSheet({
    required String title,
    required String body,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Theme(
          data: AppPalette.lightSheetTheme(sheetContext),
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(sheetContext).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      body,
                      style: const TextStyle(
                        color: Color(0xFF374151),
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('Close'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _startTopup({
    required int amount,
    required AppUserModel me,
  }) async {
    if (_razorpayTopupEnabled) {
      await _startRazorpayTopup(amount: amount, me: me);
      return;
    }

    if (_topupBusy) return;

    setState(() {
      _topupBusy = true;
    });

    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('createTopupOrder_v1')
          .call({
        'amount': amount,
        'currency': 'INR',
        'gateway': 'sandbox',
        'metadata': {
          'screen': 'wallet_details',
          'userEmail': me.email,
          'userName': me.displayName,
          'mode': 'sandbox',
        },
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      _currentOrderId = _safeString(data['orderId']);

      if (_currentOrderId == null || _currentOrderId!.isEmpty) {
        throw Exception('Invalid sandbox payment order response.');
      }

      debugPrint(
        'wallet.topup.order.created gateway=sandbox '
        'orderId=${AppLog.safeId(_currentOrderId!)} amount=$amount',
      );

      await _verifySandboxPayment();
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'wallet.topup.order.error code=${e.code}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not create top-up order. Please try again.'),
        ),
      );
      setState(() {
        _topupBusy = false;
      });
    } catch (e) {
      debugPrint('wallet.topup.order.error unexpected=${e.runtimeType}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start top-up. Please try again.'),
        ),
      );
      setState(() {
        _topupBusy = false;
      });
    }
  }

  Future<void> _startRazorpayTopup({
    required int amount,
    required AppUserModel me,
  }) async {
    if (_topupBusy) return;

    setState(() {
      _topupBusy = true;
    });

    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('createRazorpayOrder_v1')
          .call({
        'amount': amount,
        'currency': 'INR',
        'metadata': {
          'screen': 'wallet_details',
          'userEmail': me.email,
          'userName': me.displayName,
          'mode': 'razorpay',
        },
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final keyId = _safeString(data['keyId']);
      final orderId = _safeString(data['orderId']);
      final razorpayOrderId = _safeString(
        data['razorpayOrderId'] ?? data['gatewayOrderId'],
      );

      if (keyId.isEmpty || orderId.isEmpty || razorpayOrderId.isEmpty) {
        throw Exception('Invalid Razorpay order response.');
      }

      _currentOrderId = orderId;
      _currentGatewayOrderId = razorpayOrderId;

      debugPrint(
        'wallet.topup.order.created gateway=razorpay '
        'orderId=${AppLog.safeId(orderId)} '
        'gatewayOrderId=${AppLog.safeId(razorpayOrderId)} amount=$amount',
      );

      _razorpay.open({
        'key': keyId,
        'amount': amount * 100,
        'currency': 'INR',
        'name': 'Friendify',
        'description': 'Wallet top-up',
        'order_id': razorpayOrderId,
        'prefill': {
          'email': me.email,
          'name': me.displayName,
        },
        'notes': {
          'friendifyOrderId': orderId,
          'source': 'wallet_details',
        },
      });
    } on FirebaseFunctionsException catch (e) {
      debugPrint('wallet.razorpay.order.error code=${e.code}');
      _resetTopupState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not create Razorpay order. Please try again.'),
        ),
      );
    } catch (e) {
      debugPrint('wallet.razorpay.order.error unexpected=${e.runtimeType}');
      await _markCurrentTopupFailed('checkout_open_failed');
      _resetTopupState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open Razorpay checkout. Please try again.'),
        ),
      );
    }
  }

  Future<void> _handleRazorpaySuccess(PaymentSuccessResponse response) async {
    final orderId = _currentOrderId;
    final razorpayOrderId =
        _safeString(response.orderId, fallback: _currentGatewayOrderId ?? '');
    final paymentId = _safeString(response.paymentId);
    final signature = _safeString(response.signature);

    if (orderId == null ||
        orderId.isEmpty ||
        razorpayOrderId.isEmpty ||
        paymentId.isEmpty ||
        signature.isEmpty) {
      debugPrint('wallet.razorpay.verify.skipped missing_response_fields');
      await _markCurrentTopupFailed('missing_success_fields');
      _resetTopupState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Payment response was incomplete. Please contact support.'),
        ),
      );
      return;
    }

    try {
      await FirebaseFunctions.instance
          .httpsCallable('verifyRazorpayPayment_v1')
          .call({
        'orderId': orderId,
        'razorpayOrderId': razorpayOrderId,
        'paymentId': paymentId,
        'signature': signature,
      });

      debugPrint(
        'wallet.razorpay.verify.success '
        'orderId=${AppLog.safeId(orderId)} '
        'paymentId=${AppLog.safeId(paymentId)}',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Top-up completed and wallet updated.'),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'wallet.razorpay.verify.error '
        'orderId=${AppLog.safeId(orderId)} code=${e.code}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment verification failed. Please contact support.'),
        ),
      );
    } catch (e) {
      debugPrint(
        'wallet.razorpay.verify.error '
        'orderId=${AppLog.safeId(orderId)} unexpected=${e.runtimeType}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment verification failed. Please contact support.'),
        ),
      );
    } finally {
      _resetTopupState();
    }
  }

  Future<void> _handleRazorpayError(PaymentFailureResponse response) async {
    debugPrint(
      'wallet.razorpay.payment.error code=${response.code} '
      'message=${response.message ?? ''}',
    );
    await _markCurrentTopupFailed('razorpay_error_${response.code}');
    _resetTopupState();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Payment was not completed. No wallet credit was added.'),
      ),
    );
  }

  Future<void> _handleRazorpayExternalWallet(
    ExternalWalletResponse response,
  ) async {
    debugPrint(
      'wallet.razorpay.external_wallet ${response.walletName ?? ''}',
    );
  }

  Future<void> _markCurrentTopupFailed(String reason) async {
    final orderId = _currentOrderId;
    if (orderId == null || orderId.isEmpty) return;

    try {
      await FirebaseFunctions.instance.httpsCallable('failTopupOrder_v1').call({
        'orderId': orderId,
        'failureReason': reason,
      });
    } catch (e) {
      debugPrint(
        'wallet.topup.fail_mark.error '
        'orderId=${AppLog.safeId(orderId)} unexpected=${e.runtimeType}',
      );
    }
  }

  void _resetTopupState() {
    if (mounted) {
      setState(() {
        _topupBusy = false;
        _currentOrderId = null;
        _currentGatewayOrderId = null;
      });
      return;
    }

    _topupBusy = false;
    _currentOrderId = null;
    _currentGatewayOrderId = null;
  }

  Future<void> _verifySandboxPayment() async {
    final orderId = _currentOrderId;
    if (orderId == null || orderId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment order is missing.'),
          ),
        );
        setState(() {
          _topupBusy = false;
        });
      } else {
        _topupBusy = false;
      }
      return;
    }

    try {
      await FirebaseFunctions.instance
          .httpsCallable('verifyTopupSandbox_v1')
          .call({
        'orderId': orderId,
        'approve': true,
      });

      debugPrint(
        'wallet.topup.verify.success orderId=${AppLog.safeId(orderId)}',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Top-up completed and wallet updated.'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'wallet.topup.verify.error '
        'orderId=${AppLog.safeId(orderId)} code=${e.code}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment verification failed. Please try again.'),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'wallet.topup.verify.error '
        'orderId=${AppLog.safeId(orderId)} unexpected=${e.runtimeType}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment verification failed. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _topupBusy = false;
          _currentOrderId = null;
        });
      } else {
        _topupBusy = false;
        _currentOrderId = null;
      }
    }
  }

  Future<void> _requestWithdrawalSheet(
    BuildContext context,
    AppUserModel me,
  ) async {
    if (_withdrawSheetOpen) return;

    _withdrawSheetOpen = true;

    try {
      final bool? result = await showModalBottomSheet<bool>(
        context: context,
        useRootNavigator: false,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          return Theme(
            data: AppPalette.lightSheetTheme(sheetContext),
            child: _WithdrawalRequestSheet(
              me: me,
            ),
          );
        },
      );

      if (result == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Withdrawal request submitted.'),
          ),
        );
      }
    } finally {
      _withdrawSheetOpen = false;
    }
  }

  bool _isEarningStatementType(String type) {
    final safe = type.trim();
    return safe == FirestorePaths.txTypeCallEarning ||
        safe == FirestorePaths.txTypeAdminAdjustmentCredit ||
        safe.contains('earning');
  }

  List<Map<String, dynamic>> _statementDocsForFilter(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> ledgerDocs,
    _WalletStatementFilter filter,
  ) {
    switch (filter) {
      case _WalletStatementFilter.all:
        return ledgerDocs;
      case _WalletStatementFilter.earnings:
        return ledgerDocs.where((doc) {
          final type = _safeString(doc[FirestorePaths.fieldTransactionType]);
          return walletRepository.transactionDirection(doc) ==
                  FirestorePaths.txDirectionCredit &&
              _isEarningStatementType(type);
        }).toList(growable: false);
      case _WalletStatementFilter.spent:
        return ledgerDocs.where((doc) {
          return walletRepository.transactionDirection(doc) ==
              FirestorePaths.txDirectionDebit;
        }).toList(growable: false);
    }
  }

  String _statementTitleForFilter(_WalletStatementFilter filter) {
    switch (filter) {
      case _WalletStatementFilter.all:
        return 'Recent Transactions';
      case _WalletStatementFilter.earnings:
        return 'Earning Statement';
      case _WalletStatementFilter.spent:
        return 'Spent Statement';
    }
  }

  String _statementEmptyTextForFilter(_WalletStatementFilter filter) {
    switch (filter) {
      case _WalletStatementFilter.all:
        return 'No recent transactions yet.';
      case _WalletStatementFilter.earnings:
        return 'No earning history yet.';
      case _WalletStatementFilter.spent:
        return 'No spent history yet.';
    }
  }

  String _walletDisplayAmount(int amount, {bool decimals = false}) {
    final raw = amount.abs().toString();
    final grouped = raw.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final prefix = amount < 0 ? '-' : '';
    final suffix = decimals ? '.00' : '';
    return '$prefix\u20B9 $grouped$suffix';
  }

  Widget _walletBalanceCard({
    required int totalCredits,
    required AppUserModel me,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF243BFF),
            Color(0xFF2333C9),
            Color(0xFF132066),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF243BFF).withValues(alpha: 0.32),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Balance',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _walletDisplayAmount(totalCredits, decimals: true),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 31,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                foregroundColor: AppPalette.blue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed:
                  _topupBusy ? null : () => _startTopup(amount: 500, me: me),
              child: _topupBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded, size: 29),
            ),
          ),
        ],
      ),
    );
  }

  Widget _walletActionButton({
    required String label,
    required VoidCallback? onPressed,
    required List<Color> colors,
  }) {
    return Expanded(
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: colors.first.withValues(alpha: 0.34),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          onPressed: onPressed,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _walletStatementTabsLocal({
    required _WalletStatementFilter selectedFilter,
    required ValueChanged<_WalletStatementFilter> onChanged,
  }) {
    return Row(
      children: [
        _walletStatementTabLocal(
          'All',
          _WalletStatementFilter.all,
          selectedFilter: selectedFilter,
          onChanged: onChanged,
        ),
        const SizedBox(width: 8),
        _walletStatementTabLocal(
          'Earnings',
          _WalletStatementFilter.earnings,
          selectedFilter: selectedFilter,
          onChanged: onChanged,
        ),
        const SizedBox(width: 8),
        _walletStatementTabLocal(
          'Spent',
          _WalletStatementFilter.spent,
          selectedFilter: selectedFilter,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _walletStatementTabLocal(
    String label,
    _WalletStatementFilter filter, {
    required _WalletStatementFilter selectedFilter,
    required ValueChanged<_WalletStatementFilter> onChanged,
  }) {
    final selected = selectedFilter == filter;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          if (selected) return;
          onChanged(filter);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppPalette.blue : AppPalette.feedBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppPalette.blue : AppPalette.border,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? Colors.white : AppPalette.textSecondary,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactTransactionList(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> ledgerDocs, {
    required String emptyText,
    int limit = 12,
  }) {
    final shown = ledgerDocs.take(limit).toList(growable: false);
    if (shown.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppPalette.feedBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          emptyText,
          style: const TextStyle(
            color: AppPalette.textSecondary,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return Column(
      children: shown.map((data) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: _compactTransactionTile(walletRepository, data),
        );
      }).toList(growable: false),
    );
  }

  Widget _compactTransactionTile(
    WalletRepository walletRepository,
    Map<String, dynamic> data,
  ) {
    final type = _safeString(data[FirestorePaths.fieldTransactionType]);
    final direction = walletRepository.transactionDirection(data);
    final positive = direction == FirestorePaths.txDirectionCredit;
    final amount = _safeInt(data[FirestorePaths.fieldTransactionAmount]);
    final createdAt = _safeDateTime(
      data[FirestorePaths.fieldTransactionCreatedAt] ??
          data[FirestorePaths.fieldCreatedAt],
    );
    final title = walletTransactionTitle(type);
    final signed = formatSignedWalletCurrencyAmount(
      positive ? amount : -amount.abs(),
      currency: walletRepository.transactionCurrency(data),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Row(
        children: [
          _compactTransactionIcon(type, positive),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _dateTimeLabel(createdAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppPalette.textMuted,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            signed,
            style: TextStyle(
              color: positive ? AppPalette.online : const Color(0xFFDC2626),
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactTransactionIcon(String type, bool positive) {
    final icon = switch (type.trim()) {
      'topup' => Icons.add_rounded,
      'withdraw_request' ||
      'withdrawal_request' ||
      'withdraw_complete' ||
      'withdrawal_paid' ||
      'withdrawal_debit' =>
        Icons.account_balance_wallet_rounded,
      'call_earning' => Icons.call_received_rounded,
      'call_charge' => Icons.call_made_rounded,
      _ => positive ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
    };

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: positive
            ? AppPalette.online.withValues(alpha: 0.15)
            : const Color(0xFFDC2626).withValues(alpha: 0.12),
      ),
      child: Icon(
        icon,
        color: positive ? AppPalette.online : const Color(0xFFDC2626),
        size: 21,
      ),
    );
  }

  Widget _walletWarningCard({
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.sync_problem_rounded,
            color: Color(0xFFD97706),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onAction,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(actionLabel),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final walletRepository = WalletRepository.instance;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppPalette.pageBg,
        appBar: AppBar(
          backgroundColor: AppPalette.card,
          foregroundColor: AppPalette.textPrimary,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('Wallet'),
        ),
        body: StreamBuilder<AppUserModel?>(
          key: ValueKey('wallet_user_$_walletRetryToken'),
          stream: walletRepository.watchMyWallet(),
          builder: (_, userSnap) {
            if (userSnap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _walletWarningCard(
                    title: 'Wallet unavailable',
                    message:
                        'Your account and wallet state could not sync. Check your connection and try again.',
                    actionLabel: 'Retry',
                    onAction: _retryWalletLoad,
                  ),
                ),
              );
            }

            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final me = userSnap.data;
            if (me == null) {
              return const Center(
                child: Text(
                  'Unable to load your wallet right now.',
                  style: TextStyle(color: AppPalette.textPrimary),
                ),
              );
            }
            final totalCredits = walletRepository.totalCredits(me);

            return StreamBuilder<List<Map<String, dynamic>>>(
              key: ValueKey('wallet_ledger_$_ledgerRetryToken'),
              stream: walletRepository.watchMyTransactions(limit: 60),
              builder: (_, ledgerSnap) {
                final ledgerDocs =
                    ledgerSnap.data ?? const <Map<String, dynamic>>[];
                final statementDocs = _statementDocsForFilter(
                  walletRepository,
                  ledgerDocs,
                  _statementFilter,
                );

                return ListView(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 28),
                  children: [
                    _walletBalanceCard(totalCredits: totalCredits, me: me),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _walletActionButton(
                          label: 'Withdraw',
                          onPressed: !kDebugMode
                              ? () => _showInfoSheet(
                                    title: 'Withdrawal',
                                    body:
                                        'Withdrawals are available from the debug wallet tools during testing.',
                                  )
                              : () => _requestWithdrawalSheet(context, me),
                          colors: const [
                            Color(0xFF2F6FED),
                            Color(0xFF225CFF),
                          ],
                        ),
                        const SizedBox(width: 10),
                        _walletActionButton(
                          label: _topupBusy ? 'Processing...' : 'Add money',
                          onPressed: _topupBusy
                              ? null
                              : () => _startTopup(amount: 500, me: me),
                          colors: const [
                            Color(0xFF3D7BF0),
                            Color(0xFF6AA0F7),
                          ],
                        ),
                      ],
                    ),
                    if (ledgerSnap.hasError) ...[
                      const SizedBox(height: 12),
                      _walletWarningCard(
                        title: 'Wallet history sync issue',
                        message:
                            'Balance is shown from your account record, but recent transactions could not refresh.',
                        actionLabel: 'Retry history',
                        onAction: _retryLedgerLoad,
                      ),
                    ],
                    const SizedBox(height: 18),
                    _walletStatementTabsLocal(
                      selectedFilter: _statementFilter,
                      onChanged: (filter) =>
                          setState(() => _statementFilter = filter),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _statementTitleForFilter(_statementFilter),
                      style: const TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _compactTransactionList(
                      walletRepository,
                      statementDocs,
                      emptyText: _statementEmptyTextForFilter(_statementFilter),
                      limit: 30,
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _WithdrawalRequestSheet extends StatefulWidget {
  const _WithdrawalRequestSheet({
    required this.me,
  });

  final AppUserModel me;

  @override
  State<_WithdrawalRequestSheet> createState() =>
      _WithdrawalRequestSheetState();
}

class _WithdrawalRequestSheetState extends State<_WithdrawalRequestSheet> {
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  late final TextEditingController _upiController;
  late final TextEditingController _holderController;
  late final TextEditingController _accountController;
  late final TextEditingController _ifscController;
  late final TextEditingController _bankNameController;

  String _payoutMethod = 'upi'; // 'upi' | 'bank'
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController();
    _noteController = TextEditingController();
    _upiController = TextEditingController();
    _holderController = TextEditingController();
    _accountController = TextEditingController();
    _ifscController = TextEditingController();
    _bankNameController = TextEditingController();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _upiController.dispose();
    _holderController.dispose();
    _accountController.dispose();
    _ifscController.dispose();
    _bankNameController.dispose();
    super.dispose();
  }

  // Builds the payout snapshot the backend requires; returns null (and sets an
  // inline error) when the chosen method is incomplete/invalid.
  Map<String, dynamic>? _buildPayoutSnapshot() {
    if (_payoutMethod == 'upi') {
      final upi = _upiController.text.trim();
      if (!RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(upi)) {
        setState(() => _error = 'Enter a valid UPI ID (e.g. name@bank).');
        return null;
      }
      return {'payoutMethod': 'upi', 'upiId': upi};
    }

    final holder = _holderController.text.trim();
    final account = _accountController.text.trim();
    final ifsc = _ifscController.text.trim();
    final bankName = _bankNameController.text.trim();
    if (holder.isEmpty || account.isEmpty || ifsc.isEmpty) {
      setState(() =>
          _error = 'Enter account holder name, account number, and IFSC code.');
      return null;
    }
    return {
      'payoutMethod': 'bank',
      'accountHolderName': holder,
      'accountNumber': account,
      'ifsc': ifsc,
      if (bankName.isNotEmpty) 'bankName': bankName,
    };
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final amount = int.tryParse(_amountController.text.trim()) ?? 0;
    final note = _noteController.text.trim();

    if (amount <= 0) {
      setState(() => _error = 'Enter a valid amount.');
      return;
    }

    if (amount < 50) {
      setState(
          () => _error = 'Minimum withdrawal is ${formatWalletAmount(50)}.');
      return;
    }

    if (amount > widget.me.earningsCredits) {
      setState(
        () => _error =
            'You can request up to ${formatWalletAmount(widget.me.earningsCredits)}.',
      );
      return;
    }

    final payoutAccountSnapshot = _buildPayoutSnapshot();
    if (payoutAccountSnapshot == null) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await FirebaseFunctions.instance
          .httpsCallable('requestWithdrawal_v1')
          .call({
        'amount': amount,
        'note': note,
        'payoutMode': 'manual_test',
        'realMoneyEnabled': false,
        'payoutAccountSnapshot': payoutAccountSnapshot,
      });

      debugPrint('wallet.withdrawal.create.success');

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'wallet.withdrawal.create.error code=${e.code}',
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Withdrawal request failed. Please try again.';
      });
    } catch (e) {
      debugPrint(
        'wallet.withdrawal.create.error unexpected=${e.runtimeType}',
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Withdrawal request failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Request Withdrawal',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Available earnings: ${formatWalletAmount(widget.me.earningsCredits)}\n'
                  'Withdrawal options depend on the support path currently available for your account.',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _amountController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    hintText:
                        'Enter amount in ${formatWalletAmount(0).replaceAll('0', '')}',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Payout method',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('UPI'),
                      selected: _payoutMethod == 'upi',
                      onSelected: _submitting
                          ? null
                          : (_) => setState(() => _payoutMethod = 'upi'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Bank account'),
                      selected: _payoutMethod == 'bank',
                      onSelected: _submitting
                          ? null
                          : (_) => setState(() => _payoutMethod = 'bank'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_payoutMethod == 'upi')
                  TextField(
                    controller: _upiController,
                    decoration: const InputDecoration(
                      labelText: 'UPI ID',
                      hintText: 'name@bank',
                    ),
                  )
                else ...[
                  TextField(
                    controller: _holderController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Account holder name',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Account number',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ifscController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'IFSC code',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _bankNameController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Bank name (optional)',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  maxLength: 200,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Optional note',
                    hintText: 'Add any helpful detail for this request',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFDC2626),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: const Text('Close'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: Text(
                          _submitting ? 'Submitting...' : 'Request',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
