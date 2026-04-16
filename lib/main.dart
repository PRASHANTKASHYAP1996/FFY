import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'services/call_session_manager.dart';
import 'services/notifications_service.dart';

final Map<String, DateTime> _bgHandledEvents = <String, DateTime>{};
bool _backgroundHandlerRegistered = false;
bool _appCheckActivated = false;

void _cleanupBgHandledEvents() {
  _bgHandledEvents.removeWhere(
    (_, value) => DateTime.now().difference(value) > const Duration(minutes: 1),
  );
}

bool _wasBgEventHandledRecently(String key) {
  final at = _bgHandledEvents[key];
  if (at == null) return false;
  return DateTime.now().difference(at) <= const Duration(seconds: 20);
}

void _markBgEventHandled(String key) {
  _bgHandledEvents[key] = DateTime.now();
  _cleanupBgHandledEvents();
}

String _safeDataString(
  Map<String, dynamic> data,
  String key, {
  String fallback = '',
}) {
  final value = data[key];
  if (value is String) return value.trim();
  if (value == null) return fallback;
  return value.toString().trim();
}

bool _isMobileAppleOrAndroid() {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  } catch (_) {
    return false;
  }
}

String _configuredAppCheckMode() {
  const rawMode = String.fromEnvironment(
    'FRIENDIFY_APP_CHECK_MODE',
    defaultValue: 'auto',
  );
  return rawMode.trim().toLowerCase();
}

bool _shouldUseReleaseAppCheckProvider() {
  switch (_configuredAppCheckMode()) {
    case 'release':
      return true;
    case 'debug':
      return false;
    case 'off':
      return false;  
    default:
      return kReleaseMode;
  }
}

String _currentAppCheckModeLabel() {
  if (!_isMobileAppleOrAndroid()) {
    return 'skipped-unsupported-platform';
  }

  final configuredMode = _configuredAppCheckMode();
  if (configuredMode == 'off') {
    return 'disabled (override=off)';
  }

  final resolvedMode = _shouldUseReleaseAppCheckProvider()
      ? 'release-attestation'
      : 'debug';

  return configuredMode == 'auto'
      ? resolvedMode
      : '$resolvedMode (override=$configuredMode)';
}

Future<void> _ensureFirebaseInitialized({bool activateAppCheck = false}) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {
    // Firebase may already be initialized.
  }

  if (activateAppCheck) {
    await _activateAppCheckSafely();
  }
}

Future<void> _activateAppCheckSafely() async {
  if (_appCheckActivated) return;

  if (!_isMobileAppleOrAndroid()) {
    debugPrint(
      'Firebase App Check skipped on unsupported platform '
      '(${defaultTargetPlatform.name}).',
    );
    _appCheckActivated = true;
    return;
  }

  if (_configuredAppCheckMode() == 'off') {
    debugPrint(
      'Firebase App Check is disabled via '
      '--dart-define=FRIENDIFY_APP_CHECK_MODE=off. '
      'Use this only for local debugging.',
    );
    _appCheckActivated = true;
    return;
  }

  final useReleaseProvider = _shouldUseReleaseAppCheckProvider();

  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider:
          useReleaseProvider
              ? AndroidProvider.playIntegrity
              : AndroidProvider.debug,
      appleProvider:
          useReleaseProvider
              ? AppleProvider.deviceCheck
              : AppleProvider.debug,
    );

    await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);

    debugPrint(
      'Firebase App Check activated '
      '(mode=${_currentAppCheckModeLabel()})',
    );

    if (!useReleaseProvider) {
      debugPrint(
        'App Check is using the debug provider. '
        'Keep this only for local/dev installs and register the debug token '
        'if Firebase App Check enforcement is enabled.',
      );
    } else {
      debugPrint(
        'App Check is using Play Integrity / DeviceCheck. '
        'Release-only attestation requires the installed app package, SHA '
        'fingerprints, signing key, and Firebase registration to match.',
      );
    }

    _appCheckActivated = true;
  } catch (e, st) {
    debugPrint(
      'Firebase App Check activation failed '
      '(mode=${_currentAppCheckModeLabel()}): $e',
    );
    debugPrintStack(stackTrace: st);

    if (useReleaseProvider) {
      debugPrint(
        'Release attestation failed. Verify Firebase App Check registration, '
        'Play Integrity setup, signing SHA fingerprints, and package name.',
      );
    } else {
      debugPrint(
        'Debug App Check failed. If you are testing with a release APK or an '
        'internally shared build, override the provider explicitly with '
        '--dart-define=FRIENDIFY_APP_CHECK_MODE=debug until production '
        'signing and App Check registration are fully verified.',
      );
    }
  }
}

CallKitParams _buildIncomingCallKitParams({
  required String callId,
  required String callerName,
}) {
  final safeCallerName =
      callerName.trim().isEmpty ? 'Someone' : callerName.trim();

  return CallKitParams(
    id: callId,
    nameCaller: safeCallerName,
    appName: 'Friendify',
    avatar: '',
    handle: 'Friendify audio call',
    type: 0,
    duration: 45000,
    textAccept: 'Accept',
    textDecline: 'Reject',
    extra: <String, dynamic>{
      'callId': callId,
      'type': 'incoming_call',
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
}

Future<void> _registerBackgroundMessageHandlerOnce() async {
  if (_backgroundHandlerRegistered) return;

  FirebaseMessaging.onBackgroundMessage(
    firebaseMessagingBackgroundHandler,
  );

  _backgroundHandlerRegistered = true;
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await _ensureFirebaseInitialized(activateAppCheck: false);

    final data = message.data;
    final type = _safeDataString(data, 'type');
    final callId = _safeDataString(data, 'callId');
    final callerName = _safeDataString(
      data,
      'callerName',
      fallback: 'Someone',
    );

    final dedupeKey = callId.isNotEmpty
        ? 'bg::$type::$callId'
        : 'bg::$type::${message.messageId ?? data.toString()}';

    if (_wasBgEventHandledRecently(dedupeKey)) {
      debugPrint('Skipping duplicate background push: $dedupeKey');
      return;
    }
    _markBgEventHandled(dedupeKey);

    if (type == 'incoming_call') {
      if (callId.isEmpty) {
        debugPrint('Background incoming_call ignored: missing callId');
        return;
      }

      final session = CallSessionManager.instance;
      final activeCallId = session.callDocRef?.id.trim() ?? '';
      if (session.active && activeCallId.isNotEmpty && activeCallId == callId) {
        debugPrint(
          'Background incoming_call ignored because call is already active locally: $callId',
        );
        return;
      }

      try {
        await FlutterCallkitIncoming.endCall(callId);
      } catch (_) {
        // ignore stale cleanup failure
      }

      final params = _buildIncomingCallKitParams(
        callId: callId,
        callerName: callerName,
      );

      await FlutterCallkitIncoming.showCallkitIncoming(params);
      return;
    }

    if (type == 'missed_call') {
      if (callId.isEmpty) return;

      try {
        await FlutterCallkitIncoming.endCall(callId);
      } catch (_) {
        // ignore cleanup failure
      }
      return;
    }
  } catch (e, st) {
    debugPrint('Background incoming call handler failed: $e');
    debugPrintStack(stackTrace: st);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _configureAppStartup();

  final firebaseInit = await _initializeFirebase();
  if (!firebaseInit.$1) {
    runApp(FirebaseInitErrorApp(error: firebaseInit.$2));
    return;
  }

  runApp(const FriendifyBootstrapApp());
}

Future<void> _configureAppStartup() async {
  FlutterForegroundTask.initCommunicationPort();

  await _registerBackgroundMessageHandlerOnce();

  _initForegroundTask();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exception}');
    if (details.stack != null) {
      debugPrintStack(stackTrace: details.stack);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PlatformDispatcher error: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'friendify_active_call',
      channelName: 'Friendify Active Call',
      channelDescription:
          'Keeps Friendify voice calls alive while the app is in background.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<(bool, String)> _initializeFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    await _activateAppCheckSafely();

    return (true, '');
  } catch (e, st) {
    debugPrint('Firebase init failed: $e');
    debugPrintStack(stackTrace: st);
    return (false, 'Firebase init failed:\n$e');
  }
}

Future<void> _startNotificationsSafely() async {
  try {
    await NotificationsService.instance.start();
  } catch (e, st) {
    debugPrint('Notification startup failed: $e');
    debugPrintStack(stackTrace: st);
  }
}

class FriendifyBootstrapApp extends StatefulWidget {
  const FriendifyBootstrapApp({super.key});

  @override
  State<FriendifyBootstrapApp> createState() => _FriendifyBootstrapAppState();
}

class _FriendifyBootstrapAppState extends State<FriendifyBootstrapApp> {
  bool _startedNotifications = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_startedNotifications) return;

      _startedNotifications = true;
      unawaited(_startNotificationsSafely());
    });
  }

  @override
  Widget build(BuildContext context) {
    return const FriendifyApp();
  }
}

class FirebaseInitErrorApp extends StatelessWidget {
  final String error;

  const FirebaseInitErrorApp({
    super.key,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 54),
                    const SizedBox(height: 12),
                    const Text(
                      'Friendify failed to start',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'An initialization error occurred. Please check Firebase setup and try again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SelectableText(
                      error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}