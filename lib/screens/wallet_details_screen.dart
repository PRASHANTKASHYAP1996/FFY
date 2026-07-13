import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../core/constants/firestore_paths.dart';
import '../core/constants/legal_links.dart';
import '../core/theme/app_palette.dart';
import '../core/theme/friendify_brand.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../repositories/wallet_repository.dart';
import '../services/app_log.dart';
import '../services/call_session_manager.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/call_model.dart';
import '../shared/wallet_amount_formatter.dart';
import 'call_history_screen.dart';
import 'caller_waiting_screen.dart';
import 'listener_profile_screen.dart';
import 'voice_call_screen.dart';

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
  final UserRepository _userRepository = UserRepository.instance;
  final CallRepository _callRepository = CallRepository.instance;
  final TextEditingController _callsSearchController = TextEditingController();
  late final Razorpay _razorpay;

  String? _currentOrderId;
  String? _currentGatewayOrderId;
  bool _topupBusy = false;
  bool _withdrawSheetOpen = false;
  int _walletRetryToken = 0;
  int _ledgerRetryToken = 0;
  int _callReadyRetryToken = 0;
  String _callingFor = '';
  final _WalletStatementFilter _statementFilter = _WalletStatementFilter.all;

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
    _callsSearchController.dispose();
    super.dispose();
  }

  void _retryWalletLoad() {
    setState(() {
      _walletRetryToken++;
      _ledgerRetryToken++;
      _callReadyRetryToken++;
    });
  }

  void _retryLedgerLoad() {
    setState(() => _ledgerRetryToken++);
  }

  void _retryCallReadyLoad() {
    setState(() => _callReadyRetryToken++);
  }

  String _durationLabel(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;
    final fullMinutes = safeSeconds >= 60 ? (safeSeconds ~/ 60) : 0;
    if (fullMinutes == 0) return 'Under 60s (Free)';
    return '$fullMinutes min';
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

  String _withdrawalStatus(Map<String, dynamic> data) {
    return _safeString(
      data[FirestorePaths.fieldTransactionStatus] ?? data['status'],
      fallback: FirestorePaths.withdrawalStatusPending,
    );
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

  Color _withdrawStatusColor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'approved':
      case 'paid':
      case 'completed':
        return const Color(0xFF15803D);
      case 'rejected':
      case 'cancelled':
        return const Color(0xFFDC2626);
      case 'pending':
      default:
        return const Color(0xFFD97706);
    }
  }

  Widget _withdrawalStatusChip(String status) {
    final color = _withdrawStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        walletStatusLabel(status),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Color _callSettlementColor(CallModel call) {
    if (call.listenerPayout <= 0) return const Color(0xFF6B7280);
    if (call.settled || call.listenerCredited) {
      return const Color(0xFF15803D);
    }
    return const Color(0xFFD97706);
  }

  String _callSettlementLabel(CallModel call) {
    if (call.listenerPayout <= 0) return 'Free';
    if (call.settled || call.listenerCredited) return 'Credited';
    return 'Pending';
  }

  String _callSettlementSubtitle(CallModel call) {
    if (call.listenerPayout <= 0) {
      return 'No payout because the call stayed under 60 seconds.';
    }

    if (call.settled) {
      return 'Server settlement completed successfully.';
    }

    if (call.listenerCredited) {
      return 'Marked credited and awaiting final reconciliation view.';
    }

    return 'Call ended, but payout is still pending settlement.';
  }

  Color _callSettlementAmountColor(CallModel call) {
    if (call.listenerPayout <= 0) return const Color(0xFF6B7280);
    if (call.settled || call.listenerCredited) {
      return const Color(0xFF15803D);
    }
    return const Color(0xFFD97706);
  }

  Widget _statTile({
    required String label,
    required String value,
    String? subtitle,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: highlight ? FriendifyBrand.primaryGradient : null,
        color: highlight ? null : FriendifyBrand.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight
              ? FriendifyBrand.lavenderGlow.withValues(alpha: 0.45)
              : FriendifyBrand.darkStroke,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: highlight ? Colors.white70 : FriendifyBrand.softGrey,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: highlight ? 24 : 20,
              fontWeight: FontWeight.w900,
              color: FriendifyBrand.pureWhite,
            ),
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: highlight ? Colors.white70 : FriendifyBrand.softGrey,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: FriendifyBrand.softViolet.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.22),
        ),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: FriendifyBrand.lavenderGlow,
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppPalette.textPrimary,
              ),
            ),
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _rowLine({
    required String label,
    required String value,
    Color valueColor = AppPalette.textPrimary,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _launchLinkTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color iconColor = AppPalette.blue,
    Color iconBg = AppPalette.blueTint,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: iconBg,
        child: Icon(icon, color: iconColor),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: AppPalette.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Color(0xFF9CA3AF),
      ),
      onTap: onTap,
    );
  }

  Widget _walletShortcut({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: FriendifyBrand.darkSurfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: FriendifyBrand.darkStroke),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: FriendifyBrand.iconTileDecoration(),
                child: Icon(icon, color: FriendifyBrand.pureWhite, size: 18),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: FriendifyBrand.softGrey,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _walletPreviewHeader({
    required AppUserModel me,
    required int totalCredits,
    required int usableCredits,
    required int earningsCredits,
    required int reservedCredits,
    required bool withdrawalBlocked,
  }) {
    final minimumWithdrawalText = formatWalletAmount(50);

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF19124A),
            Color(0xFF0B0F2F),
            Color(0xFF2F176F),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.24),
        ),
        boxShadow: [
          BoxShadow(
            color: FriendifyBrand.softViolet.withValues(alpha: 0.22),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Wallet',
                    style: TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Wallet help',
                  onPressed: () => _showInfoSheet(
                    title: 'Wallet Help',
                    body:
                        'Your wallet tracks top-ups, paid call charges, listener earnings, refunds, and withdrawal requests. Backend settlement remains the source of truth.',
                  ),
                  icon: const Icon(Icons.help_outline_rounded),
                  color: FriendifyBrand.pureWhite,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: FriendifyBrand.deepIndigo.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.22),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Total Balance',
                    style: TextStyle(
                      color: FriendifyBrand.softGrey,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formatWalletAmount(totalCredits),
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _statTile(
                          label: 'Usable',
                          value: formatWalletAmount(usableCredits),
                          subtitle: 'Ready now',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _statTile(
                          label: 'Earned',
                          value: formatWalletAmount(earningsCredits),
                          subtitle: 'Listener credits',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (kDebugMode)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _topupBusy
                      ? null
                      : () => _startTopup(amount: 500, me: me),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(_topupBusy ? 'Processing...' : 'Add Money'),
                ),
              )
            else
              const Text(
                'Wallet access depends on the options currently available for your account.',
                style: TextStyle(
                  color: FriendifyBrand.softGrey,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                _walletShortcut(
                  icon: Icons.history_rounded,
                  label: 'History',
                  onTap: () => _showInfoSheet(
                    title: 'Wallet History',
                    body:
                        'Recent transactions, call earnings, refunds, and withdrawal requests are listed below.',
                  ),
                ),
                const SizedBox(width: 10),
                _walletShortcut(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'Withdraw',
                  onTap: withdrawalBlocked
                      ? () => _showInfoSheet(
                            title: 'Withdrawal',
                            body:
                                'Minimum withdrawal is $minimumWithdrawalText. Pending requests must finish before creating another request.',
                          )
                      : () => _requestWithdrawalSheet(context, me),
                ),
                const SizedBox(width: 10),
                _walletShortcut(
                  icon: Icons.support_agent_rounded,
                  label: 'Help',
                  onTap: () => _showInfoSheet(
                    title: 'Wallet Support',
                    body:
                        'For wallet issues, share your latest transaction or withdrawal request details with support. The app keeps the server ledger as the final record.',
                  ),
                ),
              ],
            ),
            if (reservedCredits > 0) ...[
              const SizedBox(height: 12),
              _summaryChip('Reserved', formatWalletAmount(reservedCredits)),
            ],
          ],
        ),
      ),
    );
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

  // ignore: unused_element
  Widget _activeCallBanner(BuildContext context) {
    final session = CallSessionManager.instance;

    return AnimatedBuilder(
      animation: session,
      builder: (_, __) {
        if (!session.active) {
          return const SizedBox.shrink();
        }

        final call = session.call;
        final otherName = session.iAmCaller
            ? (((call['calleeName'] ?? '') as Object)
                    .toString()
                    .trim()
                    .isNotEmpty
                ? (call['calleeName'] as String).trim()
                : 'Listener')
            : (((call['callerName'] ?? '') as Object)
                    .toString()
                    .trim()
                    .isNotEmpty
                ? (call['callerName'] as String).trim()
                : 'User');

        final mm = (session.seconds ~/ 60).toString().padLeft(2, '0');
        final ss = (session.seconds % 60).toString().padLeft(2, '0');

        return Card(
          color: const Color(0xFFECFDF3),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFD1FAE5),
                  child: Icon(Icons.call, color: Color(0xFF047857)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Call is active',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'With $otherName - ${session.status}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.joined ? 'Duration $mm:$ss' : 'Connecting...',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(
                          name: VoiceCallScreen.routeName,
                        ),
                        builder: (_) => const VoiceCallScreen(),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ],
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

  Future<void> _cancelWithdrawal(
    BuildContext context, {
    required String requestId,
    required int amount,
    required String currency,
  }) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Cancel withdrawal?'),
              content: Text(
                'This will cancel your pending withdrawal for '
                '${formatWalletCurrencyAmount(amount, currency: currency)}.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Keep request'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Cancel withdrawal'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed || !context.mounted) return;

    try {
      await FirebaseFunctions.instance
          .httpsCallable('cancelMyWithdrawal_v1')
          .call({
        'requestId': requestId,
      });

      debugPrint(
        'wallet.withdrawal.cancel.success '
        'requestId=${AppLog.safeId(requestId)}',
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Withdrawal request cancelled.')),
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'wallet.withdrawal.cancel.error '
        'requestId=${AppLog.safeId(requestId)} code=${e.code}',
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not cancel withdrawal request. Please try again.'),
        ),
      );
    } catch (e) {
      debugPrint(
        'wallet.withdrawal.cancel.error '
        'requestId=${AppLog.safeId(requestId)} unexpected=${e.runtimeType}',
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not cancel withdrawal request. Please try again.'),
        ),
      );
    }
  }

  // ignore: unused_element
  Widget _buildPendingWithdrawalCards(
    BuildContext context,
    WalletRepository walletRepository,
    List<Map<String, dynamic>> pendingWithdrawals,
  ) {
    if (pendingWithdrawals.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      children: pendingWithdrawals.map((data) {
        final requestId = _safeString(data['id']);
        final amount = _safeInt(data['amount']);
        final note = _safeString(data['note']);
        final requestedAt = _safeDateTime(
          data['requestedAt'] ?? data['createdAt'],
        );
        final currency = walletRepository.withdrawalCurrency(data);
        final reason = walletRepository.withdrawalStatusReason(data);
        final adminNote = walletRepository.withdrawalAdminNote(data);

        return Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Pending withdrawal',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  _withdrawalStatusChip(FirestorePaths.withdrawalStatusPending),
                ],
              ),
              const SizedBox(height: 10),
              _rowLine(
                label: 'Amount',
                value: formatWalletCurrencyAmount(amount, currency: currency),
              ),
              _rowLine(
                label: 'Requested',
                value: _dateTimeLabel(requestedAt),
              ),
              if (note.isNotEmpty) _rowLine(label: 'Note', value: note),
              if (reason.isNotEmpty) _rowLine(label: 'Reason', value: reason),
              if (adminNote.isNotEmpty)
                _rowLine(label: 'Admin note', value: adminNote),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: requestId.isEmpty
                      ? null
                      : () => _cancelWithdrawal(
                            context,
                            requestId: requestId,
                            amount: amount,
                            currency: currency,
                          ),
                  child: const Text('Cancel request'),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ignore: unused_element
  Widget _buildSpeakerBreakdownSection({
    required String title,
    required List<MapEntry<String, int>> rows,
    required bool positive,
  }) {
    final amountColor =
        positive ? const Color(0xFF15803D) : const Color(0xFFD97706);

    return _sectionCard(
      title: title,
      children: rows.isEmpty
          ? const [
              Text(
                'No data yet.',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]
          : rows
              .map(
                (e) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.key,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827),
                          ),
                        ),
                      ),
                      Text(
                        formatWalletAmount(e.value),
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: amountColor,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
    );
  }

  // ignore: unused_element
  Widget _buildRecentIncomingCallsSection(List<CallModel> ended) {
    if (ended.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No calls yet.',
            style: TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Column(
      children: ended.take(20).map((call) {
        final callerName =
            call.callerName.trim().isEmpty ? 'Unknown' : call.callerName.trim();
        final seconds = call.endedSeconds;
        final payout = call.listenerPayout;
        final settlementColor = _callSettlementColor(call);
        final settlementLabel = _callSettlementLabel(call);
        final settlementSubtitle = _callSettlementSubtitle(call);

        final payoutText = payout <= 0
            ? formatSignedWalletAmount(0)
            : formatSignedWalletAmount(payout);

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        callerName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    Text(
                      payoutText,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: _callSettlementAmountColor(call),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Duration: ${_durationLabel(seconds)}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: settlementColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: settlementColor.withValues(alpha: 0.24),
                        ),
                      ),
                      child: Text(
                        settlementLabel,
                        style: TextStyle(
                          color: settlementColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    settlementSubtitle,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ignore: unused_element
  Widget _buildLedgerSection(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> ledgerDocs,
  ) {
    return _sectionCard(
      title: 'Recent Wallet Ledger',
      subtitle: 'Latest wallet activity and balance adjustments.',
      children: ledgerDocs.isEmpty
          ? const [
              Text(
                'No wallet transactions yet.',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]
          : ledgerDocs.map((data) {
              final type = _safeString(data['type']);
              final notes = _safeString(data['notes']);
              final status = _safeString(
                data[FirestorePaths.fieldTransactionStatus] ?? data['status'],
                fallback: 'completed',
              );
              final amount = _safeInt(data['amount']);
              final createdAt = _safeDateTime(
                data['createdAt'] ?? data['createdAtMs'],
              );

              final direction = walletRepository.transactionDirection(data);
              final isPositive =
                  direction == FirestorePaths.txDirectionCredit || amount >= 0;
              final amountText = formatSignedWalletCurrencyAmount(
                amount,
                currency: walletRepository.transactionCurrency(data),
              );

              final callId = walletRepository.transactionCallId(data);
              final paymentOrderId =
                  walletRepository.transactionPaymentOrderId(data);
              final paymentId = walletRepository.transactionPaymentId(data);
              final withdrawalRequestId =
                  walletRepository.transactionWithdrawalRequestId(data);
              final source = walletRepository.transactionSource(data);
              final gateway = walletRepository.transactionGateway(data);

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            walletTransactionTitle(type),
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _dateTimeLabel(createdAt),
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (notes.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              notes,
                              style: const TextStyle(
                                color: Color(0xFF374151),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            'Status: ${walletStatusLabel(status)}',
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (source.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Source: $source',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (gateway.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Gateway: $gateway',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (callId.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Call: ${AppLog.safeId(callId)}',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (paymentOrderId.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Order: ${AppLog.safeId(paymentOrderId)}',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (paymentId.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Payment: ${AppLog.safeId(paymentId)}',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (withdrawalRequestId.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Withdrawal: $withdrawalRequestId',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      amountText,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: isPositive
                            ? const Color(0xFF15803D)
                            : const Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
    );
  }

  // ignore: unused_element
  Widget _buildWithdrawalHistorySection(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> withdrawalDocs,
  ) {
    return _sectionCard(
      title: 'Withdrawal History',
      subtitle: 'Track withdrawal requests and status.',
      children: withdrawalDocs.isEmpty
          ? const [
              Text(
                'No withdrawal requests yet.',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]
          : withdrawalDocs.map((data) {
              final amount = _safeInt(data['amount']);
              final note = _safeString(data['note']);
              final status = _withdrawalStatus(data);
              final requestedAt = _safeDateTime(
                data['requestedAt'] ?? data['createdAt'],
              );
              final currency = walletRepository.withdrawalCurrency(data);
              final statusReason =
                  walletRepository.withdrawalStatusReason(data);
              final adminNote = walletRepository.withdrawalAdminNote(data);
              final paymentReference =
                  walletRepository.withdrawalPaymentReference(data);
              final ledgerTransactionId =
                  walletRepository.withdrawalLedgerTransactionId(data);
              final paidAt = walletRepository.withdrawalPaidAt(data);
              final approvedAt = walletRepository.withdrawalApprovedAt(data);
              final rejectedAt = walletRepository.withdrawalRejectedAt(data);

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          formatWalletCurrencyAmount(amount,
                              currency: currency),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const Spacer(),
                        _withdrawalStatusChip(status),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _rowLine(
                      label: 'Requested',
                      value: _dateTimeLabel(requestedAt),
                    ),
                    if (note.isNotEmpty) _rowLine(label: 'Note', value: note),
                    if (statusReason.isNotEmpty)
                      _rowLine(label: 'Reason', value: statusReason),
                    if (adminNote.isNotEmpty)
                      _rowLine(label: 'Admin note', value: adminNote),
                    if (paymentReference.isNotEmpty)
                      _rowLine(
                        label: 'Payment ref',
                        value: paymentReference,
                      ),
                    if (ledgerTransactionId.isNotEmpty)
                      _rowLine(
                        label: 'Ledger tx',
                        value: ledgerTransactionId,
                      ),
                    if (approvedAt != null)
                      _rowLine(
                        label: 'Approved',
                        value: _dateTimeLabel(approvedAt),
                      ),
                    if (rejectedAt != null)
                      _rowLine(
                        label: 'Rejected',
                        value: _dateTimeLabel(rejectedAt),
                      ),
                    if (paidAt != null)
                      _rowLine(
                        label: 'Paid',
                        value: _dateTimeLabel(paidAt),
                      ),
                  ],
                ),
              );
            }).toList(),
    );
  }

  // ignore: unused_element
  Widget _buildPaymentOrdersSection(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> paymentOrders,
  ) {
    return _sectionCard(
      title: 'Payment Orders',
      subtitle: 'Top-up order history.',
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: const Text(
            'Payment order history is hidden from the normal wallet view.',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF92400E),
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...(paymentOrders.isEmpty
            ? const [
                Text(
                  'No payment orders yet.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ]
            : paymentOrders.map((doc) {
                final gateway = walletRepository.paymentOrderGateway(doc);
                final orderId = walletRepository.paymentOrderId(doc);
                final paymentId = walletRepository.paymentId(doc);
                final amount = walletRepository.paymentOrderAmount(doc);
                final currency = walletRepository.paymentOrderCurrency(doc);
                final status = walletRepository.paymentOrderStatus(doc);
                final createdAt = _safeDateTime(
                  doc[FirestorePaths.fieldPaymentOrderCreatedAt],
                );
                final verifiedAt = _safeDateTime(
                  doc[FirestorePaths.fieldPaymentOrderVerifiedAt],
                );
                final failureReason = _safeString(
                  doc[FirestorePaths.fieldPaymentOrderFailureReason],
                );

                final isVerified = walletRepository.isPaymentOrderVerified(doc);
                final isPending = walletRepository.isPaymentOrderPending(doc);

                final color = isVerified
                    ? const Color(0xFF15803D)
                    : isPending
                        ? const Color(0xFFD97706)
                        : const Color(0xFFDC2626);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              formatWalletCurrencyAmount(
                                amount,
                                currency: currency,
                              ),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: Color(0xFF111827),
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: color.withValues(alpha: 0.24),
                              ),
                            ),
                            child: Text(
                              walletStatusLabel(status),
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (gateway.isNotEmpty)
                        _rowLine(label: 'Gateway', value: gateway),
                      if (orderId.isNotEmpty)
                        _rowLine(label: 'Order', value: orderId),
                      if (paymentId.isNotEmpty)
                        _rowLine(label: 'Payment', value: paymentId),
                      _rowLine(
                        label: 'Created',
                        value: _dateTimeLabel(createdAt),
                      ),
                      if (verifiedAt != null)
                        _rowLine(
                          label: 'Verified',
                          value: _dateTimeLabel(verifiedAt),
                        ),
                      if (failureReason.isNotEmpty)
                        _rowLine(label: 'Failure', value: failureReason),
                    ],
                  ),
                );
              }).toList()),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildLaunchDisclosureSection() {
    return _sectionCard(
      title: 'Support & policies',
      subtitle: 'Review policy and support details related to your account.',
      children: [
        _launchLinkTile(
          icon: Icons.receipt_long_outlined,
          title: 'Refund / Cancellation Policy',
          subtitle: 'See refund and cancellation details.',
          iconColor: const Color(0xFFD97706),
          iconBg: const Color(0xFFFFFBEB),
          onTap: () {
            _showInfoSheet(
              title: 'Refund / Cancellation Policy',
              body: LegalLinks.refundCancellationPolicyMessage,
            );
          },
        ),
        const Divider(height: 1),
        _launchLinkTile(
          icon: Icons.support_agent_rounded,
          title: 'Support',
          subtitle: 'Get help with account or payment issues.',
          iconColor: const Color(0xFF15803D),
          iconBg: const Color(0xFFECFDF3),
          onTap: () {
            _showInfoSheet(
              title: 'Support',
              body: LegalLinks.supportMessage,
            );
          },
        ),
        const Divider(height: 1),
        _launchLinkTile(
          icon: Icons.delete_outline_rounded,
          title: 'Delete Account Request',
          subtitle: 'Submit a request to delete your account.',
          iconColor: const Color(0xFFDC2626),
          iconBg: const Color(0xFFFEF2F2),
          onTap: () {
            _showInfoSheet(
              title: 'Delete Account Request',
              body: LegalLinks.deleteAccountRequestMessage,
            );
          },
        ),
      ],
    );
  }

  // ignore: unused_element
  int _thisWeekCreditTotal(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> ledgerDocs,
  ) {
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    var total = 0;

    for (final doc in ledgerDocs) {
      final direction = walletRepository.transactionDirection(doc);
      if (direction != FirestorePaths.txDirectionCredit) continue;

      final createdAt = _safeDateTime(
        doc[FirestorePaths.fieldTransactionCreatedAt] ??
            doc[FirestorePaths.fieldCreatedAt],
      );
      if (createdAt == null || createdAt.isBefore(weekStart)) continue;

      total += _safeInt(doc[FirestorePaths.fieldTransactionAmount]);
    }

    return total;
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

  // ignore: unused_element
  Widget _walletTopBar() {
    return Row(
      children: [
        const Text(
          'Wallet',
          style: TextStyle(
            color: FriendifyBrand.pureWhite,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          Icons.visibility_outlined,
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.72),
          size: 20,
        ),
        const Spacer(),
        SizedBox(
          width: 40,
          height: 40,
          child: IconButton(
            tooltip: 'Wallet menu',
            padding: EdgeInsets.zero,
            onPressed: () => _showInfoSheet(
              title: 'Wallet',
              body:
                  'Recent transactions, top-ups, withdrawals, and earnings are shown here.',
            ),
            icon: const Icon(Icons.menu_rounded, size: 24),
            color: FriendifyBrand.pureWhite,
          ),
        ),
      ],
    );
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

  // ignore: unused_element
  Widget _walletMiniStat({
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Container(
        constraints: const BoxConstraints(minHeight: 78),
        padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
        decoration: BoxDecoration(
          color: AppPalette.feedBg,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.05),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: FriendifyBrand.pureWhite.withValues(alpha: 0.62),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: FriendifyBrand.pureWhite,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
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

  bool _matchesCallSearch(AppUserModel user) {
    final query = _callsSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;

    final haystack = <String>[
      user.displayName,
      user.bio,
      user.city,
      user.state,
      ...user.topics,
      ...user.languages,
    ].join(' ').toLowerCase();

    return haystack.contains(query);
  }

  String _listenerDisplayName(AppUserModel user) {
    final name = user.displayName.trim();
    if (name.isNotEmpty) return name;
    return 'Friendify Listener';
  }

  Widget _listenerAvatar(AppUserModel user, {double size = 54}) {
    final photoUrl = user.photoURL.trim();
    final name = _listenerDisplayName(user);

    Widget fallback() {
      return Center(
        child: Text(
          name.characters.first.toUpperCase(),
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.40,
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.blue,
        border: Border.all(
          color: AppPalette.border,
          width: 2,
        ),
      ),
      child: ClipOval(
        child: photoUrl.isEmpty
            ? fallback()
            : Image.network(
                photoUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback(),
              ),
      ),
    );
  }

  Widget _callsSearchBar() {
    return TextField(
      controller: _callsSearchController,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(
        color: AppPalette.textPrimary,
        fontWeight: FontWeight.w800,
      ),
      decoration: InputDecoration(
        hintText: 'Search call-ready listeners...',
        hintStyle: const TextStyle(
          color: AppPalette.textMuted,
          fontWeight: FontWeight.w800,
        ),
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: AppPalette.textMuted,
        ),
        filled: true,
        fillColor: AppPalette.feedBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(
            color: AppPalette.border,
            width: 1.2,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(
            color: AppPalette.blue,
            width: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _callsTopBar() {
    return const Center(
      child: Text(
        'Calls',
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }

  Widget _callsActionTiles({
    required AppUserModel me,
    required WalletRepository walletRepository,
    required List<Map<String, dynamic>> ledgerDocs,
  }) {
    return Row(
      children: [
        Expanded(
          child: _callsInfoTile(
            icon: Icons.account_balance_wallet_rounded,
            title: 'Wallet',
            trailing: SizedBox(
              width: 32,
              height: 32,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: AppPalette.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed:
                    _topupBusy ? null : () => _startTopup(amount: 500, me: me),
                child: _topupBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded, size: 23),
              ),
            ),
            onTap: () => _showWalletSheet(
              me: me,
              walletRepository: walletRepository,
              ledgerDocs: ledgerDocs,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _callsInfoTile(
            icon: Icons.receipt_long_rounded,
            title: 'History',
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppPalette.textMuted,
            ),
            onTap: _openCallHistory,
          ),
        ),
      ],
    );
  }

  Widget _callsInfoTile({
    required IconData icon,
    required String title,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppPalette.feedBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppPalette.border,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppPalette.blue, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w900,
                  fontSize: 14.5,
                ),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  void _openCallHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const CallHistoryScreen(),
      ),
    );
  }

  Future<void> _startCall({
    required AppUserModel me,
    required AppUserModel listener,
  }) async {
    if (_callingFor.isNotEmpty) return;

    final safeListenerId = listener.uid.trim();
    if (safeListenerId.isEmpty || safeListenerId == me.uid) return;
    if (_callRepository.hasBlockingCallState) {
      _showInfoSheet(
        title: 'Call',
        body: 'Finish your current call flow first.',
      );
      return;
    }

    setState(() => _callingFor = safeListenerId);
    try {
      final canCall = await _callRepository.canCurrentUserCallListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      final readiness = _callRepository.callReadinessForKnownUsers(
        me: me,
        listener: listener,
        hasCallAccess: canCall,
        requiredCredits: listener.listenerRate > 0 ? listener.listenerRate : 5,
      );
      if (!readiness.canStart) {
        _showInfoSheet(
          title: 'Call',
          body: readiness.message,
        );
        return;
      }

      final callStart = await _callRepository.createCallToListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      if (callStart == null) {
        _showInfoSheet(
          title: 'Call',
          body: 'Call could not start. Please try again.',
        );
        return;
      }

      if (!callStart.canOpenWaitingScreen) {
        _showInfoSheet(
          title: 'Call',
          body: 'Call setup is incomplete. Please try again.',
        );
        return;
      }

      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => CallerWaitingScreen(
            callDocRef: callStart.callRef,
            initialAgoraToken: callStart.agoraToken,
            initialAgoraUid: callStart.agoraUid,
            initialChannelId: callStart.channelId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showInfoSheet(
        title: 'Call',
        body: _callRepository.humanizeCallActionError(e),
      );
    } finally {
      if (mounted) {
        setState(() => _callingFor = '');
      } else {
        _callingFor = '';
      }
    }
  }

  void _openListenerProfile(AppUserModel listener) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(
          listenerId: listener.uid,
          initialUser: listener,
        ),
      ),
    );
  }

  void _showWalletSheet({
    required AppUserModel me,
    required WalletRepository walletRepository,
    required List<Map<String, dynamic>> ledgerDocs,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        var sheetFilter = _statementFilter;
        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.42,
          maxChildSize: 0.92,
          builder: (_, controller) {
            final totalCredits = walletRepository.totalCredits(me);
            return StatefulBuilder(
              builder: (_, setSheetState) {
                final statementDocs = _statementDocsForFilter(
                  walletRepository,
                  ledgerDocs,
                  sheetFilter,
                );

                return Container(
                  decoration: const BoxDecoration(
                    color: AppPalette.card,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: ListView(
                    controller: controller,
                    padding: FriendifyBrand.screenPadding(
                      sheetContext,
                      top: 16,
                      bottom: 28,
                    ),
                    children: [
                      Center(
                        child: Container(
                          width: 48,
                          height: 5,
                          decoration: BoxDecoration(
                            color: AppPalette.textMuted.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
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
                                : () =>
                                    _requestWithdrawalSheet(sheetContext, me),
                            colors: const [
                              Color(0xFF2F6FED),
                              Color(0xFF225CFF),
                            ],
                          ),
                          const SizedBox(width: 10),
                          _walletActionButton(
                            label: _topupBusy ? 'Processing...' : 'Top Up',
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
                      const SizedBox(height: 18),
                      _walletStatementTabsLocal(
                        selectedFilter: sheetFilter,
                        onChanged: (filter) {
                          setSheetState(() => sheetFilter = filter);
                        },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _statementTitleForFilter(sheetFilter),
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
                        emptyText: _statementEmptyTextForFilter(sheetFilter),
                        limit: 30,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _callReadySection({
    required AppUserModel me,
    required List<AppUserModel> listeners,
    required List<Map<String, dynamic>> chatSessions,
  }) {
    final filtered = listeners
        .where((user) => user.uid.trim().isNotEmpty)
        .where((user) => user.uid != me.uid)
        .where(_matchesCallSearch)
        .toList(growable: false);
    final sessionsByListenerId = <String, Map<String, dynamic>>{};

    for (final session in chatSessions) {
      if (session['exists'] != true) continue;
      final participantIds =
          _callRepository.sessionParticipantIds(session).toSet();
      if (!participantIds.contains(me.uid)) continue;

      for (final listener in filtered) {
        if (!participantIds.contains(listener.uid)) continue;
        sessionsByListenerId[listener.uid] = session;
      }
    }

    final callReadyListeners = filtered.where((listener) {
      final session = sessionsByListenerId[listener.uid];
      if (session == null) return false;
      final sessionBlocked =
          session[FirestorePaths.fieldSpeakerBlocked] == true ||
              session[FirestorePaths.fieldListenerBlocked] == true;
      if (sessionBlocked) return false;

      return _sessionAllowsCallAccess(
        session: session,
        me: me,
        listener: listener,
      );
    }).toList(growable: false);

    if (callReadyListeners.isEmpty) {
      return _emptyCallReadyCard(
        'Search profiles, chat, and send a call request first. Accepted listeners will show here.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Call-ready people',
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 15,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 7),
        ...callReadyListeners.map((listener) {
          final session = sessionsByListenerId[listener.uid];
          return Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: _callReadyTile(
              me: me,
              listener: listener,
              hasCallAccess: session == null
                  ? false
                  : _sessionAllowsCallAccess(
                      session: session,
                      me: me,
                      listener: listener,
                    ),
            ),
          );
        }),
      ],
    );
  }

  bool _sessionAllowsCallAccess({
    required Map<String, dynamic> session,
    required AppUserModel me,
    required AppUserModel listener,
  }) {
    final strictAllowed = _callRepository.sessionAllowsCallForDirection(
      session: session,
      speakerId: me.uid,
      listenerId: listener.uid,
    );
    if (strictAllowed) return true;

    final status = (session[FirestorePaths.fieldChatStatus] ?? '').toString();
    if (status != FirestorePaths.chatStatusAccepted) return false;

    final actualListenerId =
        (session[FirestorePaths.fieldActualListenerId] ?? '').toString().trim();
    return actualListenerId == listener.uid.trim() &&
        _callRepository.sessionIdentityLooksComplete(
          session: session,
          speakerId: me.uid,
          listenerId: listener.uid,
        );
  }

  Widget _callReadyTile({
    required AppUserModel me,
    required AppUserModel listener,
    required bool hasCallAccess,
  }) {
    final calling = _callingFor == listener.uid;
    final rate = listener.listenerRate > 0 ? listener.listenerRate : 5;
    final readiness = _callRepository.callReadinessForKnownUsers(
      me: me,
      listener: listener,
      hasCallAccess: hasCallAccess,
      requiredCredits: rate,
    );
    final callReady = readiness.canStart;
    final followerCount = listener.ratingCount < 0 ? 0 : listener.ratingCount;
    final statText = '0 posts  -  $followerCount followers';

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _openListenerProfile(listener),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppPalette.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppPalette.border,
          ),
        ),
        child: Row(
          children: [
            _listenerAvatar(listener, size: 44),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _listenerDisplayName(listener),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 15.5,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      _statusPill('Rs $rate/min', AppPalette.blue),
                      _statusPill(
                        readiness.label,
                        callReady
                            ? AppPalette.online
                            : readiness.reason.contains('credit')
                                ? const Color(0xFFF59E0B)
                                : AppPalette.blue,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppPalette.textMuted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 106,
              height: 38,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  backgroundColor:
                      callReady ? AppPalette.blue : AppPalette.feedBg,
                  disabledBackgroundColor: AppPalette.feedBg,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: AppPalette.textMuted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: calling || !callReady
                    ? null
                    : () => _startCall(me: me, listener: listener),
                icon: calling
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.call_rounded, size: 18),
                label: Text(
                  calling ? 'Wait' : 'Call',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 11.5,
        ),
      ),
    );
  }

  Widget _emptyCallReadyCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.call_outlined,
            color: AppPalette.blue,
            size: 30,
          ),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w800,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _callsWarningCard({
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
        body: DecoratedBox(
          decoration: const BoxDecoration(color: AppPalette.pageBg),
          child: StreamBuilder<AppUserModel?>(
            key: ValueKey('wallet_user_$_walletRetryToken'),
            stream: walletRepository.watchMyWallet(),
            builder: (_, userSnap) {
              if (userSnap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _callsWarningCard(
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
                    'Unable to load calls right now.',
                    style: TextStyle(color: AppPalette.textPrimary),
                  ),
                );
              }

              return StreamBuilder<List<Map<String, dynamic>>>(
                key: ValueKey('wallet_ledger_$_ledgerRetryToken'),
                stream: walletRepository.watchMyTransactions(limit: 60),
                builder: (_, ledgerSnap) {
                  final ledgerDocs =
                      ledgerSnap.data ?? const <Map<String, dynamic>>[];

                  return StreamBuilder<List<AppUserModel>>(
                    key: ValueKey('wallet_listeners_$_callReadyRetryToken'),
                    stream: _userRepository.watchAvailableListeners(limit: 200),
                    builder: (_, listenersSnap) {
                      final listeners =
                          listenersSnap.data ?? const <AppUserModel>[];

                      return StreamBuilder<List<Map<String, dynamic>>>(
                        key: ValueKey('wallet_sessions_$_callReadyRetryToken'),
                        stream: _callRepository.watchCurrentUserChatSessions(
                          limit: 100,
                        ),
                        builder: (_, sessionsSnap) {
                          final chatSessions = sessionsSnap.data ??
                              const <Map<String, dynamic>>[];
                          final loadingCalls = (listenersSnap.connectionState ==
                                      ConnectionState.waiting &&
                                  listeners.isEmpty) ||
                              (sessionsSnap.connectionState ==
                                      ConnectionState.waiting &&
                                  chatSessions.isEmpty);
                          final ledgerLoadError = ledgerSnap.hasError;
                          final listenersLoadError = listenersSnap.hasError;
                          final sessionsLoadError = sessionsSnap.hasError;
                          final callsLoadError =
                              listenersLoadError || sessionsLoadError;

                          return ListView(
                            padding: FriendifyBrand.screenPadding(
                              context,
                              top: 18,
                              bottom: 104,
                            ),
                            children: [
                              SafeArea(
                                bottom: false,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _callsTopBar(),
                                    const SizedBox(height: 12),
                                    _callsSearchBar(),
                                    const SizedBox(height: 12),
                                    _callsActionTiles(
                                      me: me,
                                      walletRepository: walletRepository,
                                      ledgerDocs: ledgerDocs,
                                    ),
                                    if (ledgerLoadError) ...[
                                      const SizedBox(height: 12),
                                      _callsWarningCard(
                                        title: 'Wallet history sync issue',
                                        message:
                                            'Balance is shown from your account record, but recent transactions could not refresh.',
                                        actionLabel: 'Retry history',
                                        onAction: _retryLedgerLoad,
                                      ),
                                    ],
                                    const SizedBox(height: 14),
                                    if (callsLoadError)
                                      _callsWarningCard(
                                        title: 'Call-ready list unavailable',
                                        message: listenersLoadError
                                            ? 'Listener profiles could not load. Your accepted call list may be incomplete.'
                                            : 'Accepted chat sessions could not load. Try again when the connection settles.',
                                        actionLabel: 'Retry calls',
                                        onAction: _retryCallReadyLoad,
                                      )
                                    else if (loadingCalls)
                                      const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(20),
                                          child: CircularProgressIndicator(),
                                        ),
                                      )
                                    else
                                      _callReadySection(
                                        me: me,
                                        listeners: listeners,
                                        chatSessions: chatSessions,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
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
