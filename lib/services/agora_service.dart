import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class AgoraService {
  final String appId;
  final String? token;

  RtcEngine? _engine;

  bool _initialized = false;
  bool _joined = false;
  bool _released = false;
  bool _connectionLostFired = false;
  bool _joining = false;
  bool _leaving = false;
  bool _poorNetworkActive = false;

  int? _localUid;
  String? _joinedChannelId;

  AgoraService({
    required this.appId,
    this.token,
  });

  bool get initialized => _initialized;
  bool get joined => _joined;
  bool get released => _released;
  bool get joining => _joining;
  bool get leaving => _leaving;
  bool get poorNetworkActive => _poorNetworkActive;
  int? get localUid => _localUid;
  String? get joinedChannelId => _joinedChannelId;

  void _resetRuntimeState() {
    _initialized = false;
    _joined = false;
    _released = false;
    _connectionLostFired = false;
    _joining = false;
    _leaving = false;
    _poorNetworkActive = false;
    _localUid = null;
    _joinedChannelId = null;
  }

  Future<void> _releaseExistingEngineIfAny({
    Function(String message)? onLog,
  }) async {
    final existing = _engine;
    _engine = null;

    if (existing == null) return;

    try {
      try {
        await existing.leaveChannel();
      } catch (_) {
        // ignore
      }

      try {
        await existing.release();
      } catch (_) {
        // ignore
      }
    } catch (e) {
      onLog?.call('Agora existing engine cleanup failed: $e');
    }
  }

  Future<void> init({
    required VoidCallback onJoinSuccess,
    required Function(int uid) onRemoteJoined,
    required Function(int uid) onRemoteLeft,
    VoidCallback? onConnectionLost,
    VoidCallback? onPoorNetwork,
    VoidCallback? onNetworkRecovered,
    Function(String message)? onLog,
  }) async {
    if (_initialized && _engine != null && !_released) {
      onLog?.call('Agora init skipped: already initialized.');
      return;
    }

    await _releaseExistingEngineIfAny(onLog: onLog);
    _resetRuntimeState();

    final engine = createAgoraRtcEngine();
    _engine = engine;

    onLog?.call('Agora initializing engine...');

    try {
      await engine.initialize(
        RtcEngineContext(
          appId: appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );

      await engine.enableAudio();

      await engine.setAudioProfile(
        profile: AudioProfileType.audioProfileDefault,
        scenario: AudioScenarioType.audioScenarioChatroom,
      );

      await engine.setClientRole(
        role: ClientRoleType.clientRoleBroadcaster,
      );

      await engine.enableLocalAudio(true);
      await engine.muteLocalAudioStream(false);

      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) async {
            if (_released) return;

            _joined = true;
            _joining = false;
            _connectionLostFired = false;
            _poorNetworkActive = false;
            _joinedChannelId = connection.channelId;
            _localUid = connection.localUid;

            onLog?.call(
              'Agora joined successfully. '
              'channel=${connection.channelId} localUid=${connection.localUid}',
            );

            await ensureAudioFlow(onLog: onLog);
            if (_released) return;

            onJoinSuccess();
          },
          onUserJoined: (connection, remoteUid, elapsed) async {
            if (_released) return;

            _poorNetworkActive = false;
            onLog?.call('Agora remote user joined: $remoteUid');
            await ensureAudioFlow(onLog: onLog);
            if (_released) return;

            onRemoteJoined(remoteUid);
          },
          onUserOffline: (connection, remoteUid, reason) {
            if (_released) return;

            onLog?.call('Agora remote user offline: $remoteUid reason=$reason');
            onRemoteLeft(remoteUid);
          },
          onConnectionStateChanged: (connection, state, reason) {
            if (_released) return;

            onLog?.call('Agora connection state=$state reason=$reason');

            final lost =
                state == ConnectionStateType.connectionStateDisconnected ||
                state == ConnectionStateType.connectionStateFailed;

            if (lost && !_connectionLostFired) {
              _connectionLostFired = true;
              onConnectionLost?.call();
            }

            final connected =
                state == ConnectionStateType.connectionStateConnected;

            if (connected) {
              _connectionLostFired = false;
              if (_poorNetworkActive) {
                _poorNetworkActive = false;
              }
              onNetworkRecovered?.call();
            }
          },
          onLocalAudioStateChanged: (connection, state, reason) {
            if (_released) return;
            onLog?.call('Agora local audio state=$state reason=$reason');
          },
          onRemoteAudioStateChanged:
              (connection, remoteUid, state, reason, elapsed) {
            if (_released) return;
            onLog?.call(
              'Agora remote audio state remoteUid=$remoteUid '
              'state=$state reason=$reason elapsed=$elapsed',
            );

            if (state == RemoteAudioState.remoteAudioStateFrozen) {
              if (!_poorNetworkActive) {
                _poorNetworkActive = true;
                onPoorNetwork?.call();
              }
              return;
            }

            if (state == RemoteAudioState.remoteAudioStateDecoding ||
                state == RemoteAudioState.remoteAudioStateStarting) {
              if (_poorNetworkActive) {
                _poorNetworkActive = false;
                onNetworkRecovered?.call();
              }
            }
          },
          onError: (err, msg) {
            debugPrint('Agora onError: $err $msg');
            onLog?.call('Agora error=$err msg=$msg');

            if (_joining) {
              _joining = false;
            }
          },
        ),
      );

      _initialized = true;
      onLog?.call('Agora initialization completed.');
    } catch (e) {
      onLog?.call('Agora initialization failed: $e');
      try {
        await engine.release();
      } catch (_) {
        // ignore
      }
      _engine = null;
      _resetRuntimeState();
      rethrow;
    }
  }

  Future<void> joinVoiceChannel({
    required String channelId,
    required int uid,
  }) async {
    final safeChannelId = channelId.trim();

    if (!_initialized || _engine == null || _released) {
      throw StateError('AgoraService.joinVoiceChannel called before init().');
    }

    if (safeChannelId.isEmpty) {
      throw ArgumentError('channelId cannot be empty.');
    }

    if (uid <= 0) {
      throw ArgumentError('Agora uid must be greater than 0.');
    }

    if (_joined || _joining || _leaving) return;

    _joining = true;
    _localUid = uid;
    _joinedChannelId = safeChannelId;

    final engine = _engine!;
    final safeToken = (token ?? '').trim();

    try {
      await _startForegroundCallService();
      if (_released || _leaving) {
        _joining = false;
        return;
      }

      await engine.enableAudio();
      await engine.enableLocalAudio(true);
      await engine.muteLocalAudioStream(false);

      await engine.joinChannel(
        token: safeToken,
        channelId: safeChannelId,
        uid: uid,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileCommunication,
          publishMicrophoneTrack: true,
          autoSubscribeAudio: true,
          enableAudioRecordingOrPlayout: true,
        ),
      );
    } catch (_) {
      _joining = false;
      rethrow;
    }
  }

  Future<void> ensureAudioFlow({Function(String message)? onLog}) async {
    final engine = _engine;
    if (engine == null || _released) return;

    try {
      await engine.enableAudio();
      onLog?.call('ensureAudioFlow: enableAudio OK');
    } catch (e) {
      onLog?.call('ensureAudioFlow: enableAudio failed: $e');
    }

    try {
      await engine.enableLocalAudio(true);
      onLog?.call('ensureAudioFlow: enableLocalAudio(true) OK');
    } catch (e) {
      onLog?.call('ensureAudioFlow: enableLocalAudio(true) failed: $e');
    }

    try {
      await engine.muteLocalAudioStream(false);
      onLog?.call('ensureAudioFlow: muteLocalAudioStream(false) OK');
    } catch (e) {
      onLog?.call('ensureAudioFlow: muteLocalAudioStream(false) failed: $e');
    }

    if (_joined) {
      try {
        await engine.setEnableSpeakerphone(true);
        onLog?.call('ensureAudioFlow: setEnableSpeakerphone(true) OK');
      } catch (e) {
        onLog?.call('ensureAudioFlow: setEnableSpeakerphone(true) failed: $e');
      }
    }
  }

  Future<void> _startForegroundCallService() async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) return;

      await FlutterForegroundTask.startService(
        serviceId: 2001,
        notificationTitle: 'Friendify call active',
        notificationText: 'Voice call is running in background',
      );
    } catch (e) {
      debugPrint('Foreground service start failed: $e');
    }
  }

  Future<void> _stopForegroundCallService() async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) return;

      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('Foreground service stop failed: $e');
    }
  }

  Future<void> leave() async {
    final engine = _engine;
    if (engine == null || _released || _leaving) return;

    _leaving = true;
    _released = true;
    _initialized = false;
    _joined = false;
    _joining = false;
    _connectionLostFired = false;
    _poorNetworkActive = false;
    _engine = null;

    try {
      try {
        await engine.muteLocalAudioStream(true);
      } catch (_) {
        // ignore
      }

      try {
        await engine.enableLocalAudio(false);
      } catch (_) {
        // ignore
      }

      try {
        await engine.leaveChannel();
      } catch (_) {
        // ignore
      }

      try {
        await engine.release();
      } catch (_) {
        // ignore
      }
    } finally {
      await _stopForegroundCallService();
      _localUid = null;
      _joinedChannelId = null;
      _leaving = false;
    }
  }
}