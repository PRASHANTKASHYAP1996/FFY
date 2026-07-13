import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_palette.dart';
import '../repositories/wallet_repository.dart';
import '../repositories/user_repository.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/call_model.dart';
import '../shared/wallet_amount_formatter.dart';
import 'voice_call_screen.dart';

class EarningsScreen extends StatelessWidget {
  const EarningsScreen({super.key});

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

  String _durationLabel(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;
    if (safeSeconds < 60) return 'Under 60s (Free)';
    final fullMinutes = safeSeconds ~/ 60;
    return '$fullMinutes min';
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
          padding: const EdgeInsets.all(14),
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
                        color: AppPalette.textPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'With $otherName - $safeStateLabel',
                      style: const TextStyle(
                        color: AppPalette.textSecondary,
                        fontWeight: FontWeight.w600,
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
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: safeStateColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: safeStateColor.withValues(alpha: 0.30),
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

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(18),
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
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
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
        color: highlight ? AppPalette.blueTint : AppPalette.feedBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlight
              ? AppPalette.blue.withValues(alpha: 0.24)
              : AppPalette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: highlight ? 24 : 20,
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
        ),
      ),
    );
  }

  Widget _noticeChip(
    String text, {
    Color? bg,
    Color? fg,
  }) {
    final chipBg = bg ?? AppPalette.feedBg;
    final chipFg = fg ?? AppPalette.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: chipFg.withValues(alpha: 0.24)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: chipFg,
        ),
      ),
    );
  }

  Widget _callCard(CallModel call) {
    final callerName =
        call.callerName.trim().isEmpty ? 'Unknown' : call.callerName.trim();
    final payout = call.listenerPayout;
    final settlementDone = call.settled || call.listenerCredited;
    final settlementColor = payout <= 0
        ? AppPalette.textSecondary
        : settlementDone
            ? AppPalette.online
            : const Color(0xFFF59E0B);

    final settlementLabel = payout <= 0
        ? 'Free'
        : settlementDone
            ? 'Credited'
            : 'Pending';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  callerName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              Text(
                formatSignedWalletAmount(payout),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: settlementColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Duration: ${_durationLabel(call.endedSeconds)}',
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = CallSessionManager.instance;
    final walletRepository = WalletRepository.instance;
    final userRepository = UserRepository.instance;

    return StreamBuilder<AppUserModel?>(
      stream: userRepository.watchMe(),
      builder: (_, userSnap) {
        if (!userSnap.hasData) {
          return const Scaffold(
            backgroundColor: AppPalette.pageBg,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final me = userSnap.data!;
        final blocked = List<String>.from(me.blocked);

        return StreamBuilder<List<CallModel>>(
          stream: walletRepository.watchMyListenerCalls(limit: 100),
          builder: (_, callsSnap) {
            final allCalls = callsSnap.data ?? const <CallModel>[];
            final endedCalls = walletRepository.endedCalls(allCalls);

            final totalCredited =
                walletRepository.totalListenerCredited(endedCalls);
            final totalPending =
                walletRepository.totalListenerPending(endedCalls);
            final freeCalls = walletRepository.freeCalls(endedCalls).length;
            final paidCalls = walletRepository.paidCalls(endedCalls).length;
            final settledCalls =
                endedCalls.where((e) => e.settled || e.listenerCredited).length;

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
                  title: const Text('Earnings & Safety'),
                ),
                body: Theme(
                  data: AppPalette.lightSheetTheme(context),
                  child: DecoratedBox(
                    decoration: const BoxDecoration(color: AppPalette.pageBg),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _activeCallBanner(context, session),
                        if (session.active) const SizedBox(height: 12),
                        _sectionCard(
                          title: 'Earnings overview',
                          subtitle:
                              'Listener-side earnings and settlement overview.',
                          children: [
                            _statTile(
                              label: 'Current earnings credits',
                              value: formatWalletAmount(me.earningsCredits),
                              subtitle: 'Visible earned balance in app',
                              highlight: true,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: _statTile(
                                    label: 'Credited total',
                                    value: formatWalletAmount(totalCredited),
                                    subtitle: 'Settled listener earnings',
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _statTile(
                                    label: 'Pending total',
                                    value: formatWalletAmount(totalPending),
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
                                    'Ended calls', '${endedCalls.length}'),
                                _summaryChip('Paid calls', '$paidCalls'),
                                _summaryChip('Free calls', '$freeCalls'),
                                _summaryChip('Settled', '$settledCalls'),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _sectionCard(
                          title: 'Payout availability',
                          subtitle:
                              'See what support options are currently available for withdrawals.',
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _noticeChip(
                                  'Withdrawal requests',
                                  bg: const Color(0xFFF59E0B)
                                      .withValues(alpha: 0.14),
                                  fg: const Color(0xFFB45309),
                                ),
                                _noticeChip(
                                  'Processing may vary',
                                  bg: const Color(0xFFDC2626)
                                      .withValues(alpha: 0.12),
                                  fg: const Color(0xFFDC2626),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'This screen shows earnings and settlement status. '
                              'Withdrawal requests are handled through the support '
                              'options currently available in Friendify.',
                              style: TextStyle(
                                color: AppPalette.textSecondary,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _sectionCard(
                          title: 'Recent earning calls',
                          subtitle: 'Latest listener-side earning outcomes.',
                          children: endedCalls.isEmpty
                              ? const [
                                  Text(
                                    'No completed calls yet.',
                                    style: TextStyle(
                                      color: AppPalette.textSecondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ]
                              : endedCalls.take(12).map(_callCard).toList(),
                        ),
                        const SizedBox(height: 12),
                        _sectionCard(
                          title: 'Blocked users',
                          subtitle:
                              'People you have blocked from your own account side.',
                          children: [
                            if (blocked.isEmpty)
                              const Text(
                                'No blocked users.',
                                style: TextStyle(
                                  color: AppPalette.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            else
                              ...blocked.map(
                                (id) => ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const CircleAvatar(
                                    backgroundColor: Color(0xFFDC2626),
                                    child: Icon(
                                      Icons.block,
                                      color: Colors.white,
                                    ),
                                  ),
                                  title: Text(
                                    id,
                                    style: const TextStyle(
                                      color: AppPalette.textPrimary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  trailing: TextButton(
                                    onPressed: () =>
                                        FirestoreService.unblockUser(id),
                                    child: const Text('Unblock'),
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
          },
        );
      },
    );
  }
}
