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
import 'voice_call_screen.dart';

class CallerWaitingScreen extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> callDocRef;
  final String initialAgoraToken;
  final int initialAgoraUid;
  final String initialChannelId;

  const CallerWaitingScreen({
    super.key,
    required this.callDocRef,
    this.initialAgoraToken = '',
    this.initialAgoraUid = 0,
    this.initialChannelId = '',
  });

  @override
  State<CallerWaitingScreen> createState() => _CallerWaitingScreenState();
}

class _CallerWaitingScreenState extends State<CallerWaitingScreen>
    with WidgetsBindingObserver {
  final CallSessionManager _callSession = CallSessionManager.instance;

  Timer? _ticker;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSnapshotSub;

  bool _navigatedToCall = false;
  bool _closing = false;
  bool _popDone = false;
  bool _restoring = false;
  bool _showingTerminalSheet = false;
  bool _handledTerminalState = false;
  bool _disposed = false;
  bool _acceptedNavigationQueued = false;

  int _remainingSeconds = CallTiming.callerWaitingTimeoutSeconds;

  bool _navigatorHasPendingTransitions(NavigatorState navigator) {
    final binding = SchedulerBinding.instance;
    return navigator.userGestureInProgress ||
        binding.transientCallbackCount > 0;
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  int _createdAtMs(Map<String, dynamic> call) {
    final createdAtMs = _asInt(call[FirestorePaths.fieldCreatedAtMs]);
    if (createdAtMs > 0) return createdAtMs;

    final createdAt = call[FirestorePaths.fieldCreatedAt];
    if (createdAt is Timestamp) {
      return createdAt.toDate().millisecondsSinceEpoch;
    }

    return 0;
  }

  int _startedAtMs(Map<String, dynamic> call) {
    final startedAt = call[FirestorePaths.fieldStartedAt];
    if (startedAt is Timestamp) {
      return startedAt.toDate().millisecondsSinceEpoch;
    }
    return 0;
  }

  int _endedAtMs(Map<String, dynamic> call) {
    final endedAtMs = _asInt(call[FirestorePaths.fieldEndedAtMs]);
    if (endedAtMs > 0) return endedAtMs;

    final endedAt = call[FirestorePaths.fieldEndedAt];
    if (endedAt is Timestamp) {
      return endedAt.toDate().millisecondsSinceEpoch;
    }
    return 0;
  }

  int _expiresAtMs(Map<String, dynamic> call) {
    final explicitExpiresAtMs = _asInt(call[FirestorePaths.fieldExpiresAtMs]);
    if (explicitExpiresAtMs > 0) return explicitExpiresAtMs;

    final createdAtMs = _createdAtMs(call);
    if (createdAtMs <= 0) return 0;

    return createdAtMs + CallTiming.callerWaitingTimeoutSeconds * 1000;
  }

  int _remainingFromCall(Map<String, dynamic> call) {
    final expiresAtMs = _expiresAtMs(call);
    if (expiresAtMs <= 0) {
      return CallTiming.callerWaitingTimeoutSeconds;
    }

    final left = ((expiresAtMs - _nowMs()) / 1000).ceil();
    return left < 0 ? 0 : left;
  }

  int _bestAcceptedSeconds(Map<String, dynamic> call) {
    final explicitEndedSeconds = _asInt(
      call[FirestorePaths.fieldEndedSeconds],
      fallback: -1,
    );
    final status = _asString(call[FirestorePaths.fieldStatus]);

    if (status == FirestorePaths.statusEnded && explicitEndedSeconds >= 0) {
      return explicitEndedSeconds;
    }

    final startedAtMs = _startedAtMs(call);
    if (startedAtMs <= 0) {
      return _callSession.seconds > 0 ? _callSession.seconds : 0;
    }

    final endedAtMs = _endedAtMs(call);
    if (endedAtMs > 0 && endedAtMs >= startedAtMs) {
      final elapsed = ((endedAtMs - startedAtMs) / 1000).floor();
      final safeElapsed = elapsed < 0 ? 0 : elapsed;
      return safeElapsed > _callSession.seconds
          ? safeElapsed
          : _callSession.seconds;
    }

    final liveElapsed = ((_nowMs() - startedAtMs) / 1000).floor();
    final safeLiveElapsed = liveElapsed < 0 ? 0 : liveElapsed;
    return safeLiveElapsed > _callSession.seconds
        ? safeLiveElapsed
        : _callSession.seconds;
  }

  bool _isExpired(Map<String, dynamic> call) {
    return _remainingFromCall(call) <= 0;
  }

  bool _wasAnswered(Map<String, dynamic> call) {
    final startedAt = call[FirestorePaths.fieldStartedAt];
    if (startedAt != null) return true;

    final endedSeconds = _asInt(call[FirestorePaths.fieldEndedSeconds]);
    if (endedSeconds > 0) return true;

    final status = _asString(call[FirestorePaths.fieldStatus]);
    if (status == FirestorePaths.statusAccepted) return true;

    return false;
  }

  bool _isSameRunningCall() {
    return _callSession.active &&
        _callSession.callDocRef?.path == widget.callDocRef.path;
  }

  bool _isSameTerminalCallAlreadyHandledBySession(Map<String, dynamic> call) {
    final status = _asString(call[FirestorePaths.fieldStatus]);
    if (!_isSameRunningCall()) return false;
    return status == FirestorePaths.statusEnded ||
        status == FirestorePaths.statusRejected;
  }

  bool _shouldHandleTerminal(Map<String, dynamic> call) {
    if (_disposed) return false;
    if (_closing) return false;
    if (_showingTerminalSheet) return false;
    if (_handledTerminalState) return false;
    if (_navigatedToCall) return false;
    if (_acceptedNavigationQueued) return false;
    if (_isSameRunningCall()) return false;
    if (_isSameTerminalCallAlreadyHandledBySession(call)) return false;

    final status = _asString(call[FirestorePaths.fieldStatus]);
    return status == FirestorePaths.statusRejected ||
        status == FirestorePaths.statusEnded;
  }

  String _terminalResultKey({
    required String status,
    required String reason,
  }) {
    final safe = reason.trim().toLowerCase();

    switch (safe) {
      case 'timeout':
      case 'caller_timeout':
      case 'caller_timeout_cleanup':
      case 'server_timeout':
      case 'stale_timeout':
        return 'timed_out';
      case 'busy':
        return 'missed';
      case 'caller_cancel':
      case 'callkit_ended':
        return 'cancelled';
      case 'callee_reject':
      case 'callee_reject_callkit':
        return 'declined';
      case 'insufficient_credits':
      case 'credit_limit_reached':
        return 'insufficient_credits';
      case 'invalid':
      case 'invalid_channel':
      case 'open_call_failed':
      case 'connection_lost':
      case 'remote_left':
        return 'failed';
      case 'user_end':
        return status == FirestorePaths.statusEnded ? 'cancelled' : 'failed';
      case '':
        return status == FirestorePaths.statusRejected ? 'declined' : 'failed';
      default:
        return 'failed';
    }
  }

  String _terminalResultTitle(String key) {
    switch (key) {
      case 'declined':
        return 'Call declined';
      case 'missed':
        return 'Call missed';
      case 'timed_out':
        return 'Call timed out';
      case 'cancelled':
        return 'Call cancelled';
      case 'insufficient_credits':
        return 'Add credits';
      case 'failed':
      default:
        return 'Call could not connect';
    }
  }

  String _terminalResultSubtitle(String key) {
    switch (key) {
      case 'declined':
        return 'Call declined. No charge applied.';
      case 'missed':
        return 'Call missed. No charge applied.';
      case 'timed_out':
        return 'Call timed out. No charge applied.';
      case 'cancelled':
        return 'Call cancelled. No charge applied.';
      case 'insufficient_credits':
        return 'Add credits before starting a call.';
      case 'failed':
      default:
        return 'Call could not connect. No charge applied.';
    }
  }

  String _safeWaitingStatusLabel({
    required String status,
    required bool isSameRunningCall,
  }) {
    if (isSameRunningCall) return 'Call active';
    switch (status) {
      case FirestorePaths.statusRinging:
        return 'Waiting for answer';
      case FirestorePaths.statusAccepted:
        return 'Opening call';
      case FirestorePaths.statusEnded:
      case FirestorePaths.statusRejected:
        return 'Call closed';
      default:
        return 'Preparing call';
    }
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

  Future<bool> _waitForNavigatorToSettle() async {
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return false;

    var stableFrames = 0;
    for (int attempt = 0; attempt < 24; attempt++) {
      if (!mounted || _disposed) return false;

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
          return mounted &&
              !_disposed &&
              !_navigatorHasPendingTransitions(navigator);
        }
      } else {
        stableFrames = 0;
      }

      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    return mounted && !_disposed && !_navigatorHasPendingTransitions(navigator);
  }

  void _listenToCallSnapshots() {
    _callSnapshotSub?.cancel();
    _callSnapshotSub = widget.callDocRef.snapshots().listen((snap) {
      final call = snap.data() ?? <String, dynamic>{};
      final nextRemaining = _remainingFromCall(call);
      final status = _asString(
        call[FirestorePaths.fieldStatus],
        fallback: FirestorePaths.statusRinging,
      );

      if (mounted &&
          !_closing &&
          !_disposed &&
          status == FirestorePaths.statusRinging &&
          _remainingSeconds != nextRemaining) {
        setState(() {
          _remainingSeconds = nextRemaining;
        });
      } else {
        _remainingSeconds = nextRemaining;
      }

      unawaited(_handleCallSnapshot(call));
    });
  }

  Future<void> _handleCallSnapshot(Map<String, dynamic> call) async {
    if (!mounted || _disposed || _closing) return;

    final status = _asString(
      call[FirestorePaths.fieldStatus],
      fallback: FirestorePaths.statusRinging,
    );
    final isSameRunningCall = _isSameRunningCall();

    if (_shouldHandleTerminal(call)) {
      _ticker?.cancel();
      await _handleTerminalState(call);
      return;
    }

    if (status == FirestorePaths.statusRinging &&
        !_navigatedToCall &&
        !_acceptedNavigationQueued &&
        _isExpired(call)) {
      await _safeCancel(
        reason: FirestorePaths.reasonCallerTimeout,
      );
      return;
    }

    if (status == FirestorePaths.statusAccepted &&
        !_navigatedToCall &&
        !_acceptedNavigationQueued &&
        !_showingTerminalSheet &&
        !isSameRunningCall) {
      _acceptedNavigationQueued = true;
      try {
        await _openVoiceCallIfAccepted();
      } finally {
        _acceptedNavigationQueued = false;
      }
    }
  }

  Future<void> _showTerminalSheet({
    required String title,
    required String subtitle,
    required String cta,
  }) async {
    if (!mounted || _disposed) return;
    if (_showingTerminalSheet) return;

    final settled = await _waitForNavigatorToSettle();
    if (!settled || !mounted || _disposed) return;

    _showingTerminalSheet = true;

    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (sheetContext) {
        return SafeArea(
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
                    color: AppPalette.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: Text(cta),
                ),
              ],
            ),
          ),
        );
      },
    );

    _showingTerminalSheet = false;
  }

  Future<void> _handleTerminalState(Map<String, dynamic> call) async {
    if (_handledTerminalState) return;
    if (_acceptedNavigationQueued || _navigatedToCall || _isSameRunningCall()) {
      return;
    }

    _handledTerminalState = true;
    _ticker?.cancel();

    final status = _asString(call[FirestorePaths.fieldStatus]);
    final calleeName = _asString(
      call[FirestorePaths.fieldCalleeName],
      fallback: 'Listener',
    );
    final safeName = calleeName.isEmpty ? 'Listener' : calleeName;
    final wasAnswered = _wasAnswered(call);

    if (status == FirestorePaths.statusRejected && !wasAnswered) {
      final rejectedReason =
          _asString(call[FirestorePaths.fieldRejectedReason]);
      final resultKey = _terminalResultKey(
        status: status,
        reason: rejectedReason,
      );
      await _showTerminalSheet(
        title: _terminalResultTitle(resultKey),
        subtitle: _terminalResultSubtitle(resultKey),
        cta: 'Back',
      );
      await _safePopFalse();
      return;
    }

    if (status == FirestorePaths.statusEnded && !wasAnswered) {
      final endedReason = _asString(call[FirestorePaths.fieldEndedReason]);
      final resultKey = _terminalResultKey(
        status: status,
        reason: endedReason,
      );
      await _showTerminalSheet(
        title: _terminalResultTitle(resultKey),
        subtitle: _terminalResultSubtitle(resultKey),
        cta: 'Back',
      );
      await _safePopFalse();
      return;
    }

    if (status == FirestorePaths.statusEnded && wasAnswered) {
      final seconds = _bestAcceptedSeconds(call);
      final speakerRate = _asInt(
        call[FirestorePaths.fieldSpeakerRate],
        fallback: 5,
      );
      final speakerCharge = _asInt(call[FirestorePaths.fieldSpeakerCharge]);
      final billableMinutes = seconds >= 60 ? (seconds ~/ 60) : 0;

      await _showTerminalSheet(
        title: 'Call finished',
        subtitle:
            'With $safeName\nDuration: ${_durationLabel(seconds)}\nBillable minutes: $billableMinutes\nRate: Rs $speakerRate/min\nCharged: Rs $speakerCharge',
        cta: 'Continue',
      );
      await _safePopFalse();
    }
  }

  void _startTicker() {
    _ticker?.cancel();

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || _disposed) return;

      if (_closing || _navigatedToCall || _acceptedNavigationQueued) {
        _ticker?.cancel();
        return;
      }

      try {
        final snap = await widget.callDocRef.get();
        final data = snap.data() ?? <String, dynamic>{};
        final status = _asString(data[FirestorePaths.fieldStatus]);

        if (_isSameRunningCall()) {
          _ticker?.cancel();
          return;
        }

        if (status == FirestorePaths.statusAccepted ||
            status == FirestorePaths.statusEnded ||
            status == FirestorePaths.statusRejected) {
          _ticker?.cancel();
          return;
        }

        final nextRemaining = _remainingFromCall(data);

        if (mounted && !_closing && !_disposed) {
          setState(() {
            _remainingSeconds = nextRemaining;
          });
        }

        if (nextRemaining <= 0) {
          _ticker?.cancel();
          await _safeCancel(
            reason: FirestorePaths.reasonCallerTimeout,
          );
        }
      } catch (_) {
        // ignore ticker read failures
      }
    });
  }

  Future<void> _safePopFalse() async {
    if (!mounted || _disposed || _popDone) return;

    final settled = await _waitForNavigatorToSettle();
    if (!settled || !mounted || _disposed || _popDone) return;

    _popDone = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(false);
    }
  }

  Future<void> _safeCancel({required String reason}) async {
    if (_closing || _disposed) return;
    _closing = true;

    _ticker?.cancel();

    try {
      final snap = await widget.callDocRef.get();
      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(
        data[FirestorePaths.fieldStatus],
        fallback: FirestorePaths.statusRinging,
      );

      if (_isSameRunningCall()) {
        await _safePopFalse();
        return;
      }

      if (status == FirestorePaths.statusRinging) {
        await FirestoreService.cancelOutgoingCall(
          callRef: widget.callDocRef,
          reason: reason,
        );
      } else if (status == FirestorePaths.statusAccepted) {
        await FirestoreService.endCallWithBilling(
          callRef: widget.callDocRef,
          seconds: _bestAcceptedSeconds(data),
          reason: reason,
        );
      }
    } catch (_) {
      // ignore cancel failures
    }

    await _safePopFalse();
  }

  Future<void> _openVoiceCallIfAccepted() async {
    if (_closing || _disposed) return;
    if (_navigatedToCall) return;

    final sameRunningCall = _isSameRunningCall();
    if (sameRunningCall) {
      if (!mounted) return;

      _ticker?.cancel();
      setState(() => _navigatedToCall = true);

      try {
        final settled = await _waitForNavigatorToSettle();
        if (!settled || !mounted || _disposed) return;

        await Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            settings: const RouteSettings(name: VoiceCallScreen.routeName),
            builder: (_) => const VoiceCallScreen(),
          ),
        );
      } finally {
        if (mounted && !_disposed) {
          _navigatedToCall = false;
        }
      }
      return;
    }

    try {
      final restored = await _callSession.tryRestoreFromCallDoc(
        callDocRef: widget.callDocRef,
        iAmCaller: true,
        initialAgoraToken: widget.initialAgoraToken,
        initialAgoraUid: widget.initialAgoraUid,
        initialChannelId: widget.initialChannelId,
      );

      if (!restored || !mounted || _closing || _disposed) {
        return;
      }

      _ticker?.cancel();
      setState(() => _navigatedToCall = true);

      final settled = await _waitForNavigatorToSettle();
      if (!settled || !mounted || _disposed) return;

      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: VoiceCallScreen.routeName),
          builder: (_) => const VoiceCallScreen(),
        ),
      );
    } catch (_) {
      // ignore
    } finally {
      if (mounted && !_disposed) {
        _navigatedToCall = false;
      }
    }
  }

  Future<void> _tryRestoreAcceptedCallOnResume() async {
    if (_restoring || _disposed) return;
    if (_closing) return;
    if (_navigatedToCall) return;
    if (_isSameRunningCall()) return;

    _restoring = true;
    try {
      final restored = await _callSession.tryRestoreFromCallDoc(
        callDocRef: widget.callDocRef,
        iAmCaller: true,
        initialAgoraToken: widget.initialAgoraToken,
        initialAgoraUid: widget.initialAgoraUid,
        initialChannelId: widget.initialChannelId,
      );

      if (restored && mounted && !_navigatedToCall && !_closing && !_disposed) {
        _acceptedNavigationQueued = true;
        try {
          await _openVoiceCallIfAccepted();
        } finally {
          _acceptedNavigationQueued = false;
        }
        return;
      }

      final latestSnap = await widget.callDocRef.get();
      final latestData = latestSnap.data() ?? <String, dynamic>{};
      final latestStatus = _asString(latestData[FirestorePaths.fieldStatus]);

      if ((latestStatus == FirestorePaths.statusEnded ||
              latestStatus == FirestorePaths.statusRejected) &&
          _shouldHandleTerminal(latestData)) {
        await _handleTerminalState(latestData);
      }
    } finally {
      _restoring = false;
    }
  }

  Widget _infoChip(
    String text, {
    Color? bg,
    Color? fg,
  }) {
    final chipBg = bg ?? Colors.white.withValues(alpha: 0.12);
    final chipFg = fg ?? Colors.white70;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: chipFg.withValues(alpha: 0.22),
        ),
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

  Color _statusColor(String status) {
    switch (status) {
      case FirestorePaths.statusAccepted:
        return AppPalette.callSuccess;
      case FirestorePaths.statusRejected:
      case FirestorePaths.statusEnded:
        return AppPalette.callDanger;
      case FirestorePaths.statusRinging:
      default:
        return AppPalette.callAccent;
    }
  }

  Widget _activeCallBanner() {
    return AnimatedBuilder(
      animation: _callSession,
      builder: (_, __) {
        final isSameCall = _isSameRunningCall();

        if (!isSameCall) {
          return const SizedBox.shrink();
        }

        final calleeName = _asString(
          _callSession.call[FirestorePaths.fieldCalleeName],
          fallback: 'Listener',
        );

        final safeName = calleeName.isEmpty ? 'Listener' : calleeName;
        final mm = (_callSession.seconds ~/ 60).toString().padLeft(2, '0');
        final ss = (_callSession.seconds % 60).toString().padLeft(2, '0');

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: AppPalette.callCardDecoration(),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.call_rounded,
                  color: AppPalette.callSuccess,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Call is running',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'With $safeName - ${_callSession.status}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppPalette.callAccent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _callSession.joined
                          ? 'Duration $mm:$ss'
                          : 'Connecting...',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () async {
                  if (_navigatedToCall || _disposed) return;

                  setState(() => _navigatedToCall = true);
                  try {
                    final settled = await _waitForNavigatorToSettle();
                    if (!settled || !mounted || _disposed) return;

                    await Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(
                          name: VoiceCallScreen.routeName,
                        ),
                        builder: (_) => const VoiceCallScreen(),
                      ),
                    );
                  } finally {
                    if (mounted && !_disposed) {
                      _navigatedToCall = false;
                    }
                  }
                },
                child: const Text('Open'),
              ),
            ],
          ),
        );
      },
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
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: color.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
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
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(CallWakeLockService.instance.enable('caller_waiting'));
    _startTicker();
    _listenToCallSnapshots();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryRestoreAcceptedCallOnResume();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _callSnapshotSub?.cancel();
    _ticker?.cancel();
    unawaited(CallWakeLockService.instance.release('caller_waiting'));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tryRestoreAcceptedCallOnResume();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: widget.callDocRef.snapshots(),
      builder: (_, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFF17357E),
            body: DecoratedBox(
              decoration: BoxDecoration(gradient: AppPalette.callGradient),
              child: Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                ),
              ),
            ),
          );
        }

        final call = snap.data!.data() ?? <String, dynamic>{};
        final status = _asString(
          call[FirestorePaths.fieldStatus],
          fallback: FirestorePaths.statusRinging,
        );
        final calleeName = _asString(
          call[FirestorePaths.fieldCalleeName],
          fallback: 'Listener',
        );

        final listenerEarnRate = _asInt(
          call[FirestorePaths.fieldListenerPayoutRate],
          fallback: 4,
        );
        final speakerRate = _asInt(
          call[FirestorePaths.fieldSpeakerRate],
          fallback: 5,
        );

        final statusColor = _statusColor(status);
        final safeName = calleeName.isEmpty ? 'Listener' : calleeName;

        final isSameRunningCall = _isSameRunningCall();
        final safeStatusLabel = _safeWaitingStatusLabel(
          status: status,
          isSameRunningCall: isSameRunningCall,
        );

        final canCancel = !_closing &&
            !_navigatedToCall &&
            !_acceptedNavigationQueued &&
            !isSameRunningCall &&
            status == FirestorePaths.statusRinging;

        return Scaffold(
          backgroundColor: const Color(0xFF17357E),
          appBar: AppBar(
            title: const Text('Calling...'),
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            systemOverlayStyle: SystemUiOverlayStyle.light,
          ),
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: AppPalette.callGradient),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      children: [
                        _activeCallBanner(),
                        if (isSameRunningCall) const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: AppPalette.callCardDecoration(),
                          child: Column(
                            children: [
                              Container(
                                width: 92,
                                height: 92,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.28),
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  safeName.isNotEmpty
                                      ? safeName[0].toUpperCase()
                                      : 'L',
                                  style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Calling $safeName',
                                style: const TextStyle(
                                  fontSize: 24,
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
                                  color: statusColor.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: statusColor.withValues(alpha: 0.24),
                                  ),
                                ),
                                child: Text(
                                  safeStatusLabel,
                                  style: TextStyle(
                                    color: statusColor,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                isSameRunningCall
                                    ? 'Call is active now'
                                    : status == FirestorePaths.statusAccepted
                                        ? 'Call accepted. Opening...'
                                        : 'Auto-cancels in ${_remainingSeconds < 0 ? 0 : _remainingSeconds}s',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 22,
                                  color: Colors.white,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.center,
                                children: [
                                  _infoChip(
                                    'You pay Rs $speakerRate/min',
                                    bg: Colors.white.withValues(alpha: 0.14),
                                    fg: AppPalette.callAccent,
                                  ),
                                  _infoChip(
                                    'Listener earns Rs $listenerEarnRate/min',
                                    bg: AppPalette.callSuccess
                                        .withValues(alpha: 0.16),
                                    fg: AppPalette.callSuccess,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _statTile(
                                label: 'Call charge',
                                value: 'Rs $speakerRate/min',
                                subtitle: 'Visible rate to caller',
                                color: AppPalette.callAccent,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statTile(
                                label: 'Listener payout',
                                value: 'Rs $listenerEarnRate/min',
                                subtitle: 'Per full minute',
                                color: AppPalette.callSuccess,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: AppPalette.callCardDecoration(),
                          child: Column(
                            children: [
                              const Text(
                                'What happens next',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                isSameRunningCall
                                    ? 'Your call is already active. You can reopen the live call screen anytime.'
                                    : status == FirestorePaths.statusAccepted
                                        ? 'Please wait while the live call screen opens automatically.'
                                        : 'If the listener accepts, the voice call screen will open automatically.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'No charge unless the call connects.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppPalette.callAccent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.30),
                      ),
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                    ),
                    onPressed: canCancel
                        ? () => _safeCancel(
                              reason: FirestorePaths.reasonCallerCancel,
                            )
                        : null,
                    icon: const Icon(Icons.call_end_rounded),
                    label: Text(_closing ? 'Cancelling...' : 'Cancel Call'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isSameRunningCall
                        ? 'Your call is still running in background.'
                        : status == FirestorePaths.statusAccepted
                            ? 'Connecting you to the active call.'
                            : 'If the listener does not accept in time, the call will auto-cancel.',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
