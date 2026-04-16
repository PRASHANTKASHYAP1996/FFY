import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../app.dart';
import '../repositories/call_repository.dart';
import '../screens/voice_call_screen.dart';
import 'call_session_manager.dart';

class CallManager {
  CallManager._();

  static final CallManager instance = CallManager._();

  static const Duration _incomingShowDebounce = Duration(milliseconds: 1200);
  static const Duration _recentAcceptWindow = Duration(seconds: 6);

  static const String _stateIncomingRinging = 'incoming_ringing';
  static const String _stateAccepting = 'accepting';
  static const String _stateAcceptedOpening = 'accepted_opening';
  static const String _stateDismissed = 'dismissed';
  static const String _stateEnded = 'ended';

  final CallSessionManager _callSession = CallSessionManager.instance;
  final CallRepository _callRepository = CallRepository.instance;

  bool _openingVoiceFromCallkit = false;
  bool _openingActiveVoiceScreen = false;

  String _activeIncomingCallId = '';
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _activeIncomingSub;
  Timer? _pendingShowTimer;
  String _pendingShowCallId = '';

  final Set<String> _activeIncomingCalls = <String>{};
  final Map<String, String> _callStates = <String, String>{};

  final Set<String> _recentlyAcceptedCalls = <String>{};
  final Map<String, Timer> _recentAcceptExpiryTimers = <String, Timer>{};

  final Set<String> _incomingUiOpsInProgress = <String>{};
  final Set<String> _acceptOpsInProgress = <String>{};

  String _voiceScreenOpeningCallId = '';
  String _voiceScreenVisibleCallId = '';

  bool isSystemIncomingUiActiveFor(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return false;

    if (_activeIncomingCallId.trim() == safe) return true;
    if (_pendingShowCallId.trim() == safe) return true;
    if (_activeIncomingCalls.contains(safe)) return true;

    final state = _callStates[safe] ?? '';
    return state == _stateIncomingRinging ||
        state == _stateAccepting ||
        state == _stateAcceptedOpening;
  }

  bool shouldSuppressCustomIncomingOverlay(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return false;

    if (_isRecentlyAccepted(safe)) return true;
    if (_callSession.active) return true;
    if (_openingVoiceFromCallkit) return true;
    if (_openingActiveVoiceScreen) return true;
    if (_voiceScreenOpeningCallId == safe) return true;
    if (_voiceScreenVisibleCallId == safe) return true;

    final state = _callStates[safe] ?? '';
    if (_isTerminalState(state)) return true;

    return isSystemIncomingUiActiveFor(safe);
  }

  void markIncomingUiShown(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return;

    _activeIncomingCallId = safe;
    _markIncomingState(safe, _stateIncomingRinging);
  }

  void _markIncomingState(String callId, String state) {
    final safe = callId.trim();
    if (safe.isEmpty) return;

    _callStates[safe] = state;

    if (state == _stateIncomingRinging ||
        state == _stateAccepting ||
        state == _stateAcceptedOpening) {
      _activeIncomingCalls.add(safe);
      return;
    }

    _activeIncomingCalls.remove(safe);
  }

  bool _isTerminalState(String state) {
    return state == _stateDismissed || state == _stateEnded;
  }

  void _markRecentlyAccepted(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return;

    _recentlyAcceptedCalls.add(safe);
    _recentAcceptExpiryTimers[safe]?.cancel();
    _recentAcceptExpiryTimers[safe] = Timer(_recentAcceptWindow, () {
      _recentlyAcceptedCalls.remove(safe);
      _recentAcceptExpiryTimers.remove(safe);
    });
  }

  bool _isRecentlyAccepted(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return false;
    return _recentlyAcceptedCalls.contains(safe);
  }

  void _clearRecentlyAccepted(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return;

    _recentAcceptExpiryTimers[safe]?.cancel();
    _recentAcceptExpiryTimers.remove(safe);
    _recentlyAcceptedCalls.remove(safe);
  }

  bool _shouldIgnoreIncomingUiForCall(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return true;

    if (_isRecentlyAccepted(safe)) return true;

    if (_callSession.active &&
        _callSession.callDocRef?.id == safe &&
        _openingVoiceFromCallkit == false) {
      return true;
    }

    if (_voiceScreenOpeningCallId == safe || _voiceScreenVisibleCallId == safe) {
      return true;
    }

    final state = _callStates[safe] ?? '';
    if (_isTerminalState(state)) return true;

    return _activeIncomingCalls.contains(safe) ||
        _activeIncomingCallId == safe ||
        _pendingShowCallId == safe;
  }

  Future<void> _stopIncomingWatcher() async {
    await _activeIncomingSub?.cancel();
    _activeIncomingSub = null;
  }

  void _cancelPendingShow([String? callId]) {
    final safe = (callId ?? '').trim();

    if (safe.isEmpty || _pendingShowCallId == safe) {
      _pendingShowTimer?.cancel();
      _pendingShowTimer = null;
      _pendingShowCallId = '';
    }
  }

  void _clearPerCallGuards(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return;

    _incomingUiOpsInProgress.remove(safe);
    _acceptOpsInProgress.remove(safe);
  }

  Future<void> clearIncomingUi([String? callId]) async {
    final safe = (callId ?? '').trim();

    _cancelPendingShow(callId);

    if (safe.isEmpty) {
      await _stopIncomingWatcher();
      _activeIncomingCallId = '';
      _activeIncomingCalls.clear();
      _callStates.clear();
      _incomingUiOpsInProgress.clear();
      _acceptOpsInProgress.clear();

      try {
        await FlutterCallkitIncoming.endAllCalls();
      } catch (_) {
        // ignore cleanup failure
      }
      return;
    }

    if (_activeIncomingCallId.trim() == safe) {
      await _stopIncomingWatcher();
      _activeIncomingCallId = '';
    }

    _activeIncomingCalls.remove(safe);
    _clearPerCallGuards(safe);

    final currentState = _callStates[safe] ?? '';
    if (!_isTerminalState(currentState)) {
      _callStates.remove(safe);
    }

    try {
      await FlutterCallkitIncoming.endCall(safe);
    } catch (_) {
      // ignore cleanup failure
    }
  }

  Map<String, dynamic> safeMap(dynamic value) {
    if (value is Map) {
      return value.map(
        (key, val) => MapEntry(key.toString(), val),
      );
    }
    return <String, dynamic>{};
  }

  String extractCallId(Map<String, dynamic> body) {
    final direct = (body['id'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;

    final extra = body['extra'];
    if (extra is Map) {
      final extraCallId = (extra['callId'] ?? '').toString().trim();
      if (extraCallId.isNotEmpty) return extraCallId;
    }

    return '';
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  Future<bool> _isStillValidIncomingCall(String callId) async {
    try {
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (myUid.isEmpty) return false;

      final snap =
          await FirebaseFirestore.instance.collection('calls').doc(callId).get();
      if (!snap.exists) return false;

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);
      final calleeId = _asString(data['calleeId']);

      return status == 'ringing' && calleeId == myUid;
    } catch (_) {
      return false;
    }
  }

  Future<void> _watchIncomingCall(String callId) async {
    await _stopIncomingWatcher();

    final ref = FirebaseFirestore.instance.collection('calls').doc(callId);

    _activeIncomingSub = ref.snapshots().listen((snap) async {
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

      if (!snap.exists) {
        _markIncomingState(callId, _stateEnded);
        await clearIncomingUi(callId);
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);
      final calleeId = _asString(data['calleeId']);

      if (calleeId != myUid ||
          status == 'ended' ||
          status == 'rejected' ||
          status.isEmpty) {
        _markIncomingState(callId, _stateEnded);
        await clearIncomingUi(callId);
        return;
      }

      if (status == 'accepted') {
        _markIncomingState(callId, _stateAcceptedOpening);
        await clearIncomingUi(callId);
        return;
      }
    }, onError: (_) async {
      _markIncomingState(callId, _stateEnded);
      await clearIncomingUi(callId);
    });
  }

  Future<void> _showIncomingCallUi({
    required String callId,
    required String callerName,
  }) async {
    final safeCallId = callId.trim();
    final safeCallerName =
        callerName.trim().isEmpty ? 'Someone' : callerName.trim();

    if (safeCallId.isEmpty) return;
    if (_shouldIgnoreIncomingUiForCall(safeCallId)) return;
    if (_incomingUiOpsInProgress.contains(safeCallId)) return;

    _incomingUiOpsInProgress.add(safeCallId);
    _activeIncomingCallId = safeCallId;
    _markIncomingState(safeCallId, _stateIncomingRinging);

    try {
      final stillValidBeforeShow = await _isStillValidIncomingCall(safeCallId);
      if (!stillValidBeforeShow || _shouldIgnoreIncomingUiForCall(safeCallId)) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      try {
        await FlutterCallkitIncoming.endCall(safeCallId);
      } catch (_) {
        // ignore stale same-call cleanup failure
      }

      final stillValidAfterCleanup = await _isStillValidIncomingCall(safeCallId);
      if (!stillValidAfterCleanup || _shouldIgnoreIncomingUiForCall(safeCallId)) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      final params = CallKitParams(
        id: safeCallId,
        nameCaller: safeCallerName,
        appName: 'Friendify',
        avatar: '',
        handle: 'Friendify audio call',
        type: 0,
        duration: 45000,
        textAccept: 'Accept',
        textDecline: 'Reject',
        extra: <String, dynamic>{
          'callId': safeCallId,
        },
        missedCallNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: false,
          subtitle: 'Missed call',
          callbackText: 'Call back',
        ),
        callingNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: false,
          subtitle: 'Incoming call',
          callbackText: 'Open',
        ),
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0F172A',
          backgroundUrl: '',
          actionColor: '#22C55E',
          textColor: '#FFFFFF',
          incomingCallNotificationChannelName: 'Incoming Call',
          missedCallNotificationChannelName: 'Missed Call',
          isShowCallID: false,
        ),
        ios: const IOSParams(
          iconName: 'CallKitLogo',
          handleType: 'generic',
          supportsVideo: false,
          maximumCallGroups: 1,
          maximumCallsPerCallGroup: 1,
          supportsDTMF: false,
          supportsHolding: false,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      await FlutterCallkitIncoming.showCallkitIncoming(params);
      await _watchIncomingCall(safeCallId);
    } finally {
      _incomingUiOpsInProgress.remove(safeCallId);
    }
  }

  Future<void> showIncomingCallFromMessage(RemoteMessage message) async {
    final data = message.data;
    await showIncomingCallFromPushData(data);
  }

  Future<void> showIncomingCallFromPushData(
    Map<String, dynamic> data,
  ) async {
    final type = (data['type'] ?? '').toString().trim();
    if (type != 'incoming_call') return;

    final callId = (data['callId'] ?? '').toString().trim();
    if (callId.isEmpty) return;
    if (_shouldIgnoreIncomingUiForCall(callId)) return;
    if (_isRecentlyAccepted(callId)) return;

    final callerName = (data['callerName'] ?? 'Someone').toString().trim();

    final firstCheck = await _isStillValidIncomingCall(callId);
    if (!firstCheck) {
      _markIncomingState(callId, _stateEnded);
      await clearIncomingUi(callId);
      return;
    }

    _cancelPendingShow();
    _pendingShowCallId = callId;
    _markIncomingState(callId, _stateIncomingRinging);

    _pendingShowTimer = Timer(_incomingShowDebounce, () async {
      final currentPending = _pendingShowCallId;
      _pendingShowTimer = null;
      _pendingShowCallId = '';

      if (currentPending != callId) return;
      if (_isRecentlyAccepted(callId)) return;
      if (_shouldIgnoreIncomingUiForCall(callId)) return;

      final secondCheck = await _isStillValidIncomingCall(callId);
      if (!secondCheck) {
        _markIncomingState(callId, _stateEnded);
        await clearIncomingUi(callId);
        return;
      }

      try {
        await _showIncomingCallUi(
          callId: callId,
          callerName: callerName,
        );
      } catch (e) {
        debugPrint('Show CallKit incoming failed: $e');
        _markIncomingState(callId, _stateEnded);
        await clearIncomingUi(callId);
      }
    });
  }

  Future<void> handleAcceptFromCallkit(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_acceptOpsInProgress.contains(safeCallId)) return;

    final currentState = _callStates[safeCallId] ?? '';
    if (currentState == _stateAccepting ||
        currentState == _stateAcceptedOpening) {
      return;
    }

    _acceptOpsInProgress.add(safeCallId);
    _cancelPendingShow(safeCallId);
    _markIncomingState(safeCallId, _stateAccepting);

    try {
      final ref = FirebaseFirestore.instance.collection('calls').doc(safeCallId);

      final snap = await ref.get();
      if (!snap.exists) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      final call = snap.data() ?? <String, dynamic>{};
      final status = _asString(call['status']);
      final calleeId = _asString(call['calleeId']);
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

      if (myUid.isEmpty) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      if (status != 'ringing' || calleeId != myUid) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      await _callRepository.acceptCallById(safeCallId);

      final after = await ref.get();
      final afterData = after.data() ?? <String, dynamic>{};
      final afterStatus = _asString(afterData['status']);
      final afterChannelId = _asString(afterData['channelId']);

      if (afterStatus != 'accepted' || afterChannelId.isEmpty) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      _markRecentlyAccepted(safeCallId);

      final ringingOthers = await FirebaseFirestore.instance
          .collection('calls')
          .where('calleeId', isEqualTo: myUid)
          .where('status', isEqualTo: 'ringing')
          .get();

      for (final d in ringingOthers.docs) {
        if (d.id == safeCallId) continue;
        try {
          await _callRepository.rejectCallById(
            d.id,
            rejectedReason: 'busy',
          );
        } catch (_) {
          // ignore cleanup failures
        }

        _markIncomingState(d.id, _stateEnded);
        await clearIncomingUi(d.id);
      }

      _markIncomingState(safeCallId, _stateAcceptedOpening);
      await openAcceptedCall(safeCallId);
    } catch (e) {
      debugPrint('Handle accept from CallKit failed: $e');
      _markIncomingState(safeCallId, _stateEnded);
      await clearIncomingUi(safeCallId);
    } finally {
      _acceptOpsInProgress.remove(safeCallId);
    }
  }

  Future<void> handleDeclineFromCallkit(
    String callId,
    String reason,
  ) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    _markIncomingState(safeCallId, _stateDismissed);
    _clearRecentlyAccepted(safeCallId);

    try {
      final ref = FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final snap = await ref.get();
      if (!snap.exists) {
        await clearIncomingUi(safeCallId);
        return;
      }

      final call = snap.data() ?? <String, dynamic>{};
      final status = _asString(call['status']);

      if (status == 'ringing') {
        await _callRepository.rejectCallById(
          safeCallId,
          rejectedReason: reason,
        );
      }

      await clearIncomingUi(safeCallId);
    } catch (e) {
      debugPrint('Handle decline from CallKit failed: $e');
      await clearIncomingUi(safeCallId);
    }
  }

  Future<void> handleTimeoutFromCallkit(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    _markIncomingState(safeCallId, _stateEnded);
    _clearRecentlyAccepted(safeCallId);

    try {
      final ref = FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final snap = await ref.get();

      if (!snap.exists) {
        await clearIncomingUi(safeCallId);
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);

      if (status == 'ringing') {
        await _callRepository.rejectCallById(
          safeCallId,
          rejectedReason: 'timeout',
        );
      }

      await clearIncomingUi(safeCallId);
    } catch (e) {
      debugPrint('Handle timeout from CallKit failed: $e');
      await clearIncomingUi(safeCallId);
    }
  }

  Future<void> handleEndedFromCallkit(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    final state = _callStates[safeCallId] ?? '';
    if (state == _stateAcceptedOpening || _isRecentlyAccepted(safeCallId)) {
      return;
    }

    _markIncomingState(safeCallId, _stateEnded);

    try {
      final ref = FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final snap = await ref.get();
      if (!snap.exists) {
        await clearIncomingUi(safeCallId);
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);

      if (status == 'ringing') {
        await _callRepository.rejectCallById(
          safeCallId,
          rejectedReason: 'callkit_ended',
        );
      }

      await clearIncomingUi(safeCallId);
    } catch (e) {
      debugPrint('Handle ended from CallKit failed: $e');
      await clearIncomingUi(safeCallId);
    }
  }

  Future<void> _openActiveVoiceScreen({String callId = ''}) async {
    final safeCallId = callId.trim();

    if (_openingActiveVoiceScreen) return;
    if (!_callSession.active) return;
    if (safeCallId.isNotEmpty && _voiceScreenOpeningCallId == safeCallId) {
      return;
    }
    if (safeCallId.isNotEmpty && _voiceScreenVisibleCallId == safeCallId) {
      return;
    }

    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    if (!nav.mounted) return;

    final currentContext = rootNavigatorKey.currentContext;
    if (currentContext != null) {
      final currentRoute = ModalRoute.of(currentContext);
      if (currentRoute?.settings.name == VoiceCallScreen.routeName) {
        if (safeCallId.isNotEmpty) {
          _voiceScreenVisibleCallId = safeCallId;
        }
        return;
      }
    }

    _openingActiveVoiceScreen = true;
    _voiceScreenOpeningCallId = safeCallId;

    try {
      if (safeCallId.isNotEmpty) {
        _voiceScreenVisibleCallId = safeCallId;
      }

      await nav.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: VoiceCallScreen.routeName),
          builder: (_) => const VoiceCallScreen(),
        ),
      );
    } catch (e) {
      debugPrint('Open active voice screen failed: $e');
    } finally {
      _openingActiveVoiceScreen = false;
      _voiceScreenOpeningCallId = '';
      _voiceScreenVisibleCallId = '';
    }
  }

  Future<void> openAcceptedCall(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_openingVoiceFromCallkit) return;

    _openingVoiceFromCallkit = true;
    _cancelPendingShow(safeCallId);
    _markIncomingState(safeCallId, _stateAcceptedOpening);
    _markRecentlyAccepted(safeCallId);

    try {
      final ref = FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

      if (myUid.isEmpty) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      for (int i = 0; i < 12; i++) {
        final snap = await ref.get();
        if (!snap.exists) {
          _markIncomingState(safeCallId, _stateEnded);
          await clearIncomingUi(safeCallId);
          return;
        }

        final call = snap.data() ?? <String, dynamic>{};
        final status = _asString(call['status']);
        final channelId = _asString(call['channelId']);
        final calleeId = _asString(call['calleeId']);

        if (calleeId != myUid) {
          _markIncomingState(safeCallId, _stateEnded);
          await clearIncomingUi(safeCallId);
          return;
        }

        if (status == 'accepted' && channelId.isNotEmpty) {
          final sameCallAlreadyActive =
              _callSession.active && _callSession.callDocRef?.path == ref.path;

          if (!sameCallAlreadyActive) {
            await _callSession.startOrAttach(
              callDocRef: ref,
              channelId: channelId,
              iAmCaller: false,
            );
          } else {
            await _callSession.syncWithServer();
          }

          if (!_callSession.active) {
            _markIncomingState(safeCallId, _stateEnded);
            await clearIncomingUi(safeCallId);
            return;
          }

          _voiceScreenVisibleCallId = safeCallId;
          await clearIncomingUi(safeCallId);
          await _openActiveVoiceScreen(callId: safeCallId);
          return;
        }

        if (status == 'ended' || status == 'rejected') {
          _markIncomingState(safeCallId, _stateEnded);
          await clearIncomingUi(safeCallId);
          return;
        }

        await Future.delayed(const Duration(milliseconds: 250));
      }

      _markIncomingState(safeCallId, _stateEnded);
      await clearIncomingUi(safeCallId);
    } catch (e) {
      debugPrint('Open accepted call from CallKit failed: $e');
      _markIncomingState(safeCallId, _stateEnded);
      await clearIncomingUi(safeCallId);
    } finally {
      _openingVoiceFromCallkit = false;
    }
  }

  Future<void> recoverCallFromPushOpen(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_isRecentlyAccepted(safeCallId)) return;

    try {
      final ref = FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final snap = await ref.get();
      if (!snap.exists) return;

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);
      final calleeId = _asString(data['calleeId']);
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

      if (calleeId != myUid) return;

      if (status == 'accepted') {
        _markIncomingState(safeCallId, _stateAcceptedOpening);
        _markRecentlyAccepted(safeCallId);
        await openAcceptedCall(safeCallId);
        return;
      }

      if (status == 'ringing') {
        if (_shouldIgnoreIncomingUiForCall(safeCallId)) return;

        final stillValid = await _isStillValidIncomingCall(safeCallId);
        if (!stillValid) {
          _markIncomingState(safeCallId, _stateEnded);
          await clearIncomingUi(safeCallId);
          return;
        }

        final callerName = _asString(data['callerName'], fallback: 'Someone');
        await _showIncomingCallUi(
          callId: safeCallId,
          callerName: callerName,
        );
      }
    } catch (e) {
      debugPrint('Recover call from push open failed: $e');
    }
  }
}