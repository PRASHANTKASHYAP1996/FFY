import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../screens/voice_call_screen.dart';
import '../services/call_session_manager.dart';
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

  bool _actionRunning = false;
  bool _navigatingToCall = false;
  String _activeCallId = '';

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

    return createdAtMs + FirestoreService.ringingTimeoutSeconds * 1000;
  }

  bool _isExpired(Map<String, dynamic> call) {
    final expiresAtMs = _expiresAtMs(call);
    if (expiresAtMs <= 0) return false;
    return _nowMs() > expiresAtMs;
  }

  int _remainingSeconds(Map<String, dynamic> call) {
    final expiresAtMs = _expiresAtMs(call);
    if (expiresAtMs <= 0) {
      return FirestoreService.ringingTimeoutSeconds;
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

    final sorted = [...docs]
      ..sort((a, b) {
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

      await FirestoreService.rejectCall(
        doc.reference,
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

      await FirestoreService.acceptCall(doc.reference);

      final after = await doc.reference.get();
      final afterData = after.data() ?? <String, dynamic>{};
      final afterStatus = _asString(afterData[FirestorePaths.fieldStatus]);
      final afterChannelId = _asString(
        afterData[FirestorePaths.fieldChannelId],
        fallback: latestChannelId,
      );

      if (afterStatus != FirestorePaths.statusAccepted) {
        return;
      }

      if (afterChannelId.isEmpty) {
        return;
      }

      await _callSession.startOrAttach(
        callDocRef: doc.reference,
        channelId: afterChannelId,
        iAmCaller: false,
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

  @override
  Widget build(BuildContext context) {
    final stream = FirestoreService.calls
        .where(
          FirestorePaths.fieldCalleeId,
          isEqualTo: widget.myUid,
        )
        .where(
          FirestorePaths.fieldStatus,
          isEqualTo: FirestorePaths.statusRinging,
        )
        .limit(5)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (_, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final docs = snap.data!.docs;

        for (final doc in docs) {
          unawaited(_cleanupIfNeeded(doc.reference, doc.data()));
        }

        final selected = _selectCall(docs);
        if (selected == null) {
          return const SizedBox.shrink();
        }

        if (_callSession.active &&
            _callSession.callDocRef?.path == selected.reference.path) {
          return const SizedBox.shrink();
        }

        if (_callSession.active) {
          return const SizedBox.shrink();
        }

        if (NotificationsService.instance.isSystemIncomingUiActiveFor(
          selected.id,
        )) {
          return const SizedBox.shrink();
        }

        final call = selected.data();

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
          color: Colors.black54,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          safeCallerName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF374151),
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
                              bg: const Color(0xFFFFF7ED),
                              fg: const Color(0xFFD97706),
                            ),
                            _infoChip(
                              'Voice call',
                              bg: const Color(0xFFEEF2FF),
                              fg: const Color(0xFF4338CA),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFFE5E7EB),
                            ),
                          ),
                          child: Column(
                            children: const [
                              Text(
                                'Quick decision needed',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                  color: Color(0xFF111827),
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Accept to open the live voice call screen. Reject to decline this incoming call.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF6B7280),
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
                                onPressed:
                                    (_actionRunning ||
                                            _navigatingToCall ||
                                            channelId.isEmpty)
                                        ? null
                                        : () => _acceptCall(selected, channelId),
                                icon: const Icon(Icons.call_rounded),
                                label: Text(
                                  isBusyWithThisCard
                                      ? 'Connecting...'
                                      : 'Accept',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Billing starts after 60 seconds (full minutes only).',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF6B7280),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'This call will auto-expire in about $remainingSeconds seconds if not answered.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF6B7280),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
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