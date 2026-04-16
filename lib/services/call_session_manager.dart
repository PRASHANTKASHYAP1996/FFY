import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/firestore_paths.dart';
import '../repositories/call_repository.dart';
import 'agora_service.dart';
import 'permissions_service.dart';

enum CallState {
  idle,
  preparing,
  joining,
  connected,
  reconnecting,
  ending,
  ended,
  failed,
}

class CallSessionManager extends ChangeNotifier {
  CallSessionManager._();

  static final CallSessionManager instance = CallSessionManager._();

  static const String agoraAppId = '8ba12eb2de3b4a23a7eb754453dc7ecc';
  static const int reconnectGraceSeconds = 15;
  static const Duration _audioRecoveryCooldown = Duration(milliseconds: 900);
  static const Duration _reconnectRestartGuard = Duration(milliseconds: 800);

  final CallRepository _callRepository = CallRepository.instance;

  DocumentReference<Map<String, dynamic>>? _callDocRef;
  String? _channelId;
  bool _iAmCaller = false;

  AgoraService? _agora;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;

  bool _starting = false;
  bool _startLocked = false;
  bool _joined = false;
  bool _remoteConnected = false;
  bool _ending = false;
  bool _closed = true;
  bool _agoraLeaving = false;
  bool _connectionLostHandled = false;
  bool _endRequestedFromRemoteState = false;
  bool _timerStarted = false;
  bool _acceptedSessionObserved = false;
  bool _remoteEndedHandled = false;
  bool _audioRecoveryRunning = false;
  bool _disposingInternally = false;
  bool _billingEndRequested = false;
  bool _poorNetworkActive = false;

  int _remoteUid = 0;
  int _localAgoraUid = 0;
  int _seconds = 0;
  int _reconnectRemaining = 0;
  int _sessionVersion = 0;

  String? _currentCallId;
  String _status = 'Idle';
  CallState _state = CallState.idle;

  Timer? _timer;
  Timer? _reconnectTimer;

  Map<String, dynamic> _call = <String, dynamic>{};

  DateTime? _lastAudioRecoveryAt;
  DateTime? _lastReconnectStartedAt;

  DocumentReference<Map<String, dynamic>>? get callDocRef => _callDocRef;
  String get channelId => _channelId ?? '';
  bool get iAmCaller => _iAmCaller;
  bool get joined => _joined;
  bool get remoteConnected => _remoteConnected;
  bool get ending => _ending;
  bool get active =>
      !_closed && _callDocRef != null && !_isTerminalState(_state);
  int get remoteUid => _remoteUid;
  int get localAgoraUid => _localAgoraUid;
  int get seconds => _seconds;
  int get reconnectRemaining => _reconnectRemaining;
  String get status => _status;
  CallState get state => _state;
  bool get poorNetworkActive => _poorNetworkActive;
  Map<String, dynamic> get call => Map<String, dynamic>.unmodifiable(_call);

  int fullMinutes(int seconds) => seconds >= 60 ? (seconds ~/ 60) : 0;

  bool _isTerminalState(CallState state) {
    return state == CallState.idle ||
        state == CallState.ended ||
        state == CallState.failed;
  }

  bool _isCurrentSession(int version) => version == _sessionVersion;

  bool _isSameCallTransitionInProgress({
    required DocumentReference<Map<String, dynamic>> callDocRef,
    required String channelId,
    required bool iAmCaller,
  }) {
    return _currentCallId == callDocRef.id &&
        _callDocRef?.path == callDocRef.path &&
        _channelId == channelId &&
        _iAmCaller == iAmCaller &&
        (_starting ||
            _state == CallState.preparing ||
            _state == CallState.joining ||
            _state == CallState.connected ||
            _state == CallState.reconnecting ||
            _state == CallState.ending);
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

  int _timestampMs(dynamic value) {
    if (value is Timestamp) {
      return value.toDate().millisecondsSinceEpoch;
    }
    if (value is DateTime) {
      return value.millisecondsSinceEpoch;
    }
    return 0;
  }

  int _startedAtMsFromCall(Map<String, dynamic> call) {
    return _timestampMs(call[FirestorePaths.fieldStartedAt]);
  }

  int _prepaidEndsAtMsFromCall(Map<String, dynamic> call) {
    return _safeInt(call['prepaidEndsAtMs']);
  }

  int _maxPrepaidMinutesFromCall(Map<String, dynamic> call) {
    return _safeInt(call['maxPrepaidMinutes']);
  }

  int _clampNonNegativeInt(int value) {
    return value.clamp(0, 1 << 30);
  }

  int _serverAuthoritativeSeconds(Map<String, dynamic> call) {
    final explicitEndedSeconds = _safeInt(
      call[FirestorePaths.fieldEndedSeconds],
      fallback: -1,
    );

    if (explicitEndedSeconds >= 0 &&
        _safeString(call[FirestorePaths.fieldStatus]) ==
            FirestorePaths.statusEnded) {
      return explicitEndedSeconds;
    }

    final startedAtMs = _startedAtMsFromCall(call);
    if (startedAtMs <= 0) return 0;

    final endedAtMs = _timestampMs(call[FirestorePaths.fieldEndedAt]);
    if (endedAtMs > 0 && endedAtMs >= startedAtMs) {
      final elapsedSeconds = ((endedAtMs - startedAtMs) / 1000).floor();
      return _clampNonNegativeInt(elapsedSeconds);
    }

    final liveSeconds =
        ((DateTime.now().millisecondsSinceEpoch - startedAtMs) / 1000).floor();
    return _clampNonNegativeInt(liveSeconds);
  }

  int _remainingPrepaidSeconds(Map<String, dynamic> call) {
    final prepaidEndsAtMs = _prepaidEndsAtMsFromCall(call);
    if (prepaidEndsAtMs <= 0) return 0;

    final left =
        ((prepaidEndsAtMs - DateTime.now().millisecondsSinceEpoch) / 1000)
            .ceil();
    return left < 0 ? 0 : left;
  }

  int _secondsForBillingFromCurrentState() {
    final fromCall = _serverAuthoritativeSeconds(_call);
    final best = fromCall > _seconds ? fromCall : _seconds;
    return best < 0 ? 0 : best;
  }

  String _buildConnectedStatusFromCall() {
    final remaining = _remainingPrepaidSeconds(_call);

    if (_poorNetworkActive) {
      if (_iAmCaller && remaining > 0) {
        return 'Poor network • $remaining s left';
      }

      if (_iAmCaller && _maxPrepaidMinutesFromCall(_call) > 0) {
        final mins = _maxPrepaidMinutesFromCall(_call);
        return 'Poor network • prepaid $mins min';
      }

      return 'Poor network...';
    }

    if (_iAmCaller && remaining > 0) {
      return _remoteConnected
          ? 'Remote connected • $remaining s left'
          : 'Connected • $remaining s left';
    }

    if (_iAmCaller && _maxPrepaidMinutesFromCall(_call) > 0) {
      final mins = _maxPrepaidMinutesFromCall(_call);
      return _remoteConnected
          ? 'Remote connected • prepaid $mins min'
          : 'Connected • prepaid $mins min';
    }

    return _remoteConnected ? 'Remote connected' : 'Connected';
  }

  int _localAgoraUidFromCall(Map<String, dynamic> call) {
    final direct = _iAmCaller
        ? _safeInt(call['callerAgoraUid'])
        : _safeInt(call['calleeAgoraUid']);
    if (direct > 0) return direct;

    final callerUid = _safeInt(call['callerAgoraUid']);
    final calleeUid = _safeInt(call['calleeAgoraUid']);
    final genericUid = _safeInt(call['agoraUid']);

    if (_iAmCaller && callerUid > 0) return callerUid;
    if (!_iAmCaller && calleeUid > 0) return calleeUid;
    if (genericUid > 0) return genericUid;

    return 0;
  }

  void _notify() {
    notifyListeners();
  }

  void _setStatus(String value) {
    if (_status == value) return;
    _status = value;
    _notify();
  }

  void _setState(CallState newState) {
    if (_state == newState) return;
    _state = newState;
    debugPrint('CallState -> $_state');
    _notify();
  }

  void _setStateAndStatus(CallState newState, String value) {
    final stateChanged = _state != newState;
    final statusChanged = _status != value;

    _state = newState;
    _status = value;

    if (stateChanged) {
      debugPrint('CallState -> $_state');
    }

    if (stateChanged || statusChanged) {
      _notify();
    }
  }

  void _setPoorNetworkActive(bool value) {
    if (_poorNetworkActive == value) return;
    _poorNetworkActive = value;

    if (!_closed && !_ending && _acceptedSessionObserved) {
      _status = _buildConnectedStatusFromCall();
    }

    _notify();
  }

  void _resetSessionFlags() {
    _joined = false;
    _remoteConnected = false;
    _ending = false;
    _closed = false;
    _agoraLeaving = false;
    _connectionLostHandled = false;
    _endRequestedFromRemoteState = false;
    _timerStarted = false;
    _acceptedSessionObserved = false;
    _remoteEndedHandled = false;
    _audioRecoveryRunning = false;
    _disposingInternally = false;
    _billingEndRequested = false;
    _poorNetworkActive = false;
    _remoteUid = 0;
    _localAgoraUid = 0;
    _seconds = 0;
    _reconnectRemaining = 0;
    _lastAudioRecoveryAt = null;
    _lastReconnectStartedAt = null;
  }

  Future<void> startOrAttach({
    required DocumentReference<Map<String, dynamic>> callDocRef,
    required String channelId,
    required bool iAmCaller,
  }) async {
    final safeChannelId = channelId.trim();
    if (safeChannelId.isEmpty) return;

    if (_currentCallId != null && _currentCallId == callDocRef.id && active) {
      return;
    }

    if (_isSameCallTransitionInProgress(
      callDocRef: callDocRef,
      channelId: safeChannelId,
      iAmCaller: iAmCaller,
    )) {
      return;
    }

    final sameRunningCall = active &&
        _callDocRef?.path == callDocRef.path &&
        _channelId == safeChannelId &&
        _iAmCaller == iAmCaller;

    if (sameRunningCall) {
      _notify();
      return;
    }

    if (_starting || _startLocked) return;
    _startLocked = true;
    _starting = true;

    final int nextVersion = _sessionVersion + 1;

    try {
      if (!_closed) {
        await _disposeSessionInternal(
          leaveAgora: true,
          clearStartingFlag: false,
        );
      }

      _sessionVersion = nextVersion;
      _callDocRef = callDocRef;
      _currentCallId = callDocRef.id;
      _channelId = safeChannelId;
      _iAmCaller = iAmCaller;
      _call = <String, dynamic>{};

      _resetSessionFlags();
      _setStateAndStatus(CallState.preparing, 'Preparing...');

      await _init(sessionVersion: nextVersion);

      if (_isCurrentSession(nextVersion) &&
          (_state == CallState.failed || _state == CallState.ended)) {
        await _disposeSessionInternal(
          leaveAgora: true,
          clearStartingFlag: false,
          finalState: _state,
          finalStatus: _status,
        );
      }
    } finally {
      if (_isCurrentSession(nextVersion)) {
        _starting = false;
      }
      _startLocked = false;
    }
  }

  Future<bool> tryRestoreFromCallDoc({
    required DocumentReference<Map<String, dynamic>> callDocRef,
    required bool iAmCaller,
  }) async {
    try {
      final snap = await callDocRef.get();
      if (!snap.exists) return false;

      final data = snap.data() ?? <String, dynamic>{};
      final status = _safeString(data[FirestorePaths.fieldStatus]);
      final channelId = _safeString(data[FirestorePaths.fieldChannelId]);

      if (status != FirestorePaths.statusAccepted) return false;
      if (channelId.isEmpty) return false;

      await startOrAttach(
        callDocRef: callDocRef,
        channelId: channelId,
        iAmCaller: iAmCaller,
      );

      return active;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestServerBilledEnd({
    required String reason,
    required int sessionVersion,
  }) async {
    if (!_isCurrentSession(sessionVersion)) return;
    if (_billingEndRequested) return;
    if (_closed) return;
    if (_state == CallState.ended || _state == CallState.idle) return;

    final ref = _callDocRef;
    if (ref == null) return;

    _billingEndRequested = true;

    try {
      _call = {
        ..._call,
        FirestorePaths.fieldEndedReason: reason,
      };

      await _callRepository.requestEndById(
        callId: ref.id,
        seconds: _secondsForBillingFromCurrentState(),
        reason: reason,
      );
    } catch (_) {
      _billingEndRequested = false;
    }
  }

  void _startTimer(int sessionVersion) {
    if (!_isCurrentSession(sessionVersion)) return;
    if (_timerStarted) return;
    if (_timer != null) {
      _timer?.cancel();
      _timer = null;
    }

    _timerStarted = true;

    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!_isCurrentSession(sessionVersion)) return;
      if (_closed || _ending) return;
      if (_state == CallState.ended || _state == CallState.idle) return;

      final computedSeconds = _serverAuthoritativeSeconds(_call);
      if (computedSeconds != _seconds) {
        _seconds = computedSeconds;
      }

      if (_acceptedSessionObserved) {
        _status = _buildConnectedStatusFromCall();
      }

      if (_iAmCaller &&
          _safeString(_call[FirestorePaths.fieldStatus]) ==
              FirestorePaths.statusAccepted) {
        final remaining = _remainingPrepaidSeconds(_call);
        if (remaining <= 0 && _prepaidEndsAtMsFromCall(_call) > 0) {
          _status = 'Credit limit reached. Ending call...';
          _notify();

          await _requestServerBilledEnd(
            reason: FirestorePaths.reasonCreditLimitReached,
            sessionVersion: sessionVersion,
          );
          return;
        }
      }

      _notify();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _timerStarted = false;
  }

  Future<void> _leaveAgoraSafely() async {
    if (_agoraLeaving) return;

    _agoraLeaving = true;
    try {
      await _agora?.leave();
    } catch (_) {
      // ignore
    } finally {
      _agoraLeaving = false;
    }
  }

  void _cancelReconnectGrace({String? status}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectRemaining = 0;
    _connectionLostHandled = false;
    _lastReconnectStartedAt = null;

    if (status != null && !_ending && !_closed) {
      _status = status;
      if (_state == CallState.reconnecting) {
        _setState(CallState.connected);
      } else {
        _notify();
      }
    }
  }

  void _startReconnectGrace({
    required String reason,
    required int sessionVersion,
  }) {
    if (!_isCurrentSession(sessionVersion)) return;
    if (_ending || _closed) return;
    if (_state == CallState.ended || _state == CallState.idle) return;
    if (_reconnectTimer != null) return;

    final now = DateTime.now();
    final lastStartedAt = _lastReconnectStartedAt;
    if (lastStartedAt != null &&
        now.difference(lastStartedAt) < _reconnectRestartGuard) {
      return;
    }
    _lastReconnectStartedAt = now;

    _reconnectRemaining = reconnectGraceSeconds;
    _status = 'Reconnecting... ($_reconnectRemaining s)';
    _setState(CallState.reconnecting);

    _reconnectTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!_isCurrentSession(sessionVersion) || _closed || _ending) {
        timer.cancel();
        if (_isCurrentSession(sessionVersion)) {
          _reconnectTimer = null;
        }
        return;
      }

      _reconnectRemaining -= 1;

      if (_reconnectRemaining <= 0) {
        timer.cancel();
        _reconnectTimer = null;

        if (_closed || _ending) return;
        _setStatus('Connection lost. Ending call...');
        await endCall(reason: reason);
        return;
      }

      _status = 'Reconnecting... ($_reconnectRemaining s)';
      _notify();
    });
  }

  bool _shouldSkipAudioRecovery(String source) {
    if (_lastAudioRecoveryAt == null) return false;

    final elapsed = DateTime.now().difference(_lastAudioRecoveryAt!);
    if (elapsed >= _audioRecoveryCooldown) return false;

    return true;
  }

  Future<void> recoverAudioFlow(String source) async {
    if (_audioRecoveryRunning) return;
    if (_closed || _ending) return;
    if (_agora == null) return;
    if (!_joined && source != 'firestoreAccepted') return;
    if (_shouldSkipAudioRecovery(source)) return;

    _audioRecoveryRunning = true;
    _lastAudioRecoveryAt = DateTime.now();

    try {
      debugPrint('CallSessionManager: recovering audio flow from $source');
      await _agora!.ensureAudioFlow(
        onLog: (msg) => debugPrint('AgoraRecover[$source] $msg'),
      );
    } catch (e) {
      debugPrint('CallSessionManager: audio recovery failed from $source: $e');
    } finally {
      _audioRecoveryRunning = false;
    }
  }

  Future<void> syncWithServer() async {
    final ref = _callDocRef;
    if (ref == null || _closed) return;

    try {
      final snap = await ref.get();
      if (!snap.exists) {
        await _handleRemoteEndedState();
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final status = _safeString(data[FirestorePaths.fieldStatus]);

      _call = data;
      _seconds = _serverAuthoritativeSeconds(data);

      if (status == FirestorePaths.statusAccepted) {
        _acceptedSessionObserved = true;
        _cancelReconnectGrace(
          status: _buildConnectedStatusFromCall(),
        );

        if (_joined && !_timerStarted) {
          _startTimer(_sessionVersion);
        }

        await recoverAudioFlow('manualSyncAccepted');
      }

      if (status == FirestorePaths.statusEnded ||
          status == FirestorePaths.statusRejected) {
        await _handleRemoteEndedState();
        return;
      }

      _notify();
    } catch (_) {
      // ignore sync failures
    }
  }

  Future<void> _handleRemoteEndedState() async {
    if (_ending || _closed) return;
    if (_endRequestedFromRemoteState) return;
    if (_remoteEndedHandled) return;

    _remoteEndedHandled = true;
    _endRequestedFromRemoteState = true;

    if (_state != CallState.ended) {
      _status = 'Call ended';
      _notify();
    }

    await _disposeSessionInternal(
      finalState: CallState.ended,
      finalStatus: 'Call ended',
    );
  }

  Future<void> _failAndRelease({
    required String message,
    required int sessionVersion,
  }) async {
    if (!_isCurrentSession(sessionVersion)) return;

    _setStateAndStatus(CallState.failed, message);

    await _disposeSessionInternal(
      leaveAgora: true,
      clearStartingFlag: false,
      finalState: CallState.failed,
      finalStatus: message,
    );
  }

  Future<void> _init({required int sessionVersion}) async {
    final ref = _callDocRef;
    if (ref == null) return;

    try {
      final callSnap = await ref.get();
      if (!_isCurrentSession(sessionVersion)) return;

      if (!callSnap.exists) {
        await _disposeSessionInternal(
          finalState: CallState.ended,
          finalStatus: 'Call ended',
        );
        return;
      }

      _call = callSnap.data() ?? <String, dynamic>{};
      _seconds = _serverAuthoritativeSeconds(_call);
      _localAgoraUid = _localAgoraUidFromCall(_call);
    } catch (_) {
      if (!_isCurrentSession(sessionVersion)) return;
      _call = <String, dynamic>{};
      _seconds = 0;
      _localAgoraUid = 0;
    }

    if (_closed || !_isCurrentSession(sessionVersion)) return;

    if (_localAgoraUid <= 0) {
      await _failAndRelease(
        message: 'Missing Agora identity.',
        sessionVersion: sessionVersion,
      );
      return;
    }

    _setStateAndStatus(
      CallState.preparing,
      'Requesting microphone permission...',
    );

    final micOk = await PermissionsService.requestMicrophone();
    if (!_isCurrentSession(sessionVersion)) return;

    if (!micOk) {
      if (_closed) return;
      await _failAndRelease(
        message: 'Microphone permission denied.',
        sessionVersion: sessionVersion,
      );
      return;
    }

    final tokenField = _iAmCaller
        ? FirestorePaths.fieldAgoraTokenCaller
        : FirestorePaths.fieldAgoraTokenCallee;
    final token = _safeString(_call[tokenField]);

    _agora = AgoraService(
      appId: agoraAppId,
      token: token.isEmpty ? null : token,
    );

    if (_closed || !_isCurrentSession(sessionVersion)) return;

    _setStateAndStatus(CallState.preparing, 'Starting Agora...');

    try {
      await _agora!.init(
        onJoinSuccess: () async {
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;
          if (_joined) return;

          _acceptedSessionObserved = true;
          _joined = true;
          _seconds = _serverAuthoritativeSeconds(_call);
          _localAgoraUid = _agora?.localUid ?? _localAgoraUid;
          _status = _buildConnectedStatusFromCall();
          _setState(CallState.connected);

          _startTimer(sessionVersion);

          await recoverAudioFlow('onJoinSuccess');
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;

          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;

          await recoverAudioFlow('postJoinDelay');
        },
        onRemoteJoined: (uid) async {
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;

          _acceptedSessionObserved = true;
          _setPoorNetworkActive(false);
          _cancelReconnectGrace(status: _buildConnectedStatusFromCall());

          _remoteUid = uid;
          _remoteConnected = true;
          _status = _buildConnectedStatusFromCall();
          _setState(CallState.connected);

          await recoverAudioFlow('onRemoteJoined');
        },
        onRemoteLeft: (uid) {
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;

          if (_remoteUid == uid) {
            _remoteUid = 0;
          }
          _remoteConnected = false;
          _notify();

          if (_acceptedSessionObserved) {
            _startReconnectGrace(
              reason: FirestorePaths.reasonRemoteLeft,
              sessionVersion: sessionVersion,
            );
          }
        },
        onConnectionLost: () {
          if (!_isCurrentSession(sessionVersion)) return;
          if (_connectionLostHandled) return;
          _connectionLostHandled = true;

          if (_closed || _ending) return;
          _startReconnectGrace(
            reason: FirestorePaths.reasonConnectionLost,
            sessionVersion: sessionVersion,
          );
        },
        onPoorNetwork: () async {
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;

          _setPoorNetworkActive(true);

          if (_state == CallState.connected) {
            _status = _buildConnectedStatusFromCall();
            _notify();
          }

          await recoverAudioFlow('poorNetwork');
        },
        onNetworkRecovered: () async {
          if (!_isCurrentSession(sessionVersion) || _closed || _ending) return;

          _setPoorNetworkActive(false);

          if (_acceptedSessionObserved) {
            _cancelReconnectGrace(
              status: _buildConnectedStatusFromCall(),
            );
          } else {
            _status = _buildConnectedStatusFromCall();
            _notify();
          }

          await recoverAudioFlow('networkRecovered');
        },
        onLog: (msg) {
          debugPrint('AgoraLog: $msg');
        },
      );
    } catch (e) {
      debugPrint('CallSessionManager agora init failed: $e');
      await _failAndRelease(
        message: 'Failed to start voice engine.',
        sessionVersion: sessionVersion,
      );
      return;
    }

    if (_closed || !_isCurrentSession(sessionVersion)) return;

    _setStateAndStatus(CallState.joining, 'Joining channel...');

    try {
      await _agora!.joinVoiceChannel(
        channelId: _channelId!,
        uid: _localAgoraUid,
      );
    } catch (e) {
      if (!_isCurrentSession(sessionVersion) || _closed) return;
      debugPrint('CallSessionManager joinVoiceChannel failed: $e');
      await _failAndRelease(
        message: 'Failed to join voice channel.',
        sessionVersion: sessionVersion,
      );
      return;
    }

    if (!_isCurrentSession(sessionVersion) || _callDocRef == null) return;

    await _callSub?.cancel();
    _callSub = _callDocRef!.snapshots().listen((snap) async {
      if (!_isCurrentSession(sessionVersion)) return;

      if (!snap.exists) {
        await _handleRemoteEndedState();
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final status = _safeString(data[FirestorePaths.fieldStatus]);

      _call = data;
      _seconds = _serverAuthoritativeSeconds(data);

      if (_localAgoraUid <= 0) {
        _localAgoraUid = _localAgoraUidFromCall(data);
      }

      if (_closed) return;

      if (status == FirestorePaths.statusAccepted) {
        _acceptedSessionObserved = true;
        _cancelReconnectGrace(
          status: _buildConnectedStatusFromCall(),
        );

        if (!_timerStarted && _joined) {
          _startTimer(sessionVersion);
        }

        await recoverAudioFlow('firestoreAccepted');
      }

      if ((status == FirestorePaths.statusEnded ||
              status == FirestorePaths.statusRejected) &&
          !_ending) {
        await _handleRemoteEndedState();
        return;
      }

      _notify();
    });

    await syncWithServer();
  }

  Future<void> endCall({required String reason}) async {
    final ref = _callDocRef;
    if (_ending || _closed || ref == null) return;

    _ending = true;
    _setState(CallState.ending);
    _stopTimer();

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _lastReconnectStartedAt = null;
    _notify();

    try {
      final latest = await ref.get();
      final latestData = latest.data() ?? <String, dynamic>{};
      final status = _safeString(latestData[FirestorePaths.fieldStatus]);

      if (latestData.isNotEmpty) {
        _call = latestData;
      }

      if (status == FirestorePaths.statusRinging) {
        if (_iAmCaller) {
          await _callRepository.cancelOutgoingCallById(
            ref.id,
            reason: reason,
          );
        } else {
          await _callRepository.rejectCallById(
            ref.id,
            rejectedReason: reason,
          );
        }
      } else if (status == FirestorePaths.statusAccepted) {
        await _requestServerBilledEnd(
          reason: reason,
          sessionVersion: _sessionVersion,
        );
      }
    } catch (_) {
      // ignore close-path failures
    }

    await _disposeSessionInternal(
      finalState: CallState.ended,
      finalStatus: 'Call ended',
    );
  }

  Future<void> _disposeSessionInternal({
    bool leaveAgora = true,
    bool clearStartingFlag = true,
    CallState finalState = CallState.ended,
    String finalStatus = 'Idle',
  }) async {
    if (_disposingInternally) return;
    _disposingInternally = true;

    try {
      _stopTimer();

      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      await _callSub?.cancel();
      _callSub = null;

      if (leaveAgora) {
        await _leaveAgoraSafely();
        _agora = null;
      }

      _joined = false;
      _remoteConnected = false;
      _ending = false;
      _closed = true;
      _connectionLostHandled = false;
      _endRequestedFromRemoteState = false;
      _timerStarted = false;
      _acceptedSessionObserved = false;
      _remoteEndedHandled = false;
      _audioRecoveryRunning = false;
      _billingEndRequested = false;
      _poorNetworkActive = false;
      _iAmCaller = false;
      _remoteUid = 0;
      _localAgoraUid = 0;
      _reconnectRemaining = 0;
      _callDocRef = null;
      _currentCallId = null;
      _channelId = null;
      _call = <String, dynamic>{};
      _seconds = 0;
      _lastAudioRecoveryAt = null;
      _lastReconnectStartedAt = null;
      _startLocked = false;

      if (clearStartingFlag) {
        _starting = false;
      }

      _setStateAndStatus(finalState, finalStatus);
    } finally {
      _disposingInternally = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reconnectTimer?.cancel();
    _callSub?.cancel();
    super.dispose();
  }
}