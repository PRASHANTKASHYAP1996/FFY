import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants/agora_client_config.dart';
import '../core/constants/firestore_paths.dart';
import '../core/constants/ui_copy.dart';
import '../services/call_session_manager.dart';
import '../services/app_log.dart';
import '../services/firestore_service.dart';
import '../shared/chat_direction_resolver.dart';
import '../shared/listener_availability.dart';
import '../shared/models/call_model.dart';
import '../shared/models/app_user_model.dart';

enum CallPermissionRequestResult {
  sent,
  alreadyAllowed,
  alreadyPending,
  invalidTarget,
  blocked,
}

class CallReadinessResult {
  const CallReadinessResult({
    required this.canStart,
    required this.label,
    required this.message,
    required this.reason,
  });

  final bool canStart;
  final String label;
  final String message;
  final String reason;
}

class ChatSessionDirectionResolution {
  const ChatSessionDirectionResolution._({
    required this.participantIds,
    required this.actualSpeakerId,
    required this.actualListenerId,
    required this.otherUid,
    required this.iAmListener,
    required this.errorReason,
  });

  const ChatSessionDirectionResolution.success({
    required List<String> participantIds,
    required String actualSpeakerId,
    required String actualListenerId,
    required String otherUid,
    required bool iAmListener,
  }) : this._(
          participantIds: participantIds,
          actualSpeakerId: actualSpeakerId,
          actualListenerId: actualListenerId,
          otherUid: otherUid,
          iAmListener: iAmListener,
          errorReason: '',
        );

  const ChatSessionDirectionResolution.error(String errorReason)
      : this._(
          participantIds: const <String>[],
          actualSpeakerId: '',
          actualListenerId: '',
          otherUid: '',
          iAmListener: false,
          errorReason: errorReason,
        );

  final List<String> participantIds;
  final String actualSpeakerId;
  final String actualListenerId;
  final String otherUid;
  final bool iAmListener;
  final String errorReason;

  bool get isResolved => errorReason.isEmpty;
}

class CallRepository {
  CallRepository._();

  static final CallRepository instance = CallRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _functions => FirebaseFunctions.instance;

  final Set<String> _endingCallIds = <String>{};
  final Set<String> _rejectingCallIds = <String>{};
  final Set<String> _acceptingCallIds = <String>{};
  final Set<String> _cancelingCallIds = <String>{};
  final Map<String, Future<String>> _pendingChatSessionEnsures =
      <String, Future<String>>{};
  final Map<String, int> _recentlyEnsuredChatSessionsMs = <String, int>{};

  static const int _chatSessionEnsureTtlMs = 45000;
  static const String _sessionContractCompleteKey = '_contractComplete';
  static const String _sessionDirectionCompleteKey = '_directionComplete';

  CollectionReference<Map<String, dynamic>> get _calls =>
      _db.collection(FirestorePaths.calls);

  CollectionReference<Map<String, dynamic>> get _chatSessions =>
      _db.collection(FirestorePaths.chatSessions);

  String get myUid => FirestoreService.uid();

  bool get hasBlockingCallState {
    final callSession = CallSessionManager.instance;
    return callSession.active ||
        callSession.state == CallState.preparing ||
        callSession.state == CallState.joining ||
        callSession.state == CallState.reconnecting ||
        callSession.state == CallState.ending;
  }

  CallReadinessResult callReadinessForKnownUsers({
    required AppUserModel me,
    required AppUserModel listener,
    required bool hasCallAccess,
    int? requiredCredits,
  }) {
    final safeListenerId = listener.uid.trim();
    if (me.uid.trim().isEmpty || safeListenerId.isEmpty) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Unavailable',
        message: 'Call setup is incomplete. Please try again.',
        reason: 'missing_user_id',
      );
    }

    if (me.uid == safeListenerId) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Your profile',
        message: 'You cannot call your own listener profile.',
        reason: 'self_call',
      );
    }

    if (hasBlockingCallState || me.isOnCall) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Call active',
        message: 'Finish your current call flow first.',
        reason: 'caller_busy',
      );
    }

    if (me.blocked.contains(safeListenerId)) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Blocked',
        message: 'Unblock this listener before calling.',
        reason: 'caller_blocked_listener',
      );
    }

    if (me.onlyChatMode) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Chat only',
        message: 'Only Chat Mode is ON. Turn it off from Home before calling.',
        reason: 'self_only_chat_mode',
      );
    }

    if (listener.onlyChatMode) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Chat only',
        message: 'This listener is in Only Chat Mode.',
        reason: 'peer_only_chat_mode',
      );
    }

    final creditsNeeded = requiredCredits ?? listener.listenerRate;
    if (creditsNeeded > 0 && me.usableCredits < creditsNeeded) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Add credits',
        message: 'Add credits before starting a call.',
        reason: 'insufficient_credits',
      );
    }

    if (!hasCallAccess) {
      return const CallReadinessResult(
        canStart: false,
        label: 'Request approval',
        message: 'Open chat and wait for this listener to approve calls.',
        reason: 'call_access_not_accepted',
      );
    }

    final availability = ListenerAvailabilityResolver.resolve(
      isAvailable: listener.isAvailable,
      isOnCall: listener.isOnCall,
      activeCallId: listener.activeCallId,
      lastSeen: listener.lastSeen,
    );
    if (!availability.canCallNow) {
      return CallReadinessResult(
        canStart: false,
        label: availability.label,
        message: availability.kind == ListenerAvailabilityKind.onAnotherCall
            ? 'This listener is on another call right now.'
            : 'This listener is not available for calls right now.',
        reason: availability.reason,
      );
    }

    return const CallReadinessResult(
      canStart: true,
      label: 'Call-ready',
      message: 'This listener is ready for a call.',
      reason: 'ready',
    );
  }

  String humanizeChatActionError(Object error) {
    if (_looksLikeNetworkError(error)) {
      return 'Internet connection is unstable. Please check network and try again.';
    }
    if (error is FirebaseFunctionsException) {
      final code = error.code.trim();
      final message = (error.message ?? '').trim();
      final failureReason = FirestoreService.functionFailureReason(error);

      if (failureReason == 'app_check_failed' ||
          message == 'App Check token is required.') {
        return 'Chat is temporarily unavailable. Please try again later.';
      }

      switch (code) {
        case 'permission-denied':
          if (message == 'Listener blocked this speaker' ||
              message == 'Listener blocked you') {
            return 'This listener is not available for chat.';
          }
          return message.isNotEmpty
              ? message
              : 'You do not have permission to open this chat.';
        case 'failed-precondition':
          if (message == 'Speaker profile missing') {
            return 'Your account profile is not ready yet. Please try again.';
          }
          if (message == 'Listener profile missing') {
            return 'This listener profile is not ready yet.';
          }
          if (message == 'Speaker not available' ||
              message == 'Listener not available') {
            return 'This listener is currently not available.';
          }
          if (message == 'Speaker blocked this listener') {
            return 'You blocked this listener.';
          }
          return message.isNotEmpty
              ? message
              : 'Chat cannot be prepared right now.';
        case 'unauthenticated':
          return 'Please log in again.';
        case 'invalid-argument':
          return 'This chat request is invalid.';
        case 'not-found':
          return 'This listener could not be found.';
        case 'unavailable':
          return 'Chat service is temporarily unavailable. Please try again.';
        default:
          return message.isNotEmpty
              ? message
              : 'Could not open chat right now.';
      }
    }

    final raw = error.toString().trim();
    if (raw.isEmpty) return 'Could not open chat right now.';
    return 'Could not open chat right now.';
  }

  bool _looksLikeNetworkError(Object error) {
    if (error is FirebaseFunctionsException) {
      final code = error.code.trim().toLowerCase();
      final message = (error.message ?? '').trim().toLowerCase();
      if (code == 'unavailable' || code == 'deadline-exceeded') return true;
      return message.contains('unable to resolve host') ||
          message.contains('network') ||
          message.contains('socketexception') ||
          message.contains('internet');
    }

    final raw = error.toString().trim().toLowerCase();
    return raw.contains('unable to resolve host') ||
        raw.contains('network') ||
        raw.contains('socketexception') ||
        raw.contains('internet') ||
        raw.contains('host lookup');
  }

  String _formatCallStartErrorDebugDetails(Object error) {
    if (error is PlatformException) {
      return 'errorType=PlatformException '
          'platformCode=${error.code} '
          'messagePresent=${(error.message ?? '').trim().isNotEmpty} '
          'detailsPresent=${error.details != null}';
    }

    if (error is FirebaseException) {
      return 'errorType=${error.runtimeType} '
          'firebaseCode=${error.code} '
          'messagePresent=${(error.message ?? '').trim().isNotEmpty}';
    }

    return 'errorType=${error.runtimeType}';
  }

  String _callMessageForFailureReason(String reason) {
    switch (reason) {
      case 'insufficient_credits':
        return 'Add credits before starting a call.';
      case 'app_check_failed':
      case 'server_config_missing':
        return 'Calls are temporarily unavailable. Please try again later.';
      case 'self_only_chat_mode':
        return 'Only Chat Mode is ON. Turn it off from Home to request or receive calls.';
      case 'peer_only_chat_mode':
        return 'The other person is in Only Chat Mode.';
      case 'call_access_not_accepted':
        return 'This call is not approved yet. Open chat and wait for approval.';
      case 'caller_not_speaker':
      case 'listener_mismatch':
        return 'This call approval does not belong to this direction yet.';
      case 'active_call_exists':
      case 'caller_busy':
        return 'You already have an active call.';
      case 'peer_busy':
        return 'This person is on another call right now.';
      case 'wallet_reserve_failed':
        return 'Could not reserve credits for this call. Please try again.';
      case 'unknown_precondition':
        return 'Call cannot be started right now.';
      default:
        return '';
    }
  }

  String humanizeCallActionError(Object error) {
    if (error is FirebaseFunctionsException) {
      final code = error.code.trim();
      final message = (error.message ?? '').trim();
      final failureReason = FirestoreService.functionFailureReason(error);
      final failureText = _callMessageForFailureReason(failureReason);
      if (failureText.isNotEmpty) return failureText;

      if (message == 'App Check token is required.') {
        return 'Calls are temporarily unavailable. Please try again later.';
      }

      switch (code) {
        case 'resource-exhausted':
          return 'Too many call attempts. Please wait and try again.';
        case 'failed-precondition':
          if (message == 'SESSION_NOT_FOUND') {
            return 'Send a message first to start this chat.';
          }
          if (message == 'LEGACY_SESSION_MIGRATION_REQUIRED') {
            return 'This chat still needs migration cleanup before calling can start.';
          }
          if (message == 'REQUEST_NOT_APPROVED') {
            return 'This call is not approved yet. Open chat and wait for approval.';
          }
          if (message == 'CALL_NOT_ALLOWED_FOR_DIRECTION') {
            return 'This call approval does not belong to this direction yet.';
          }
          if (message == 'CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION') {
            return 'The current call approval belongs to the opposite direction. Send a new request from this side.';
          }
          if (message == 'Listener is busy') {
            return 'This person is on another call right now.';
          }
          if (message == 'Listener is offline right now') {
            return 'This person is offline right now.';
          }
          if (message == 'Call is not allowed for this chat yet.') {
            return 'This call is not approved yet. Open chat and wait for approval.';
          }
          if (message == 'Chat session missing. Open chat first.') {
            return 'Send a message first to start this chat.';
          }
          if (message == 'Listener blocked you' ||
              message == 'You blocked this listener') {
            return 'Calling is unavailable for this chat.';
          }
          if (message == 'You already have an active call') {
            return 'You already have an active call.';
          }
          return 'Call cannot be started right now.';
        case 'unauthenticated':
          return 'Please log in again.';
        case 'invalid-argument':
          return 'Invalid call request.';
        case 'not-found':
          return 'Listener not found.';
        case 'permission-denied':
          if (message == 'CHAT_PAIR_BLOCKED') {
            return 'Calling is unavailable for this chat.';
          }
          return 'You do not have permission to place this call.';
        default:
          return 'Could not start call.';
      }
    }

    final raw = error.toString().trim();
    if (raw.contains(AgoraClientConfig.developerRunCommandMessage)) {
      return UiCopy.callSetupNotReady;
    }
    if (raw.isEmpty) return 'Could not start call. Please try again.';
    return 'Could not start call. Please try again.';
  }

  DocumentReference<Map<String, dynamic>> callDoc(String callId) =>
      _calls.doc(callId.trim());

  String chatSessionIdForPair({
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (safeSpeakerId.isEmpty || safeListenerId.isEmpty) {
      return '';
    }
    if (safeSpeakerId == safeListenerId) {
      return '';
    }

    final ids = <String>[safeSpeakerId, safeListenerId]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  DocumentReference<Map<String, dynamic>> chatSessionDoc({
    required String speakerId,
    required String listenerId,
  }) {
    final id = chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
    return _chatSessions.doc(id);
  }

  bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return fallback;
  }

  int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    if (value == null) return fallback;
    return value.toString().trim();
  }

  bool _isSafeParticipant(CallModel call) {
    return call.callerId == myUid || call.calleeId == myUid;
  }

  bool _isMissedRejectedCall(CallModel call) {
    final endedReason = call.endedReason.trim().toLowerCase();
    final rejectedReason = call.rejectedReason.trim().toLowerCase();

    const missedReasons = <String>{
      FirestorePaths.reasonTimeout,
      FirestorePaths.reasonServerTimeout,
      'callee_timeout',
      'ring_timeout',
      'missed',
      'no_answer',
    };

    return missedReasons.contains(endedReason) ||
        missedReasons.contains(rejectedReason);
  }

  bool _isAcceptedLiveCall(CallModel call) {
    return call.status == FirestorePaths.statusAccepted && !call.isFinal;
  }

  bool _isRingingLiveCall(CallModel call) {
    return call.status == FirestorePaths.statusRinging && !call.isFinal;
  }

  int _safeRequestedEndSeconds(int seconds) {
    if (seconds < 0) return 0;
    return seconds;
  }

  bool _shouldClientUseNoChargePath({
    required CallModel call,
    required int seconds,
  }) {
    if (_isRingingLiveCall(call)) return true;
    if (seconds < 60) return true;
    return false;
  }

  Future<CallModel?> _getFreshCallOrNull(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return null;
    return getCall(safeCallId);
  }

  bool _isValidPairIds({
    required String speakerId,
    required String listenerId,
  }) {
    if (speakerId.trim().isEmpty || listenerId.trim().isEmpty) return false;
    if (speakerId.trim() == listenerId.trim()) return false;
    return true;
  }

  List<String> sessionParticipantIds(
    Map<String, dynamic> session, {
    String fallbackSpeakerId = '',
    String fallbackListenerId = '',
  }) {
    final seen = <String>{};
    final ids = <String>[];

    void addId(dynamic value) {
      final safe = _asString(value, fallback: '');
      if (safe.isEmpty || seen.contains(safe)) return;
      seen.add(safe);
      ids.add(safe);
    }

    final rawParticipantIds = session[FirestorePaths.fieldParticipantIds];
    if (rawParticipantIds is List) {
      for (final value in rawParticipantIds) {
        addId(value);
      }
    }

    if (ids.length != 2) {
      ids.clear();
      seen.clear();
      addId(session[FirestorePaths.fieldPairUserA]);
      addId(session[FirestorePaths.fieldPairUserB]);
      addId(session[FirestorePaths.fieldSpeakerId]);
      addId(session[FirestorePaths.fieldListenerId]);
      addId(fallbackSpeakerId);
      addId(fallbackListenerId);
    }

    ids.sort();
    if (ids.length == 2 && ids[0] != ids[1]) {
      return List<String>.unmodifiable(ids);
    }
    return const <String>[];
  }

  String sessionPairKey(
    Map<String, dynamic> session, {
    String fallbackSpeakerId = '',
    String fallbackListenerId = '',
  }) {
    final explicit = _asString(
      session[FirestorePaths.fieldPairKey],
      fallback: '',
    );
    if (explicit.isNotEmpty) return explicit;

    final ids = sessionParticipantIds(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
    );
    if (ids.length != 2) return '';
    return '${ids[0]}_${ids[1]}';
  }

  String actualListenerIdForSession(
    Map<String, dynamic> session, {
    required String fallbackSpeakerId,
    required String fallbackListenerId,
    ChatDirectionResolutionMode mode =
        ChatDirectionResolutionMode.strictStoredDirection,
  }) {
    final participants = sessionParticipantIds(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
    );
    if (participants.length != 2) {
      return '';
    }

    final requestedBy = _asString(
      session[FirestorePaths.fieldRequesterId],
      fallback: _asString(
        session[FirestorePaths.fieldCallRequestedBy],
        fallback: '',
      ),
    );
    final directCandidates = <String>[
      _asString(session[FirestorePaths.fieldResponderId], fallback: ''),
      _asString(session[FirestorePaths.fieldPendingFor], fallback: ''),
      _asString(session[FirestorePaths.fieldActualListenerId], fallback: ''),
    ];
    for (final candidate in directCandidates) {
      if (participants.contains(candidate) && candidate != requestedBy) {
        return candidate;
      }
    }

    if (mode != ChatDirectionResolutionMode.legacyRepair) {
      return '';
    }

    if (participants.contains(requestedBy)) {
      return participants.firstWhere((uid) => uid != requestedBy);
    }

    return '';
  }

  ChatSessionDirectionResolution resolveSessionDirectionForUser({
    required Map<String, dynamic> session,
    required String myUid,
    required String fallbackSpeakerId,
    required String fallbackListenerId,
    ChatDirectionResolutionMode mode =
        ChatDirectionResolutionMode.strictStoredDirection,
  }) {
    final safeMyUid = myUid.trim();
    final participants = sessionParticipantIds(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
    );

    if (participants.length != 2) {
      return const ChatSessionDirectionResolution.error(
        'participantIds are incomplete',
      );
    }

    if (!participants.contains(safeMyUid)) {
      return ChatSessionDirectionResolution.error(
        'current user $safeMyUid is not part of ${participants.join(',')}',
      );
    }

    final actualListenerId = actualListenerIdForSession(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
      mode: mode,
    );
    if (!participants.contains(actualListenerId)) {
      return const ChatSessionDirectionResolution.error(
        'actualListenerId is missing or unsafe',
      );
    }

    final actualSpeakerId = participants.firstWhere(
      (uid) => uid != actualListenerId,
      orElse: () => '',
    );
    if (actualSpeakerId.isEmpty || actualSpeakerId == actualListenerId) {
      return const ChatSessionDirectionResolution.error(
        'actual speaker could not be derived',
      );
    }

    final otherUid = participants.firstWhere(
      (uid) => uid != safeMyUid,
      orElse: () => '',
    );
    if (otherUid.isEmpty) {
      return const ChatSessionDirectionResolution.error(
        'other participant could not be derived',
      );
    }

    return ChatSessionDirectionResolution.success(
      participantIds: participants,
      actualSpeakerId: actualSpeakerId,
      actualListenerId: actualListenerId,
      otherUid: otherUid,
      iAmListener: safeMyUid == actualListenerId,
    );
  }

  String otherParticipantIdForSession(
    Map<String, dynamic> session, {
    required String myUid,
    required String fallbackSpeakerId,
    required String fallbackListenerId,
  }) {
    final safeMyUid = myUid.trim();
    final participants = sessionParticipantIds(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
    );
    if (participants.length != 2) {
      return safeMyUid == fallbackSpeakerId.trim()
          ? fallbackListenerId.trim()
          : fallbackSpeakerId.trim();
    }
    if (participants[0] == safeMyUid) return participants[1];
    if (participants[1] == safeMyUid) return participants[0];
    return participants[0];
  }

  bool _participantIdsExactlyMatchPair({
    required List<String> participantIds,
    required List<String> expectedIds,
  }) {
    if (participantIds.length != 2 || expectedIds.length != 2) {
      return false;
    }
    return listEquals(participantIds, expectedIds);
  }

  bool _chatSessionContractLooksComplete({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    final canonicalIds = <String>[safeSpeakerId, safeListenerId]..sort();
    if (canonicalIds.length != 2 || canonicalIds[0] == canonicalIds[1]) {
      return false;
    }

    final canonicalId = chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
    if (canonicalId.isEmpty) return false;

    final rawParticipantIds = session[FirestorePaths.fieldParticipantIds];
    if (rawParticipantIds is! List) return false;

    final explicitParticipants = <String>[];
    final seen = <String>{};
    for (final value in rawParticipantIds) {
      final safeValue = _asString(value, fallback: '');
      if (safeValue.isEmpty || seen.contains(safeValue)) continue;
      seen.add(safeValue);
      explicitParticipants.add(safeValue);
    }
    explicitParticipants.sort();

    if (!_participantIdsExactlyMatchPair(
      participantIds: explicitParticipants,
      expectedIds: canonicalIds,
    )) {
      return false;
    }

    if (_asString(session[FirestorePaths.fieldSpeakerId], fallback: '') !=
        canonicalIds[0]) {
      return false;
    }
    if (_asString(session[FirestorePaths.fieldListenerId], fallback: '') !=
        canonicalIds[1]) {
      return false;
    }
    if (_asString(session[FirestorePaths.fieldPairUserA], fallback: '') !=
        canonicalIds[0]) {
      return false;
    }
    if (_asString(session[FirestorePaths.fieldPairUserB], fallback: '') !=
        canonicalIds[1]) {
      return false;
    }
    if (_asString(session[FirestorePaths.fieldPairKey], fallback: '') !=
        canonicalId) {
      return false;
    }

    final explicitSessionId = _asString(
      session[FirestorePaths.fieldChatSessionId],
      fallback: '',
    );
    if (explicitSessionId.isNotEmpty && explicitSessionId != canonicalId) {
      return false;
    }

    return true;
  }

  bool _chatSessionDirectionLooksComplete({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    if (!_chatSessionContractLooksComplete(
      session: session,
      speakerId: speakerId,
      listenerId: listenerId,
    )) {
      return false;
    }

    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    final explicitParticipants = sessionParticipantIds(
      session,
      fallbackSpeakerId: safeSpeakerId,
      fallbackListenerId: safeListenerId,
    );
    if (explicitParticipants.length != 2) {
      return false;
    }

    final explicitActualListenerId = _asString(
      session[FirestorePaths.fieldActualListenerId],
      fallback: '',
    );
    if (!explicitParticipants.contains(explicitActualListenerId)) {
      return false;
    }

    final callRequestedBy = _asString(
      session[FirestorePaths.fieldCallRequestedBy],
      fallback: '',
    );
    final requesterId = _asString(
      session[FirestorePaths.fieldRequesterId],
      fallback: '',
    );
    final responderId = _asString(
      session[FirestorePaths.fieldResponderId],
      fallback: '',
    );
    final pendingFor = _asString(
      session[FirestorePaths.fieldPendingFor],
      fallback: '',
    );
    final actionOwner = _asString(
      session[FirestorePaths.fieldActionOwner],
      fallback: '',
    );
    final callRequestOpen = _asBool(
      session[FirestorePaths.fieldCallRequestOpen],
      fallback: false,
    );
    final callAllowed = _asBool(
      session[FirestorePaths.fieldCallAllowed],
      fallback: false,
    );

    final requestStateNeedsActors = callRequestOpen ||
        callAllowed ||
        callRequestedBy.isNotEmpty ||
        requesterId.isNotEmpty ||
        responderId.isNotEmpty ||
        pendingFor.isNotEmpty ||
        actionOwner.isNotEmpty;

    if (callRequestedBy.isNotEmpty &&
        !explicitParticipants.contains(callRequestedBy)) {
      return false;
    }

    if (requestStateNeedsActors) {
      if (!explicitParticipants.contains(requesterId)) {
        return false;
      }
      if (!explicitParticipants.contains(responderId)) {
        return false;
      }
      if (requesterId == responderId) {
        return false;
      }
      if (callRequestedBy.isNotEmpty && requesterId != callRequestedBy) {
        return false;
      }
    }

    if (pendingFor.isNotEmpty && !explicitParticipants.contains(pendingFor)) {
      return false;
    }
    if (actionOwner.isNotEmpty && !explicitParticipants.contains(actionOwner)) {
      return false;
    }
    if (callRequestOpen &&
        responderId.isNotEmpty &&
        pendingFor != responderId) {
      return false;
    }

    if (explicitActualListenerId != safeListenerId) {
      return false;
    }
    if (requesterId.isNotEmpty && requesterId != safeSpeakerId) {
      return false;
    }
    if (callRequestedBy.isNotEmpty && callRequestedBy != safeSpeakerId) {
      return false;
    }
    if (responderId.isNotEmpty && responderId != safeListenerId) {
      return false;
    }
    if (callRequestOpen &&
        pendingFor.isNotEmpty &&
        pendingFor != safeListenerId) {
      return false;
    }

    return true;
  }

  bool sessionIdentityLooksComplete({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    final fromMetadata = session[_sessionContractCompleteKey];
    if (fromMetadata is bool) return fromMetadata;
    return _chatSessionContractLooksComplete(
      session: session,
      speakerId: speakerId,
      listenerId: listenerId,
    );
  }

  bool sessionDirectionLooksComplete({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    final fromMetadata = session[_sessionDirectionCompleteKey];
    if (fromMetadata is bool) return fromMetadata;
    return _chatSessionDirectionLooksComplete(
      session: session,
      speakerId: speakerId,
      listenerId: listenerId,
    );
  }

  bool _sessionExists(Map<String, dynamic> session) {
    return session['exists'] == true;
  }

  bool _sessionIsBlocked(Map<String, dynamic> session) {
    return _asBool(session[FirestorePaths.fieldSpeakerBlocked],
            fallback: false) ||
        _asBool(session[FirestorePaths.fieldListenerBlocked], fallback: false);
  }

  String _directionalCallApprovalReason({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_sessionExists(session)) {
      return 'SESSION_NOT_FOUND';
    }

    if (_sessionIsBlocked(session)) {
      return 'CHAT_PAIR_BLOCKED';
    }

    if (!_chatSessionContractLooksComplete(
      session: session,
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return 'SESSION_CONTRACT_INCOMPLETE';
    }

    final explicitActualListenerId = _asString(
      session[FirestorePaths.fieldActualListenerId],
      fallback: '',
    );
    final callAllowed = _asBool(
      session[FirestorePaths.fieldCallAllowed],
      fallback: false,
    );
    final statusAccepted = _asString(
          session[FirestorePaths.fieldChatStatus],
          fallback: '',
        ) ==
        FirestorePaths.chatStatusAccepted;
    final accessApproved = callAllowed || statusAccepted;

    if (statusAccepted) {
      if (explicitActualListenerId != safeListenerId) {
        return 'CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION'
            '(actualListenerId=$explicitActualListenerId)';
      }
      return '';
    }

    if (!_chatSessionDirectionLooksComplete(
      session: session,
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return 'CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION';
    }

    final requesterId = _asString(
      session[FirestorePaths.fieldRequesterId],
      fallback: '',
    );
    final callRequestedBy = _asString(
      session[FirestorePaths.fieldCallRequestedBy],
      fallback: '',
    );
    final responderId = _asString(
      session[FirestorePaths.fieldResponderId],
      fallback: '',
    );
    final callRequestOpen = _asBool(
      session[FirestorePaths.fieldCallRequestOpen],
      fallback: false,
    );

    if (requesterId.isEmpty && callRequestedBy.isEmpty) {
      return accessApproved
          ? 'CALL_NOT_ALLOWED_FOR_DIRECTION(requesterId missing)'
          : 'REQUEST_NOT_APPROVED';
    }
    if (requesterId.isNotEmpty && requesterId != safeSpeakerId) {
      return 'CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION(requesterId=$requesterId)';
    }
    if (callRequestedBy.isNotEmpty && callRequestedBy != safeSpeakerId) {
      return 'CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION(callRequestedBy=$callRequestedBy)';
    }
    if (responderId.isNotEmpty && responderId != safeListenerId) {
      return 'CALL_APPROVAL_BELONGS_TO_OTHER_DIRECTION(responderId=$responderId)';
    }
    if (callRequestOpen && !accessApproved) {
      return 'REQUEST_NOT_APPROVED';
    }
    if (!accessApproved) {
      return 'CALL_NOT_ALLOWED_FOR_DIRECTION';
    }

    return '';
  }

  bool sessionAllowsCallForDirection({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    return _directionalCallApprovalReason(
      session: session,
      speakerId: speakerId,
      listenerId: listenerId,
    ).isEmpty;
  }

  bool sessionHasPendingRequestForDirection({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_sessionExists(session) || _sessionIsBlocked(session)) return false;
    if (!_asBool(session[FirestorePaths.fieldCallRequestOpen],
        fallback: false)) {
      return false;
    }

    return _chatSessionDirectionLooksComplete(
      session: session,
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );
  }

  Map<String, dynamic> _emptyChatSession({
    required String speakerId,
    required String listenerId,
  }) {
    final ids = <String>[speakerId.trim(), listenerId.trim()]..sort();
    final canonicalId = chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
    final safeActualListenerId = listenerId.trim();

    return <String, dynamic>{
      FirestorePaths.fieldChatSessionId: canonicalId,
      FirestorePaths.fieldSpeakerId: ids[0],
      FirestorePaths.fieldListenerId: ids[1],
      FirestorePaths.fieldPairUserA: ids[0],
      FirestorePaths.fieldPairUserB: ids[1],
      FirestorePaths.fieldParticipantIds: ids,
      FirestorePaths.fieldPairKey: canonicalId,
      FirestorePaths.fieldActualListenerId:
          ids.contains(safeActualListenerId) ? safeActualListenerId : '',
      FirestorePaths.fieldRequesterId: '',
      FirestorePaths.fieldResponderId: '',
      FirestorePaths.fieldPendingFor: '',
      FirestorePaths.fieldActionOwner: '',
      FirestorePaths.fieldChatStatus: FirestorePaths.chatStatusNone,
      FirestorePaths.fieldCallAllowed: false,
      FirestorePaths.fieldCallRequestedBy: '',
      FirestorePaths.fieldCallRequestOpen: false,
      FirestorePaths.fieldCallRequestAtMs: 0,
      FirestorePaths.fieldCallAllowedAtMs: 0,
      FirestorePaths.fieldSpeakerBlocked: false,
      FirestorePaths.fieldListenerBlocked: false,
      FirestorePaths.fieldLastMessageText: '',
      FirestorePaths.fieldLastMessageSenderId: '',
      FirestorePaths.fieldLastMessageType: '',
      FirestorePaths.fieldLastMessageAtMs: 0,
      FirestorePaths.fieldSpeakerUnreadCount: 0,
      FirestorePaths.fieldListenerUnreadCount: 0,
      FirestorePaths.fieldChatCreatedAtMs: 0,
      FirestorePaths.fieldChatUpdatedAtMs: 0,
      FirestorePaths.fieldChatArchived: false,
      'exists': false,
      'docId': canonicalId,
      'canonicalDocId': canonicalId,
      'canonicalSpeakerId': ids[0],
      'canonicalListenerId': ids[1],
      'normalized': true,
    };
  }

  Map<String, dynamic> _normalizeChatSessionPayload({
    required String requestedSpeakerId,
    required String requestedListenerId,
    required String docId,
    required Map<String, dynamic> data,
    required bool exists,
  }) {
    final ids = <String>[requestedSpeakerId.trim(), requestedListenerId.trim()]
      ..sort();
    final canonicalDocId = chatSessionIdForPair(
      speakerId: requestedSpeakerId,
      listenerId: requestedListenerId,
    );

    final merged = <String, dynamic>{
      ..._emptyChatSession(
        speakerId: requestedSpeakerId,
        listenerId: requestedListenerId,
      ),
      ...data,
      'exists': exists,
      'docId': docId,
      'canonicalDocId': canonicalDocId,
      'normalized': docId == canonicalDocId,
    };

    merged[FirestorePaths.fieldChatSessionId] = canonicalDocId;
    merged[FirestorePaths.fieldSpeakerId] = ids[0];
    merged[FirestorePaths.fieldListenerId] = ids[1];
    merged[FirestorePaths.fieldPairUserA] = ids[0];
    merged[FirestorePaths.fieldPairUserB] = ids[1];
    merged[FirestorePaths.fieldParticipantIds] = sessionParticipantIds(
      data,
      fallbackSpeakerId: requestedSpeakerId,
      fallbackListenerId: requestedListenerId,
    );
    merged[FirestorePaths.fieldPairKey] = sessionPairKey(
      data,
      fallbackSpeakerId: requestedSpeakerId,
      fallbackListenerId: requestedListenerId,
    );
    merged[FirestorePaths.fieldActualListenerId] = actualListenerIdForSession(
      data,
      fallbackSpeakerId: requestedSpeakerId,
      fallbackListenerId: requestedListenerId,
      mode: ChatDirectionResolutionMode.strictStoredDirection,
    );
    final requestedBy = _asString(
      data[FirestorePaths.fieldRequesterId],
      fallback: _asString(data[FirestorePaths.fieldCallRequestedBy]),
    );
    merged[FirestorePaths.fieldRequesterId] = requestedBy;
    merged[FirestorePaths.fieldResponderId] = _asString(
      data[FirestorePaths.fieldResponderId],
      fallback: '',
    );
    merged[FirestorePaths.fieldPendingFor] = _asString(
      data[FirestorePaths.fieldPendingFor],
      fallback: '',
    );
    merged[FirestorePaths.fieldActionOwner] = _asString(
      data[FirestorePaths.fieldActionOwner],
      fallback: '',
    );
    merged[FirestorePaths.fieldChatStatus] = exists
        ? _asString(
            data[FirestorePaths.fieldChatStatus],
            fallback: _asString(
              merged[FirestorePaths.fieldChatStatus],
              fallback: FirestorePaths.chatStatusPending,
            ),
          )
        : FirestorePaths.chatStatusNone;
    merged[FirestorePaths.fieldCallAllowed] = exists
        ? _asBool(
            data[FirestorePaths.fieldCallAllowed],
            fallback: false,
          )
        : false;
    merged[FirestorePaths.fieldCallRequestOpen] = exists
        ? _asBool(
            data[FirestorePaths.fieldCallRequestOpen],
            fallback: false,
          )
        : false;
    merged[FirestorePaths.fieldSpeakerBlocked] = exists
        ? _asBool(
            data[FirestorePaths.fieldSpeakerBlocked],
            fallback: false,
          )
        : false;
    merged[FirestorePaths.fieldListenerBlocked] = exists
        ? _asBool(
            data[FirestorePaths.fieldListenerBlocked],
            fallback: false,
          )
        : false;
    merged[FirestorePaths.fieldCallRequestedBy] = exists
        ? _asString(
            data[FirestorePaths.fieldCallRequestedBy],
            fallback: '',
          )
        : '';
    merged[FirestorePaths.fieldLastMessageText] = exists
        ? _asString(
            data[FirestorePaths.fieldLastMessageText],
            fallback: '',
          )
        : '';
    merged[FirestorePaths.fieldLastMessageSenderId] = exists
        ? _asString(
            data[FirestorePaths.fieldLastMessageSenderId],
            fallback: '',
          )
        : '';
    merged[FirestorePaths.fieldLastMessageType] = exists
        ? _asString(
            data[FirestorePaths.fieldLastMessageType],
            fallback: '',
          )
        : '';
    merged[FirestorePaths.fieldCallRequestAtMs] = exists
        ? _asInt(
            data[FirestorePaths.fieldCallRequestAtMs],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldCallAllowedAtMs] = exists
        ? _asInt(
            data[FirestorePaths.fieldCallAllowedAtMs],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldLastMessageAtMs] = exists
        ? _asInt(
            data[FirestorePaths.fieldLastMessageAtMs],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldSpeakerUnreadCount] = exists
        ? _asInt(
            data[FirestorePaths.fieldSpeakerUnreadCount],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldListenerUnreadCount] = exists
        ? _asInt(
            data[FirestorePaths.fieldListenerUnreadCount],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldChatCreatedAtMs] = exists
        ? _asInt(
            data[FirestorePaths.fieldChatCreatedAtMs],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldChatUpdatedAtMs] = exists
        ? _asInt(
            data[FirestorePaths.fieldChatUpdatedAtMs],
            fallback: 0,
          )
        : 0;
    merged[FirestorePaths.fieldChatArchived] = exists
        ? _asBool(
            data[FirestorePaths.fieldChatArchived],
            fallback: false,
          )
        : false;
    merged['canonicalSpeakerId'] = ids[0];
    merged['canonicalListenerId'] = ids[1];

    return merged;
  }

  @visibleForTesting
  Map<String, dynamic> debugNormalizeChatSessionPayload({
    required String requestedSpeakerId,
    required String requestedListenerId,
    required String docId,
    required Map<String, dynamic> data,
    required bool exists,
  }) {
    return _annotateNormalizedChatSessionPayload(
      normalized: _normalizeChatSessionPayload(
        requestedSpeakerId: requestedSpeakerId,
        requestedListenerId: requestedListenerId,
        docId: docId,
        data: data,
        exists: exists,
      ),
      rawSession: data,
      speakerId: requestedSpeakerId,
      listenerId: requestedListenerId,
    );
  }

  Map<String, dynamic> _annotateNormalizedChatSessionPayload({
    required Map<String, dynamic> normalized,
    required Map<String, dynamic> rawSession,
    required String speakerId,
    required String listenerId,
  }) {
    return <String, dynamic>{
      ...normalized,
      _sessionContractCompleteKey: _chatSessionContractLooksComplete(
        session: rawSession,
        speakerId: speakerId,
        listenerId: listenerId,
      ),
      _sessionDirectionCompleteKey: _chatSessionDirectionLooksComplete(
        session: rawSession,
        speakerId: speakerId,
        listenerId: listenerId,
      ),
    };
  }

  Future<Map<String, dynamic>> _normalizeChatSessionPayloadWithRepair({
    required String speakerId,
    required String listenerId,
    required String docId,
    required Map<String, dynamic> data,
    required bool exists,
  }) async {
    if (!exists) {
      return _emptyChatSession(
        speakerId: speakerId,
        listenerId: listenerId,
      );
    }

    var currentData = Map<String, dynamic>.from(data);
    if (!_chatSessionContractLooksComplete(
      session: currentData,
      speakerId: speakerId,
      listenerId: listenerId,
    )) {
      try {
        await ensureChatSessionByPair(
          speakerId: speakerId,
          listenerId: listenerId,
        );

        final repairedSnap = await _chatSessions.doc(docId).get();
        if (repairedSnap.exists) {
          currentData = Map<String, dynamic>.from(
            repairedSnap.data() ?? <String, dynamic>{},
          );
        }
      } catch (_) {
        // Keep the current payload so the UI can still use normalized fallbacks.
      }
    }

    return _annotateNormalizedChatSessionPayload(
      normalized: _normalizeChatSessionPayload(
        requestedSpeakerId: speakerId,
        requestedListenerId: listenerId,
        docId: docId,
        data: currentData,
        exists: true,
      ),
      rawSession: currentData,
      speakerId: speakerId,
      listenerId: listenerId,
    );
  }

  Stream<CallModel?> watchCall(String callId) {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) {
      return Stream<CallModel?>.value(null);
    }

    return callDoc(safeCallId).snapshots().map((snap) {
      if (!snap.exists) return null;
      return CallModel.fromMap(
        snap.id,
        snap.data() ?? <String, dynamic>{},
      );
    });
  }

  Future<CallModel?> getCall(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return null;

    final snap = await callDoc(safeCallId).get();
    if (!snap.exists) return null;

    return CallModel.fromMap(
      snap.id,
      snap.data() ?? <String, dynamic>{},
    );
  }

  Future<CallStartResult?> createCallToListener({
    required String listenerId,
  }) async {
    final safeListener = listenerId.trim();
    if (safeListener.isEmpty) return null;
    if (hasBlockingCallState) {
      debugPrint(
        'createCallToListener blocked by local call session state for '
        'listener=${AppLog.safeId(safeListener)}',
      );
      return null;
    }

    if (AgoraClientConfig.resolvedAppId.isEmpty) {
      throw StateError(AgoraClientConfig.developerRunCommandMessage);
    }

    try {
      return await FirestoreService.createCallToListener(
        listenerId: safeListener,
      );
    } on FirebaseFunctionsException catch (e) {
      final failureReason = FirestoreService.functionFailureReason(e);
      debugPrint(
        'createCallToListener functions failure: '
        'code=${e.code} '
        'failureReason=${failureReason.isEmpty ? 'unknown' : failureReason}',
      );
      rethrow;
    } catch (e) {
      debugPrint(
        'createCallToListener unexpected failure: '
        '${_formatCallStartErrorDebugDetails(e)}',
      );
      rethrow;
    }
  }

  Future<CallAcceptResult?> acceptCallById(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return null;
    if (hasBlockingCallState) return null;
    if (_acceptingCallIds.contains(safeCallId)) return null;

    if (AgoraClientConfig.resolvedAppId.isEmpty) {
      throw StateError(AgoraClientConfig.developerRunCommandMessage);
    }

    _acceptingCallIds.add(safeCallId);
    try {
      return await FirestoreService.acceptCallById(safeCallId);
    } finally {
      _acceptingCallIds.remove(safeCallId);
    }
  }

  Future<void> rejectCallById(
    String callId, {
    String? rejectedReason,
  }) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_rejectingCallIds.contains(safeCallId)) return;

    _rejectingCallIds.add(safeCallId);
    try {
      final call = await _getFreshCallOrNull(safeCallId);
      if (call == null) return;
      if (!_isSafeParticipant(call)) return;
      if (call.isFinal) return;

      if (_isRingingLiveCall(call)) {
        await FirestoreService.rejectCall(
          callDoc(safeCallId),
          rejectedReason:
              rejectedReason ?? FirestorePaths.reasonCalleeRejectCallkit,
        );
        return;
      }

      await FirestoreService.endCallNoCharge(
        callRef: callDoc(safeCallId),
        reason: rejectedReason ?? FirestorePaths.reasonCalleeRejectCallkit,
      );
    } finally {
      _rejectingCallIds.remove(safeCallId);
    }
  }

  Future<void> cancelOutgoingCallById(
    String callId, {
    String reason = 'caller_cancelled',
  }) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_cancelingCallIds.contains(safeCallId)) return;

    _cancelingCallIds.add(safeCallId);
    try {
      final call = await _getFreshCallOrNull(safeCallId);
      if (call == null) return;
      if (!_isSafeParticipant(call)) return;
      if (call.isFinal) return;
      if (!_isRingingLiveCall(call)) return;
      if (!amICaller(call)) return;

      await FirestoreService.cancelOutgoingCall(
        callRef: callDoc(safeCallId),
        reason: reason,
      );
    } finally {
      _cancelingCallIds.remove(safeCallId);
    }
  }

  Future<void> requestEndById({
    required String callId,
    required int seconds,
    String? reason,
  }) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_endingCallIds.contains(safeCallId)) return;

    _endingCallIds.add(safeCallId);
    try {
      final call = await _getFreshCallOrNull(safeCallId);
      if (call == null) return;
      if (!_isSafeParticipant(call)) return;
      if (call.isFinal) return;

      final safeSeconds = _safeRequestedEndSeconds(seconds);

      if (_isRingingLiveCall(call)) {
        if (amICaller(call)) {
          await FirestoreService.cancelOutgoingCall(
            callRef: callDoc(safeCallId),
            reason: reason ?? 'caller_cancelled',
          );
        } else {
          await FirestoreService.rejectCall(
            callDoc(safeCallId),
            rejectedReason: reason ?? FirestorePaths.reasonCalleeRejectCallkit,
          );
        }
        return;
      }

      if (!_isAcceptedLiveCall(call)) return;

      if (_shouldClientUseNoChargePath(
        call: call,
        seconds: safeSeconds,
      )) {
        await FirestoreService.endCallNoCharge(
          callRef: callDoc(safeCallId),
          reason: reason ?? 'ended_by_user',
        );
        return;
      }

      await FirestoreService.endCallWithBilling(
        callRef: callDoc(safeCallId),
        seconds: safeSeconds,
        reason: reason,
      );
    } finally {
      _endingCallIds.remove(safeCallId);
    }
  }

  Future<void> endCallWithBillingById({
    required String callId,
    required int seconds,
    String? reason,
  }) {
    return requestEndById(
      callId: callId,
      seconds: seconds,
      reason: reason,
    );
  }

  Future<void> endCallNoChargeById({
    required String callId,
    required String reason,
  }) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (_endingCallIds.contains(safeCallId)) return;

    _endingCallIds.add(safeCallId);
    try {
      final call = await _getFreshCallOrNull(safeCallId);
      if (call == null) return;
      if (!_isSafeParticipant(call)) return;
      if (call.isFinal) return;

      if (_isRingingLiveCall(call)) {
        if (amICaller(call)) {
          await FirestoreService.cancelOutgoingCall(
            callRef: callDoc(safeCallId),
            reason: reason,
          );
        } else {
          await FirestoreService.rejectCall(
            callDoc(safeCallId),
            rejectedReason: reason,
          );
        }
        return;
      }

      if (!_isAcceptedLiveCall(call)) return;

      await FirestoreService.endCallNoCharge(
        callRef: callDoc(safeCallId),
        reason: reason,
      );
    } finally {
      _endingCallIds.remove(safeCallId);
    }
  }

  Future<void> cleanupMyStaleCalls() {
    return FirestoreService.cleanupMyStaleCalls();
  }

  Stream<List<CallModel>> watchMyIncomingCalls({
    int limit = 50,
  }) {
    final safeLimit = limit < 1 ? 1 : limit;

    return _calls
        .where(FirestorePaths.fieldCalleeId, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(safeLimit)
        .snapshots()
        .map(
          (query) => query.docs
              .map((doc) => CallModel.fromMap(doc.id, doc.data()))
              .toList(),
        );
  }

  Stream<List<CallModel>> watchMyOutgoingCalls({
    int limit = 50,
  }) {
    final safeLimit = limit < 1 ? 1 : limit;

    return _calls
        .where(FirestorePaths.fieldCallerId, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(safeLimit)
        .snapshots()
        .map(
          (query) => query.docs
              .map((doc) => CallModel.fromMap(doc.id, doc.data()))
              .toList(),
        );
  }

  Stream<List<CallModel>> watchAllLiveCalls({
    int limit = 200,
  }) {
    final safeLimit = limit < 1 ? 1 : limit;

    return _calls
        .where(
          FirestorePaths.fieldStatus,
          whereIn: const <String>[
            FirestorePaths.statusRinging,
            FirestorePaths.statusAccepted,
          ],
        )
        .limit(safeLimit)
        .snapshots()
        .map(
          (query) => query.docs
              .map((doc) => CallModel.fromMap(doc.id, doc.data()))
              .toList(),
        );
  }

  Stream<Map<String, dynamic>> watchChatSessionForListener(String listenerId) {
    final safeListenerId = listenerId.trim();
    final speakerId = myUid;

    if (!_isValidPairIds(
      speakerId: speakerId,
      listenerId: safeListenerId,
    )) {
      return Stream<Map<String, dynamic>>.value(
        _emptyChatSession(
          speakerId: speakerId,
          listenerId: safeListenerId,
        ),
      );
    }

    return watchChatSessionByPair(
      speakerId: speakerId,
      listenerId: safeListenerId,
    );
  }

  Stream<List<Map<String, dynamic>>> watchCurrentUserChatSessions({
    int limit = 100,
  }) {
    final currentUid = myUid;
    if (currentUid.isEmpty) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    final safeLimit = limit.clamp(1, 200).toInt();
    return _chatSessions
        .where(FirestorePaths.fieldParticipantIds, arrayContains: currentUid)
        .orderBy(FirestorePaths.fieldChatUpdatedAtMs, descending: true)
        .limit(safeLimit)
        .snapshots()
        .map((query) {
      return query.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        final speakerId = _asString(data[FirestorePaths.fieldSpeakerId]);
        final listenerId = _asString(data[FirestorePaths.fieldListenerId]);
        final normalized = speakerId.isNotEmpty && listenerId.isNotEmpty
            ? _normalizeChatSessionPayload(
                requestedSpeakerId: speakerId,
                requestedListenerId: listenerId,
                docId: doc.id,
                data: data,
                exists: true,
              )
            : <String, dynamic>{
                ...data,
                'exists': true,
                'docId': doc.id,
              };

        return normalized;
      }).toList(growable: false);
    });
  }

  Stream<Map<String, dynamic>> watchChatSessionByPair({
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (safeSpeakerId.isEmpty || safeListenerId.isEmpty) {
      return Stream<Map<String, dynamic>>.value(
        _emptyChatSession(
          speakerId: safeSpeakerId,
          listenerId: safeListenerId,
        ),
      );
    }

    final canonicalRef = chatSessionDoc(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );

    return canonicalRef.snapshots().asyncMap((snap) async {
      if (!snap.exists) {
        return _emptyChatSession(
          speakerId: safeSpeakerId,
          listenerId: safeListenerId,
        );
      }

      return _normalizeChatSessionPayloadWithRepair(
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
        docId: canonicalRef.id,
        data: snap.data() ?? <String, dynamic>{},
        exists: true,
      );
    });
  }

  Future<Map<String, dynamic>> getChatSessionByPair({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (safeSpeakerId.isEmpty || safeListenerId.isEmpty) {
      return _emptyChatSession(
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
      );
    }

    final canonicalRef = chatSessionDoc(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );

    final snap = await canonicalRef.get();
    if (!snap.exists) {
      return _emptyChatSession(
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
      );
    }

    return _normalizeChatSessionPayloadWithRepair(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
      docId: canonicalRef.id,
      data: snap.data() ?? <String, dynamic>{},
      exists: true,
    );
  }

  Future<ChatSessionDirectionResolution>
      resolveStoredChatDirectionForCurrentUser({
    required String speakerId,
    required String listenerId,
    ChatDirectionResolutionMode mode =
        ChatDirectionResolutionMode.strictStoredDirection,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    final currentUid = myUid;

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return const ChatSessionDirectionResolution.error(
        'speaker/listener pair is invalid',
      );
    }

    if (currentUid.isEmpty) {
      return const ChatSessionDirectionResolution.error(
        'current user is not signed in',
      );
    }

    final session = await getChatSessionByPair(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );
    if (session['exists'] != true) {
      return const ChatSessionDirectionResolution.error(
        'chat session not found',
      );
    }

    return resolveSessionDirectionForUser(
      session: session,
      myUid: currentUid,
      fallbackSpeakerId: safeSpeakerId,
      fallbackListenerId: safeListenerId,
      mode: mode,
    );
  }

  Future<Map<String, dynamic>> _ensureChatSessionViaCallable({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return <String, dynamic>{};
    }

    final result = await _callable('ensureChatSession_v1').call(
      <String, dynamic>{
        'speakerId': safeSpeakerId,
        'listenerId': safeListenerId,
      },
    );

    final data = result.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }

  Future<String> ensureChatSessionWithListener(String listenerId) async {
    final safeListenerId = listenerId.trim();
    final speakerId = myUid;

    if (!_isValidPairIds(
      speakerId: speakerId,
      listenerId: safeListenerId,
    )) {
      return '';
    }

    return ensureChatSessionByPair(
      speakerId: speakerId,
      listenerId: safeListenerId,
    );
  }

  Future<String> ensureChatSessionByPair({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    final currentUid = myUid;

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return '';
    }

    if (currentUid.isEmpty) return '';
    if (currentUid != safeSpeakerId && currentUid != safeListenerId) {
      return '';
    }

    final cacheKey = '$safeSpeakerId::$safeListenerId';
    final pending = _pendingChatSessionEnsures[cacheKey];
    if (pending != null) {
      return pending;
    }

    final canonicalId = chatSessionIdForPair(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );
    if (canonicalId.isEmpty) return '';

    Future<String> resolveFallbackId() async {
      final snap = await _chatSessions.doc(canonicalId).get();
      if (!snap.exists) return '';

      final looksComplete = _chatSessionContractLooksComplete(
        session: snap.data() ?? <String, dynamic>{},
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
      );
      if (looksComplete) {
        _recentlyEnsuredChatSessionsMs[canonicalId] =
            DateTime.now().millisecondsSinceEpoch;
      }
      return looksComplete ? canonicalId : '';
    }

    final ensuredAtMs = _recentlyEnsuredChatSessionsMs[canonicalId] ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (ensuredAtMs > 0 && nowMs - ensuredAtMs <= _chatSessionEnsureTtlMs) {
      return canonicalId;
    }

    final existingSnap = await _chatSessions.doc(canonicalId).get();
    final existingLooksComplete = existingSnap.exists &&
        _chatSessionContractLooksComplete(
          session: existingSnap.data() ?? <String, dynamic>{},
          speakerId: safeSpeakerId,
          listenerId: safeListenerId,
        );
    if (existingLooksComplete) {
      _recentlyEnsuredChatSessionsMs[canonicalId] = nowMs;
      return canonicalId;
    }

    final future = () async {
      try {
        await _ensureChatSessionViaCallable(
          speakerId: safeSpeakerId,
          listenerId: safeListenerId,
        );

        final fallbackId = await resolveFallbackId();
        if (fallbackId.isNotEmpty) {
          return fallbackId;
        }

        throw StateError(
          'Canonical chat session contract is incomplete after ensure '
          'for $canonicalId.',
        );
      } catch (_) {
        final fallbackId = await resolveFallbackId();
        if (fallbackId.isNotEmpty) {
          return fallbackId;
        }
        rethrow;
      }
    }();

    _pendingChatSessionEnsures[cacheKey] = future;

    try {
      return await future;
    } finally {
      _pendingChatSessionEnsures.remove(cacheKey);
    }
  }

  Future<bool> canCurrentUserCallListener({
    required String listenerId,
  }) async {
    final safeListenerId = listenerId.trim();
    final speakerId = myUid;

    if (safeListenerId.isEmpty || speakerId.isEmpty) return false;
    if (safeListenerId == speakerId) return false;
    if (hasBlockingCallState) return false;

    final session = await getChatSessionByPair(
      speakerId: speakerId,
      listenerId: safeListenerId,
    );

    final exists = session['exists'] == true;
    final callAllowed = _asBool(
      session[FirestorePaths.fieldCallAllowed],
      fallback: false,
    );
    final listenerBlocked =
        _asBool(session[FirestorePaths.fieldListenerBlocked]);
    final speakerBlocked = _asBool(session[FirestorePaths.fieldSpeakerBlocked]);
    final callRequestOpen =
        _asBool(session[FirestorePaths.fieldCallRequestOpen]);
    final status = _asString(
      session[FirestorePaths.fieldChatStatus],
      fallback: FirestorePaths.chatStatusNone,
    );
    final accessApproved =
        callAllowed || status == FirestorePaths.chatStatusAccepted;

    debugPrint(
      'canCurrentUserCallListener '
      'listenerPresent=${safeListenerId.isNotEmpty} '
      'exists=$exists '
      'status=$status '
      'callAllowed=$callAllowed '
      'callRequestOpen=$callRequestOpen '
      'speakerBlocked=$speakerBlocked '
      'listenerBlocked=$listenerBlocked',
    );

    final requestedBy = _asString(
      session[FirestorePaths.fieldCallRequestedBy],
      fallback: '',
    );
    final directionReason = _directionalCallApprovalReason(
      session: session,
      speakerId: speakerId,
      listenerId: safeListenerId,
    );

    if (!exists) return false;
    if (listenerBlocked || speakerBlocked) return false;
    if (!accessApproved) {
      debugPrint(
        'canCurrentUserCallListener denied reason='
        '${callRequestOpen ? 'REQUEST_NOT_APPROVED' : 'CALL_NOT_ALLOWED_FOR_DIRECTION'} '
        'requestedByPresent=${requestedBy.isNotEmpty} '
        'speakerPresent=${speakerId.isNotEmpty}',
      );
      return false;
    }
    if (directionReason.isNotEmpty) {
      debugPrint(
        'canCurrentUserCallListener denied reason=$directionReason '
        'requestedByPresent=${requestedBy.isNotEmpty} '
        'speakerPresent=${speakerId.isNotEmpty} '
        'listenerPresent=${safeListenerId.isNotEmpty}',
      );
      return false;
    }

    debugPrint(
      'canCurrentUserCallListener allowedForSpeaker='
      '${requestedBy == speakerId || requestedBy.isEmpty} '
      'requestedByPresent=${requestedBy.isNotEmpty} '
      'speakerPresent=${speakerId.isNotEmpty} '
      'statusAccepted=${status == FirestorePaths.chatStatusAccepted}',
    );

    return true;
  }

  HttpsCallable _callable(String name) {
    return _functions.httpsCallable(name);
  }

  Future<Map<String, dynamic>> _invokeChatActionCallable({
    required String name,
    required Map<String, dynamic> payload,
  }) async {
    final result = await _callable(name).call(payload);
    final data = result.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }

  Future<CallPermissionRequestResult> requestCallPermissionFromListener({
    required String listenerId,
  }) async {
    final safeListenerId = listenerId.trim();
    final speakerId = myUid;

    if (speakerId.isEmpty ||
        safeListenerId.isEmpty ||
        speakerId == safeListenerId) {
      return CallPermissionRequestResult.invalidTarget;
    }

    await ensureChatSessionByPair(
      speakerId: speakerId,
      listenerId: safeListenerId,
    );

    final currentSession = await getChatSessionByPair(
      speakerId: speakerId,
      listenerId: safeListenerId,
    );

    final speakerBlocked = _asBool(
      currentSession[FirestorePaths.fieldSpeakerBlocked],
      fallback: false,
    );
    final listenerBlocked = _asBool(
      currentSession[FirestorePaths.fieldListenerBlocked],
      fallback: false,
    );
    if (speakerBlocked || listenerBlocked) {
      return CallPermissionRequestResult.blocked;
    }

    final callAllowedForDirection = sessionAllowsCallForDirection(
      session: currentSession,
      speakerId: speakerId,
      listenerId: safeListenerId,
    );
    if (callAllowedForDirection) {
      debugPrint(
        'requestCallPermissionFromListener skipped because call is already allowed',
      );
      return CallPermissionRequestResult.alreadyAllowed;
    }

    final alreadyPendingForDirection = sessionHasPendingRequestForDirection(
      session: currentSession,
      speakerId: speakerId,
      listenerId: safeListenerId,
    );
    if (alreadyPendingForDirection) {
      debugPrint(
        'requestCallPermissionFromListener skipped because request is already open',
      );
      return CallPermissionRequestResult.alreadyPending;
    }

    await _invokeChatActionCallable(
      name: 'speakerRequestChatAccess_v1',
      payload: <String, dynamic>{
        'listenerId': safeListenerId,
      },
    );
    return CallPermissionRequestResult.sent;
  }

  Future<void> markListenerAllowedChatOnly({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return;
    }

    await _ensureSessionIfMissing(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );

    await _invokeChatActionCallable(
      name: 'listenerRespondToChatRequest_v1',
      payload: <String, dynamic>{
        'speakerId': safeSpeakerId,
        'action': 'allow_chat_only',
      },
    );
  }

  Future<void> markListenerAllowedCall({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return;
    }

    await _ensureSessionIfMissing(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );

    await _invokeChatActionCallable(
      name: 'listenerRespondToChatRequest_v1',
      payload: <String, dynamic>{
        'speakerId': safeSpeakerId,
        'action': 'allow_call',
      },
    );
  }

  Future<void> markListenerDeniedCall({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return;
    }

    await _ensureSessionIfMissing(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );

    await _invokeChatActionCallable(
      name: 'listenerRespondToChatRequest_v1',
      payload: <String, dynamic>{
        'speakerId': safeSpeakerId,
        'action': 'deny_call',
      },
    );
  }

  Future<void> blockChatPair({
    required String speakerId,
    required String listenerId,
    required bool blockedByListener,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (!_isValidPairIds(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    )) {
      return;
    }

    if (!blockedByListener) {
      throw UnsupportedError(
        'Only listener-side pair blocking is supported by the backend flow.',
      );
    }

    await _ensureSessionIfMissing(
      speakerId: safeSpeakerId,
      listenerId: safeListenerId,
    );

    await _invokeChatActionCallable(
      name: 'listenerRespondToChatRequest_v1',
      payload: <String, dynamic>{
        'speakerId': safeSpeakerId,
        'action': 'block_pair',
      },
    );
  }

  bool isCallFinal(CallModel call) => call.isFinal;

  bool isCallLive(CallModel call) => call.isLiveCall;

  Future<void> _ensureSessionIfMissing({
    required String speakerId,
    required String listenerId,
  }) async {
    final session = await getChatSessionByPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
    if (session['exists'] == true) return;

    await ensureChatSessionByPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
  }

  bool amICaller(CallModel call) => call.callerId == myUid;

  bool amICallee(CallModel call) => call.calleeId == myUid;

  String otherPartyId(CallModel call) {
    if (amICaller(call)) return call.calleeId;
    return call.callerId;
  }

  Stream<List<CallModel>> watchMissedCalls({int limit = 20}) {
    final safeLimit = limit < 1 ? 1 : limit;
    final uid = myUid.trim();
    if (uid.isEmpty) return Stream.value(const <CallModel>[]);

    return _calls
        .where(FirestorePaths.fieldCalleeId, isEqualTo: uid)
        .where(
          FirestorePaths.fieldStatus,
          isEqualTo: FirestorePaths.statusRejected,
        )
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(safeLimit * 3)
        .snapshots()
        .map(
          (query) => query.docs
              .map((doc) => CallModel.fromMap(doc.id, doc.data()))
              .where(_isSafeParticipant)
              .where(_isMissedRejectedCall)
              .take(safeLimit)
              .toList(),
        );
  }

  Future<List<CallModel>> fetchRecentCalls({int limit = 50}) async {
    final safeLimit = limit < 1 ? 1 : limit;

    final incoming = await _calls
        .where(FirestorePaths.fieldCalleeId, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(safeLimit)
        .get();

    final outgoing = await _calls
        .where(FirestorePaths.fieldCallerId, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(safeLimit)
        .get();

    final all = <String, CallModel>{};

    for (final doc in incoming.docs) {
      all[doc.id] = CallModel.fromMap(doc.id, doc.data());
    }
    for (final doc in outgoing.docs) {
      all[doc.id] = CallModel.fromMap(doc.id, doc.data());
    }

    final list = all.values.toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));

    return list.take(safeLimit).toList();
  }
}
