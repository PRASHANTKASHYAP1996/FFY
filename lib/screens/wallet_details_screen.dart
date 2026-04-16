import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../repositories/wallet_repository.dart';
import '../services/call_session_manager.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/call_model.dart';
import 'voice_call_screen.dart';

class WalletDetailsScreen extends StatefulWidget {
  const WalletDetailsScreen({super.key});

  @override
  State<WalletDetailsScreen> createState() => _WalletDetailsScreenState();
}

class _WalletDetailsScreenState extends State<WalletDetailsScreen> {
  String? _currentOrderId;
  bool _topupBusy = false;
  bool _withdrawSheetOpen = false;

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

  String _withdrawStatusLabel(String status) {
    final safe = status.trim().toLowerCase();
    switch (safe) {
      case 'approved':
        return 'Approved';
      case 'paid':
        return 'Paid';
      case 'completed':
        return 'Completed';
      case 'rejected':
        return 'Rejected';
      case 'cancelled':
        return 'Cancelled';
      case 'pending':
      default:
        return 'Pending';
    }
  }

  String _paymentStatusHuman(String status) {
    final safe = status.trim().toLowerCase();
    switch (safe) {
      case 'verified':
        return 'Payment verified';
      case 'pending':
        return 'Waiting for confirmation';
      case 'created':
        return 'Order created';
      case 'failed':
        return 'Payment failed';
      case 'cancelled':
        return 'Cancelled';
      default:
        if (safe.isEmpty) return 'Unknown';
        return status;
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
        _withdrawStatusLabel(status),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  String _transactionTitle(String type) {
    switch (type.trim()) {
      case 'call_earning':
        return 'Call Earning';
      case 'call_charge':
        return 'Call Charge';
      case 'withdraw_request':
      case 'withdrawal_request':
        return 'Withdrawal Request';
      case 'withdraw_complete':
      case 'withdrawal_paid':
        return 'Withdrawal Paid';
      case 'withdrawal_debit':
        return 'Withdrawal Debit';
      case 'withdrawal_rejected':
        return 'Withdrawal Rejected';
      case 'withdrawal_cancelled':
        return 'Withdrawal Cancelled';
      case 'refund':
        return 'Refund';
      case 'topup':
        return 'Top-up';
      case 'call_reserve_hold':
        return 'Reserve Hold';
      case 'call_reserve_release':
        return 'Reserve Release';
      case 'admin_adjustment_credit':
        return 'Admin Credit';
      case 'admin_adjustment_debit':
        return 'Admin Debit';
      default:
        return type.trim().isEmpty ? 'Transaction' : type.trim();
    }
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFEEF2FF) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlight
              ? const Color(0xFFC7D2FE)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: highlight ? 24 : 20,
              fontWeight: FontWeight.w900,
              color: highlight
                  ? const Color(0xFF312E81)
                  : const Color(0xFF111827),
            ),
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFF6B7280),
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
        color: const Color(0xFFF3F4F8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: Color(0xFF374151),
        ),
      ),
    );
  }

  Widget _noticeChip(
    String text, {
    Color bg = const Color(0xFFF3F4F8),
    Color fg = const Color(0xFF374151),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
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
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _rowLine({
    required String label,
    required String value,
    Color valueColor = const Color(0xFF111827),
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6B7280),
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
    Color iconColor = const Color(0xFF4F46E5),
    Color iconBg = const Color(0xFFEEF2FF),
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
          color: Color(0xFF111827),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: Color(0xFF6B7280),
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

  void _showInfoSheet({
    required String title,
    required String body,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
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
        );
      },
    );
  }

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
            padding: const EdgeInsets.all(14),
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
                        'With $otherName • ${session.status}',
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

      await _verifySandboxPayment();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (e.message ?? 'Could not create test top-up order.').trim(),
          ),
        ),
      );
      setState(() {
        _topupBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start test top-up. Please try again.'),
        ),
      );
      setState(() {
        _topupBusy = false;
      });
    }
  }

  Future<void> _verifySandboxPayment() async {
    final orderId = _currentOrderId;
    if (orderId == null || orderId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test payment order is missing.'),
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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test top-up verified and wallet updated.'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (e.message ?? 'Test payment verification failed.').trim(),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test payment verification failed.'),
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
          return _WithdrawalRequestSheet(
            me: me,
          );
        },
      );

      if (result == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Withdrawal request submitted in test/manual mode.'),
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
  }) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('cancelMyWithdrawal_v1')
          .call({
        'requestId': requestId,
      });

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Withdrawal request cancelled.')),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (e.message ?? 'Could not cancel withdrawal request.').trim(),
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not cancel withdrawal request.'),
        ),
      );
    }
  }

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
          padding: const EdgeInsets.all(14),
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
              _rowLine(label: 'Amount', value: '$currency $amount'),
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
                  padding: const EdgeInsets.all(14),
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
                        '₹${e.value}',
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
        final callerName = call.callerName.trim().isEmpty
            ? 'Unknown'
            : call.callerName.trim();
        final seconds = call.endedSeconds;
        final payout = call.listenerPayout;
        final settlementColor = _callSettlementColor(call);
        final settlementLabel = _callSettlementLabel(call);
        final settlementSubtitle = _callSettlementSubtitle(call);

        final payoutText = payout <= 0 ? '+₹0' : '+₹$payout';

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
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
              final amountText =
                  '${isPositive ? '+' : ''}${walletRepository.transactionCurrency(data)} $amount';

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
                padding: const EdgeInsets.all(14),
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
                            _transactionTitle(type),
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
                            'Status: ${status.trim().isEmpty ? 'completed' : status}',
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
                              'Call: $callId',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (paymentOrderId.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Order: $paymentOrderId',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (paymentId.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Payment: $paymentId',
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

  Widget _buildWithdrawalHistorySection(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> withdrawalDocs,
  ) {
    return _sectionCard(
      title: 'Withdrawal History',
      subtitle: 'All test/manual withdrawal requests and their status.',
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
              final payoutMode = _safeString(
                data['payoutMode'],
                fallback: 'manual_test',
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
                padding: const EdgeInsets.all(14),
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
                          '$currency $amount',
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
                    _rowLine(label: 'Mode', value: payoutMode),
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

  Widget _buildPaymentOrdersSection(
    WalletRepository walletRepository,
    List<Map<String, dynamic>> paymentOrders,
  ) {
    return _sectionCard(
      title: 'Payment Orders',
      subtitle: 'Internal test-order layer for wallet top-up flow.',
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
            '⚠️ Test mode is active. No real-money production payment claim should be made from this screen.',
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
                  'No payment orders yet. This section shows test order history only.',
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

                final isVerified =
                    walletRepository.isPaymentOrderVerified(doc);
                final isPending = walletRepository.isPaymentOrderPending(doc);

                final color = isVerified
                    ? const Color(0xFF15803D)
                    : isPending
                        ? const Color(0xFFD97706)
                        : const Color(0xFFDC2626);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
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
                              '$currency $amount',
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
                              _paymentStatusHuman(status),
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

  Widget _buildLaunchDisclosureSection() {
    return _sectionCard(
      title: 'Payment mode, refunds & support',
      subtitle:
          'Important launch-phase disclosure for the current build.',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _noticeChip(
              'Test wallet mode',
              bg: const Color(0xFFFFFBEB),
              fg: const Color(0xFF92400E),
            ),
            _noticeChip(
              'Manual test withdrawals',
              bg: const Color(0xFFFFFBEB),
              fg: const Color(0xFF92400E),
            ),
            _noticeChip(
              'Not full production money flow',
              bg: const Color(0xFFFEF2F2),
              fg: const Color(0xFFB91C1C),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current payment truth',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Top-ups in this build are test-oriented. Withdrawal requests are also manual/test workflow only. This screen should not be treated as a fully live production money wallet yet.',
                style: TextStyle(
                  color: Color(0xFF374151),
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _launchLinkTile(
          icon: Icons.receipt_long_outlined,
          title: 'Refund Policy',
          subtitle: 'Visible placeholder until final production policy is linked.',
          iconColor: const Color(0xFFD97706),
          iconBg: const Color(0xFFFFFBEB),
          onTap: () {
            _showInfoSheet(
              title: 'Refund Policy',
              body:
                  'Refund Policy is still placeholder-only in this build.\n\nCurrent truth: failed or incomplete test payment attempts should not be treated as final live charges. Formal production refund handling still needs final founder, legal, and payment setup before launch.',
            );
          },
        ),
        const Divider(height: 1),
        _launchLinkTile(
          icon: Icons.support_agent_rounded,
          title: 'Support / Grievance Contact',
          subtitle: 'Visible placeholder until final support channels are configured.',
          iconColor: const Color(0xFF15803D),
          iconBg: const Color(0xFFECFDF3),
          onTap: () {
            _showInfoSheet(
              title: 'Support / Grievance Contact',
              body:
                  'Support and grievance contact details are not finalized in this build yet.\n\nBefore launch, configure support email, support response window, grievance officer/contact, escalation path, and any required business address.',
            );
          },
        ),
        const Divider(height: 1),
        _launchLinkTile(
          icon: Icons.delete_outline_rounded,
          title: 'Delete Account Request',
          subtitle: 'Reachable account-deletion request surface exists from Profile.',
          iconColor: const Color(0xFFDC2626),
          iconBg: const Color(0xFFFEF2F2),
          onTap: () {
            _showInfoSheet(
              title: 'Delete Account Request',
              body:
                  'Delete-account request is available from the Profile screen.\n\nCurrent truth: it submits a controlled review request, not instant device-side deletion. Final retention policy and operational handling still need founder/business verification before launch.',
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final walletRepository = WalletRepository.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet & Earnings')),
      body: StreamBuilder<AppUserModel?>(
        stream: walletRepository.watchMyWallet(),
        builder: (_, userSnap) {
          if (userSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final me = userSnap.data;
          if (me == null) {
            return const Center(
              child: Text('Unable to load wallet right now.'),
            );
          }

          final totalCredits = walletRepository.totalCredits(me);
          final reservedCredits = walletRepository.reservedCredits(me);
          final earningsCredits = walletRepository.earningsCredits(me);
          final usableCredits = walletRepository.usableCredits(me);

          return StreamBuilder<List<CallModel>>(
            stream: walletRepository.watchMyListenerCalls(),
            builder: (_, callsSnap) {
              if (callsSnap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final allCalls = callsSnap.data ?? const <CallModel>[];
              final ended = walletRepository.endedCalls(allCalls);

              final totalCreditedFromCalls =
                  walletRepository.totalListenerCredited(ended);
              final totalPending =
                  walletRepository.totalListenerPending(ended);

              final creditedRows = walletRepository
                  .creditedByCaller(ended)
                  .entries
                  .toList()
                ..sort((a, b) => b.value.compareTo(a.value));

              final pendingRows = walletRepository
                  .pendingByCaller(ended)
                  .entries
                  .toList()
                ..sort((a, b) => b.value.compareTo(a.value));

              final freeCallsCount = walletRepository.freeCalls(ended).length;
              final paidCallsCount = walletRepository.paidCalls(ended).length;
              final settledCallsCount =
                  ended.where((e) => e.settled || e.listenerCredited).length;
              final awaitingSettlementCount = ended
                  .where((e) =>
                      e.listenerPayout > 0 &&
                      !e.settled &&
                      !e.listenerCredited)
                  .length;

              return StreamBuilder<List<Map<String, dynamic>>>(
                stream: walletRepository.watchMyWithdrawals(limit: 20),
                builder: (_, withdrawalSnap) {
                  final withdrawalDocs =
                      withdrawalSnap.data ?? const <Map<String, dynamic>>[];

                  final pendingWithdrawals = withdrawalDocs.where((doc) {
                    return walletRepository.isWithdrawalPending(doc);
                  }).toList();

                  return StreamBuilder<List<Map<String, dynamic>>>(
                    stream: walletRepository.watchMyTransactions(limit: 20),
                    builder: (_, ledgerSnap) {
                      final ledgerDocs =
                          ledgerSnap.data ?? const <Map<String, dynamic>>[];

                      final totalTopups =
                          walletRepository.totalTopupAmount(ledgerDocs);
                      final totalCharged =
                          walletRepository.totalChargedAmount(ledgerDocs);
                      final totalRefunds =
                          walletRepository.totalRefundAmount(ledgerDocs);
                      final topupCount =
                          walletRepository.topupTransactions(ledgerDocs).length;
                      final earningTxCount = walletRepository
                          .earningTransactions(ledgerDocs)
                          .length;
                      final chargeTxCount = walletRepository
                          .chargeTransactions(ledgerDocs)
                          .length;

                      return StreamBuilder<List<Map<String, dynamic>>>(
                        stream: walletRepository.watchMyPaymentOrders(limit: 20),
                        builder: (_, paymentOrdersSnap) {
                          final paymentOrders =
                              paymentOrdersSnap.data ??
                                  const <Map<String, dynamic>>[];

                          final verifiedOrderCount = paymentOrders
                              .where(walletRepository.isPaymentOrderVerified)
                              .length;
                          final pendingOrderCount = paymentOrders
                              .where(walletRepository.isPaymentOrderPending)
                              .length;

                          final hasTestPaymentUsage =
                              walletRepository.isCommercialWalletReadyFromLedger(
                                    ledgerDocs,
                                  ) ||
                                  paymentOrders.isNotEmpty;

                          return ListView(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                            children: [
                              _activeCallBanner(context),
                              if (CallSessionManager.instance.active)
                                const SizedBox(height: 12),
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Wallet Overview',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF111827),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      const Text(
                                        'A compact summary of credits, earnings, and settlement status.',
                                        style: TextStyle(
                                          color: Color(0xFF6B7280),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      _statTile(
                                        label: 'Usable credits',
                                        value: '₹$usableCredits',
                                        subtitle: 'Available right now',
                                        highlight: true,
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _statTile(
                                              label: 'Total credits',
                                              value: '₹$totalCredits',
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: _statTile(
                                              label: 'Reserved',
                                              value: '₹$reservedCredits',
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      _statTile(
                                        label: 'Lifetime earnings credits',
                                        value: '₹$earningsCredits',
                                        subtitle:
                                            'Internal credited earnings so far',
                                      ),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          _summaryChip(
                                            'Ended calls',
                                            '${ended.length}',
                                          ),
                                          _summaryChip(
                                            'Free calls',
                                            '$freeCallsCount',
                                          ),
                                          _summaryChip(
                                            'Paid calls',
                                            '$paidCallsCount',
                                          ),
                                          _summaryChip(
                                            'Settled',
                                            '$settledCallsCount',
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: FilledButton(
                                              onPressed: _topupBusy
                                                  ? null
                                                  : () => _startTopup(
                                                        amount: 100,
                                                        me: me,
                                                      ),
                                              child: Text(
                                                _topupBusy
                                                    ? 'Processing...'
                                                    : 'Add ₹100 (test)',
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: _topupBusy
                                                  ? null
                                                  : () => _startTopup(
                                                        amount: 500,
                                                        me: me,
                                                      ),
                                              child: const Text(
                                                'Add ₹500 (test)',
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Test top-up mode is active for internal wallet validation.',
                                        style: TextStyle(
                                          color: Color(0xFF6B7280),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _sectionCard(
                                title: 'Wallet Mode',
                                subtitle:
                                    'Clear launch-phase truth for this wallet build.',
                                children: [
                                  _statTile(
                                    label: 'Current mode',
                                    value: hasTestPaymentUsage
                                        ? 'Test payment activity detected'
                                        : 'Internal/test mode',
                                    subtitle: hasTestPaymentUsage
                                        ? 'Test orders or top-up style entries exist'
                                        : 'No payment-order activity detected yet',
                                    highlight: false,
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _statTile(
                                          label: 'Top-ups',
                                          value: '$topupCount',
                                          subtitle: 'Ledger top-up entries',
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _statTile(
                                          label: 'Verified orders',
                                          value: '$verifiedOrderCount',
                                          subtitle: 'Test orders verified',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _statTile(
                                          label: 'Pending orders',
                                          value: '$pendingOrderCount',
                                          subtitle: 'Awaiting test result',
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _statTile(
                                          label: 'Top-up amount',
                                          value: '₹$totalTopups',
                                          subtitle: 'Total ledger top-ups',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _sectionCard(
                                title: 'Listener Earnings',
                                subtitle:
                                    'Track credited and pending earning flow.',
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _statTile(
                                          label: 'Credited',
                                          value: '₹$totalCreditedFromCalls',
                                          subtitle: 'Completed earnings',
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _statTile(
                                          label: 'Pending',
                                          value: '₹$totalPending',
                                          subtitle: 'Awaiting settlement',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _summaryChip(
                                        'Settled',
                                        '$settledCallsCount',
                                      ),
                                      _summaryChip(
                                        'Awaiting settlement',
                                        '$awaitingSettlementCount',
                                      ),
                                      _summaryChip(
                                        'Earning tx',
                                        '$earningTxCount',
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Billing rule: under 60 seconds is free. After that, full minutes only.',
                                    style: TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _sectionCard(
                                title: 'Charges, Refunds & Adjustments',
                                subtitle:
                                    'Caller-side money movement visibility from ledger.',
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _statTile(
                                          label: 'Charged total',
                                          value: '₹$totalCharged',
                                          subtitle: 'Ledger call charges',
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _statTile(
                                          label: 'Refund total',
                                          value: '₹$totalRefunds',
                                          subtitle: 'Ledger refunds',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _summaryChip(
                                        'Charge tx',
                                        '$chargeTxCount',
                                      ),
                                      _summaryChip(
                                        'Refund tx',
                                        '${walletRepository.refundTransactions(ledgerDocs).length}',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _sectionCard(
                                title: 'Test Withdrawals',
                                subtitle:
                                    'Manual/test withdrawal workflow only. Real payouts are not enabled yet.',
                                children: [
                                  _statTile(
                                    label: 'Withdrawable test earnings',
                                    value: '₹$earningsCredits',
                                    subtitle: pendingWithdrawals.isNotEmpty
                                        ? 'You already have a pending request'
                                        : 'Minimum withdrawal is ₹50',
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: pendingWithdrawals.isNotEmpty ||
                                              earningsCredits < 50
                                          ? null
                                          : () => _requestWithdrawalSheet(
                                                context,
                                                me,
                                              ),
                                      icon: const Icon(
                                        Icons.account_balance_wallet,
                                      ),
                                      label: Text(
                                        pendingWithdrawals.isNotEmpty
                                            ? 'Withdrawal in progress'
                                            : (earningsCredits < 50
                                                ? 'Minimum ₹50 required'
                                                : 'Request withdrawal'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    '⚠️ Withdrawals here are not live commercial payouts. They are manual/test workflow only.',
                                    style: TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  _buildPendingWithdrawalCards(
                                    context,
                                    walletRepository,
                                    pendingWithdrawals,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _buildSpeakerBreakdownSection(
                                title: 'Credited by Speaker',
                                rows: creditedRows,
                                positive: true,
                              ),
                              const SizedBox(height: 12),
                              _buildSpeakerBreakdownSection(
                                title: 'Pending by Speaker',
                                rows: pendingRows,
                                positive: false,
                              ),
                              const SizedBox(height: 12),
                              _sectionCard(
                                title: 'Recent Incoming Calls',
                                subtitle: 'Latest listener-side call outcomes.',
                                children: [
                                  _buildRecentIncomingCallsSection(ended),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _buildLedgerSection(
                                walletRepository,
                                ledgerDocs,
                              ),
                              const SizedBox(height: 12),
                              _buildPaymentOrdersSection(
                                walletRepository,
                                paymentOrders,
                              ),
                              const SizedBox(height: 12),
                              _buildWithdrawalHistorySection(
                                walletRepository,
                                withdrawalDocs,
                              ),
                              const SizedBox(height: 12),
                              _buildLaunchDisclosureSection(),
                              const SizedBox(height: 12),
                              _sectionCard(
                                title: 'Current Payment Phase',
                                children: const [
                                  Text(
                                    'This build supports internal wallet visibility, call settlement visibility, wallet ledger, test payment orders, test top-ups, and manual/test withdrawal requests.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'It should not be described as full live production payments yet.',
                                    style: TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                                  SizedBox(height: 6),
                                  Text(
                                    'Next commercial step: complete end-to-end validation, then reconnect real checkout, webhook verification, and final payout processing with founder/legal/payment readiness.',
                                    style: TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
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
          );
        },
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
  State<_WithdrawalRequestSheet> createState() => _WithdrawalRequestSheetState();
}

class _WithdrawalRequestSheetState extends State<_WithdrawalRequestSheet> {
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
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
      setState(() => _error = 'Minimum withdrawal is ₹50.');
      return;
    }

    if (amount > widget.me.earningsCredits) {
      setState(
        () => _error = 'You can request up to ₹${widget.me.earningsCredits}.',
      );
      return;
    }

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
      });

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = (e.message ?? 'Withdrawal request failed.').trim();
      });
    } catch (_) {
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
                  'Test/manual mode only. No real payout will happen yet.\nAvailable earned balance: ₹${widget.me.earningsCredits}',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    hintText: 'Enter amount in ₹',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  maxLength: 200,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Optional payout note',
                    hintText: 'Example: UPI id / bank note / test note',
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