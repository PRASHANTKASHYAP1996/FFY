import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/constants/call_timing.dart';
import '../core/constants/firestore_paths.dart';
import '../core/theme/app_palette.dart';
import '../screens/voice_call_screen.dart';
import '../services/app_log.dart';
import '../services/call_session_manager.dart';
import '../services/call_wake_lock_service.dart';
import '../services/firestore_service.dart';
import '../services/notifications_service.dart';

class IncomingCallOverlay extends StatefulWidget {
  final String myUid;

  const IncomingCallOverlay({
    super.key,
    required this.myUid,
  });

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay> {
  final Set<String> _cleanupInProgress = <String>{};
  final CallSessionManager _callSession = CallSessionManager.instance;

  Timer? _expiryTimer;
  String _expiryTimerKey = '';
  bool _actionRunning = false;
  bool _navigatingToCall = false;
  String _activeCallId = '';
  String _lastVisibleOwnerLoggedCallId = '';
  String _wakeLockCallId = '';
  String _incomingCallStreamUid = '__unset__';
  Stream<QuerySnapshot<Map<String, dynamic>>>? _incomingCallStream;

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _syncIncomingWakeLock('');
    super.dispose();
  }

  void _clearExpiryTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _expiryTimerKey = '';
  }

  void _syncIncomingWakeLock(String callId) {
    final safeCallId = callId.trim();
    if (_wakeLockCallId == safeCallId) return;
    final oldCallId = _wakeLockCallId;
    _wakeLockCallId = safeCallId;
    if (oldCallId.isNotEmpty) {
      unawaited(CallWakeLockService.instance.release('incoming_$oldCallId'));
    }
    if (safeCallId.isNotEmpty) {
      unawaited(CallWakeLockService.instance.enable('incoming_$safeCallId'));
    }
  }

  bool _navigatorHasPendingTransitions(NavigatorState navigator) {
    final binding = SchedulerBinding.instance;
    return navigator.userGestureInProgress ||
        binding.transientCallbackCount > 0;
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

  int _expiresAtMs(Map<String, dynamic> call) {
    final explicitExpiresAtMs = _asInt(call[FirestorePaths.fieldExpiresAtMs]);
    if (explicitExpiresAtMs > 0) return explicitExpiresAtMs;

    final createdAtMs = _createdAtMs(call);
    if (createdAtMs <= 0) return 0;

    return createdAtMs + CallTiming.incomingRingTimeoutSeconds * 1000;
  }

  bool _isExpired(Map<String, dynamic> call) {
    final expiresAtMs = _expiresAtMs(call);
    if (expiresAtMs <= 0) return false;
    return _nowMs() > expiresAtMs;
  }

  int _remainingSeconds(Map<String, dynamic> call) {
    final expiresAtMs = _expiresAtMs(call);
    if (expiresAtMs <= 0) {
      return CallTiming.incomingRingTimeoutSeconds;
    }

    final left = ((expiresAtMs - _nowMs()) / 1000).ceil();
    return left < 0 ? 0 : left;
  }

  bool _isValidIncomingRingingCall(Map<String, dynamic> call) {
    final callerId = _asString(call[FirestorePaths.fieldCallerId]);
    final calleeId = _asString(call[FirestorePaths.fieldCalleeId]);
    final channelId = _asString(call[FirestorePaths.fieldChannelId]);
    final status = _asString(call[FirestorePaths.fieldStatus]);

    if (status != FirestorePaths.statusRinging) return false;
    if (callerId.isEmpty) return false;
    if (calleeId.isEmpty) return false;
    if (channelId.isEmpty) return false;
    if (_isExpired(call)) return false;

    return true;
  }

  void _scheduleExpiryCleanup(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    var nextCallId = '';
    var nextExpiresAtMs = 0;
    final nowMs = _nowMs();

    for (final doc in docs) {
      final data = doc.data();
      if (_asString(data[FirestorePaths.fieldStatus]) !=
          FirestorePaths.statusRinging) {
        continue;
      }

      final expiresAtMs = _expiresAtMs(data);
      if (expiresAtMs <= nowMs) {
        unawaited(_cleanupIfNeeded(doc.reference, data));
        continue;
      }

      if (nextExpiresAtMs <= 0 || expiresAtMs < nextExpiresAtMs) {
        nextExpiresAtMs = expiresAtMs;
        nextCallId = doc.id;
      }
    }

    if (nextCallId.isEmpty || nextExpiresAtMs <= 0) {
      _clearExpiryTimer();
      return;
    }

    final timerKey = '$nextCallId:$nextExpiresAtMs';
    if (_expiryTimerKey == timerKey && _expiryTimer?.isActive == true) return;

    _expiryTimer?.cancel();
    _expiryTimerKey = timerKey;
    final delayMs = (nextExpiresAtMs - nowMs + 250).clamp(250, 60000).toInt();
    _expiryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      unawaited(FirestoreService.cleanupMyStaleCalls());
      setState(() {});
    });
  }

  Future<void> _cleanupIfNeeded(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> data,
  ) async {
    if (_cleanupInProgress.contains(ref.id)) return;

    final callerId = _asString(data[FirestorePaths.fieldCallerId]);
    final calleeId = _asString(data[FirestorePaths.fieldCalleeId]);
    final channelId = _asString(data[FirestorePaths.fieldChannelId]);
    final status = _asString(data[FirestorePaths.fieldStatus]);

    if (status != FirestorePaths.statusRinging) return;

    final invalid = callerId.isEmpty || calleeId.isEmpty || channelId.isEmpty;
    final expired = _isExpired(data);

    if (!invalid && !expired) return;

    _cleanupInProgress.add(ref.id);

    try {
      if (invalid) {
        await FirestoreService.rejectCall(
          ref,
          rejectedReason: FirestorePaths.reasonInvalid,
        );
      } else if (expired) {
        await FirestoreService.rejectCall(
          ref,
          rejectedReason: FirestorePaths.reasonTimeout,
        );
      }
    } catch (_) {
      // ignore cleanup failures
    } finally {
      _cleanupInProgress.remove(ref.id);
    }
  }

  QueryDocumentSnapshot<Map<String, dynamic>>? _selectCall(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    if (docs.isEmpty) return null;

    final sorted = [...docs]..sort((a, b) {
        final aMs = _createdAtMs(a.data());
        final bMs = _createdAtMs(b.data());
        return bMs.compareTo(aMs);
      });

    for (final doc in sorted) {
      final data = doc.data();
      if (_isValidIncomingRingingCall(data)) {
        return doc;
      }
    }

    return null;
  }

  Future<void> _rejectCall(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    if (_actionRunning || _navigatingToCall) return;

    if (mounted) {
      setState(() {
        _actionRunning = true;
        _activeCallId = doc.id;
      });
    }

    try {
      final latest = await doc.reference.get();
      final data = latest.data() ?? <String, dynamic>{};

      if (_asString(data[FirestorePaths.fieldStatus]) !=
          FirestorePaths.statusRinging) {
        return;
      }

      await FirestoreService.rejectCallById(
        doc.id,
        rejectedReason: FirestorePaths.reasonCalleeReject,
      );
    } catch (_) {
      // ignore
    } finally {
      if (mounted) {
        setState(() {
          _actionRunning = false;
          _activeCallId = '';
        });
      }
    }
  }

  Future<void> _openVoiceCallScreen() async {
    if (!mounted) return;

    setState(() {
      _navigatingToCall = true;
    });

    try {
      final settled = await _waitForNavigatorToSettle();
      if (!settled || !mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: VoiceCallScreen.routeName),
          builder: (_) => const VoiceCallScreen(),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _navigatingToCall = false;
          _actionRunning = false;
          _activeCallId = '';
        });
      }
    }
  }

  Future<void> _acceptCall(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    String initialChannelId,
  ) async {
    if (_actionRunning || _navigatingToCall) return;

    if (_callSession.active) {
      return;
    }

    if (mounted) {
      setState(() {
        _actionRunning = true;
        _activeCallId = doc.id;
      });
    }

    try {
      final latest = await doc.reference.get();
      final latestData = latest.data() ?? <String, dynamic>{};
      final latestStatus = _asString(latestData[FirestorePaths.fieldStatus]);

      if (latestStatus != FirestorePaths.statusRinging) {
        return;
      }

      if (_isExpired(latestData)) {
        await FirestoreService.rejectCall(
          doc.reference,
          rejectedReason: FirestorePaths.reasonTimeout,
        );
        return;
      }

      final latestChannelId = _asString(
        latestData[FirestorePaths.fieldChannelId],
        fallback: initialChannelId,
      );

      if (latestChannelId.isEmpty) {
        await FirestoreService.rejectCall(
          doc.reference,
          rejectedReason: FirestorePaths.reasonInvalid,
        );
        return;
      }

      final acceptResult = await FirestoreService.acceptCallById(doc.id);
      if (acceptResult == null ||
          acceptResult.status != FirestorePaths.statusAccepted) {
        return;
      }

      final acceptedChannelId = acceptResult.channelId.isNotEmpty
          ? acceptResult.channelId
          : latestChannelId;
      if (acceptedChannelId.isEmpty || acceptResult.agoraUid <= 0) {
        return;
      }

      await _callSession.startOrAttach(
        callDocRef: doc.reference,
        channelId: acceptedChannelId,
        iAmCaller: false,
        initialAgoraToken: acceptResult.agoraToken,
        initialAgoraUid: acceptResult.agoraUid,
      );

      if (!_callSession.active) {
        return;
      }

      await _openVoiceCallScreen();
    } catch (_) {
      if (mounted) {
        setState(() {
          _actionRunning = false;
          _activeCallId = '';
        });
      }
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _authBoundIncomingCallStream() {
    final safeUid = widget.myUid.trim();
    final query = FirestoreService.calls
        .where(
          FirestorePaths.fieldCalleeId,
          isEqualTo: safeUid,
        )
        .where(
          FirestorePaths.fieldStatus,
          isEqualTo: FirestorePaths.statusRinging,
        )
        .limit(5);

    late StreamController<QuerySnapshot<Map<String, dynamic>>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? subscription;

    controller =
        StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast(
      onListen: () {
        subscription = query.snapshots().listen(
          (snapshot) {
            if (FirestoreService.safeUidOrNull() != safeUid) return;
            if (controller.isClosed) return;
            controller.add(snapshot);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (FirestoreService.safeUidOrNull() != safeUid) return;
            if (controller.isClosed) return;
            controller.addError(error, stackTrace);
          },
        );
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _incomingCallStreamForWidget() {
    final safeUid = widget.myUid.trim();
    if (_incomingCallStream != null && _incomingCallStreamUid == safeUid) {
      return _incomingCallStream!;
    }

    _incomingCallStreamUid = safeUid;
    _incomingCallStream = _authBoundIncomingCallStream();
    return _incomingCallStream!;
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
          color: chipFg.withValues(alpha: 0.24),
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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _incomingCallStreamForWidget(),
      builder: (_, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          _lastVisibleOwnerLoggedCallId = '';
          _syncIncomingWakeLock('');
          return const SizedBox.shrink();
        }

        final docs = snap.data!.docs;
        _scheduleExpiryCleanup(docs);

        for (final doc in docs) {
          unawaited(_cleanupIfNeeded(doc.reference, doc.data()));
        }

        final selected = _selectCall(docs);
        if (selected == null) {
          _lastVisibleOwnerLoggedCallId = '';
          _syncIncomingWakeLock('');
          return const SizedBox.shrink();
        }

        if (_callSession.active &&
            _callSession.callDocRef?.path == selected.reference.path) {
          _lastVisibleOwnerLoggedCallId = '';
          _syncIncomingWakeLock('');
          return const SizedBox.shrink();
        }

        if (_callSession.active) {
          _lastVisibleOwnerLoggedCallId = '';
          _syncIncomingWakeLock('');
          return const SizedBox.shrink();
        }

        if (NotificationsService.instance.isSystemIncomingUiActiveFor(
          selected.id,
        )) {
          debugPrint(
            'incoming_ui.deduped_existing_callId '
            'callId=${AppLog.safeId(selected.id)}',
          );
          _lastVisibleOwnerLoggedCallId = '';
          _syncIncomingWakeLock('');
          return const SizedBox.shrink();
        }

        final call = selected.data();
        _syncIncomingWakeLock(selected.id);
        if (_lastVisibleOwnerLoggedCallId != selected.id) {
          _lastVisibleOwnerLoggedCallId = selected.id;
          debugPrint(
            'incoming_ui.owner=foreground_flutter_overlay '
            'callId=${AppLog.safeId(selected.id)}',
          );
          debugPrint(
            'incoming_ui.persistent_until=accepted|declined|terminal|timeout '
            'callId=${AppLog.safeId(selected.id)}',
          );
        }

        final callerName = _asString(
          call[FirestorePaths.fieldCallerName],
          fallback: 'Someone',
        );
        final channelId = _asString(call[FirestorePaths.fieldChannelId]);
        final remainingSeconds = _remainingSeconds(call);
        final isBusyWithThisCard =
            _actionRunning && _activeCallId == selected.id;
        final safeCallerName = callerName.isEmpty ? 'Someone' : callerName;

        return Material(
          color: Colors.black.withValues(alpha: 0.72),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  margin: const EdgeInsets.all(18),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: AppPalette.callGradient,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 104,
                        height: 104,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          safeCallerName.isNotEmpty
                              ? safeCallerName[0].toUpperCase()
                              : 'S',
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Incoming call',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        safeCallerName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.callAccent,
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
                            'Expires in ${remainingSeconds}s',
                            bg: Colors.white.withValues(alpha: 0.14),
                            fg: const Color(0xFFFFC26B),
                          ),
                          _infoChip(
                            'Voice call',
                            bg: Colors.white.withValues(alpha: 0.14),
                            fg: AppPalette.callAccent,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18),
                          ),
                        ),
                        child: const Column(
                          children: [
                            Text(
                              'Quick decision needed',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Accept to open the live voice call screen. Reject to decline this incoming call.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(54),
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.30),
                                ),
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.12),
                              ),
                              onPressed: (_actionRunning || _navigatingToCall)
                                  ? null
                                  : () => _rejectCall(selected),
                              icon: const Icon(Icons.call_end_rounded),
                              label: Text(
                                isBusyWithThisCard
                                    ? 'Please wait...'
                                    : 'Reject',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(54),
                                backgroundColor: AppPalette.online,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor:
                                    Colors.white.withValues(alpha: 0.20),
                              ),
                              onPressed: (_actionRunning ||
                                      _navigatingToCall ||
                                      channelId.isEmpty)
                                  ? null
                                  : () => _acceptCall(selected, channelId),
                              icon: const Icon(Icons.call_rounded),
                              label: Text(
                                isBusyWithThisCard ? 'Connecting...' : 'Accept',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'No charge unless the call connects.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppPalette.callAccent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'This call auto-expires in about $remainingSeconds seconds if not answered.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
