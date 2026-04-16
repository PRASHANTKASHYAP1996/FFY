import 'package:flutter/material.dart';

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
    if (isShortAnswered) return const Color(0xFFD97706);
    if (isIncoming) {
      return amount <= 0 ? const Color(0xFF15803D) : const Color(0xFF16A34A);
    }
    return amount <= 0 ? const Color(0xFFD97706) : const Color(0xFFDC2626);
  }

  Color _badgeColor(CallHistoryItem item, String badgeText) {
    if (badgeText == 'Missed' || badgeText == 'Not answered') {
      return const Color(0xFFDC2626);
    }

    if (badgeText == 'Received <60s' || badgeText == 'Call <60s') {
      return const Color(0xFFD97706);
    }

    if (item.isIncoming) {
      if (badgeText == 'Credited') return const Color(0xFF15803D);
      if (badgeText == 'Pending') return const Color(0xFFD97706);
      return const Color(0xFF15803D);
    }

    if (badgeText == 'Paid') return const Color(0xFFDC2626);
    return const Color(0xFFD97706);
  }

  Color _cardAccentColor(CallHistoryItem item) {
    if (item.isMissed) return const Color(0xFFDC2626);
    if (item.isUnderOneMinuteAnswered) return const Color(0xFFD97706);
    if (item.isIncoming) return const Color(0xFF15803D);
    return const Color(0xFF4F46E5);
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

  String _titleForItem(CallHistoryItem item) {
    if (item.isMissed) {
      return item.isIncoming ? 'Missed incoming call' : 'Unanswered outgoing call';
    }

    if (item.isUnderOneMinuteAnswered) {
      return item.isIncoming
          ? 'Received call under 60s'
          : 'Outgoing call under 60s';
    }

    return item.isIncoming
        ? 'Incoming call'
        : 'Outgoing call';
  }

  String _subtitleForItem(CallHistoryItem item) {
    return item.isIncoming ? 'From: ${item.name}' : 'To: ${item.name}';
  }

  Widget _metaChip({
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Color _callStateColor(CallSessionManager session) {
    switch (session.state) {
      case CallState.connected:
        return const Color(0xFF15803D);
      case CallState.reconnecting:
        return const Color(0xFFD97706);
      case CallState.failed:
      case CallState.ending:
      case CallState.ended:
        return const Color(0xFFDC2626);
      case CallState.preparing:
      case CallState.joining:
        return const Color(0xFF4F46E5);
      case CallState.idle:
        return const Color(0xFF6B7280);
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
            ? (((call['calleeName'] ?? '') as Object).toString().trim().isNotEmpty
                ? (call['calleeName'] as String).trim()
                : 'Listener')
            : (((call['callerName'] ?? '') as Object).toString().trim().isNotEmpty
                ? (call['callerName'] as String).trim()
                : 'User');

        final mm = (session.seconds ~/ 60).toString().padLeft(2, '0');
        final ss = (session.seconds % 60).toString().padLeft(2, '0');
        final safeStateColor = _callStateColor(session);
        final safeStateLabel = _callStateLabel(session);

        final showDuration = session.state == CallState.connected ||
            session.state == CallState.reconnecting;

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
                        'With $otherName • $safeStateLabel',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        showDuration ? 'Duration $mm:$ss' : 'Connecting...',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
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
    final title = _titleForItem(item);
    final subtitle = _subtitleForItem(item);
    final durationDetailed =
        historyRepository.durationLabelDetailed(item.seconds);
    final durationCompact =
        historyRepository.durationLabelCompact(item.seconds);
    final dateLabel = _dateLabel(item.endedAtMs);
    final timeLabel = _timeLabel(item.endedAtMs);

    final amountLabel = historyRepository.amountLabel(
      isIncoming: item.isIncoming,
      amount: item.amount,
    );

    final badgeText = historyRepository.badgeText(item);
    final secondaryStatus = historyRepository.secondaryStatus(item);

    final amountColor = _amountColor(
      isIncoming: item.isIncoming,
      amount: item.amount,
      isMissed: item.isMissed,
      isShortAnswered: item.isUnderOneMinuteAnswered,
    );

    final badgeColor = _badgeColor(item, badgeText);
    final accentColor = _cardAccentColor(item);

    final icon = item.isMissed
        ? (item.isIncoming ? Icons.call_missed : Icons.phone_missed)
        : item.isIncoming
            ? Icons.call_received
            : Icons.call_made;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: accentColor.withValues(alpha: 0.12),
                  child: Icon(
                    icon,
                    color: accentColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFF374151),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  amountLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: amountColor,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Duration: $durationDetailed',
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
                    color: badgeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.30),
                    ),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
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
                secondaryStatus,
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _metaChip(
                  text: dateLabel,
                  color: const Color(0xFF4F46E5),
                ),
                _metaChip(
                  text: timeLabel,
                  color: const Color(0xFF7C3AED),
                ),
                _metaChip(
                  text: durationCompact,
                  color: accentColor,
                ),
              ],
            ),
          ],
        ),
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
        const Icon(
          Icons.history_rounded,
          size: 56,
          color: Color(0xFF9CA3AF),
        ),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            'No call history yet.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Your past incoming and outgoing calls will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF6B7280),
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

    return Scaffold(
      appBar: AppBar(title: const Text('Call History')),
      body: StreamBuilder<List<CallHistoryItem>>(
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            children: [
              _activeCallBanner(context, session),
              if (session.active) const SizedBox(height: 12),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'History Overview',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'A cleaner summary of your recent calls and outcomes.',
                        style: TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _statTile(
                        label: 'Total calls',
                        value: '${items.length}',
                        subtitle: 'All recorded call history',
                        highlight: true,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _statTile(
                              label: 'Incoming',
                              value: '$incomingCount',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _statTile(
                              label: 'Outgoing',
                              value: '$outgoingCount',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _statTile(
                              label: 'Missed',
                              value: '$missedCount',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _statTile(
                              label: 'Under 60s',
                              value: '$shortCount',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _statTile(
                        label: 'Paid / Credited',
                        value: '$paidCount',
                        subtitle: 'Calls that created billing or credit result',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _summaryChip('State', session.state.name),
                          _summaryChip('Incoming', '$incomingCount'),
                          _summaryChip('Outgoing', '$outgoingCount'),
                          _summaryChip('Missed', '$missedCount'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              ...List.generate(items.length, (i) {
                final item = items[i];
                return Padding(
                  padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 10),
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
    );
  }
}