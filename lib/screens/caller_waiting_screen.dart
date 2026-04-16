import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import 'voice_call_screen.dart';

class CallerWaitingScreen extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> callDocRef;

  const CallerWaitingScreen({
    super.key,
    required this.callDocRef,
  });

  @override
  State<CallerWaitingScreen> createState() => _CallerWaitingScreenState();
}

class _CallerWaitingScreenState extends State<CallerWaitingScreen>
    with WidgetsBindingObserver {
  final CallSessionManager _callSession = CallSessionManager.instance;

  Timer? _ticker;

  bool _navigatedToCall = false;
  bool _closing = false;
  bool _popDone = false;
  bool _restoring = false;
  bool _showingTerminalSheet = false;
  bool _handledTerminalState = false;
  bool _disposed = false;
  bool _acceptedNavigationQueued = false;

  int _remainingSeconds = FirestoreService.ringingTimeoutSeconds;

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

    return createdAtMs + FirestoreService.ringingTimeoutSeconds * 1000;
  }

  int _remainingFromCall(Map<String, dynamic> call) {
    final expiresAtMs = _expiresAtMs(call);
    if (expiresAtMs <= 0) {
      return FirestoreService.ringingTimeoutSeconds;
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

  String _humanizeReason(String value) {
    final safe = value.trim().toLowerCase();

    switch (safe) {
      case 'timeout':
        return 'No answer';
      case 'busy':
        return 'Listener is busy';
      case 'caller_cancel':
        return 'Call cancelled';
      case 'caller_timeout':
        return 'No answer';
      case 'caller_timeout_cleanup':
        return 'No answer';
      case 'callee_reject':
        return 'Listener rejected the call';
      case 'callee_reject_callkit':
        return 'Listener rejected from system incoming screen';
      case 'callkit_ended':
        return 'Ended from system incoming screen';
      case 'invalid':
        return 'Invalid call';
      case 'invalid_channel':
        return 'Invalid channel';
      case 'open_call_failed':
        return 'Could not open call';
      case 'user_end':
        return 'Call ended normally';
      case 'connection_lost':
        return 'Connection lost';
      case 'remote_left':
        return 'Listener left the call';
      case 'server_timeout':
        return 'No answer';
      case 'stale_timeout':
        return 'Call expired';
      case 'credit_limit_reached':
        return 'Credit limit reached';
      case '':
        return 'Call closed';
      default:
        return safe.replaceAll('_', ' ');
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

  Future<void> _showTerminalSheet({
    required String title,
    required String subtitle,
    required String cta,
  }) async {
    if (!mounted || _disposed) return;
    if (_showingTerminalSheet) return;

    _showingTerminalSheet = true;

    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
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
      final rejectedReason = _asString(call[FirestorePaths.fieldRejectedReason]);
      await _showTerminalSheet(
        title: 'Call not answered',
        subtitle:
            '$safeName did not join.\nReason: ${_humanizeReason(rejectedReason)}',
        cta: 'Back',
      );
      await _safePopFalse();
      return;
    }

    if (status == FirestorePaths.statusEnded && !wasAnswered) {
      final endedReason = _asString(call[FirestorePaths.fieldEndedReason]);
      await _showTerminalSheet(
        title: 'Call closed',
        subtitle:
            '$safeName was unavailable.\nReason: ${_humanizeReason(endedReason)}',
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
            'With $safeName\nDuration: ${_durationLabel(seconds)}\nBillable minutes: $billableMinutes\nRate: ₹$speakerRate/min\nCharged: ₹$speakerCharge',
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
      );

      if (!restored || !mounted || _closing || _disposed) {
        return;
      }

      _ticker?.cancel();
      setState(() => _navigatedToCall = true);

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

  Color _statusColor(String status) {
    switch (status) {
      case FirestorePaths.statusAccepted:
        return const Color(0xFF15803D);
      case FirestorePaths.statusRejected:
      case FirestorePaths.statusEnded:
        return const Color(0xFFDC2626);
      case FirestorePaths.statusRinging:
      default:
        return const Color(0xFF4F46E5);
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
                        'Call is running',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'With $safeName • ${_callSession.status}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _callSession.joined
                            ? 'Duration $mm:$ss'
                            : 'Connecting...',
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
                    if (_navigatedToCall || _disposed) return;

                    setState(() => _navigatedToCall = true);
                    try {
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
              color: Color(0xFF6B7280),
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTicker();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryRestoreAcceptedCallOnResume();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
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
            body: Center(child: CircularProgressIndicator()),
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

        final calculatedRemaining = _remainingFromCall(call);
        final statusColor = _statusColor(status);
        final safeName = calleeName.isEmpty ? 'Listener' : calleeName;

        final isSameRunningCall = _isSameRunningCall();

        final canCancel =
            !_closing &&
            !_navigatedToCall &&
            !_acceptedNavigationQueued &&
            !isSameRunningCall &&
            status == FirestorePaths.statusRinging;

        if (!_closing &&
            !_disposed &&
            status == FirestorePaths.statusRinging &&
            _remainingSeconds != calculatedRemaining) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _closing || _disposed) return;
            setState(() {
              _remainingSeconds = calculatedRemaining;
            });
          });
        }

        if (_shouldHandleTerminal(call)) {
          _ticker?.cancel();

          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted || _closing || _disposed) return;
            await _handleTerminalState(call);
          });
        }

        if (status == FirestorePaths.statusRinging &&
            !_closing &&
            !_disposed &&
            !_navigatedToCall &&
            !_acceptedNavigationQueued &&
            _isExpired(call)) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted || _closing || _disposed) return;
            await _safeCancel(
              reason: FirestorePaths.reasonCallerTimeout,
            );
          });
        }

        if (status == FirestorePaths.statusAccepted &&
            !_closing &&
            !_disposed &&
            !_navigatedToCall &&
            !_acceptedNavigationQueued &&
            !_showingTerminalSheet &&
            !isSameRunningCall) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted || _closing || _disposed) return;
            _acceptedNavigationQueued = true;
            try {
              await _openVoiceCallIfAccepted();
            } finally {
              _acceptedNavigationQueued = false;
            }
          });
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Calling...')),
          body: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      _activeCallBanner(),
                      if (isSameRunningCall) const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Container(
                                width: 92,
                                height: 92,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF6366F1),
                                      Color(0xFF8B5CF6),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(30),
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
                                  color: Color(0xFF111827),
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
                                  'Status: $status',
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
                                        : 'Auto-cancel in ${_remainingSeconds < 0 ? 0 : _remainingSeconds}s',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 22,
                                  color: Color(0xFF111827),
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
                                    'You pay ₹$speakerRate/min',
                                    bg: const Color(0xFFEEF2FF),
                                    fg: const Color(0xFF4338CA),
                                  ),
                                  _infoChip(
                                    'Listener earns ₹$listenerEarnRate/min',
                                    bg: const Color(0xFFECFDF3),
                                    fg: const Color(0xFF15803D),
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
                              label: 'Call charge',
                              value: '₹$speakerRate/min',
                              subtitle: 'Visible rate to caller',
                              color: const Color(0xFF4F46E5),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _statTile(
                              label: 'Listener payout',
                              value: '₹$listenerEarnRate/min',
                              subtitle: 'Per full minute',
                              color: const Color(0xFF15803D),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFFE5E7EB),
                          ),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'What happens next',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: Color(0xFF111827),
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
                                color: Color(0xFF4B5563),
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Billing starts only after 60 seconds.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xFF6B7280),
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
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}