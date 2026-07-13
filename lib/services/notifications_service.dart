import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../app.dart';
import '../core/constants/firestore_paths.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../screens/chat_conversation_screen.dart';
import '../shared/chat_direction_resolver.dart';
import '../shared/chat_navigation_guards.dart';
import '../shared/models/app_user_model.dart';
import 'auth_scoped_subscriptions.dart';
import 'app_log.dart';
import 'call_latency_tracker.dart';
import 'call_manager.dart';
import 'firestore_service.dart';
import 'notification_channels.dart';

class _PushActualListenerResolution {
  const _PushActualListenerResolution({
    required this.actualListenerId,
    required this.source,
  });

  final String actualListenerId;
  final String source;

  bool get isResolved => actualListenerId.isNotEmpty;
  bool get usedLegacyRepair => source.startsWith('legacy.');
}

@visibleForTesting
Future<bool> pushResolvedChatConversation({
  required String myUid,
  required String speakerId,
  required String listenerId,
  required String actualListenerId,
  required Future<void> Function(ChatConversationScreen screen) onPush,
  AppUserModel? initialOtherUser,
}) async {
  if (!isSafeChatPushDirection(
    speakerId: speakerId,
    listenerId: listenerId,
    actualListenerId: actualListenerId,
    myUid: myUid,
  )) {
    return false;
  }

  await onPush(
    ChatConversationScreen(
      speakerId: speakerId,
      listenerId: listenerId,
      actualListenerId: actualListenerId,
      iAmListener: actualListenerId.isNotEmpty && myUid == actualListenerId,
      initialOtherUser: initialOtherUser,
    ),
  );
  return true;
}

class NotificationsService {
  NotificationsService._();

  static final NotificationsService instance = NotificationsService._();
  final CallRepository _callRepository = CallRepository.instance;

  bool _started = false;
  bool _starting = false;
  bool _callkitEventsBound = false;
  bool _permissionsInitialized = false;
  bool _deferredPermissionInitScheduled = false;
  Future<void>? _permissionInitFuture;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundMessageSub;
  StreamSubscription<RemoteMessage>? _messageOpenedSub;
  StreamSubscription<dynamic>? _callkitEventSub;

  final Set<String> _acceptInProgress = <String>{};
  final Set<String> _declineInProgress = <String>{};
  final Set<String> _timeoutInProgress = <String>{};
  final Set<String> _endedInProgress = <String>{};
  final Set<String> _recoverInProgress = <String>{};
  final Set<String> _foregroundIncomingHandled = <String>{};
  final Set<String> _foregroundMissedHandled = <String>{};
  final Set<String> _foregroundChatHandled = <String>{};
  final Set<String> _chatOpenInProgress = <String>{};

  final Map<String, DateTime> _recentAccepts = <String, DateTime>{};
  final Map<String, DateTime> _recentForegroundEvents = <String, DateTime>{};

  static const Duration _ignoreEndedAfterAcceptWindow = Duration(seconds: 8);
  static const Duration _dedupeWindow = Duration(seconds: 12);
  static const Duration _tokenSyncDebounce = Duration(seconds: 3);

  String _lastSyncedUid = '';
  String _lastSyncedToken = '';
  DateTime? _lastTokenSyncAt;
  Future<void>? _tokenSyncFuture;
  Timer? _delayedTokenSyncTimer;
  Timer? _deferredPermissionInitTimer;

  bool isSystemIncomingUiActiveFor(String callId) {
    return CallManager.instance.isSystemIncomingUiActiveFor(callId);
  }

  bool shouldSuppressCustomIncomingOverlay(String callId) {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return false;
    return CallManager.instance.shouldSuppressCustomIncomingOverlay(safeCallId);
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    if (value == null) return fallback;
    return value.toString().trim();
  }

  bool _navigatorHasPendingTransitions(NavigatorState navigator) {
    final binding = SchedulerBinding.instance;
    return navigator.userGestureInProgress ||
        binding.transientCallbackCount > 0;
  }

  Future<bool> _waitForNavigatorToSettle(NavigatorState navigator) async {
    var stableFrames = 0;

    for (int attempt = 0; attempt < 24; attempt++) {
      if (!navigator.mounted) return false;

      final navigatorBusy = _navigatorHasPendingTransitions(navigator);

      if (!navigatorBusy) {
        stableFrames += 1;
        if (stableFrames >= 3) {
          await WidgetsBinding.instance.endOfFrame;
          return navigator.mounted &&
              !_navigatorHasPendingTransitions(navigator);
        }
      } else {
        stableFrames = 0;
      }

      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    return navigator.mounted && !_navigatorHasPendingTransitions(navigator);
  }

  bool _wasRecentlyAccepted(String callId) {
    final at = _recentAccepts[callId];
    if (at == null) return false;
    return DateTime.now().difference(at) <= _ignoreEndedAfterAcceptWindow;
  }

  void _markAccepted(String callId) {
    _recentAccepts[callId] = DateTime.now();
    _cleanupRecentCaches();
  }

  bool _isDuplicateRecentEvent(String key) {
    final at = _recentForegroundEvents[key];
    if (at == null) return false;
    return DateTime.now().difference(at) <= _dedupeWindow;
  }

  void _markRecentEvent(String key) {
    _recentForegroundEvents[key] = DateTime.now();
    _cleanupRecentCaches();
  }

  void _cleanupRecentCaches() {
    final now = DateTime.now();
    _recentAccepts.removeWhere(
      (_, value) => now.difference(value) > const Duration(minutes: 1),
    );
    _recentForegroundEvents.removeWhere(
      (_, value) => now.difference(value) > const Duration(minutes: 1),
    );
  }

  void _scheduleSetCleanup(Set<String> target, String value) {
    Future<void>.delayed(const Duration(seconds: 20), () {
      target.remove(value);
    });
  }

  bool _isIncomingCallMessage(RemoteMessage message) {
    final type = _asString(message.data['type']);
    return type == 'incoming_call';
  }

  bool _isMissedCallMessage(RemoteMessage message) {
    final type = _asString(message.data['type']);
    return type == 'missed_call';
  }

  bool _isIncomingChatMessage(RemoteMessage message) {
    final type = _asString(message.data['type']);
    return type == 'chat_message' || type == 'incoming_chat_message';
  }

  String _messageCallId(RemoteMessage message) {
    return _asString(message.data['callId']);
  }

  String _messageChatSessionId(RemoteMessage message) {
    return _asString(message.data['chatSessionId']);
  }

  String _messageSpeakerId(RemoteMessage message) {
    return _asString(
      message.data[FirestorePaths.fieldSpeakerId] ?? message.data['speakerId'],
    );
  }

  String _messageListenerId(RemoteMessage message) {
    return _asString(
      message.data[FirestorePaths.fieldListenerId] ??
          message.data['listenerId'],
    );
  }

  String _messageSenderId(RemoteMessage message) {
    return _asString(
      message.data[FirestorePaths.fieldMessageSenderId] ??
          message.data['senderId'],
    );
  }

  String _messageReceiverId(RemoteMessage message) {
    return _asString(
      message.data[FirestorePaths.fieldMessageReceiverId] ??
          message.data['receiverId'],
    );
  }

  List<String> _messageParticipantIds(RemoteMessage message) {
    final seen = <String>{};
    final ids = <String>[];

    void addId(dynamic value) {
      final safe = _asString(value);
      if (safe.isEmpty || seen.contains(safe)) return;
      seen.add(safe);
      ids.add(safe);
    }

    final rawParticipantIds =
        message.data[FirestorePaths.fieldParticipantIds] ??
            message.data['participantIds'];
    if (rawParticipantIds is List) {
      for (final value in rawParticipantIds) {
        addId(value);
      }
    } else if (rawParticipantIds is String &&
        rawParticipantIds.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawParticipantIds);
        if (decoded is List) {
          for (final value in decoded) {
            addId(value);
          }
        }
      } catch (_) {
        // Ignore malformed payload JSON and fall back to pair ids.
      }
    }

    if (ids.length != 2) {
      ids.clear();
      seen.clear();
      addId(message.data[FirestorePaths.fieldPairUserA] ??
          message.data['pairUserA']);
      addId(message.data[FirestorePaths.fieldPairUserB] ??
          message.data['pairUserB']);
      addId(_messageSpeakerId(message));
      addId(_messageListenerId(message));
    }

    ids.sort();
    if (ids.length == 2 && ids[0] != ids[1]) {
      return List<String>.unmodifiable(ids);
    }
    return const <String>[];
  }

  String _messageSenderName(RemoteMessage message) {
    return _asString(
      message.data['senderName'],
      fallback: 'New message',
    );
  }

  String _messageText(RemoteMessage message) {
    final raw = _asString(
      message.data[FirestorePaths.fieldMessageText] ??
          message.data['text'] ??
          message.data['messageText'] ??
          message.data['body'],
    );
    return raw.trim().isNotEmpty ? raw : 'You received a new message.';
  }

  String _dedupeKeyForMessage(RemoteMessage message) {
    final type = _asString(message.data['type'], fallback: 'unknown');
    final callId = _messageCallId(message);
    if (callId.isNotEmpty) return '$type::$callId';

    final messageId = _asString(message.data['messageId']);
    if (messageId.isNotEmpty) return '$type::msg::$messageId';

    final chatSessionId = _messageChatSessionId(message);
    if (chatSessionId.isNotEmpty) {
      final senderId = _messageSenderId(message);
      final receiverId = _messageReceiverId(message);
      return '$type::chat::$chatSessionId::$senderId::$receiverId';
    }

    final remoteMessageId = _asString(message.messageId);
    if (remoteMessageId.isNotEmpty) return '$type::remote::$remoteMessageId';

    return '$type::hash::${message.data.toString()}';
  }

  Future<void> start() async {
    if (_started || _starting) return;
    _starting = true;

    try {
      final messaging = FirebaseMessaging.instance;

      _bindCallkitEvents();
      await CallManager.instance.startNativeCallBridge();
      _scheduleDeferredPermissionInitialization();

      await _messageOpenedSub?.cancel();
      _messageOpenedSub =
          FirebaseMessaging.onMessageOpenedApp.listen((message) {
        unawaited(_handleMessageOpened(message));
      });

      await _foregroundMessageSub?.cancel();
      _foregroundMessageSub =
          FirebaseMessaging.onMessage.listen((message) async {
        try {
          _cleanupRecentCaches();

          final dedupeKey = _dedupeKeyForMessage(message);
          if (_isDuplicateRecentEvent(dedupeKey)) {
            debugPrint(
              'Skipping duplicate foreground push: ${AppLog.safeId(dedupeKey)}',
            );
            return;
          }
          _markRecentEvent(dedupeKey);

          if (_isIncomingCallMessage(message)) {
            final callId = _messageCallId(message);
            if (callId.isNotEmpty &&
                _foregroundIncomingHandled.contains(callId)) {
              debugPrint(
                'Foreground incoming_call already handled for '
                '${AppLog.safeId(callId)}',
              );
              debugPrint('call.incoming_ui_deduped');
              return;
            }

            if (callId.isNotEmpty) {
              _foregroundIncomingHandled.add(callId);
            }

            try {
              await CallManager.instance.showIncomingCallFromMessage(message);
            } finally {
              if (callId.isNotEmpty) {
                _scheduleSetCleanup(_foregroundIncomingHandled, callId);
              }
            }
            return;
          }

          if (_isMissedCallMessage(message)) {
            final callId = _messageCallId(message);
            if (callId.isNotEmpty &&
                _foregroundMissedHandled.contains(callId)) {
              debugPrint(
                'Foreground missed_call already handled for '
                '${AppLog.safeId(callId)}',
              );
              return;
            }

            if (callId.isNotEmpty) {
              _foregroundMissedHandled.add(callId);
            }

            try {
              if (callId.isNotEmpty) {
                await CallManager.instance.clearIncomingUi(callId);
              }
              debugPrint('Foreground missed_call push received');
            } finally {
              if (callId.isNotEmpty) {
                _scheduleSetCleanup(_foregroundMissedHandled, callId);
              }
            }
            return;
          }

          if (_isIncomingChatMessage(message)) {
            final chatSessionId = _messageChatSessionId(message);
            final messageId = _asString(message.data['messageId']);
            final senderId = _messageSenderId(message);
            final receiverId = _messageReceiverId(message);
            final foregroundChatKey = messageId.isNotEmpty
                ? messageId
                : '$chatSessionId::$senderId::$receiverId';

            if (foregroundChatKey.isNotEmpty &&
                _foregroundChatHandled.contains(foregroundChatKey)) {
              debugPrint(
                'Foreground incoming chat already handled for '
                '${AppLog.safeId(foregroundChatKey)}',
              );
              return;
            }

            if (!_isCurrentUserReceiver(message)) {
              debugPrint(
                  'Ignoring chat push because current user is not receiver.');
              return;
            }

            if (CallManager.instance.hasActiveCallContext) {
              debugPrint('chat_push.skipped_call_context');
              return;
            }

            if (chatSessionId.isNotEmpty &&
                ActiveChatSessionTracker.instance.isActive(chatSessionId)) {
              debugPrint('chat_push.suppressed_active_chat');
              return;
            }

            final messenger = rootMessengerKey.currentState;
            if (messenger == null) {
              debugPrint('chat_push.queued_until_main_isolate_ready');
              return;
            }

            if (foregroundChatKey.isNotEmpty) {
              _foregroundChatHandled.add(foregroundChatKey);
            }

            try {
              final senderName = _messageSenderName(message);
              final text = _messageText(message);
              debugPrint('Foreground chat push received');

              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(
                SnackBar(
                  content: Text('$senderName: $text'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 3),
                  action: SnackBarAction(
                    label: 'Open',
                    onPressed: () {
                      messenger.hideCurrentSnackBar();
                      unawaited(_openChatFromPush(message));
                    },
                  ),
                ),
              );
            } finally {
              if (foregroundChatKey.isNotEmpty) {
                _scheduleSetCleanup(_foregroundChatHandled, foregroundChatKey);
              }
            }
            return;
          }
        } catch (e) {
          debugPrint('Foreground FCM handling failed: ${e.runtimeType}');
        }
      });

      try {
        final initialMessage = await messaging.getInitialMessage();
        if (initialMessage != null) {
          await _handleMessageOpened(initialMessage);
        }
      } catch (e) {
        debugPrint('FCM initial message read failed: ${e.runtimeType}');
      }

      await _authSub?.cancel();
      _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
        _delayedTokenSyncTimer?.cancel();

        final previousUid = _lastSyncedUid.trim();
        final nextUid = user?.uid.trim() ?? '';
        if (previousUid.isNotEmpty && previousUid != nextUid) {
          await AuthScopedSubscriptions.instance.disposeForUid(previousUid);
        }

        await _detachTokenFromPreviousUserIfNeeded(user);

        if (user == null) {
          _clearTokenSyncCache();
          return;
        }

        _scheduleTokenSync(force: true);
      });

      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = messaging.onTokenRefresh.listen((_) async {
        _scheduleTokenSync(force: true);
      });

      _scheduleTokenSync();
      _started = true;
    } finally {
      _starting = false;
    }
  }

  void _scheduleDeferredPermissionInitialization() {
    if (_permissionsInitialized ||
        _deferredPermissionInitScheduled ||
        _permissionInitFuture != null) {
      return;
    }

    _deferredPermissionInitScheduled = true;
    _deferredPermissionInitTimer?.cancel();
    _deferredPermissionInitTimer = Timer(
      const Duration(milliseconds: 900),
      () {
        _deferredPermissionInitScheduled = false;
        unawaited(_initCallkitPermissions());
      },
    );
  }

  void _scheduleTokenSync({bool force = false}) {
    _delayedTokenSyncTimer?.cancel();
    _delayedTokenSyncTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_syncToken(force: force)),
    );
  }

  Future<void> _initCallkitPermissions() async {
    if (_permissionsInitialized) return;
    final existing = _permissionInitFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final completer = Completer<void>();
    _permissionInitFuture = completer.future;

    try {
      try {
        await ensureFriendifyNotificationChannelsInitialized();
      } catch (e) {
        debugPrint('Notification channel setup failed: ${e.runtimeType}');
      }

      try {
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (e) {
        debugPrint('FCM permission request failed: ${e.runtimeType}');
      }

      try {
        await FlutterCallkitIncoming.requestNotificationPermission({
          'title': 'Notification permission',
          'rationaleMessagePermission':
              'Notification permission is required to show incoming calls and chat alerts.',
          'postNotificationMessageRequired':
              'Please allow notification permission from settings.',
        });
      } catch (e) {
        debugPrint(
          'CallKit notification permission failed: ${e.runtimeType}',
        );
      }

      try {
        final canUse = await FlutterCallkitIncoming.canUseFullScreenIntent();
        if (canUse != true) {
          await FlutterCallkitIncoming.requestFullIntentPermission();
        }
      } catch (e) {
        debugPrint(
          'Full screen intent permission failed: ${e.runtimeType}',
        );
      }

      _permissionsInitialized = true;
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_permissionInitFuture, completer.future)) {
        _permissionInitFuture = null;
      }
    }
  }

  String _extractEventName(dynamic rawEvent) {
    final direct = _asString(rawEvent?.event);
    if (direct.isNotEmpty) return direct;

    final asMap = CallManager.instance.safeMap(rawEvent);
    final fromMap = _asString(asMap['event']);
    if (fromMap.isNotEmpty) return fromMap;

    return _asString(rawEvent?.toString());
  }

  String _extractCallIdFromEvent(dynamic rawEvent) {
    final body = CallManager.instance.safeMap(rawEvent?.body);
    final fromBody = CallManager.instance.extractCallId(body);
    if (fromBody.isNotEmpty) return fromBody;

    final asMap = CallManager.instance.safeMap(rawEvent);
    final fromMap = CallManager.instance.extractCallId(asMap);
    if (fromMap.isNotEmpty) return fromMap;

    return '';
  }

  void _bindCallkitEvents() {
    if (_callkitEventsBound) return;

    _callkitEventSub?.cancel();

    _callkitEventSub =
        FlutterCallkitIncoming.onEvent.listen((dynamic rawEvent) async {
      try {
        _cleanupRecentCaches();

        final eventName = _extractEventName(rawEvent);
        final callId = _extractCallIdFromEvent(rawEvent);

        debugPrint('CallKit event: $eventName callId=${AppLog.safeId(callId)}');

        if (callId.isEmpty) return;

        if (eventName.contains('actionCallIncoming')) {
          CallManager.instance.markIncomingUiShown(callId);
          return;
        }

        if (eventName.contains('actionCallStart')) {
          CallManager.instance.markIncomingUiShown(callId);
          return;
        }

        if (eventName.contains('actionCallAccept')) {
          CallLatencyTracker.trace(
            'call.callkit_accept_received',
            callId: callId,
            actorRole: 'callee',
          );
          if (_acceptInProgress.contains(callId)) return;
          _acceptInProgress.add(callId);

          try {
            _markAccepted(callId);
            await CallManager.instance.handleAcceptFromCallkit(callId);
          } finally {
            _acceptInProgress.remove(callId);
          }
          return;
        }

        if (eventName.contains('actionCallDecline')) {
          if (_declineInProgress.contains(callId)) return;
          _declineInProgress.add(callId);

          try {
            await CallManager.instance.handleDeclineFromCallkit(
              callId,
              FirestorePaths.reasonCalleeRejectCallkit,
            );
          } finally {
            _declineInProgress.remove(callId);
          }
          return;
        }

        if (eventName.contains('actionCallTimeout')) {
          if (_timeoutInProgress.contains(callId)) return;
          _timeoutInProgress.add(callId);

          try {
            await CallManager.instance.handleTimeoutFromCallkit(callId);
          } finally {
            _timeoutInProgress.remove(callId);
          }
          return;
        }

        if (eventName.contains('actionCallEnded')) {
          CallLatencyTracker.trace(
            'call.callkit_end_received',
            callId: callId,
            actorRole: 'callee',
          );
          if (_endedInProgress.contains(callId)) return;
          _endedInProgress.add(callId);

          try {
            if (_wasRecentlyAccepted(callId)) {
              CallLatencyTracker.trace(
                'call.callkit_end_ignored_recent_accept',
                callId: callId,
                actorRole: 'callee',
              );
              debugPrint(
                'Ignoring actionCallEnded for recently accepted call: '
                '${AppLog.safeId(callId)}',
              );
              return;
            }

            await CallManager.instance.handleEndedFromCallkit(callId);
            CallLatencyTracker.trace(
              'call.callkit_end_processed',
              callId: callId,
              actorRole: 'callee',
            );
          } finally {
            _endedInProgress.remove(callId);
          }
          return;
        }
      } catch (e) {
        debugPrint('CallKit event handling failed: ${e.runtimeType}');
      }
    });

    _callkitEventsBound = true;
  }

  bool _isCurrentUserReceiver(RemoteMessage message) {
    final myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) return false;

    final receiverId = _messageReceiverId(message);
    if (receiverId.isEmpty) return true;

    return receiverId == myUid;
  }

  bool _payloadParticipantsAreConsistent(
    RemoteMessage message, {
    required List<String> participantIds,
  }) {
    if (participantIds.length != 2 || participantIds[0] == participantIds[1]) {
      return false;
    }

    final speakerId = _messageSpeakerId(message);
    if (speakerId.isNotEmpty && speakerId != participantIds[0]) {
      return false;
    }

    final listenerId = _messageListenerId(message);
    if (listenerId.isNotEmpty && listenerId != participantIds[1]) {
      return false;
    }

    final pairUserA = _asString(
      message.data[FirestorePaths.fieldPairUserA] ?? message.data['pairUserA'],
    );
    if (pairUserA.isNotEmpty && pairUserA != participantIds[0]) {
      return false;
    }

    final pairUserB = _asString(
      message.data[FirestorePaths.fieldPairUserB] ?? message.data['pairUserB'],
    );
    if (pairUserB.isNotEmpty && pairUserB != participantIds[1]) {
      return false;
    }

    final senderId = _messageSenderId(message);
    if (senderId.isNotEmpty && !participantIds.contains(senderId)) {
      return false;
    }

    final receiverId = _messageReceiverId(message);
    if (receiverId.isNotEmpty && !participantIds.contains(receiverId)) {
      return false;
    }

    return true;
  }

  _PushActualListenerResolution _payloadActualListenerId(
    RemoteMessage message, {
    required List<String> participantIds,
  }) {
    final directActualListenerId = _asString(
      message.data[FirestorePaths.fieldActualListenerId] ??
          message.data['actualListenerId'],
    );
    if (participantIds.contains(directActualListenerId)) {
      return _PushActualListenerResolution(
        actualListenerId: directActualListenerId,
        source: 'payload.actualListenerId',
      );
    }
    return const _PushActualListenerResolution(
      actualListenerId: '',
      source: '',
    );
  }

  Future<Map<String, String>?> _resolveChatPairFromMessage(
    RemoteMessage message,
  ) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) return null;

    final payloadParticipantIds = _messageParticipantIds(message);
    final directSpeakerId = payloadParticipantIds.length == 2
        ? payloadParticipantIds[0]
        : _messageSpeakerId(message);
    final directListenerId = payloadParticipantIds.length == 2
        ? payloadParticipantIds[1]
        : _messageListenerId(message);
    final senderId = _messageSenderId(message);
    final receiverId = _messageReceiverId(message);

    final directActualListener = _payloadActualListenerId(
      message,
      participantIds: payloadParticipantIds,
    );

    if (payloadParticipantIds.length == 2 &&
        _payloadParticipantsAreConsistent(
          message,
          participantIds: payloadParticipantIds,
        ) &&
        directSpeakerId.isNotEmpty &&
        directListenerId.isNotEmpty &&
        directActualListener.isResolved) {
      final iAmParticipant =
          myUid == directSpeakerId || myUid == directListenerId;
      final pushMatchesParticipant = senderId.isEmpty ||
          receiverId.isEmpty ||
          ((senderId == directSpeakerId || senderId == directListenerId) &&
              (receiverId == directSpeakerId ||
                  receiverId == directListenerId));

      if (iAmParticipant && pushMatchesParticipant) {
        final direction = ChatDirectionResolver.resolvePushDirectionForUser(
          participantIds: payloadParticipantIds,
          myUid: myUid,
          actualListenerId: directActualListener.actualListenerId,
        );
        if (direction.isResolved) {
          return <String, String>{
            'speakerId': direction.actualSpeakerId,
            'listenerId': direction.actualListenerId,
            'actualListenerId': direction.actualListenerId,
            'directionSource': directActualListener.source,
          };
        }
      }
    }

    final chatSessionId = _messageChatSessionId(message);
    if (chatSessionId.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(FirestorePaths.chatSessions)
            .doc(chatSessionId)
            .get();

        if (snap.exists) {
          final data = snap.data() ?? <String, dynamic>{};
          final participantIds = _callRepository.sessionParticipantIds(
            data,
            fallbackSpeakerId: directSpeakerId,
            fallbackListenerId: directListenerId,
          );
          final speakerId = participantIds.isNotEmpty
              ? participantIds[0]
              : _asString(data[FirestorePaths.fieldSpeakerId]);
          final listenerId = participantIds.length == 2
              ? participantIds[1]
              : _asString(data[FirestorePaths.fieldListenerId]);
          final actualListenerId = _callRepository.actualListenerIdForSession(
            data,
            fallbackSpeakerId: speakerId,
            fallbackListenerId: listenerId,
            mode: ChatDirectionResolutionMode.strictStoredDirection,
          );

          if (speakerId.isNotEmpty &&
              listenerId.isNotEmpty &&
              speakerId != listenerId &&
              (myUid == speakerId || myUid == listenerId)) {
            final direction = ChatDirectionResolver.resolvePushDirectionForUser(
              participantIds: participantIds,
              myUid: myUid,
              actualListenerId: actualListenerId,
            );
            if (direction.isResolved) {
              return <String, String>{
                'speakerId': direction.actualSpeakerId,
                'listenerId': direction.actualListenerId,
                'actualListenerId': direction.actualListenerId,
                'directionSource': 'session.actualListenerId',
              };
            }
          }
        }
      } catch (e) {
        debugPrint(
          'Failed to load chat session from push: ${e.runtimeType}',
        );
      }
    }

    return null;
  }

  Future<void> _openChatFromPush(RemoteMessage message) async {
    final navigator = rootNavigatorKey.currentState;
    final context = rootNavigatorKey.currentContext;
    final myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

    if (navigator == null || context == null || myUid.isEmpty) {
      debugPrint('Cannot open chat from push: navigator or user missing.');
      return;
    }

    if (!_isCurrentUserReceiver(message)) {
      debugPrint('Cannot open chat from push: current user is not receiver.');
      return;
    }

    final resolved = await _resolveChatPairFromMessage(message);
    if (resolved == null) {
      debugPrint('Cannot resolve chat pair from push payload.');
      return;
    }

    final speakerId = _asString(resolved['speakerId']);
    final listenerId = _asString(resolved['listenerId']);
    final actualListenerId = _asString(resolved['actualListenerId']);
    final directionSource = _asString(resolved['directionSource']);

    if (!isSafeChatPushDirection(
      speakerId: speakerId,
      listenerId: listenerId,
      actualListenerId: actualListenerId,
      myUid: myUid,
    )) {
      if (kDebugMode) {
        debugPrint(
          'Cannot open chat from push: direction payload is missing or unsafe.',
        );
      }
      return;
    }

    if (kDebugMode && directionSource.startsWith('legacy.')) {
      debugPrint(
        'Opening chat from push using legacy repaired direction '
        '($directionSource).',
      );
    }

    final pairKey = _callRepository.chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
    if (_chatOpenInProgress.contains(pairKey)) {
      debugPrint('Chat open already in progress.');
      return;
    }

    _chatOpenInProgress.add(pairKey);

    try {
      final otherUid = myUid == listenerId ? speakerId : listenerId;
      AppUserModel? otherUser;

      try {
        otherUser = await UserRepository.instance.getUser(otherUid);
      } catch (e) {
        debugPrint(
          'Failed to preload other user from push: ${e.runtimeType}',
        );
      }

      final settled = await _waitForNavigatorToSettle(navigator);
      if (!settled) {
        debugPrint(
            'Skipped open chat from push because navigator was not settled.');
        return;
      }

      if (navigator.mounted) {
        FocusManager.instance.primaryFocus?.unfocus();
        await pushResolvedChatConversation(
          myUid: myUid,
          speakerId: speakerId,
          listenerId: listenerId,
          actualListenerId: actualListenerId,
          initialOtherUser: otherUser,
          onPush: (screen) => navigator.push(
            MaterialPageRoute(
              settings: const RouteSettings(
                name: ChatConversationScreen.routeName,
              ),
              builder: (_) => screen,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Open chat from push failed: ${e.runtimeType}');
    } finally {
      _chatOpenInProgress.remove(pairKey);
    }
  }

  Future<void> _handleMessageOpened(RemoteMessage message) async {
    _cleanupRecentCaches();

    final type = _asString(message.data['type']);
    final callId = _asString(message.data['callId']);
    final chatSessionId = _asString(message.data['chatSessionId']);
    final messageId = _asString(message.data['messageId']);

    final anchor = callId.isNotEmpty
        ? callId
        : messageId.isNotEmpty
            ? messageId
            : chatSessionId;

    final dedupeKey = 'opened::$type::$anchor';
    if (_isDuplicateRecentEvent(dedupeKey)) {
      debugPrint(
        'Skipping duplicate open-from-push for ${AppLog.safeId(dedupeKey)}',
      );
      return;
    }
    _markRecentEvent(dedupeKey);

    if (type == 'incoming_call' || type == 'missed_call') {
      if (callId.isEmpty) return;

      if (_recoverInProgress.contains(callId)) {
        debugPrint(
          'Recover already in progress for callId=${AppLog.safeId(callId)}',
        );
        return;
      }

      _recoverInProgress.add(callId);
      try {
        await CallManager.instance.recoverCallFromPushOpen(callId);
      } finally {
        _recoverInProgress.remove(callId);
      }
      return;
    }

    if (type == 'chat_message' || type == 'incoming_chat_message') {
      debugPrint(
        'Open-from-push for chat session: ${AppLog.safeId(chatSessionId)}',
      );
      await _openChatFromPush(message);
      return;
    }
  }

  void _clearTokenSyncCache() {
    _lastSyncedUid = '';
    _lastSyncedToken = '';
    _lastTokenSyncAt = null;
  }

  Future<void> _removeTokenFromUser({
    required String uid,
    required String token,
    required String reason,
  }) async {
    final safeUid = uid.trim();
    final safeToken = token.trim();

    if (safeUid.isEmpty || safeToken.isEmpty) return;

    try {
      await FirestoreService.removeFcmTokenForUser(
        uid: safeUid,
        token: safeToken,
      );
      debugPrint('FCM token removed for ${AppLog.safeId(safeUid)} ($reason)');
    } catch (e) {
      debugPrint(
        'FCM token removal failed for ${AppLog.safeId(safeUid)} '
        '($reason): ${e.runtimeType}',
      );
    }
  }

  Future<void> detachCurrentTokenForSignOut() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final previousUid = _lastSyncedUid.trim();
    final previousToken = _lastSyncedToken.trim();

    if (currentUid.isEmpty ||
        previousUid.isEmpty ||
        previousToken.isEmpty ||
        currentUid != previousUid) {
      _clearTokenSyncCache();
      return;
    }

    await _removeTokenFromUser(
      uid: previousUid,
      token: previousToken,
      reason: 'sign-out',
    );
    _clearTokenSyncCache();
  }

  Future<void> _detachTokenFromPreviousUserIfNeeded(User? nextUser) async {
    final previousUid = _lastSyncedUid.trim();
    final previousToken = _lastSyncedToken.trim();
    final nextUid = nextUser?.uid.trim() ?? '';

    if (previousUid.isEmpty || previousToken.isEmpty) return;
    if (previousUid == nextUid) return;

    final activeUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (activeUid != previousUid) {
      _clearTokenSyncCache();
      if (kDebugMode) {
        debugPrint(
          'FCM token detach skipped because auth no longer owns '
          '${AppLog.safeId(previousUid)}',
        );
      }
      return;
    }

    await _removeTokenFromUser(
      uid: previousUid,
      token: previousToken,
      reason: nextUid.isEmpty ? 'sign-out' : 'account-switch',
    );
    _clearTokenSyncCache();
  }

  bool _shouldSkipTokenSync({
    required String uid,
    required String token,
    required bool force,
  }) {
    if (force) return false;
    if (uid.isEmpty || token.isEmpty) return true;

    if (_lastSyncedUid == uid && _lastSyncedToken == token) {
      final lastAt = _lastTokenSyncAt;
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _tokenSyncDebounce) {
        return true;
      }
    }

    return false;
  }

  Future<void> _syncToken({bool force = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_tokenSyncFuture != null && !force) {
      await _tokenSyncFuture;
      return;
    }

    final completer = Completer<void>();
    _tokenSyncFuture = completer.future;

    try {
      final safeUid = user.uid.trim();
      if (safeUid.isEmpty) return;

      for (int i = 0; i < 5; i++) {
        final idToken = await user.getIdToken();
        if (idToken != null && idToken.isNotEmpty) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }

      await Future.delayed(const Duration(seconds: 1));

      final token = await FirebaseMessaging.instance.getToken();
      final safeToken = token?.trim() ?? '';

      if (safeToken.isEmpty) return;

      if (_shouldSkipTokenSync(
        uid: safeUid,
        token: safeToken,
        force: force,
      )) {
        debugPrint('FCM token sync skipped (unchanged)');
        return;
      }

      final previousUid = _lastSyncedUid.trim();
      final previousToken = _lastSyncedToken.trim();
      if (previousUid == safeUid &&
          previousToken.isNotEmpty &&
          previousToken != safeToken) {
        await _removeTokenFromUser(
          uid: previousUid,
          token: previousToken,
          reason: 'token-rotated',
        );
      }

      await FirestoreService.addMyFcmToken(safeToken);

      _lastSyncedUid = safeUid;
      _lastSyncedToken = safeToken;
      _lastTokenSyncAt = DateTime.now();

      debugPrint('FCM token saved SUCCESS');
    } catch (e) {
      debugPrint('FCM token save failed: ${e.runtimeType}');

      await Future.delayed(const Duration(seconds: 2));
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null && token.isNotEmpty) {
          await FirestoreService.addMyFcmToken(token);
          _lastSyncedUid = user.uid.trim();
          _lastSyncedToken = token.trim();
          _lastTokenSyncAt = DateTime.now();
          debugPrint('FCM token saved on retry');
        }
      } catch (_) {}
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_tokenSyncFuture, completer.future)) {
        _tokenSyncFuture = null;
      }
    }
  }

  Future<void> stop() async {
    _deferredPermissionInitTimer?.cancel();
    _deferredPermissionInitTimer = null;
    _deferredPermissionInitScheduled = false;

    _delayedTokenSyncTimer?.cancel();
    _delayedTokenSyncTimer = null;

    await _authSub?.cancel();
    await _tokenRefreshSub?.cancel();
    await _foregroundMessageSub?.cancel();
    await _messageOpenedSub?.cancel();
    await _callkitEventSub?.cancel();

    _authSub = null;
    _tokenRefreshSub = null;
    _foregroundMessageSub = null;
    _messageOpenedSub = null;
    _callkitEventSub = null;

    _started = false;
    _starting = false;
    _callkitEventsBound = false;

    _acceptInProgress.clear();
    _declineInProgress.clear();
    _timeoutInProgress.clear();
    _endedInProgress.clear();
    _recoverInProgress.clear();
    _foregroundIncomingHandled.clear();
    _foregroundMissedHandled.clear();
    _foregroundChatHandled.clear();
    _chatOpenInProgress.clear();
    _recentAccepts.clear();
    _recentForegroundEvents.clear();

    _clearTokenSyncCache();
    _tokenSyncFuture = null;

    await CallManager.instance.clearIncomingUi();
  }
}
