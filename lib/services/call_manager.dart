import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../app.dart';
import '../core/constants/agora_client_config.dart';
import '../core/constants/call_timing.dart';
import '../core/constants/firestore_paths.dart';
import '../core/constants/ui_copy.dart';
import '../repositories/call_repository.dart';
import '../screens/voice_call_screen.dart';
import 'app_log.dart';
import 'call_latency_tracker.dart';
import 'call_session_manager.dart';
import 'firestore_service.dart';

class CallManager {
  CallManager._();

  static final CallManager instance = CallManager._();

  static const Duration _incomingShowDebounce = Duration(milliseconds: 80);
  static const Duration _recentAcceptWindow = Duration(seconds: 6);
  static const MethodChannel _nativeBridgeChannel =
      MethodChannel('friendify/native_call_bridge');

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
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _activeIncomingSub;
  Timer? _pendingShowTimer;
  String _pendingShowCallId = '';

  final Set<String> _activeIncomingCalls = <String>{};
  final Map<String, String> _callStates = <String, String>{};

  final Set<String> _recentlyAcceptedCalls = <String>{};
  final Map<String, Timer> _recentAcceptExpiryTimers = <String, Timer>{};

  final Set<String> _incomingUiOpsInProgress = <String>{};
  final Set<String> _acceptOpsInProgress = <String>{};
  final Set<String> _nativeActionKeys = <String>{};

  String _voiceScreenOpeningCallId = '';
  String _voiceScreenVisibleCallId = '';
  String _nativeOngoingCallId = '';
  String _nativeOngoingState = '';
  bool _nativeBridgeStarted = false;
  bool _nativeOngoingSyncScheduled = false;
  bool _nativeOngoingStartupCleanupDone = false;

  Future<void> startNativeCallBridge() async {
    if (_nativeBridgeStarted) return;
    _nativeBridgeStarted = true;

    _nativeBridgeChannel.setMethodCallHandler(_handleNativeBridgeCall);
    _callSession.addListener(_scheduleNativeOngoingSync);

    try {
      final pending = await _nativeBridgeChannel
          .invokeMethod<dynamic>('consumePendingNativeCallActions');
      await _handleNativeActionList(pending);
    } catch (e) {
      debugPrint(
        'NativeCallBridge pending consume failed: ${e.runtimeType}',
      );
    }

    _scheduleNativeOngoingSync();
  }

  Future<String> nativeFullScreenCallPermissionStatus() async {
    try {
      final status = await _nativeBridgeChannel.invokeMethod<String>(
        'getFullScreenCallPermissionStatus',
      );
      final safeStatus = (status ?? '').trim();
      return safeStatus.isEmpty ? 'Unknown' : safeStatus;
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<dynamic> _handleNativeBridgeCall(MethodCall call) async {
    switch (call.method) {
      case 'nativeCallAction':
        await _handleNativeCallAction(safeMap(call.arguments));
        return true;
      default:
        throw MissingPluginException(
          'Unknown native call bridge method: ${call.method}',
        );
    }
  }

  Future<void> _handleNativeActionList(dynamic value) async {
    if (value is! List) return;
    for (final item in value) {
      await _handleNativeCallAction(safeMap(item));
    }
  }

  Future<void> _handleNativeCallAction(Map<String, dynamic> action) async {
    final actionName = _asString(action['action']);
    final callId = _asString(action['callId']);
    final source = _asString(action['source'], fallback: 'native_notification');
    if (actionName.isEmpty || callId.isEmpty) return;

    if (_nativeActionNeedsAuth(actionName)) {
      await _waitForSignedInUid();
    }

    final key = '$actionName::$callId';
    CallLatencyTracker.trace(
      'native_call.action_received',
      callId: callId,
      actorRole: actionName == 'hangup_call' ? 'participant' : 'callee',
      extra: <String, Object?>{'action': actionName, 'source': source},
    );

    if (_nativeActionKeys.contains(key)) {
      CallLatencyTracker.trace(
        'native_call.action_duplicate_ignored',
        callId: callId,
        actorRole: 'callee',
        extra: <String, Object?>{'action': actionName, 'source': source},
      );
      return;
    }
    _nativeActionKeys.add(key);

    if (_nativeActionKeys.length > 24) {
      _nativeActionKeys.remove(_nativeActionKeys.first);
    }

    switch (actionName) {
      case 'answer_call':
        await handleAcceptFromCallkit(callId);
        break;
      case 'reject_call':
        await handleDeclineFromCallkit(
          callId,
          FirestorePaths.reasonCalleeReject,
        );
        break;
      case 'hangup_call':
        await _handleNativeHangup(callId);
        break;
      case 'open_call':
      default:
        await recoverCallFromPushOpen(callId);
        break;
    }

    CallLatencyTracker.trace(
      'native_call.action_delivered_once',
      callId: callId,
      actorRole: actionName == 'hangup_call' ? 'participant' : 'callee',
      extra: <String, Object?>{'action': actionName, 'source': source},
    );
  }

  bool _nativeActionNeedsAuth(String actionName) {
    return actionName == 'answer_call' ||
        actionName == 'reject_call' ||
        actionName == 'open_call';
  }

  Future<String> _waitForSignedInUid({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (currentUid.isNotEmpty) return currentUid;

    try {
      final user = await FirebaseAuth.instance
          .authStateChanges()
          .firstWhere((user) => (user?.uid.trim() ?? '').isNotEmpty)
          .timeout(timeout);
      return user?.uid.trim() ?? '';
    } catch (_) {
      return FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    }
  }

  Future<void> _handleNativeHangup(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    final activeCallId = _callSession.callDocRef?.id.trim() ?? '';
    if (_callSession.active && activeCallId == safeCallId) {
      await _callSession.endCall(reason: FirestorePaths.reasonUserEnd);
    } else {
      await clearIncomingUi(safeCallId);
    }

    await _stopNativeOngoingNotification(safeCallId);
  }

  void _scheduleNativeOngoingSync() {
    if (_nativeOngoingSyncScheduled) return;
    _nativeOngoingSyncScheduled = true;
    scheduleMicrotask(() async {
      _nativeOngoingSyncScheduled = false;
      await _syncNativeOngoingNotification();
    });
  }

  Future<void> _syncNativeOngoingNotification() async {
    final callId = _callSession.callDocRef?.id.trim() ?? '';
    final state = _callSession.state;
    final shouldShow = callId.isNotEmpty &&
        (state == CallState.preparing ||
            state == CallState.joining ||
            state == CallState.connected ||
            state == CallState.reconnecting);

    if (!shouldShow) {
      if (_nativeOngoingCallId.isNotEmpty) {
        await _stopNativeOngoingNotification(_nativeOngoingCallId);
        _nativeOngoingCallId = '';
        _nativeOngoingState = '';
      } else if (!_nativeOngoingStartupCleanupDone) {
        _nativeOngoingStartupCleanupDone = true;
        await _cleanupUnknownNativeOngoingNotification();
      }
      return;
    }

    _nativeOngoingStartupCleanupDone = false;
    final nextState = state.name;
    if (_nativeOngoingCallId == callId && _nativeOngoingState == nextState) {
      return;
    }

    final displayName = _nativeOngoingDisplayName();
    try {
      final started = await _nativeBridgeChannel.invokeMethod<bool>(
        'startOngoingCallNotification',
        <String, Object?>{
          'callId': callId,
          'displayName': displayName,
          'state': nextState,
        },
      );
      if (started != true) return;
      _nativeOngoingCallId = callId;
      _nativeOngoingState = nextState;
      CallLatencyTracker.trace(
        'native_call.ongoing_started',
        callId: callId,
        actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
        extra: <String, Object?>{'state': nextState},
      );
    } catch (e) {
      debugPrint(
        'Native ongoing notification start failed for '
        '${AppLog.safeId(callId)}: ${e.runtimeType}',
      );
    }
  }

  Future<void> _stopNativeOngoingNotification(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    try {
      await _nativeBridgeChannel.invokeMethod<void>(
        'stopOngoingCallNotification',
        <String, Object?>{'callId': safeCallId},
      );
      CallLatencyTracker.trace(
        'native_call.ongoing_stopped',
        callId: safeCallId,
        actorRole: 'participant',
      );
    } catch (_) {
      // Best-effort native notification cleanup.
    }
  }

  Future<void> _cleanupUnknownNativeOngoingNotification() async {
    try {
      await _nativeBridgeChannel.invokeMethod<void>(
        'stopOngoingCallNotification',
        <String, Object?>{'callId': ''},
      );
    } catch (_) {
      // Best-effort stale foreground service cleanup.
    }
  }

  Future<void> _cancelNativeIncomingNotification(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    try {
      await _nativeBridgeChannel.invokeMethod<void>(
        'cancelIncomingCallNotification',
        <String, Object?>{'callId': safeCallId},
      );
    } catch (_) {
      // Best-effort native notification cleanup.
    }
  }

  String _nativeOngoingDisplayName() {
    final call = _callSession.call;
    final preferred = _callSession.iAmCaller
        ? _asString(call['calleeName'])
        : _asString(call['callerName']);
    if (preferred.isNotEmpty) return preferred;
    return 'Friendify call';
  }

  bool isSystemIncomingUiActiveFor(String callId) {
    final safe = callId.trim();
    if (safe.isEmpty) return false;

    if (_activeIncomingCallId.trim() == safe) return true;
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

  bool get hasActiveCallContext {
    return _callSession.callDocRef != null ||
        _callSession.active ||
        _openingVoiceFromCallkit ||
        _openingActiveVoiceScreen ||
        _voiceScreenOpeningCallId.isNotEmpty ||
        _voiceScreenVisibleCallId.isNotEmpty ||
        _activeIncomingCallId.isNotEmpty ||
        _activeIncomingCalls.isNotEmpty ||
        _incomingUiOpsInProgress.isNotEmpty ||
        (_pendingShowTimer?.isActive ?? false);
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

    if (state == _stateAccepting || state == _stateAcceptedOpening) {
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

    if (_callSession.active) {
      final activeCallId = _callSession.callDocRef?.id.trim() ?? '';
      CallLatencyTracker.trace(
        'call.incoming_skipped_active_call',
        callId: safe,
        actorRole: 'callee',
        extra: <String, Object?>{
          'activeCallId': activeCallId,
          'sameCall': activeCallId == safe,
        },
      );
      return true;
    }

    if (_voiceScreenOpeningCallId == safe ||
        _voiceScreenVisibleCallId == safe) {
      return true;
    }

    final state = _callStates[safe] ?? '';
    if (_isTerminalState(state)) return true;

    return _activeIncomingCalls.contains(safe) || _activeIncomingCallId == safe;
  }

  Future<void> _stopIncomingWatcher() async {
    await _activeIncomingSub?.cancel();
    _activeIncomingSub = null;
  }

  Future<void> disposeForUid(String uid) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return;

    await clearIncomingUi();
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

    final pendingNativeCallId = _pendingShowCallId.trim();
    _cancelPendingShow(callId);

    if (safe.isEmpty) {
      final nativeIncomingIds = <String>{
        _activeIncomingCallId.trim(),
        pendingNativeCallId,
        ..._activeIncomingCalls.map((callId) => callId.trim()),
      }..removeWhere((callId) => callId.isEmpty);
      for (final nativeCallId in nativeIncomingIds) {
        await _cancelNativeIncomingNotification(nativeCallId);
      }

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

    await _cancelNativeIncomingNotification(safe);

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
      final myUid = await _waitForSignedInUid();
      if (myUid.isEmpty) return false;

      final snap = await FirebaseFirestore.instance
          .collection('calls')
          .doc(callId)
          .get();
      if (!snap.exists) return false;

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);
      final calleeId = _asString(data['calleeId']);

      return status == 'ringing' && calleeId == myUid;
    } catch (e) {
      debugPrint('call.incoming_validation_deferred: ${e.runtimeType}');
      return true;
    }
  }

  Future<void> _watchIncomingCall(String callId) async {
    await _stopIncomingWatcher();

    final ref = FirebaseFirestore.instance.collection('calls').doc(callId);

    _activeIncomingSub = ref.snapshots().listen((snap) async {
      final myUid = await _waitForSignedInUid();

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
    }, onError: (Object error) {
      debugPrint('call.incoming_watch_deferred: ${error.runtimeType}');
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
    if (_shouldIgnoreIncomingUiForCall(safeCallId)) {
      debugPrint(
        'incoming_ui.deduped_existing_callId '
        'callId=${AppLog.safeId(safeCallId)}',
      );
      debugPrint('call.incoming_ui_deduped');
      return;
    }
    if (_incomingUiOpsInProgress.contains(safeCallId)) {
      debugPrint(
        'incoming_ui.deduped_existing_callId '
        'callId=${AppLog.safeId(safeCallId)}',
      );
      debugPrint('call.incoming_ui_deduped');
      return;
    }

    _incomingUiOpsInProgress.add(safeCallId);
    _markIncomingState(safeCallId, _stateIncomingRinging);

    try {
      final params = CallKitParams(
        id: safeCallId,
        nameCaller: safeCallerName,
        appName: 'Friendify',
        avatar: '',
        handle: 'Friendify audio call',
        type: 0,
        duration: CallTiming.incomingRingTimeoutSeconds * 1000,
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
          showNotification: false,
          isShowCallback: false,
          subtitle: 'Incoming call',
          callbackText: 'Open',
        ),
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
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

      CallLatencyTracker.trace(
        'call.incoming_callkit_show_begin',
        callId: safeCallId,
        actorRole: 'callee',
      );
      debugPrint(
        'incoming_ui.owner=background_native '
        'callId=${AppLog.safeId(safeCallId)}',
      );
      debugPrint(
        'callkit.payload_prepared callIdShort=${AppLog.safeId(safeCallId)}',
      );
      try {
        await FlutterCallkitIncoming.showCallkitIncoming(params);
      } catch (e) {
        CallLatencyTracker.trace(
          'call.incoming_callkit_show_failed',
          callId: safeCallId,
          actorRole: 'callee',
          extra: <String, Object?>{'errorType': e.runtimeType.toString()},
        );
        rethrow;
      }
      _activeIncomingCallId = safeCallId;
      _activeIncomingCalls.add(safeCallId);
      CallLatencyTracker.trace(
        'call.incoming_callkit_show_success',
        callId: safeCallId,
        actorRole: 'callee',
      );
      CallLatencyTracker.trace(
        'call.incoming_notification_shown',
        callId: safeCallId,
        actorRole: 'callee',
      );
      await _watchIncomingCall(safeCallId);
      unawaited(_clearIfIncomingCallInvalidAfterShow(safeCallId));
    } finally {
      _incomingUiOpsInProgress.remove(safeCallId);
    }
  }

  Future<void> _clearIfIncomingCallInvalidAfterShow(String callId) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    CallLatencyTracker.trace(
      'call.incoming_validation_begin',
      callId: callId,
      actorRole: 'callee',
    );
    if (!await _isStillValidIncomingCall(callId)) {
      CallLatencyTracker.trace(
        'call.incoming_validation_failed',
        callId: callId,
        actorRole: 'callee',
      );
      _markIncomingState(callId, _stateEnded);
      await clearIncomingUi(callId);
      return;
    }
    CallLatencyTracker.trace(
      'call.incoming_validation_success',
      callId: callId,
      actorRole: 'callee',
    );
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
    CallLatencyTracker.trace(
      'call.incoming_fcm_received',
      callId: callId,
      actorRole: 'callee',
    );
    if (_isAppInForeground) {
      CallLatencyTracker.trace(
        'call.incoming_foreground_overlay_preferred',
        callId: callId,
        actorRole: 'callee',
      );
      debugPrint(
        'call.incoming_foreground_overlay_preferred '
        'callId=${AppLog.safeId(callId)}',
      );
      debugPrint(
        'incoming_ui.owner=foreground_flutter_overlay '
        'callId=${AppLog.safeId(callId)}',
      );
      return;
    }
    if (_shouldIgnoreIncomingUiForCall(callId)) {
      debugPrint(
        'incoming_ui.deduped_existing_callId '
        'callId=${AppLog.safeId(callId)}',
      );
      debugPrint('call.incoming_ui_deduped');
      return;
    }
    if (_isRecentlyAccepted(callId)) {
      debugPrint(
        'incoming_ui.deduped_existing_callId '
        'callId=${AppLog.safeId(callId)}',
      );
      debugPrint('call.incoming_ui_deduped');
      return;
    }
    if (_pendingShowCallId == callId && _pendingShowTimer != null) {
      debugPrint(
        'incoming_ui.deduped_existing_callId '
        'callId=${AppLog.safeId(callId)}',
      );
      debugPrint('call.incoming_ui_deduped');
      return;
    }

    final callerName = (data['callerName'] ?? 'Someone').toString().trim();

    _cancelPendingShow();
    _pendingShowCallId = callId;
    _markIncomingState(callId, _stateIncomingRinging);
    CallLatencyTracker.trace(
      'call.incoming_push_queued',
      callId: callId,
      actorRole: 'callee',
    );

    _pendingShowTimer = Timer(_incomingShowDebounce, () async {
      final currentPending = _pendingShowCallId;
      _pendingShowTimer = null;
      _pendingShowCallId = '';

      if (currentPending != callId) return;
      if (_isRecentlyAccepted(callId)) {
        debugPrint(
          'incoming_ui.deduped_existing_callId '
          'callId=${AppLog.safeId(callId)}',
        );
        debugPrint('call.incoming_ui_deduped');
        return;
      }
      if (_shouldIgnoreIncomingUiForCall(callId)) {
        debugPrint(
          'incoming_ui.deduped_existing_callId '
          'callId=${AppLog.safeId(callId)}',
        );
        debugPrint('call.incoming_ui_deduped');
        return;
      }

      try {
        await _showIncomingCallUi(
          callId: callId,
          callerName: callerName,
        );
      } catch (e) {
        CallLatencyTracker.trace(
          'call.incoming_callkit_show_failed',
          callId: callId,
          actorRole: 'callee',
          extra: <String, Object?>{'errorType': e.runtimeType.toString()},
        );
        debugPrint('Show CallKit incoming failed: ${e.runtimeType}');
        _markIncomingState(callId, _stateEnded);
        await clearIncomingUi(callId);
      }
    });
  }

  bool get _isAppInForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.resumed;
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
    CallLatencyTracker.trace(
      'call.accept_tap',
      callId: safeCallId,
      actorRole: 'callee',
    );
    _cancelPendingShow(safeCallId);
    _markIncomingState(safeCallId, _stateAccepting);

    try {
      if (AgoraClientConfig.resolvedAppId.isEmpty) {
        rootMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text(UiCopy.callSetupNotReady),
          ),
        );
        if (kDebugMode) {
          debugPrint(AgoraClientConfig.developerRunCommandMessage);
        }
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      final myUid = await _waitForSignedInUid();

      if (myUid.isEmpty) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      final acceptResult = await _callRepository.acceptCallById(safeCallId);
      if (acceptResult == null ||
          acceptResult.status != 'accepted' ||
          !acceptResult.canOpenVoiceScreen) {
        final failureReason = acceptResult == null
            ? 'empty_accept_result'
            : acceptResult.status != 'accepted'
                ? 'unexpected_accept_status'
                : 'channel_missing';
        _traceAcceptFailure(
          safeCallId,
          failureReason,
          extra: <String, Object?>{
            'status': acceptResult?.status ?? 'null',
            'channelIdPresent': acceptResult?.channelId.trim().isNotEmpty,
            'tokenPresent': acceptResult?.agoraToken.trim().isNotEmpty,
            'agoraUidPresent': (acceptResult?.agoraUid ?? 0) > 0,
          },
        );
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      _markRecentlyAccepted(safeCallId);
      unawaited(_cleanupOtherRingingCalls(
        acceptedCallId: safeCallId,
        calleeId: myUid,
      ));

      _markIncomingState(safeCallId, _stateAcceptedOpening);
      CallLatencyTracker.trace(
        'call.accept_open_voice_begin',
        callId: safeCallId,
        actorRole: 'callee',
      );
      await openAcceptedCall(
        safeCallId,
        initialChannelId: acceptResult.channelId,
        initialAgoraToken: acceptResult.agoraToken,
        initialAgoraUid: acceptResult.agoraUid,
      );
    } catch (e) {
      final failureReason = _safeAcceptFailureReason(e);
      _traceAcceptFailure(safeCallId, failureReason);
      final networkFailure = failureReason == 'service_unavailable' ||
          failureReason == 'deadline_exceeded' ||
          failureReason == 'timeout';
      rootMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            networkFailure
                ? 'Internet connection is unstable. Please check network and try again.'
                : 'Call could not connect. Please try again.',
          ),
        ),
      );
      _markIncomingState(safeCallId, _stateEnded);
      await clearIncomingUi(safeCallId);
    } finally {
      _acceptOpsInProgress.remove(safeCallId);
    }
  }

  String _safeAcceptFailureReason(Object error) {
    if (error is FirebaseFunctionsException) {
      final reason = FirestoreService.functionFailureReason(error);
      if (reason.isNotEmpty) return reason;
      switch (error.code) {
        case 'deadline-exceeded':
          return 'deadline_exceeded';
        case 'unavailable':
          return 'service_unavailable';
        case 'unauthenticated':
          return 'unauthenticated';
        case 'not-found':
          return 'call_not_found';
        case 'failed-precondition':
          return 'failed_precondition';
        default:
          return 'functions_${error.code}';
      }
    }
    if (error is FirebaseException) {
      switch (error.code) {
        case 'unavailable':
          return 'service_unavailable';
        case 'permission-denied':
          return 'permission_denied';
        default:
          return 'firebase_${error.code}';
      }
    }
    if (error is TimeoutException) return 'timeout';
    return 'unexpected_error';
  }

  void _traceAcceptFailure(
    String callId,
    String failureReason, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final safeReason = failureReason.trim().isEmpty
        ? 'unknown'
        : failureReason.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    CallLatencyTracker.trace(
      'call.accept_callable_failed',
      callId: callId,
      actorRole: 'callee',
      extra: <String, Object?>{
        'reason': safeReason,
        ...extra,
      },
    );
    debugPrint('call.accept_callable_failed reason=$safeReason');
  }

  Future<void> _cleanupOtherRingingCalls({
    required String acceptedCallId,
    required String calleeId,
  }) async {
    CallLatencyTracker.trace(
      'call.accept_cleanup_others_begin',
      callId: acceptedCallId,
      actorRole: 'callee',
    );

    try {
      final ringingOthers = await FirebaseFirestore.instance
          .collection('calls')
          .where('calleeId', isEqualTo: calleeId)
          .where('status', isEqualTo: 'ringing')
          .get();

      for (final d in ringingOthers.docs) {
        if (d.id == acceptedCallId) continue;
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
    } finally {
      CallLatencyTracker.trace(
        'call.accept_cleanup_others_success',
        callId: acceptedCallId,
        actorRole: 'callee',
      );
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
      await _waitForSignedInUid();
      await FirestoreService.rejectCallById(
        safeCallId,
        rejectedReason: reason,
      );
      await clearIncomingUi(safeCallId);
    } catch (e) {
      debugPrint('Handle decline from CallKit failed: ${e.runtimeType}');
      await clearIncomingUi(safeCallId);
    }
  }

  Future<void> handleTimeoutFromCallkit(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    _markIncomingState(safeCallId, _stateEnded);
    _clearRecentlyAccepted(safeCallId);

    try {
      final ref =
          FirebaseFirestore.instance.collection('calls').doc(safeCallId);
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
      debugPrint('Handle timeout from CallKit failed: ${e.runtimeType}');
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
      final ref =
          FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final snap = await ref.get();
      if (!snap.exists) {
        await clearIncomingUi(safeCallId);
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);

      if (status == 'ringing') {
        CallLatencyTracker.trace(
          'call.callkit_end_ignored_ringing_cleanup_only',
          callId: safeCallId,
          actorRole: 'callee',
        );
      }

      await clearIncomingUi(safeCallId);
    } catch (e) {
      debugPrint('Handle ended from CallKit failed: ${e.runtimeType}');
      await clearIncomingUi(safeCallId);
    }
  }

  Future<bool> _openActiveVoiceScreen({
    String callId = '',
    String source = 'unknown',
  }) async {
    final safeCallId = callId.trim();

    if (_openingActiveVoiceScreen) {
      CallLatencyTracker.trace(
        'call.active_call_reopen_blocked',
        callId: safeCallId,
        actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
        extra: <String, Object?>{
          'source': source,
          'reason': 'open_in_progress',
        },
      );
      return false;
    }
    if (!_callSession.active) {
      if (safeCallId.isNotEmpty) {
        CallLatencyTracker.trace(
          'call.active_call_reopen_blocked',
          callId: safeCallId,
          actorRole: 'participant',
          extra: <String, Object?>{
            'source': source,
            'reason': 'no_active_session',
          },
        );
      }
      return false;
    }
    if (safeCallId.isNotEmpty && _voiceScreenOpeningCallId == safeCallId) {
      CallLatencyTracker.trace(
        'call.active_call_reopen_blocked',
        callId: safeCallId,
        actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
        extra: <String, Object?>{
          'source': source,
          'reason': 'same_call_opening',
        },
      );
      return false;
    }

    final nav = rootNavigatorKey.currentState;
    if (nav == null || !nav.mounted) {
      if (safeCallId.isNotEmpty) {
        CallLatencyTracker.trace(
          'call.active_call_reopen_blocked',
          callId: safeCallId,
          actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
          extra: <String, Object?>{
            'source': source,
            'reason': 'navigator_unavailable',
          },
        );
      }
      return false;
    }

    final currentContext = rootNavigatorKey.currentContext;
    if (currentContext != null) {
      final currentRoute = ModalRoute.of(currentContext);
      if (currentRoute?.settings.name == VoiceCallScreen.routeName) {
        if (safeCallId.isNotEmpty) {
          _voiceScreenVisibleCallId = safeCallId;
        }
        CallLatencyTracker.trace(
          'call.active_call_reopen_already_visible',
          callId: safeCallId,
          actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
          extra: <String, Object?>{'source': source},
        );
        return true;
      }
    }

    _openingActiveVoiceScreen = true;
    _voiceScreenOpeningCallId = safeCallId;

    try {
      if (safeCallId.isNotEmpty) {
        _voiceScreenVisibleCallId = safeCallId;
      }

      CallLatencyTracker.trace(
        'call.active_call_reopen_push_begin',
        callId: safeCallId,
        actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
        extra: <String, Object?>{'source': source},
      );

      final routeFuture = nav.push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: VoiceCallScreen.routeName),
          builder: (_) => const VoiceCallScreen(),
        ),
      );
      CallLatencyTracker.trace(
        'call.active_call_reopen_push_success',
        callId: safeCallId,
        actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
        extra: <String, Object?>{'source': source},
      );

      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 700), () {
          if (_voiceScreenOpeningCallId == safeCallId) {
            _voiceScreenOpeningCallId = '';
          }
          _openingActiveVoiceScreen = false;
        }),
      );
      unawaited(
        routeFuture.whenComplete(() {
          if (_voiceScreenVisibleCallId == safeCallId) {
            _voiceScreenVisibleCallId = '';
          }
          if (_voiceScreenOpeningCallId == safeCallId) {
            _voiceScreenOpeningCallId = '';
          }
          _openingActiveVoiceScreen = false;
        }),
      );
      return true;
    } catch (e) {
      debugPrint('Open active voice screen failed: ${e.runtimeType}');
      CallLatencyTracker.trace(
        'call.active_call_reopen_blocked',
        callId: safeCallId,
        actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
        extra: <String, Object?>{
          'source': source,
          'reason': 'push_failed',
          'errorType': e.runtimeType.toString(),
        },
      );
      _openingActiveVoiceScreen = false;
      _voiceScreenOpeningCallId = '';
      _voiceScreenVisibleCallId = '';
      return false;
    }
  }

  Future<void> openActiveCallScreen({
    String source = 'unknown',
  }) async {
    final callId = _callSession.callDocRef?.id.trim() ?? '';
    if (!_callSession.active || callId.isEmpty) {
      CallLatencyTracker.trace(
        'call.active_call_reopen_blocked',
        callId: callId,
        actorRole: 'participant',
        extra: <String, Object?>{
          'source': source,
          'reason': 'no_active_session',
        },
      );
      return;
    }

    CallLatencyTracker.trace(
      'call.active_call_reopen_begin',
      callId: callId,
      actorRole: _callSession.iAmCaller ? 'caller' : 'callee',
      extra: <String, Object?>{'source': source},
    );

    await _openActiveVoiceScreen(callId: callId, source: source);
  }

  Future<void> openAcceptedCall(
    String callId, {
    String initialChannelId = '',
    String initialAgoraToken = '',
    int initialAgoraUid = 0,
  }) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_openingVoiceFromCallkit) return;

    _openingVoiceFromCallkit = true;
    _cancelPendingShow(safeCallId);
    _markIncomingState(safeCallId, _stateAcceptedOpening);
    _markRecentlyAccepted(safeCallId);

    try {
      final ref =
          FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final myUid = await _waitForSignedInUid();

      if (myUid.isEmpty) {
        _markIncomingState(safeCallId, _stateEnded);
        await clearIncomingUi(safeCallId);
        return;
      }

      final fastChannelId = initialChannelId.trim();
      if (fastChannelId.isNotEmpty) {
        final sameCallAlreadyActive =
            _callSession.active && _callSession.callDocRef?.path == ref.path;

        if (!sameCallAlreadyActive) {
          await _callSession.startOrAttach(
            callDocRef: ref,
            channelId: fastChannelId,
            iAmCaller: false,
            initialAgoraToken: initialAgoraToken,
            initialAgoraUid: initialAgoraUid,
          );
        } else {
          await _callSession.syncWithServer();
        }

        if (_callSession.active) {
          await clearIncomingUi(safeCallId);
          CallLatencyTracker.trace(
            'call.accept_open_voice_success',
            callId: safeCallId,
            actorRole: 'callee',
          );
          await _openActiveVoiceScreen(
            callId: safeCallId,
            source: 'accept_fast_path',
          );
          return;
        }
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
              initialAgoraToken: initialAgoraToken,
              initialAgoraUid: initialAgoraUid,
            );
          } else {
            await _callSession.syncWithServer();
          }

          if (!_callSession.active) {
            _markIncomingState(safeCallId, _stateEnded);
            await clearIncomingUi(safeCallId);
            return;
          }

          await clearIncomingUi(safeCallId);
          CallLatencyTracker.trace(
            'call.accept_open_voice_success',
            callId: safeCallId,
            actorRole: 'callee',
          );
          await _openActiveVoiceScreen(
            callId: safeCallId,
            source: 'accept_restore_path',
          );
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
      final failureReason = _safeAcceptFailureReason(e);
      CallLatencyTracker.trace(
        'call.setup_failed',
        callId: safeCallId,
        actorRole: 'callee',
        extra: <String, Object?>{
          'failureReason': failureReason,
          'appIdPresent': AgoraClientConfig.resolvedAppId.isNotEmpty,
          'tokenPresent': initialAgoraToken.trim().isNotEmpty,
          'channelIdPresent': initialChannelId.trim().isNotEmpty,
          'agoraUidPresent': initialAgoraUid > 0,
          'micPermissionResult': 'unknown',
        },
      );
      debugPrint(
        'call.setup_failed '
        'failureReason=$failureReason '
        'appIdPresent=${AgoraClientConfig.resolvedAppId.isNotEmpty} '
        'tokenPresent=${initialAgoraToken.trim().isNotEmpty} '
        'channelIdPresent=${initialChannelId.trim().isNotEmpty} '
        'agoraUidPresent=${initialAgoraUid > 0} '
        'micPermissionResult=unknown',
      );
      _markIncomingState(safeCallId, _stateEnded);
      await clearIncomingUi(safeCallId);
    } finally {
      _openingVoiceFromCallkit = false;
    }
  }

  Future<void> recoverCallFromPushOpen(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;

    try {
      final ref =
          FirebaseFirestore.instance.collection('calls').doc(safeCallId);
      final snap = await ref.get();
      if (!snap.exists) return;

      final data = snap.data() ?? <String, dynamic>{};
      final status = _asString(data['status']);
      final callerId = _asString(data['callerId']);
      final calleeId = _asString(data['calleeId']);
      final myUid = await _waitForSignedInUid();

      final iAmCaller = callerId == myUid;
      final iAmCallee = calleeId == myUid;
      if (!iAmCaller && !iAmCallee) return;

      if (status == 'accepted') {
        final activeCallId = _callSession.callDocRef?.id.trim() ?? '';
        if (_callSession.active && activeCallId == safeCallId) {
          await openActiveCallScreen(source: 'native_open_call');
          return;
        }

        if (iAmCaller) {
          final channelId = _asString(data['channelId']);
          if (channelId.isEmpty) return;

          await _callSession.startOrAttach(
            callDocRef: ref,
            channelId: channelId,
            iAmCaller: true,
          );
          if (_callSession.active) {
            await openActiveCallScreen(source: 'native_open_call_recovered');
          }
          return;
        }

        _markIncomingState(safeCallId, _stateAcceptedOpening);
        _markRecentlyAccepted(safeCallId);
        await openAcceptedCall(safeCallId);
        return;
      }

      if (status == 'ringing' && iAmCallee) {
        if (_shouldIgnoreIncomingUiForCall(safeCallId)) {
          debugPrint('call.incoming_ui_deduped');
          return;
        }

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
      debugPrint('Recover call from push open failed: ${e.runtimeType}');
    }
  }
}
