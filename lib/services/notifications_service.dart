import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../app.dart';
import '../core/constants/firestore_paths.dart';
import '../firebase_options.dart';
import '../repositories/user_repository.dart';
import '../screens/chat_conversation_screen.dart';
import '../shared/models/app_user_model.dart';
import 'call_manager.dart';
import 'firestore_service.dart';

class NotificationsService {
  NotificationsService._();

  static final NotificationsService instance = NotificationsService._();

  bool _started = false;
  bool _starting = false;
  bool _callkitEventsBound = false;
  bool _permissionsInitialized = false;

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
      message.data[FirestorePaths.fieldListenerId] ?? message.data['listenerId'],
    );
  }

  String _messageSenderId(RemoteMessage message) {
    return _asString(
      message.data[FirestorePaths.fieldMessageSenderId] ?? message.data['senderId'],
    );
  }

  String _messageReceiverId(RemoteMessage message) {
    return _asString(
      message.data[FirestorePaths.fieldMessageReceiverId] ?? message.data['receiverId'],
    );
  }

  String _messageSenderRole(RemoteMessage message) {
    return _asString(message.data['senderRole']);
  }

  String _messageReceiverRole(RemoteMessage message) {
    return _asString(message.data['receiverRole']);
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

      await _initCallkitPermissions();
      _bindCallkitEvents();

      await _messageOpenedSub?.cancel();
      _messageOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
        unawaited(_handleMessageOpened(message));
      });

      await _foregroundMessageSub?.cancel();
      _foregroundMessageSub = FirebaseMessaging.onMessage.listen((message) async {
        try {
          _cleanupRecentCaches();

          final dedupeKey = _dedupeKeyForMessage(message);
          if (_isDuplicateRecentEvent(dedupeKey)) {
            debugPrint('Skipping duplicate foreground push: $dedupeKey');
            return;
          }
          _markRecentEvent(dedupeKey);

          if (_isIncomingCallMessage(message)) {
            final callId = _messageCallId(message);
            if (callId.isNotEmpty && _foregroundIncomingHandled.contains(callId)) {
              debugPrint('Foreground incoming_call already handled for $callId');
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
            if (callId.isNotEmpty && _foregroundMissedHandled.contains(callId)) {
              debugPrint('Foreground missed_call already handled for $callId');
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
                'Foreground incoming chat already handled for $foregroundChatKey',
              );
              return;
            }

            if (!_isCurrentUserReceiver(message)) {
              debugPrint('Ignoring chat push because current user is not receiver.');
              return;
            }

            if (foregroundChatKey.isNotEmpty) {
              _foregroundChatHandled.add(foregroundChatKey);
            }

            try {
              final senderName = _messageSenderName(message);
              final text = _messageText(message);

              debugPrint(
                'Foreground chat push received from $senderName: $text',
              );

              final messenger = rootMessengerKey.currentState;
              messenger?.hideCurrentSnackBar();
              messenger?.showSnackBar(
                SnackBar(
                  content: Text('$senderName: $text'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 3),
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
          debugPrint('Foreground FCM handling failed: $e');
        }
      });

      try {
        final initialMessage = await messaging.getInitialMessage();
        if (initialMessage != null) {
          await _handleMessageOpened(initialMessage);
        }
      } catch (e) {
        debugPrint('FCM initial message read failed: $e');
      }

      await _authSub?.cancel();
      _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
        _delayedTokenSyncTimer?.cancel();

        if (user == null) {
          _lastSyncedUid = '';
          _lastSyncedToken = '';
          _lastTokenSyncAt = null;
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

  void _scheduleTokenSync({bool force = false}) {
    _delayedTokenSyncTimer?.cancel();
    _delayedTokenSyncTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_syncToken(force: force)),
    );
  }

  Future<void> _initCallkitPermissions() async {
    if (_permissionsInitialized) return;

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (_) {
      // already initialized
    }

    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e) {
      debugPrint('FCM permission request failed: $e');
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
      debugPrint('CallKit notification permission failed: $e');
    }

    try {
      final canUse = await FlutterCallkitIncoming.canUseFullScreenIntent();
      if (canUse != true) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (e) {
      debugPrint('Full screen intent permission failed: $e');
    }

    _permissionsInitialized = true;
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

        debugPrint('CallKit event: $eventName callId=$callId');

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
          if (_endedInProgress.contains(callId)) return;
          _endedInProgress.add(callId);

          try {
            if (_wasRecentlyAccepted(callId)) {
              debugPrint(
                'Ignoring actionCallEnded for recently accepted call: $callId',
              );
              return;
            }

            await CallManager.instance.handleEndedFromCallkit(callId);
          } finally {
            _endedInProgress.remove(callId);
          }
          return;
        }
      } catch (e) {
        debugPrint('CallKit event handling failed: $e');
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

  bool _payloadRolesAreConsistent(RemoteMessage message) {
    final speakerId = _messageSpeakerId(message);
    final listenerId = _messageListenerId(message);
    final senderId = _messageSenderId(message);
    final receiverId = _messageReceiverId(message);
    final senderRole = _messageSenderRole(message);
    final receiverRole = _messageReceiverRole(message);

    if (speakerId.isEmpty || listenerId.isEmpty) return false;
    if (speakerId == listenerId) return false;

    if (senderId.isNotEmpty && senderId != speakerId && senderId != listenerId) {
      return false;
    }

    if (receiverId.isNotEmpty &&
        receiverId != speakerId &&
        receiverId != listenerId) {
      return false;
    }

    if (senderRole.isNotEmpty) {
      if (senderRole == 'speaker' && senderId.isNotEmpty && senderId != speakerId) {
        return false;
      }
      if (senderRole == 'listener' &&
          senderId.isNotEmpty &&
          senderId != listenerId) {
        return false;
      }
    }

    if (receiverRole.isNotEmpty) {
      if (receiverRole == 'speaker' &&
          receiverId.isNotEmpty &&
          receiverId != speakerId) {
        return false;
      }
      if (receiverRole == 'listener' &&
          receiverId.isNotEmpty &&
          receiverId != listenerId) {
        return false;
      }
    }

    return true;
  }

  Future<Map<String, String>?> _resolveChatPairFromMessage(
    RemoteMessage message,
  ) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) return null;

    final directSpeakerId = _messageSpeakerId(message);
    final directListenerId = _messageListenerId(message);
    final senderId = _messageSenderId(message);
    final receiverId = _messageReceiverId(message);

    if (_payloadRolesAreConsistent(message) &&
        directSpeakerId.isNotEmpty &&
        directListenerId.isNotEmpty) {
      final iAmParticipant =
          myUid == directSpeakerId || myUid == directListenerId;
      final pushMatchesParticipant =
          senderId.isEmpty ||
          receiverId.isEmpty ||
          ((senderId == directSpeakerId || senderId == directListenerId) &&
              (receiverId == directSpeakerId || receiverId == directListenerId));

      if (iAmParticipant && pushMatchesParticipant) {
        return <String, String>{
          'speakerId': directSpeakerId,
          'listenerId': directListenerId,
        };
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
          final speakerId = _asString(data[FirestorePaths.fieldSpeakerId]);
          final listenerId = _asString(data[FirestorePaths.fieldListenerId]);

          if (speakerId.isNotEmpty &&
              listenerId.isNotEmpty &&
              speakerId != listenerId &&
              (myUid == speakerId || myUid == listenerId)) {
            return <String, String>{
              'speakerId': speakerId,
              'listenerId': listenerId,
            };
          }
        }
      } catch (e) {
        debugPrint('Failed to load chat session from push: $e');
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

    if (speakerId.isEmpty || listenerId.isEmpty || speakerId == listenerId) {
      debugPrint('Cannot open chat from push: invalid speaker/listener pair.');
      return;
    }

    if (myUid != speakerId && myUid != listenerId) {
      debugPrint('Cannot open chat from push: current user not in pair.');
      return;
    }

    final pairKey = '$speakerId::$listenerId';
    if (_chatOpenInProgress.contains(pairKey)) {
      debugPrint('Chat open already in progress for $pairKey');
      return;
    }

    _chatOpenInProgress.add(pairKey);

    try {
      final otherUid = myUid == listenerId ? speakerId : listenerId;
      AppUserModel? otherUser;

      try {
        otherUser = await UserRepository.instance.getUser(otherUid);
      } catch (e) {
        debugPrint('Failed to preload other user from push: $e');
      }

      if (navigator.context.mounted) {
        await navigator.push(
          MaterialPageRoute(
            builder: (_) => ChatConversationScreen(
              speakerId: speakerId,
              listenerId: listenerId,
              iAmListener: myUid == listenerId,
              initialOtherUser: otherUser,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Open chat from push failed: $e');
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
      debugPrint('Skipping duplicate open-from-push for $dedupeKey');
      return;
    }
    _markRecentEvent(dedupeKey);

    if (type == 'incoming_call' || type == 'missed_call') {
      if (callId.isEmpty) return;

      if (_recoverInProgress.contains(callId)) {
        debugPrint('Recover already in progress for callId=$callId');
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
      debugPrint('Open-from-push for chat session: $chatSessionId');
      await _openChatFromPush(message);
      return;
    }
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

      await FirestoreService.addMyFcmToken(safeToken);

      _lastSyncedUid = safeUid;
      _lastSyncedToken = safeToken;
      _lastTokenSyncAt = DateTime.now();

      debugPrint('FCM token saved SUCCESS');
    } catch (e) {
      debugPrint('FCM token save failed: $e');

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

    _lastSyncedUid = '';
    _lastSyncedToken = '';
    _lastTokenSyncAt = null;
    _tokenSyncFuture = null;

    await CallManager.instance.clearIncomingUi();
  }
}