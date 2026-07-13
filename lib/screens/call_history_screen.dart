import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_palette.dart';
import '../repositories/history_repository.dart';
import '../services/call_session_manager.dart';
import 'voice_call_screen.dart';

class CallHistoryScreen extends StatelessWidget {
  const CallHistoryScreen({super.key});

  Color _amountColor({
    required bool isIncoming,
    required int amount,
    required bool isMissed,
    required bool isShortAnswered,
  }) {
    if (isMissed) return const Color(0xFFDC2626);
    if (isShortAnswered) return const Color(0xFFF59E0B);
    if (isIncoming) {
      return AppPalette.online;
    }
    return amount <= 0 ? const Color(0xFFF59E0B) : const Color(0xFFDC2626);
  }

  Color _cardAccentColor(CallHistoryItem item) {
    if (item.isMissed) return const Color(0xFFDC2626);
    if (item.isUnderOneMinuteAnswered) return const Color(0xFFF59E0B);
    if (item.isIncoming) return AppPalette.online;
    return AppPalette.blue;
  }

  Widget _summaryChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppPalette.blueTint,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppPalette.blue.withValues(alpha: 0.22),
        ),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: AppPalette.blue,
          fontSize: 12,
        ),
      ),
    );
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _monthShort(int month) {
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
    return (month >= 1 && month <= 12) ? months[month - 1] : 'Unknown';
  }

  String _dateLabel(int ms) {
    if (ms <= 0) return 'Unknown date';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day} ${_monthShort(dt.month)} ${dt.year}';
  }

  String _timeLabel(int ms) {
    if (ms <= 0) return 'Unknown time';

    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hour24 = dt.hour;
    final minute = _two(dt.minute);
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;

    return '$hour12:$minute $amPm';
  }

  String _statusLabelForItem(CallHistoryItem item) {
    if (item.isMissed) {
      final reason = '${item.endedReason} ${item.rejectedReason}'.toLowerCase();
      if (reason.contains('cancel')) return 'Cancelled';
      if (reason.contains('reject') || reason.contains('decline')) {
        return 'Declined';
      }
      if (reason.contains('timeout') || reason.contains('no_answer')) {
        return 'Missed';
      }
      return 'Missed';
    }

    if (item.isPaidCall) {
      return item.isIncoming
          ? (item.listenerCredited ? 'Credited' : 'Pending')
          : 'Paid';
    }

    if (item.isFreeAnsweredCall) return 'Free';
    return item.isIncoming ? 'Received' : 'Completed';
  }

  IconData _directionIconForItem(CallHistoryItem item) {
    if (item.isMissed) {
      return item.isIncoming
          ? Icons.call_missed_rounded
          : Icons.phone_missed_rounded;
    }

    return item.isIncoming
        ? Icons.call_received_rounded
        : Icons.call_made_rounded;
  }

  Widget _historyAvatar(CallHistoryItem item, Color accentColor) {
    final safeName = item.name.trim();
    final initial =
        safeName.isEmpty ? '?' : safeName.substring(0, 1).toUpperCase();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppPalette.blue,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.28),
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            initial,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: AppPalette.card,
              shape: BoxShape.circle,
              border: Border.all(color: AppPalette.card, width: 2),
            ),
            child: Icon(
              _directionIconForItem(item),
              color: accentColor,
              size: 13,
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusPill({
    required String label,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  Color _callStateColor(CallSessionManager session) {
    switch (session.state) {
      case CallState.connected:
        return AppPalette.online;
      case CallState.reconnecting:
        return const Color(0xFFF59E0B);
      case CallState.failed:
      case CallState.ending:
      case CallState.ended:
        return const Color(0xFFDC2626);
      case CallState.preparing:
      case CallState.joining:
        return AppPalette.blue;
      case CallState.idle:
        return AppPalette.textSecondary;
    }
  }

  String _callStateLabel(CallSessionManager session) {
    switch (session.state) {
      case CallState.preparing:
        return 'Preparing call...';
      case CallState.joining:
        return 'Joining voice channel...';
      case CallState.connected:
        return session.status;
      case CallState.reconnecting:
        return session.status;
      case CallState.ending:
        return 'Ending call...';
      case CallState.ended:
        return 'Call ended';
      case CallState.failed:
        return session.status.isEmpty ? 'Call failed' : session.status;
      case CallState.idle:
        return session.status;
    }
  }

  Widget _overviewMetric({
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showOverviewBreakdown({
    required BuildContext context,
    required int totalCount,
    required int incomingCount,
    required int outgoingCount,
    required int missedCount,
    required int freeCount,
    required int paidCount,
  }) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
          backgroundColor: Colors.transparent,
          child: Container(
            decoration: AppPalette.cardDecoration(radius: 18),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Call Overview',
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.blue,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$totalCount total',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    _overviewMetric(
                      label: 'Incoming',
                      value: '$incomingCount',
                    ),
                    _overviewMetric(
                      label: 'Outgoing',
                      value: '$outgoingCount',
                    ),
                    _overviewMetric(label: 'Missed', value: '$missedCount'),
                    _overviewMetric(label: 'Free', value: '$freeCount'),
                    _overviewMetric(label: 'Paid', value: '$paidCount'),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _overviewButton({
    required BuildContext context,
    required int totalCount,
    required int incomingCount,
    required int outgoingCount,
    required int missedCount,
    required int freeCount,
    required int paidCount,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _showOverviewBreakdown(
        context: context,
        totalCount: totalCount,
        incomingCount: incomingCount,
        outgoingCount: outgoingCount,
        missedCount: missedCount,
        freeCount: freeCount,
        paidCount: paidCount,
      ),
      child: Container(
        decoration: AppPalette.cardDecoration(radius: 18),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppPalette.blueTint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.analytics_outlined,
                color: AppPalette.blue,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total calls',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                    ),
                  ),
                  SizedBox(height: 1),
                  Text(
                    'Overview',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: AppPalette.blue,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$totalCount total',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: AppPalette.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeCallBanner(
    BuildContext context,
    CallSessionManager session,
  ) {
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
        final safeStateColor = _callStateColor(session);
        final safeStateLabel = _callStateLabel(session);

        final showDuration = session.state == CallState.connected ||
            session.state == CallState.reconnecting;

        return Container(
          decoration: AppPalette.cardDecoration(radius: 18),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppPalette.online.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.call,
                  color: AppPalette.online,
                ),
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
                        color: AppPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'With $otherName - $safeStateLabel',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      showDuration ? 'Duration $mm:$ss' : 'Connecting...',
                      style: const TextStyle(
                        color: AppPalette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: safeStateColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: safeStateColor.withValues(alpha: 0.24),
                        ),
                      ),
                      child: Text(
                        'State: ${session.state.name}',
                        style: TextStyle(
                          color: safeStateColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
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
        );
      },
    );
  }

  Widget _historyCard(
    BuildContext context,
    CallHistoryItem item,
    HistoryRepository historyRepository,
  ) {
    final durationLabel = historyRepository.durationLabelDetailed(item.seconds);
    final dateLabel = _dateLabel(item.endedAtMs);
    final timeLabel = _timeLabel(item.endedAtMs);
    final statusLabel = _statusLabelForItem(item);

    final amountLabel = historyRepository.amountLabel(
      isIncoming: item.isIncoming,
      amount: item.amount,
    );

    final amountColor = _amountColor(
      isIncoming: item.isIncoming,
      amount: item.amount,
      isMissed: item.isMissed,
      isShortAnswered: item.isUnderOneMinuteAnswered,
    );

    final accentColor = _cardAccentColor(item);
    final directionIcon = _directionIconForItem(item);

    return Container(
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        children: [
          _historyAvatar(item, accentColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.schedule_rounded,
                      size: 12,
                      color: AppPalette.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '$dateLabel, $timeLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppPalette.textSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const Icon(
                      Icons.timer_outlined,
                      size: 12,
                      color: AppPalette.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      durationLabel,
                      style: const TextStyle(
                        color: AppPalette.textSecondary,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amountLabel,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: amountColor,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              _statusPill(
                label: statusLabel,
                color: accentColor,
                icon: directionIcon,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyState(CallSessionManager session, BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _activeCallBanner(context, session),
        if (session.active) const SizedBox(height: 12),
        const SizedBox(height: 80),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppPalette.blueTint,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.history_rounded,
            size: 34,
            color: AppPalette.blue,
          ),
        ),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            'No call history yet.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Your past incoming and outgoing calls will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final historyRepository = HistoryRepository.instance;
    final session = CallSessionManager.instance;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppPalette.pageBg,
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: AppPalette.textPrimary,
          surfaceTintColor: Colors.transparent,
          title: const Text('Call History'),
        ),
        body: DecoratedBox(
          decoration: const BoxDecoration(color: AppPalette.pageBg),
          child: StreamBuilder<List<CallHistoryItem>>(
            stream: historyRepository.watchMyCallHistory(),
            builder: (_, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final items = snap.data!;

              if (historyRepository.isEmpty(items)) {
                return _emptyState(session, context);
              }

              final incomingCount = items.where((e) => e.isIncoming).length;
              final outgoingCount = items.where((e) => !e.isIncoming).length;
              final missedCount = historyRepository.missedCount(items);
              final shortCount = historyRepository.shortAnsweredCount(items);
              final paidCount = historyRepository.paidCount(items);

              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                children: [
                  _activeCallBanner(context, session),
                  if (session.active) const SizedBox(height: 12),
                  _overviewButton(
                    context: context,
                    totalCount: items.length,
                    incomingCount: incomingCount,
                    outgoingCount: outgoingCount,
                    missedCount: missedCount,
                    freeCount: shortCount,
                    paidCount: paidCount,
                  ),
                  if (session.active) ...[
                    const SizedBox(height: 8),
                    _summaryChip('State', session.state.name),
                  ],
                  const SizedBox(height: 12),
                  ...List.generate(items.length, (i) {
                    final item = items[i];
                    return Padding(
                      padding: EdgeInsets.only(
                          bottom: i == items.length - 1 ? 0 : 8),
                      child: _historyCard(
                        context,
                        item,
                        historyRepository,
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
