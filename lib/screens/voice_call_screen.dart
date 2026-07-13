import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/constants/call_timing.dart';
import '../core/constants/firestore_paths.dart';
import '../core/theme/app_palette.dart';
import '../services/call_session_manager.dart';
import '../services/call_wake_lock_service.dart';
import '../services/firestore_service.dart';
import '../shared/wallet_amount_formatter.dart';
import 'crisis_help_screen.dart';
import 'rate_call_screen.dart';

class VoiceCallScreen extends StatefulWidget {
  static const String routeName = '/voice-call';

  const VoiceCallScreen({super.key});

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with WidgetsBindingObserver {
  final CallSessionManager _session = CallSessionManager.instance;

  bool _reporting = false;
  bool _uiClosing = false;
  bool _endPressed = false;
  bool _handledEndedFlow = false;
  bool _showingEndedUi = false;
  bool _endedFlowQueued = false;

  DocumentReference<Map<String, dynamic>>? _lastCallRef;
  bool _lastIAmCaller = false;
  Map<String, dynamic> _lastCallData = <String, dynamic>{};

  bool _navigatorHasPendingTransitions(NavigatorState navigator) {
    final binding = SchedulerBinding.instance;
    return navigator.userGestureInProgress ||
        binding.transientCallbackCount > 0;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(CallWakeLockService.instance.enable('voice_call'));
    _captureSessionSnapshot();
    _session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(CallWakeLockService.instance.release('voice_call'));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_session.active) return;

    switch (state) {
      case AppLifecycleState.resumed:
        _session.recoverAudioFlow('app_resumed');
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _captureSessionSnapshot() {
    if (_session.callDocRef != null) {
      _lastCallRef = _session.callDocRef;
    }
    _lastIAmCaller = _session.iAmCaller;
    _lastCallData = Map<String, dynamic>.from(_session.call);
  }

  void _onSessionChanged() {
    if (!mounted) return;

    if (_session.active) {
      _captureSessionSnapshot();

      if (_endPressed && !_session.ending) {
        setState(() => _endPressed = false);
      }
      return;
    }

    if (_handledEndedFlow) return;
    _handledEndedFlow = true;
    _queueEndedFlow();
  }

  void _queueEndedFlow() {
    if (_endedFlowQueued || _showingEndedUi) return;
    _endedFlowQueued = true;

    unawaited(() async {
      try {
        final settled = await _waitForNavigatorToSettle();
        if (!settled || !mounted) {
          _handledEndedFlow = false;
          return;
        }
        await _handleEndedFlow();
      } finally {
        _endedFlowQueued = false;
      }
    }());
  }

  Future<bool> _waitForNavigatorToSettle() async {
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return false;

    var stableFrames = 0;
    for (int attempt = 0; attempt < 24; attempt++) {
      if (!mounted) return false;

      final route = ModalRoute.of(context);
      final navigatorBusy = _navigatorHasPendingTransitions(navigator);
      final routeAnimating = (route?.animation?.isAnimating ?? false) ||
          (route?.secondaryAnimation?.isAnimating ?? false);
      final routeCurrent = route?.isCurrent ?? true;
      final routeActive = route?.isActive ?? true;

      if (!navigatorBusy && !routeAnimating && routeCurrent && routeActive) {
        stableFrames += 1;
        if (stableFrames >= 3) {
          await WidgetsBinding.instance.endOfFrame;
          return mounted && !_navigatorHasPendingTransitions(navigator);
        }
      } else {
        stableFrames = 0;
      }

      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    return mounted && !_navigatorHasPendingTransitions(navigator);
  }

  Future<void> _handleEndedFlow() async {
    if (_showingEndedUi) return;
    _showingEndedUi = true;

    final ref = _lastCallRef;
    Map<String, dynamic> finalCall = Map<String, dynamic>.from(_lastCallData);

    if (ref != null) {
      try {
        final snap = await ref.get();
        if (snap.exists) {
          finalCall = snap.data() ?? finalCall;
        }
      } catch (_) {
        // keep cached data if fetch fails
      }
    }

    if (!mounted) return;

    final wasAnswered = _wasAnswered(finalCall);
    final otherName = _otherPartyNameFromCall(finalCall);
    final seconds = _bestSeconds(finalCall);
    final speakerRate =
        _safeInt(finalCall[FirestorePaths.fieldSpeakerRate], fallback: 5);
    final listenerRate = _safeInt(
      finalCall[FirestorePaths.fieldListenerPayoutRate],
      fallback: 4,
    );
    final speakerCharge =
        _safeInt(finalCall[FirestorePaths.fieldSpeakerCharge]);
    final listenerPayout =
        _safeInt(finalCall[FirestorePaths.fieldListenerPayout]);
    final endedReason = _safeString(finalCall[FirestorePaths.fieldEndedReason]);
    final rejectedReason =
        _safeString(finalCall[FirestorePaths.fieldRejectedReason]);

    await _showEndedSummarySheet(
      otherName: otherName,
      wasAnswered: wasAnswered,
      seconds: seconds,
      speakerRate: speakerRate,
      listenerRate: listenerRate,
      speakerCharge: speakerCharge,
      listenerPayout: listenerPayout,
      endedReason: endedReason,
      rejectedReason: rejectedReason,
    );

    if (!mounted) return;

    if (ref != null && wasAnswered) {
      try {
        final settled = await _waitForNavigatorToSettle();
        if (!settled || !mounted) return;

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RateCallScreen(
              callDocRef: ref,
              iAmCaller: _lastIAmCaller,
            ),
          ),
        );
      } catch (_) {
        // ignore rating open failure
      }
    }

    if (!mounted) return;

    final settled = await _waitForNavigatorToSettle();
    if (!settled || !mounted) return;

    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(true);
    }
  }

  Future<void> _showEndedSummarySheet({
    required String otherName,
    required bool wasAnswered,
    required int seconds,
    required int speakerRate,
    required int listenerRate,
    required int speakerCharge,
    required int listenerPayout,
    required String endedReason,
    required String rejectedReason,
  }) async {
    final fullMinutes = seconds >= 60 ? (seconds ~/ 60) : 0;

    String title;
    String subtitle;

    if (!wasAnswered) {
      title = 'Call not completed';
      subtitle = _humanizeReason(
        rejectedReason.isNotEmpty ? rejectedReason : endedReason,
      );
    } else {
      title = 'Call ended';
      subtitle = 'Your call with $otherName has finished.';
    }

    final amountLabel = _lastIAmCaller
        ? 'Charged: ${formatWalletAmount(speakerCharge)}'
        : 'Earned: ${formatWalletAmount(listenerPayout)}';

    final rateLabel = _lastIAmCaller
        ? 'Rate: ${formatWalletAmount(speakerRate)}/min'
        : 'Rate: ${formatWalletAmount(listenerRate)}/min';

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) {
        return Theme(
          data: AppPalette.lightSheetTheme(sheetContext),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          _summaryRow('Person', otherName),
                          const SizedBox(height: 8),
                          _summaryRow('Duration', _durationLabel(seconds)),
                          const SizedBox(height: 8),
                          _summaryRow(
                            'Billable minutes',
                            wasAnswered ? '$fullMinutes' : '0',
                          ),
                          const SizedBox(height: 8),
                          _summaryRow('Pricing', rateLabel),
                          const SizedBox(height: 8),
                          _summaryRow('Result', amountLabel),
                          if (!wasAnswered) ...[
                            const SizedBox(height: 8),
                            _summaryRow(
                              'Reason',
                              _humanizeReason(
                                rejectedReason.isNotEmpty
                                    ? rejectedReason
                                    : endedReason,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (wasAnswered)
                    const Text(
                      'Next step: leave a rating and optional review.',
                      style: TextStyle(
                        color: Color(0xFF4F46E5),
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    )
                  else
                    const Text(
                      'No billing applies because the call was not completed.',
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(wasAnswered ? 'Continue to Rating' : 'Done'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _summaryRow(String label, String value) {
    return Row(
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
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  bool _wasAnswered(Map<String, dynamic> call) {
    final startedAt = call[FirestorePaths.fieldStartedAt];
    if (startedAt != null) return true;

    final endedSeconds = _safeInt(call[FirestorePaths.fieldEndedSeconds]);
    if (endedSeconds > 0) return true;

    final status = _safeString(call[FirestorePaths.fieldStatus]);
    if (status == FirestorePaths.statusAccepted) return true;

    return false;
  }

  int _bestSeconds(Map<String, dynamic> call) {
    final explicitEndedSeconds = _safeInt(
      call[FirestorePaths.fieldEndedSeconds],
      fallback: -1,
    );
    if (explicitEndedSeconds >= 0) {
      return explicitEndedSeconds;
    }

    final startedAt = call[FirestorePaths.fieldStartedAt];
    final endedAt = call[FirestorePaths.fieldEndedAt];

    if (startedAt is Timestamp && endedAt is Timestamp) {
      final startedMs = startedAt.toDate().millisecondsSinceEpoch;
      final endedMs = endedAt.toDate().millisecondsSinceEpoch;
      if (endedMs >= startedMs) {
        final value = ((endedMs - startedMs) / 1000).floor();
        return value < 0 ? 0 : value;
      }
    }

    return 0;
  }

  String _durationLabel(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;

    if (safeSeconds <= 0) return '0s';

    final hours = safeSeconds ~/ 3600;
    final mins = (safeSeconds % 3600) ~/ 60;
    final secs = safeSeconds % 60;

    if (hours > 0) {
      if (secs == 0) return '${hours}h ${mins}m';
      return '${hours}h ${mins}m ${secs}s';
    }

    if (mins > 0) {
      if (secs == 0) return '${mins}m';
      return '${mins}m ${secs}s';
    }

    return '${secs}s';
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

  String _otherPartyName() {
    final call = _session.call;
    return _otherPartyNameFromCall(call);
  }

  String _otherPartyNameFromCall(Map<String, dynamic> call) {
    final callerName = _safeString(
      call[FirestorePaths.fieldCallerName],
      fallback: 'User',
    );
    final calleeName = _safeString(
      call[FirestorePaths.fieldCalleeName],
      fallback: 'Listener',
    );

    if (_lastIAmCaller) {
      return calleeName.isEmpty ? 'Listener' : calleeName;
    }
    return callerName.isEmpty ? 'User' : callerName;
  }

  String _otherPartyId() {
    final call = _session.call;
    final callerId = _safeString(call[FirestorePaths.fieldCallerId]);
    final calleeId = _safeString(call[FirestorePaths.fieldCalleeId]);

    return _session.iAmCaller ? calleeId : callerId;
  }

  Color _statusColor() {
    final safeStatus = _session.status.toLowerCase();

    if (safeStatus.contains('reconnecting')) {
      return const Color(0xFFFFC26B);
    }
    if (_session.remoteConnected) {
      return AppPalette.callSuccess;
    }
    if (safeStatus.contains('failed') ||
        safeStatus.contains('denied') ||
        safeStatus.contains('lost') ||
        safeStatus.contains('ending')) {
      return AppPalette.callDanger;
    }
    return AppPalette.callAccent;
  }

  Widget _infoChip(
    String text, {
    Color bg = const Color(0x22FFFFFF),
    Color fg = AppPalette.callAccent,
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

  Widget _statTile({
    required String label,
    required String value,
    String? subtitle,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: color.withValues(alpha: 0.30),
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
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: color,
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

  Widget _callControlButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filled(
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.white.withValues(alpha: 0.08),
              disabledForegroundColor: Colors.white38,
              fixedSize: const Size(54, 54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: Icon(icon),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _waveformBar(int index) {
    final heights = <double>[22, 48, 30, 64, 38, 78, 42, 58, 34, 46, 26];
    return Container(
      width: 3,
      height: heights[index % heights.length],
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  Future<void> _showSnack(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _reportBlock() async {
    if (_reporting) return;

    final otherId = _otherPartyId();
    final otherName = _otherPartyName();
    final callId = _session.callDocRef?.id.trim() ?? '';

    if (otherId.isEmpty) {
      await _showSnack('Unable to identify the other user.');
      return;
    }

    if (callId.isEmpty) {
      await _showSnack('Unable to identify this call.');
      return;
    }

    final reason = await _reportReasonSheet(context);
    if (!mounted) return;
    if (reason == null || reason.trim().isEmpty) return;

    setState(() => _reporting = true);

    try {
      await FirestoreService.report(
        reportedUserId: otherId,
        callId: callId,
        reason: reason,
      );
      await FirestoreService.blockUser(otherId);

      await _showSnack('Reported & blocked $otherName');
    } catch (_) {
      await _showSnack('Report failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _reporting = false);
      }
    }
  }

  Future<void> _endCall() async {
    if (_endPressed || _session.ending || !_session.active) return;

    setState(() => _endPressed = true);

    try {
      await _session.endCall(
        reason: FirestorePaths.reasonUserEnd,
      );
    } finally {
      if (mounted && _session.active && !_session.ending) {
        setState(() => _endPressed = false);
      }
    }
  }

  Future<void> _closeUiKeepCallRunning() async {
    if (!mounted) return;
    if (_uiClosing) return;

    if (!_session.active) {
      final settled = await _waitForNavigatorToSettle();
      if (!settled || !mounted) return;

      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
      }
      return;
    }

    _uiClosing = true;
    try {
      final settled = await _waitForNavigatorToSettle();
      if (!settled || !mounted) return;

      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
      }
    } finally {
      _uiClosing = false;
    }
  }

  Future<String?> _reportReasonSheet(BuildContext context) {
    final reasons = <String>[
      'Harassment / Abuse',
      'Sexual content / Flirting',
      'Threats / Violence',
      'Scam / Money request',
      'Hate speech',
      'Other',
    ];

    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) => Theme(
        data: AppPalette.lightSheetTheme(sheetContext),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Report / Block',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 12),
                ...reasons.map(
                  (r) => ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    title: Text(r),
                    onTap: () => Navigator.pop(sheetContext, r),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _humanizeReason(String value) {
    final safe = value.trim().toLowerCase();

    switch (safe) {
      case 'timeout':
        return 'Timed out';
      case 'busy':
        return 'User was busy';
      case 'caller_cancel':
        return 'Caller cancelled';
      case 'caller_timeout':
        return 'No answer';
      case 'caller_timeout_cleanup':
        return 'No answer';
      case 'callee_reject':
        return 'Rejected';
      case 'callee_reject_callkit':
        return 'Rejected';
      case 'callkit_ended':
        return 'Ended';
      case 'invalid':
        return 'Invalid call';
      case 'user_end':
        return 'Ended normally';
      case 'connection_lost':
        return 'Connection lost';
      case 'remote_left':
        return 'Other user left';
      case 'server_timeout':
        return 'Timed out';
      case 'stale_timeout':
        return 'Expired';
      case 'credit_limit_reached':
        return 'Credit limit reached';
      case '':
        return 'Call closed';
      default:
        return safe.replaceAll('_', ' ');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _session,
      builder: (_, __) {
        final seconds = _session.seconds;
        final mm = (seconds ~/ 60).toString().padLeft(2, '0');
        final ss = (seconds % 60).toString().padLeft(2, '0');

        final call = _session.call;
        final speakerRate = _safeInt(
          call[FirestorePaths.fieldSpeakerRate],
          fallback: 5,
        );
        final listenerRate = _safeInt(
          call[FirestorePaths.fieldListenerPayoutRate],
          fallback: 4,
        );
        final fullMinutes = _session.fullMinutes(seconds);
        final estCost = _session.iAmCaller ? (fullMinutes * speakerRate) : 0;
        final estEarn = _session.iAmCaller ? 0 : (fullMinutes * listenerRate);

        final otherName = _otherPartyName();
        final statusColor = _statusColor();
        final canEnd = _session.active && !_session.ending && !_endPressed;
        final showRemoteConnected =
            _session.remoteUid != 0 || _session.remoteConnected;

        final roleLabel = _session.iAmCaller ? 'Caller mode' : 'Listener mode';
        final primaryAmountLabel =
            _session.iAmCaller ? 'Estimated cost' : 'Estimated earning';
        final primaryAmountValue = _session.iAmCaller
            ? formatWalletAmount(estCost)
            : formatWalletAmount(estEarn);
        final rateValue = _session.iAmCaller
            ? '${formatWalletAmount(speakerRate)}/min'
            : '${formatWalletAmount(listenerRate)}/min';

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            await _closeUiKeepCallRunning();
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF17357E),
            appBar: AppBar(
              title: Text(otherName),
              centerTitle: true,
              backgroundColor: Colors.transparent,
              elevation: 0,
              foregroundColor: Colors.white,
              systemOverlayStyle: SystemUiOverlayStyle.light,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _closeUiKeepCallRunning,
              ),
              actions: [
                IconButton(
                  tooltip: 'Crisis Help',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CrisisHelpScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.support_agent_rounded),
                ),
                IconButton(
                  tooltip: 'Report / Block',
                  onPressed: _reporting ? null : _reportBlock,
                  icon: const Icon(Icons.report_gmailerrorred_rounded),
                ),
              ],
            ),
            body: Container(
              decoration:
                  const BoxDecoration(gradient: AppPalette.callGradient),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(18, 22, 18, 20),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _session.joined ? '$mm:$ss' : '--:--',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      _infoChip(
                                        'Encrypted',
                                        bg: AppPalette.callSuccess
                                            .withValues(alpha: 0.16),
                                        fg: AppPalette.callSuccess,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  Text(
                                    otherName,
                                    style: const TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          statusColor.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color:
                                            statusColor.withValues(alpha: 0.24),
                                      ),
                                    ),
                                    child: Text(
                                      _session.status,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: statusColor,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                  SizedBox(
                                    height: 206,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceEvenly,
                                          children:
                                              List.generate(11, _waveformBar),
                                        ),
                                        Container(
                                          width: 174,
                                          height: 174,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white
                                                .withValues(alpha: 0.22),
                                            border: Border.all(
                                              color: Colors.white
                                                  .withValues(alpha: 0.30),
                                              width: 2,
                                            ),
                                          ),
                                          padding: const EdgeInsets.all(5),
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Color(0xFF17357E),
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                              otherName.isNotEmpty
                                                  ? otherName[0].toUpperCase()
                                                  : 'U',
                                              style: const TextStyle(
                                                fontSize: 54,
                                                fontWeight: FontWeight.w900,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  Row(
                                    children: [
                                      _callControlButton(
                                        icon: Icons.mic_off_rounded,
                                        label: 'Mute',
                                        onPressed: null,
                                      ),
                                      const SizedBox(width: 10),
                                      _callControlButton(
                                        icon: Icons.volume_up_rounded,
                                        label: 'Speaker',
                                        onPressed: () =>
                                            _session.recoverAudioFlow(
                                                'voice_screen_sync'),
                                      ),
                                      const SizedBox(width: 10),
                                      _callControlButton(
                                        icon: Icons.chat_bubble_rounded,
                                        label: 'Message',
                                        onPressed: _closeUiKeepCallRunning,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      _infoChip(
                                        showRemoteConnected
                                            ? 'Remote connected'
                                            : 'Waiting for remote',
                                        fg: showRemoteConnected
                                            ? AppPalette.callSuccess
                                            : AppPalette.callAccent,
                                      ),
                                      _infoChip(roleLabel),
                                      if (_session.reconnectRemaining > 0)
                                        _infoChip(
                                          'Reconnect ${_session.reconnectRemaining}s',
                                          fg: const Color(0xFFFFC26B),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _statTile(
                                  label: 'Rate',
                                  value: rateValue,
                                  subtitle: _session.iAmCaller
                                      ? 'Call charge rate'
                                      : 'Your payout rate',
                                  color: AppPalette.blue,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _statTile(
                                  label: primaryAmountLabel,
                                  value: primaryAmountValue,
                                  subtitle: 'Based on full minutes',
                                  color: _session.iAmCaller
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFF15803D),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            decoration: AppPalette.cardDecoration(radius: 18),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Call details',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w900,
                                      color: AppPalette.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  _summaryRow(
                                    'Role',
                                    _session.iAmCaller ? 'Caller' : 'Listener',
                                  ),
                                  const SizedBox(height: 8),
                                  _summaryRow(
                                    'Timer',
                                    _session.joined
                                        ? '$mm:$ss'
                                        : 'Connecting...',
                                  ),
                                  const SizedBox(height: 8),
                                  _summaryRow(
                                    'Billable minutes',
                                    '$fullMinutes',
                                  ),
                                  const SizedBox(height: 8),
                                  _summaryRow(
                                    'Remote state',
                                    showRemoteConnected
                                        ? 'Connected'
                                        : 'Not connected yet',
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppPalette.feedBg,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: AppPalette.border,
                              ),
                            ),
                            child: Text(
                              _session.iAmCaller
                                  ? 'Billing starts after ${CallTiming.billingGraceSeconds} seconds. After that, only full minutes are charged.'
                                  : 'Earnings start after ${CallTiming.billingGraceSeconds} seconds. After that, only full minutes are counted.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppPalette.textSecondary,
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        backgroundColor: const Color(0xFFE5484D),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            Colors.white.withValues(alpha: 0.14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      onPressed: canEnd ? _endCall : null,
                      icon: const Icon(Icons.call_end_rounded),
                      label: Text(
                        _session.ending || _endPressed
                            ? 'Ending...'
                            : 'End call',
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      onPressed: _closeUiKeepCallRunning,
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('Back to app (keep call running)'),
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
}
