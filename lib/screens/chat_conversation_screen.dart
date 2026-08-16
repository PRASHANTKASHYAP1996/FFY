import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants/agora_client_config.dart';
import '../core/constants/firestore_paths.dart';
import '../core/constants/ui_copy.dart';
import '../core/theme/app_palette.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/app_log.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../shared/chat_direction_resolver.dart';
import '../shared/chat_navigation_guards.dart';
import '../shared/listener_availability.dart';
import '../shared/models/app_user_model.dart';
import '../shared/user_safety_actions.dart';
import 'caller_waiting_screen.dart';
import 'redesign/call_setup_screen.dart';
import 'crisis_help_screen.dart';

const String _chatBootstrapMismatchMessage =
    'This conversation already exists from the other side of the connection. '
    'Open the existing conversation or go back.';
const bool _verboseChatDebugLogs = bool.fromEnvironment(
  'FRIENDIFY_VERBOSE_CALL_LOGS',
  defaultValue: false,
);

enum ChatBootstrapDirectionDecisionKind {
  ready,
  mismatch,
  needsRepair,
}

enum _CallRequestUiState {
  none,
  pendingByMe,
  pendingForMe,
  acceptedSpeaker,
  acceptedListener,
  acceptedSpeakerPaused,
  acceptedListenerPaused,
  syncingAccepted,
  selfOnlyChatMode,
  peerOnlyChatMode,
  blockedOrUnavailable,
  loading,
  error,
}

class ChatBootstrapDirectionDecision {
  const ChatBootstrapDirectionDecision._({
    required this.kind,
    required this.resolution,
    required this.message,
  });

  const ChatBootstrapDirectionDecision.ready()
      : this._(
          kind: ChatBootstrapDirectionDecisionKind.ready,
          resolution: null,
          message: '',
        );

  const ChatBootstrapDirectionDecision.mismatch({
    required ChatSessionDirectionResolution resolution,
    required String message,
  }) : this._(
          kind: ChatBootstrapDirectionDecisionKind.mismatch,
          resolution: resolution,
          message: message,
        );

  const ChatBootstrapDirectionDecision.needsRepair({required String message})
      : this._(
          kind: ChatBootstrapDirectionDecisionKind.needsRepair,
          resolution: null,
          message: message,
        );

  final ChatBootstrapDirectionDecisionKind kind;
  final ChatSessionDirectionResolution? resolution;
  final String message;

  bool get handledInUi => kind != ChatBootstrapDirectionDecisionKind.ready;
}

@visibleForTesting
ChatBootstrapDirectionDecision decideChatBootstrapDirection({
  required ChatSessionDirectionResolution strictResolution,
  required ChatSessionDirectionResolution legacyResolution,
  required String requestedSpeakerId,
  required String requestedProductListenerId,
}) {
  bool matchesRequested(ChatSessionDirectionResolution resolution) {
    return resolution.actualSpeakerId == requestedSpeakerId &&
        resolution.actualListenerId == requestedProductListenerId;
  }

  if (!strictResolution.isResolved) {
    if (!legacyResolution.isResolved) {
      return const ChatBootstrapDirectionDecision.needsRepair(
        message: 'This conversation needs repair.',
      );
    }
    if (!matchesRequested(legacyResolution)) {
      return ChatBootstrapDirectionDecision.mismatch(
        resolution: legacyResolution,
        message: _chatBootstrapMismatchMessage,
      );
    }
    return const ChatBootstrapDirectionDecision.needsRepair(
      message: 'This conversation needs repair.',
    );
  }

  if (!matchesRequested(strictResolution)) {
    return ChatBootstrapDirectionDecision.mismatch(
      resolution: strictResolution,
      message: _chatBootstrapMismatchMessage,
    );
  }

  return const ChatBootstrapDirectionDecision.ready();
}

@visibleForTesting
class ChatComposerVisibilityGate extends StatefulWidget {
  const ChatComposerVisibilityGate({
    super.key,
    required this.bootstrapping,
    required this.hasBootstrapError,
    required this.navigatingAway,
    required this.child,
    this.hiddenChild = const SizedBox.shrink(),
    this.onVisibilityChanged,
  });

  final bool bootstrapping;
  final bool hasBootstrapError;
  final bool navigatingAway;
  final Widget child;
  final Widget hiddenChild;
  final void Function(bool composerVisible, bool routeTransitionActive)?
      onVisibilityChanged;

  @override
  State<ChatComposerVisibilityGate> createState() =>
      _ChatComposerVisibilityGateState();
}

class _ChatComposerVisibilityGateState
    extends State<ChatComposerVisibilityGate> {
  ModalRoute<dynamic>? _observedRoute;
  Animation<double>? _primaryAnimation;
  Animation<double>? _secondaryAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRouteAnimationListeners();
  }

  @override
  void dispose() {
    _removeRouteAnimationListeners();
    super.dispose();
  }

  void _syncRouteAnimationListeners() {
    final route = ModalRoute.of(context);
    final primaryAnimation = route?.animation;
    final secondaryAnimation = route?.secondaryAnimation;

    if (identical(route, _observedRoute) &&
        identical(primaryAnimation, _primaryAnimation) &&
        identical(secondaryAnimation, _secondaryAnimation)) {
      return;
    }

    _removeRouteAnimationListeners();

    _observedRoute = route;
    _primaryAnimation = primaryAnimation;
    _secondaryAnimation = secondaryAnimation;

    _primaryAnimation?.addStatusListener(_handleRouteAnimationStatusChanged);
    _secondaryAnimation?.addStatusListener(_handleRouteAnimationStatusChanged);
  }

  void _removeRouteAnimationListeners() {
    _primaryAnimation?.removeStatusListener(_handleRouteAnimationStatusChanged);
    _secondaryAnimation?.removeStatusListener(
      _handleRouteAnimationStatusChanged,
    );
    _observedRoute = null;
    _primaryAnimation = null;
    _secondaryAnimation = null;
  }

  void _handleRouteAnimationStatusChanged(AnimationStatus _) {
    if (!mounted) return;
    setState(() {});
  }

  bool _routeTransitionActive() {
    final route = ModalRoute.of(context);
    return isChatRouteTransitionActive(
      navigatingAway: widget.navigatingAway,
      hasRoute: route != null,
      routeIsCurrent: route?.isCurrent ?? true,
      primaryStatus: route?.animation?.status,
      secondaryStatus: route?.secondaryAnimation?.status,
    );
  }

  @override
  Widget build(BuildContext context) {
    final routeTransitionActive = _routeTransitionActive();
    final composerVisible = shouldShowChatComposerForBootstrap(
          bootstrapping: widget.bootstrapping,
          hasBootstrapError: widget.hasBootstrapError,
        ) &&
        !routeTransitionActive;

    widget.onVisibilityChanged?.call(composerVisible, routeTransitionActive);

    return composerVisible ? widget.child : widget.hiddenChild;
  }
}

@visibleForTesting
const ValueKey<String> chatSystemTileKey = ValueKey<String>(
  'chat_system_tile',
);

@visibleForTesting
const ValueKey<String> chatMessageBubbleKey = ValueKey<String>(
  'chat_message_bubble',
);

String _chatMessageString(dynamic value, {String fallback = ''}) {
  if (value is String) return value.trim();
  if (value == null) return fallback;
  return value.toString().trim();
}

String _formatChatMessageTime(dynamic createdAtMsValue) {
  final createdAtMs = createdAtMsValue is int
      ? createdAtMsValue
      : (createdAtMsValue is num ? createdAtMsValue.floor() : 0);

  if (createdAtMs <= 0) return '';

  final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $suffix';
}

@visibleForTesting
bool isChatSystemMessageType(String type) {
  final normalized = type.trim();
  return normalized == FirestorePaths.messageTypeCallStart ||
      normalized == FirestorePaths.messageTypeCallEnd ||
      normalized == FirestorePaths.messageTypeMissedCall ||
      normalized == FirestorePaths.messageTypeCallCharge ||
      normalized == FirestorePaths.messageTypeSystem ||
      normalized == FirestorePaths.messageTypeAccessRequest ||
      normalized == FirestorePaths.messageTypeAccessApproved ||
      normalized == FirestorePaths.messageTypeAccessDenied;
}

bool _chatSessionBool(dynamic value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true') return true;
    if (normalized == 'false') return false;
  }
  return fallback;
}

@visibleForTesting
bool chatSessionHasAcceptedCallAccessForUi(Map<String, dynamic> session) {
  if (session['exists'] != true) return false;
  final callAllowed = _chatSessionBool(
    session[FirestorePaths.fieldCallAllowed],
    fallback: false,
  );
  final statusAccepted =
      _chatMessageString(session[FirestorePaths.fieldChatStatus]) ==
          FirestorePaths.chatStatusAccepted;
  return callAllowed || statusAccepted;
}

@visibleForTesting
bool chatSessionHasEffectiveStartCallAccessForUi({
  required bool acceptedAccess,
  required bool directionAllowed,
  required int allowedAtMs,
  required int staleCallApprovalAtMs,
}) {
  if (!acceptedAccess || !directionAllowed) return false;
  if (staleCallApprovalAtMs == 0) return true;
  if (staleCallApprovalAtMs < 0) return allowedAtMs > 0;
  return allowedAtMs != staleCallApprovalAtMs;
}

Widget _buildChatSystemTile(
  Map<String, dynamic> message, {
  required String Function(dynamic createdAtMsValue) formatTime,
}) {
  final text = _chatMessageString(message[FirestorePaths.fieldMessageText]);
  final time = formatTime(message[FirestorePaths.fieldMessageCreatedAtMs]);

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Center(
      child: Container(
        key: chatSystemTileKey,
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppPalette.feedBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppPalette.border,
          ),
        ),
        child: Column(
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w800,
                height: 1.35,
              ),
            ),
            if (time.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                time,
                style: const TextStyle(
                  color: AppPalette.textMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

Widget _buildChatMessageBubble(
  Map<String, dynamic> message, {
  required String myUid,
  required bool showTopSpacing,
  required String Function(dynamic createdAtMsValue) formatTime,
}) {
  final type = _chatMessageString(message[FirestorePaths.fieldMessageType]);
  if (isChatSystemMessageType(type)) {
    return _buildChatSystemTile(message, formatTime: formatTime);
  }

  final isMine =
      _chatMessageString(message[FirestorePaths.fieldMessageSenderId]) == myUid;
  final text = _chatMessageString(message[FirestorePaths.fieldMessageText]);
  final time = formatTime(message[FirestorePaths.fieldMessageCreatedAtMs]);
  final seen = message[FirestorePaths.fieldMessageSeen] == true;

  final bubble = Container(
    key: chatMessageBubbleKey,
    constraints: const BoxConstraints(maxWidth: 290),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: isMine ? AppPalette.blue : AppPalette.card,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(18),
        topRight: const Radius.circular(18),
        bottomLeft: Radius.circular(isMine ? 18 : 6),
        bottomRight: Radius.circular(isMine ? 6 : 18),
      ),
      border: isMine
          ? null
          : Border.all(
              color: AppPalette.border,
            ),
      boxShadow: [
        BoxShadow(
          blurRadius: 10,
          offset: const Offset(0, 3),
          color: Colors.black.withValues(alpha: 0.05),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment:
          isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: TextStyle(
            color: isMine ? Colors.white : AppPalette.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              time,
              style: TextStyle(
                color: isMine
                    ? Colors.white.withValues(alpha: 0.86)
                    : AppPalette.textMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isMine) ...[
              const SizedBox(width: 6),
              Icon(
                seen ? Icons.done_all_rounded : Icons.done_rounded,
                size: 15,
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ],
          ],
        ),
      ],
    ),
  );

  return Padding(
    padding: EdgeInsets.only(
      top: showTopSpacing ? 12 : 4,
      bottom: 4,
    ),
    child: Row(
      mainAxisAlignment:
          isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [bubble],
    ),
  );
}

@visibleForTesting
Widget buildChatMessageTileForTest({
  required Map<String, dynamic> message,
  required String myUid,
  bool showTopSpacing = true,
}) {
  return _buildChatMessageBubble(
    message,
    myUid: myUid,
    showTopSpacing: showTopSpacing,
    formatTime: _formatChatMessageTime,
  );
}

class ChatConversationScreen extends StatefulWidget {
  static const String routeName = '/chat-conversation';

  final String speakerId;
  final String listenerId;
  final String actualListenerId;
  final bool iAmListener;
  final AppUserModel? initialOtherUser;

  const ChatConversationScreen({
    super.key,
    required this.speakerId,
    required this.listenerId,
    this.actualListenerId = '',
    this.iAmListener = false,
    this.initialOtherUser,
  });

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final CallRepository _callRepository = CallRepository.instance;
  final UserRepository _userRepository = UserRepository.instance;
  final CallSessionManager _callSession = CallSessionManager.instance;

  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  late final Stream<AppUserModel?> _otherUserStream;
  late final Stream<AppUserModel?> _meStream;
  late Future<void> _bootstrapFuture;

  StreamSubscription<Map<String, dynamic>>? _sessionResolverSub;

  bool _sending = false;
  bool _reportingUser = false;
  bool _blockingUser = false;
  bool _loadingCall = false;
  bool _callStartInFlight = false;
  bool _bootstrapping = true;
  bool _markingSeen = false;
  bool _resolvingSession = false;
  bool _requestingCall = false;
  bool _acceptingCallRequest = false;
  Timer? _callStartCooldownTimer;
  int _staleCallApprovalAtMs = 0;
  int _localCallApprovalAtMs = 0;
  int _localCallRequestAtMs = 0;

  Object? _bootstrapError;
  String? _bootstrapErrorMessage;
  _ChatDirectionMismatchState? _bootstrapDirectionMismatch;
  bool _bootstrapNeedsRepair = false;
  bool _navigatingAway = false;
  String _lastComposerDebugSignature = '';
  bool? _lastComposerTextPresent;
  int _lastRenderedMessageCount = 0;
  int _messageStreamRetryToken = 0;
  String _lastPeerSnapshotSignature = '';
  String _lastCallSystemDuplicateSignature = '';
  String _lastSeenBatchSignature = '';
  String _lastCommittedSeenBatchSignature = '';
  String _lastScheduledSeenBatchSignature = '';
  DateTime? _lastSeenBatchAt;
  String _localCallApprovalSpeakerId = '';
  String _localCallApprovalListenerId = '';
  String _localCallRequestSpeakerId = '';
  String _localCallRequestListenerId = '';
  String _lastCallRequestRenderTrace = '';
  String _lastPartialAcceptedTrace = '';
  final Set<String> _acceptedStateRepairInFlight = <String>{};
  final Map<String, DateTime> _acceptedStateRepairLastAttemptAt =
      <String, DateTime>{};
  DateTime? _callStartCooldownUntil;
  _CallRequestUiState? _lastStableAcceptedCallRequestState;

  static const int _messagesPageSize = 250;
  static const Duration _seenBatchThrottle = Duration(seconds: 2);
  static const int _maxSeenUpdatesPerBatch = 25;

  DocumentReference<Map<String, dynamic>>? _resolvedSessionRef;
  String _resolvedSessionDocId = '';

  String get _myUid => _auth.currentUser?.uid ?? '';

  bool get _callStartCooldownActive {
    final until = _callStartCooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  String get _requestedSpeakerId => widget.speakerId.trim();

  String get _requestedListenerId => widget.listenerId.trim();

  String get _requestedActualListenerId => widget.actualListenerId.trim();

  String get _requestedProductListenerId =>
      _requestedActualListenerId.isNotEmpty
          ? _requestedActualListenerId
          : _requestedListenerId;

  bool _sessionHasCallRoleState(Map<String, dynamic> session) {
    return _sessionCallRequestOpen(session) ||
        _sessionCallAllowed(session) ||
        _sessionStatusAccepted(session) ||
        _sessionCallRequestedBy(session).isNotEmpty ||
        _asString(session[FirestorePaths.fieldRequesterId]).isNotEmpty ||
        _asString(session[FirestorePaths.fieldResponderId]).isNotEmpty ||
        _asString(session[FirestorePaths.fieldPendingFor]).isNotEmpty;
  }

  List<String> _participantsForSession(Map<String, dynamic> session) {
    return _callRepository.sessionParticipantIds(
      session,
      fallbackSpeakerId: _requestedSpeakerId,
      fallbackListenerId: _requestedListenerId,
    );
  }

  String _sessionRequesterId(Map<String, dynamic> session) {
    return _asString(
      session[FirestorePaths.fieldRequesterId],
      fallback: _asString(
        session[FirestorePaths.fieldCallRequestedBy],
        fallback: '',
      ),
    );
  }

  String _sessionResponderId(Map<String, dynamic> session) {
    return _asString(
      session[FirestorePaths.fieldResponderId],
      fallback: _asString(
        session[FirestorePaths.fieldPendingFor],
        fallback: '',
      ),
    );
  }

  String _actualListenerIdForSession([Map<String, dynamic>? session]) {
    if (session != null) {
      if (!_sessionHasCallRoleState(session)) return '';

      final participantIds = _participantsForSession(session);
      final requesterId = _sessionRequesterId(session);
      final directCandidates = <String>[
        _sessionResponderId(session),
        _asString(session[FirestorePaths.fieldPendingFor]),
        _asString(session[FirestorePaths.fieldActualListenerId]),
      ];
      for (final candidate in directCandidates) {
        if (participantIds.contains(candidate) && candidate != requesterId) {
          return candidate;
        }
      }

      if (participantIds.contains(requesterId)) {
        return participantIds.firstWhere(
          (uid) => uid != requesterId,
          orElse: () => '',
        );
      }
      return '';
    }
    if (_requestedActualListenerId.isNotEmpty) {
      return _requestedActualListenerId;
    }
    return _requestedListenerId;
  }

  String _actualSpeakerIdForSession([Map<String, dynamic>? session]) {
    if (session != null) {
      final participantIds = _participantsForSession(session);
      final requesterId = _sessionRequesterId(session);
      if (_sessionHasCallRoleState(session) &&
          participantIds.contains(requesterId)) {
        return requesterId;
      }

      final listenerId = _actualListenerIdForSession(session);
      if (_sessionHasCallRoleState(session) &&
          participantIds.length == 2 &&
          listenerId.isNotEmpty) {
        return participantIds.firstWhere(
          (uid) => uid != listenerId,
          orElse: () => _requestedSpeakerId,
        );
      }

      final speakerId = _asString(
        session[FirestorePaths.fieldSpeakerId],
        fallback: '',
      );
      if (speakerId.isNotEmpty) return speakerId;
    }

    return _requestedSpeakerId;
  }

  String _actualRequesterIdForSession([Map<String, dynamic>? session]) {
    if (session != null) {
      final requesterId = _sessionRequesterId(session);
      if (requesterId.isNotEmpty) return requesterId;
    }
    return _requestedSpeakerId;
  }

  bool _amListenerForSession([Map<String, dynamic>? session]) {
    if (session != null && !_sessionHasCallRoleState(session)) return false;
    final actualListenerId = _actualListenerIdForSession(session);
    if (actualListenerId.isNotEmpty) {
      return _myUid == actualListenerId;
    }
    return widget.iAmListener;
  }

  String _otherParticipantIdForSession([Map<String, dynamic>? session]) {
    if (session != null) {
      final participantIds = _callRepository.sessionParticipantIds(
        session,
        fallbackSpeakerId: _requestedSpeakerId,
        fallbackListenerId: _requestedListenerId,
      );
      if (participantIds.length == 2 && participantIds.contains(_myUid)) {
        return participantIds.firstWhere((uid) => uid != _myUid);
      }
    }
    return _requestedListenerId;
  }

  bool get _hasBlockingCallState =>
      _callSession.callDocRef != null ||
      _callSession.active ||
      _callSession.state == CallState.preparing ||
      _callSession.state == CallState.joining ||
      _callSession.state == CallState.reconnecting ||
      _callSession.state == CallState.ending;

  bool _profileShowsActiveCall(AppUserModel? user) {
    if (user == null) return false;
    return user.isOnCall || user.activeCallId.trim().isNotEmpty;
  }

  bool _callBlockedByLocalOrProfile({
    AppUserModel? me,
    AppUserModel? otherUser,
  }) {
    return _hasBlockingCallState ||
        _profileShowsActiveCall(me) ||
        _profileShowsActiveCall(otherUser);
  }

  String get _directionalSessionId {
    return _callRepository.chatSessionIdForPair(
      speakerId: _requestedSpeakerId,
      listenerId: _requestedListenerId,
    );
  }

  List<String> get _canonicalRequestedPair {
    final ids = <String>[
      _requestedSpeakerId,
      _requestedListenerId,
    ]..sort();
    return ids;
  }

  bool get _isCanonicalDirectionalPairValid {
    if (_requestedSpeakerId.isEmpty || _requestedListenerId.isEmpty) {
      return false;
    }
    if (_requestedSpeakerId == _requestedListenerId) {
      return false;
    }
    return true;
  }

  String get _otherUid {
    if (_myUid.isEmpty) return '';
    if (_myUid == _requestedSpeakerId) return _requestedListenerId;
    if (_myUid == _requestedListenerId) return _requestedSpeakerId;
    return _requestedListenerId;
  }

  bool get _hasBootstrapError => _bootstrapError != null;

  bool _validRequestedPair() {
    if (_requestedSpeakerId.isEmpty || _requestedListenerId.isEmpty) {
      return false;
    }
    if (_requestedSpeakerId == _requestedListenerId) {
      return false;
    }
    return true;
  }

  DocumentReference<Map<String, dynamic>> get _directionalSessionRef {
    return _db
        .collection(FirestorePaths.chatSessions)
        .doc(_directionalSessionId);
  }

  @override
  void initState() {
    super.initState();
    ActiveChatSessionTracker.instance.markVisible(_directionalSessionId);
    _otherUserStream = _watchOtherUser();
    _meStream = _userRepository.watchMe();
    _bootstrapFuture = _prepareStableSession();
    _bindResolvedSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dismissComposerFocus(reason: 'focus.autofocus_suppressed');
    });
  }

  @override
  void dispose() {
    debugPrint(
      'chat_conversation.dispose '
      'requesting=$_requestingCall accepting=$_acceptingCallRequest '
      'loadingCall=$_loadingCall navigatingAway=$_navigatingAway',
    );
    ActiveChatSessionTracker.instance.clearVisible(_directionalSessionId);
    _sessionResolverSub?.cancel();
    _callStartCooldownTimer?.cancel();
    _dismissComposerFocus(reason: 'focus.cleared_on_route_leave');
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Stream<AppUserModel?> _watchOtherUser() {
    final otherUid = _otherUid;
    if (otherUid.isEmpty) {
      return Stream<AppUserModel?>.value(widget.initialOtherUser);
    }

    return _userRepository.watchUser(otherUid);
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    if (value == null) return fallback;
    return value.toString().trim();
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

  void _dismissComposerFocus({String reason = ''}) {
    _messageFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    if (kDebugMode && _verboseChatDebugLogs && reason.isNotEmpty) {
      debugPrint(reason);
    }
  }

  void _setNavigatingAway(bool value) {
    if (_navigatingAway == value) return;
    if (mounted) {
      setState(() {
        _navigatingAway = value;
      });
    } else {
      _navigatingAway = value;
    }
  }

  void _beginCallStartCooldown() {
    _callStartCooldownTimer?.cancel();
    _callStartCooldownUntil = DateTime.now().add(const Duration(seconds: 3));
    debugPrint('call.start_cooldown_begin');
    if (mounted) setState(() {});

    _callStartCooldownTimer = Timer(const Duration(seconds: 3), () {
      _callStartCooldownUntil = null;
      debugPrint('call.start_cooldown_end');
      if (mounted) setState(() {});
    });
  }

  void _clearBootstrapError() {
    _bootstrapError = null;
    _bootstrapErrorMessage = null;
    _bootstrapDirectionMismatch = null;
    _bootstrapNeedsRepair = false;
  }

  void _setBootstrapFailure(
    Object error, {
    _ChatDirectionMismatchState? mismatch,
    bool needsRepair = false,
  }) {
    _dismissComposerFocus();
    _bootstrapError = error;
    _bootstrapErrorMessage = mismatch?.message ??
        (needsRepair
            ? 'This conversation needs repair.'
            : _humanizeError(error));
    _bootstrapDirectionMismatch = mismatch;
    _bootstrapNeedsRepair = needsRepair;
  }

  String _humanizeError(Object error) {
    final raw = error.toString().trim();
    if (raw.isEmpty) return 'Something went wrong.';
    if (raw.contains('permission-denied')) {
      return 'You do not have permission to open this chat.';
    }
    if (raw.contains('unavailable')) {
      return 'Chat service is temporarily unavailable. Please try again.';
    }
    if (raw.contains('invalid-argument')) {
      return 'This chat could not be opened because some details are invalid.';
    }
    return 'Something went wrong. Please try again.';
  }

  bool _isPermissionDeniedError(Object error) {
    final raw = error.toString().trim().toLowerCase();
    if (raw.isEmpty) return false;
    return raw.contains('permission-denied') ||
        raw.contains('permission denied');
  }

  bool _isRepairableChatSessionError(Object error) {
    final raw = error.toString().trim().toLowerCase();
    if (raw.isEmpty) return false;
    return raw.contains('conversation needs repair') ||
        raw.contains('chat session contract is incomplete') ||
        raw.contains('canonical chat session could not be resolved') ||
        raw.contains('non-canonical chat session id resolved') ||
        raw.contains('resolved chat session id is empty');
  }

  void _debugLogMessageSendAttempt({
    required String sessionId,
    required String senderId,
    required String receiverId,
    required bool identityComplete,
    required bool directionComplete,
  }) {
    if (!kDebugMode || !_verboseChatDebugLogs) return;
    debugPrint(
      'Chat send attempt '
      'sessionId=${AppLog.safeId(sessionId)} '
      'requestedSpeakerPresent=${_requestedSpeakerId.isNotEmpty} '
      'requestedListenerPresent=${_requestedListenerId.isNotEmpty} '
      'senderPresent=${senderId.isNotEmpty} '
      'receiverPresent=${receiverId.isNotEmpty} '
      'identityComplete=$identityComplete '
      'directionComplete=$directionComplete',
    );
  }

  void _debugLogMessageSendFailure({
    required Object error,
    required String sessionId,
    required String senderId,
    required String receiverId,
    required bool identityComplete,
    required bool directionComplete,
  }) {
    if (!kDebugMode || !_verboseChatDebugLogs) return;
    debugPrint(
      'Chat send failed '
      'sessionId=${AppLog.safeId(sessionId)} '
      'requestedSpeakerPresent=${_requestedSpeakerId.isNotEmpty} '
      'requestedListenerPresent=${_requestedListenerId.isNotEmpty} '
      'senderPresent=${senderId.isNotEmpty} '
      'receiverPresent=${receiverId.isNotEmpty} '
      'identityComplete=$identityComplete '
      'directionComplete=$directionComplete '
      'error=${error.runtimeType}',
    );
  }

  String _safeChatSendFailureReason({
    required Object error,
    required bool identityComplete,
    required bool directionComplete,
    required String receiverId,
  }) {
    if (!identityComplete) return 'identity_incomplete';
    if (!directionComplete) return 'direction_incomplete';
    if (receiverId.trim().isEmpty || receiverId == _myUid) {
      return 'receiver_unresolved';
    }
    if (_isPermissionDeniedError(error)) return 'permission_denied';
    final raw = error.toString().toLowerCase();
    if (raw.contains('repair')) return 'session_needs_repair';
    return 'failed';
  }

  String _currentRouteLabel() {
    final route = ModalRoute.of(context);
    final routeName = route?.settings.name?.trim() ?? '';
    if (routeName.isNotEmpty) return routeName;
    return route?.runtimeType.toString() ?? ChatConversationScreen.routeName;
  }

  void _debugLogComposerState({
    required bool composerVisible,
    required bool bootstrapping,
    required bool hasBootstrapError,
    required bool routeTransitionActive,
  }) {
    if (!kDebugMode || !_verboseChatDebugLogs) return;
    final routeLabel = _currentRouteLabel();
    final signature =
        'visible=$composerVisible|boot=$bootstrapping|error=$hasBootstrapError|route=$routeLabel|transition=$routeTransitionActive';
    if (signature == _lastComposerDebugSignature) return;
    _lastComposerDebugSignature = signature;
    debugPrint(
      'Chat composer state: visible=$composerVisible, bootstrapping=$bootstrapping, hasBootstrapError=$hasBootstrapError, currentRoute=$routeLabel, routeTransitionActive=$routeTransitionActive',
    );
  }

  void _applyLocalCallApproval({
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    if (safeSpeakerId.isEmpty || safeListenerId.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _localCallApprovalSpeakerId = safeSpeakerId;
      _localCallApprovalListenerId = safeListenerId;
      _localCallApprovalAtMs = nowMs;
      _localCallRequestSpeakerId = '';
      _localCallRequestListenerId = '';
      _localCallRequestAtMs = 0;
      _staleCallApprovalAtMs = 0;
    });
  }

  void _applyLocalCallRequest({
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    if (safeSpeakerId.isEmpty ||
        safeListenerId.isEmpty ||
        safeSpeakerId == safeListenerId) {
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _localCallRequestSpeakerId = safeSpeakerId;
      _localCallRequestListenerId = safeListenerId;
      _localCallRequestAtMs = nowMs;
    });
  }

  String _callErrorTextForFailureReason(
    String reason, {
    String otherName = 'The other person',
  }) {
    switch (reason) {
      case 'insufficient_credits':
        return 'Add credits before starting a call.';
      case 'app_check_failed':
      case 'server_config_missing':
        return 'Calls are temporarily paused. Please try again later.';
      case 'self_only_chat_mode':
        return 'Only Chat Mode is ON. Turn it off from Home to request or receive calls.';
      case 'peer_only_chat_mode':
        return '$otherName is in Only Chat Mode.';
      case 'call_access_not_accepted':
        return 'This call is not approved yet. Open chat and wait for approval.';
      case 'caller_not_speaker':
      case 'listener_mismatch':
        return 'This call approval does not belong to this direction yet.';
      case 'active_call_exists':
      case 'caller_busy':
        return 'You already have an active call.';
      case 'peer_busy':
        return '$otherName is on another call right now.';
      case 'wallet_reserve_failed':
        return 'Could not reserve credits for this call. Please try again.';
      case 'unknown_precondition':
        return 'Call cannot be started right now.';
      default:
        return '';
    }
  }

  int _minimumRequiredUsableCredit(AppUserModel? listener) {
    final rate = listener?.listenerRate ?? FirestoreService.rateOptions.first;
    return rate <= 0 ? FirestoreService.rateOptions.first : rate;
  }

  String _startLocalPreflightFailureReason(
    Map<String, dynamic> session, {
    AppUserModel? me,
    AppUserModel? otherUser,
  }) {
    if (_loadingCall || _callStartInFlight || _callStartCooldownActive) {
      return 'pending_start';
    }
    if (_hasBlockingCallState || _profileShowsActiveCall(me)) {
      return 'active_call_exists';
    }
    if (_profileShowsActiveCall(otherUser)) return 'peer_busy';
    if (!_sessionExists(session) || _sessionIsBlocked(session)) {
      return 'not_accepted';
    }
    if (!_effectiveSessionCallAllowed(session)) return 'not_accepted';

    final speakerId = _actualSpeakerIdForSession(session);
    if (speakerId.isEmpty || speakerId != _myUid) return 'not_speaker';

    if (_isOnlyChatMode(me)) return 'self_only_chat_mode';
    if (_isOnlyChatMode(otherUser)) return 'peer_only_chat_mode';

    if (me != null && otherUser != null) {
      final requiredCredit = _minimumRequiredUsableCredit(otherUser);
      if (me.usableCredits < requiredCredit) return 'insufficient_credits';
    }

    return '';
  }

  String _startButtonDisabledReason({
    required bool exists,
    required bool acceptedSpeaker,
    required bool effectiveCallAllowed,
    required bool callBlockedByState,
    required bool callModeBlocked,
    required bool knownInsufficientCredit,
  }) {
    if (_hasBootstrapError) return 'bootstrap_error';
    if (!acceptedSpeaker) return 'not_speaker';
    if (!exists) return 'session_missing';
    if (callBlockedByState) return 'active_or_busy_call';
    if (callModeBlocked) return 'only_chat_mode';
    if (knownInsufficientCredit) return 'insufficient_credits';
    if (_loadingCall || _callStartInFlight) return 'pending_start';
    if (_callStartCooldownActive) return 'cooldown';
    if (!effectiveCallAllowed) return 'not_accepted';
    return '';
  }

  String _startButtonDisabledMessage(String reason,
      {required String otherName}) {
    switch (reason) {
      case 'bootstrap_error':
        return 'Chat is not ready yet.';
      case 'session_missing':
        return 'Chat session is still loading.';
      case 'active_or_busy_call':
        if (_loadingCall || _callStartInFlight) return 'Starting the call...';
        return 'Finish the current call flow before starting another.';
      case 'only_chat_mode':
        return 'Calls are paused while Only Chat Mode is ON.';
      case 'insufficient_credits':
        return 'Add credits before starting a call.';
      case 'pending_start':
        return 'Starting the call...';
      case 'cooldown':
        return 'Please wait a moment before trying again.';
      case 'not_accepted':
        return 'Waiting for $otherName to accept the call request.';
      default:
        return '';
    }
  }

  String _localPreflightMessage(
    String reason, {
    String otherName = 'This user',
  }) {
    switch (reason) {
      case 'insufficient_credits':
        return 'Add credits before starting a call.';
      case 'self_only_chat_mode':
        return 'Turn off Only Chat Mode to start calls.';
      case 'peer_only_chat_mode':
        return '$otherName is in Only Chat Mode.';
      case 'not_speaker':
        return 'Only the speaker can start the call.';
      case 'not_accepted':
        return 'Request must be accepted before starting a call.';
      case 'active_call_exists':
        return 'End the current call first.';
      case 'peer_busy':
        return '$otherName is on another call right now.';
      default:
        return 'Call cannot be started right now.';
    }
  }

  void _blockStartLocally(
    String reason, {
    String otherName = 'This user',
  }) {
    debugPrint('call.start_local_preflight_blocked reason=$reason');
    _showSnack(_localPreflightMessage(reason, otherName: otherName));
  }

  String _humanizeCallError(
    Object error, {
    String otherName = 'The other person',
  }) {
    if (_looksLikeNetworkError(error)) {
      return 'Internet connection is unstable. Please check network and try again.';
    }
    if (error is FirebaseFunctionsException) {
      final code = error.code.trim();
      final message = (error.message ?? '').trim();
      final failureReason = FirestoreService.functionFailureReason(error);
      final failureText = _callErrorTextForFailureReason(
        failureReason,
        otherName: otherName,
      );
      if (failureText.isNotEmpty) return failureText;

      if (message == 'App Check token is required.') {
        return 'Calls are temporarily paused. Please try again later.';
      }

      switch (code) {
        case 'failed-precondition':
          if (message == 'Listener is busy') {
            return '$otherName is on another call right now.';
          }
          if (message == 'Call request is still pending approval.') {
            return 'Your call request is still waiting for approval.';
          }
          if (message == 'Call is not allowed for this chat yet.') {
            return 'This call is no longer approved. Please request again.';
          }
          if (message == 'self_only_chat_mode') {
            return 'Only Chat Mode is ON. Turn it off from Home to request or receive calls.';
          }
          if (message == 'peer_only_chat_mode') {
            return '$otherName is in Only Chat Mode.';
          }
          if (message == 'call_request_not_found') {
            return 'This call request is no longer available.';
          }
          if (message == 'call_request_already_accepted') {
            return 'This call request is already accepted.';
          }
          if (message == 'invalid_call_request_state') {
            return 'Could not update call request. Please try again.';
          }
          if (message == 'Chat session missing. Open chat first.') {
            return 'Send a message first to start this chat.';
          }
          if (message == 'You already have an active call') {
            return 'You already have an active call.';
          }
          if (message == 'Listener blocked you' ||
              message == 'You blocked this listener') {
            return 'Calling is unavailable for this chat.';
          }
          return 'Call cannot be started right now.';
        case 'permission-denied':
          return 'You are not allowed to do this.';
        case 'unavailable':
          return 'Call service is temporarily unavailable.';
        case 'resource-exhausted':
          return 'You already have an active call.';
        default:
          return 'Call action failed.';
      }
    }

    final raw = error.toString().trim();
    if (raw.contains(AgoraClientConfig.developerRunCommandMessage)) {
      return UiCopy.callSetupNotReady;
    }
    return raw.isEmpty
        ? 'Call action failed.'
        : 'Something went wrong. Please try again.';
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

  Future<String> _ensureSessionBootstrap() async {
    if (!_validRequestedPair()) {
      throw StateError('Invalid chat participants.');
    }

    final myUid = _myUid;
    if (myUid.isEmpty) {
      throw StateError('You must be signed in to open chat.');
    }

    final ensuredId = await _callRepository.ensureChatSessionByPair(
      speakerId: _requestedSpeakerId,
      listenerId: _requestedListenerId,
    );

    if (ensuredId.trim().isEmpty) {
      throw StateError('Failed to prepare chat session.');
    }

    if (ensuredId.trim() != _directionalSessionId) {
      throw StateError('Resolved non-canonical chat session.');
    }

    return ensuredId.trim();
  }

  bool _sessionLooksCanonical(Map<String, dynamic> session) {
    if (!_callRepository.sessionIdentityLooksComplete(
      session: session,
      speakerId: _requestedSpeakerId,
      listenerId: _requestedListenerId,
    )) {
      return false;
    }

    final docId = _asString(
      session['docId'],
      fallback: _directionalSessionId,
    );
    final canonicalDocId = _asString(
      session['canonicalDocId'],
      fallback: _directionalSessionId,
    );
    final speakerId = _asString(
      session[FirestorePaths.fieldSpeakerId],
      fallback: '',
    );
    final listenerId = _asString(
      session[FirestorePaths.fieldListenerId],
      fallback: '',
    );
    final participantIds = _callRepository.sessionParticipantIds(
      session,
      fallbackSpeakerId: speakerId,
      fallbackListenerId: listenerId,
    );
    final expectedPairKey = _callRepository.sessionPairKey(
      session,
      fallbackSpeakerId: _requestedSpeakerId,
      fallbackListenerId: _requestedListenerId,
    );

    if (!_isCanonicalDirectionalPairValid) return false;
    final canonicalRequestedPair = _canonicalRequestedPair;
    if (participantIds.length != canonicalRequestedPair.length) return false;
    for (var i = 0; i < participantIds.length; i++) {
      if (participantIds[i] != canonicalRequestedPair[i]) return false;
    }
    if (expectedPairKey != _directionalSessionId) return false;
    if (canonicalDocId != _directionalSessionId) return false;
    if (docId != _directionalSessionId) return false;

    return true;
  }

  Future<void> _prepareStableSession() async {
    _clearBootstrapError();
    _resolvedSessionDocId = '';
    _resolvedSessionRef = null;

    if (!_validRequestedPair()) {
      _setBootstrapFailure(StateError('Invalid chat participants.'));
      if (mounted) {
        setState(() => _bootstrapping = false);
      } else {
        _bootstrapping = false;
      }
      return;
    }

    if (_myUid.isEmpty) {
      _setBootstrapFailure(StateError('User is not signed in.'));
      if (mounted) {
        setState(() => _bootstrapping = false);
      } else {
        _bootstrapping = false;
      }
      return;
    }

    try {
      final ensuredSessionId = await _ensureSessionBootstrap();
      final session = await _callRepository.getChatSessionByPair(
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );

      if (!_sessionLooksCanonical(session)) {
        throw StateError('Canonical chat session could not be resolved.');
      }

      final strictResolution = _callRepository.resolveSessionDirectionForUser(
        session: session,
        myUid: _myUid,
        fallbackSpeakerId: _requestedSpeakerId,
        fallbackListenerId: _requestedListenerId,
        mode: ChatDirectionResolutionMode.strictStoredDirection,
      );
      final legacyResolution = strictResolution.isResolved
          ? const ChatSessionDirectionResolution.error('not_needed')
          : _callRepository.resolveSessionDirectionForUser(
              session: session,
              myUid: _myUid,
              fallbackSpeakerId: _requestedSpeakerId,
              fallbackListenerId: _requestedListenerId,
              mode: ChatDirectionResolutionMode.legacyRepair,
            );

      final directionDecision = decideChatBootstrapDirection(
        strictResolution: strictResolution,
        legacyResolution: legacyResolution,
        requestedSpeakerId: _requestedSpeakerId,
        requestedProductListenerId: _requestedProductListenerId,
      );
      if (directionDecision.kind ==
          ChatBootstrapDirectionDecisionKind.needsRepair) {
        _setBootstrapFailure(
          StateError(directionDecision.message),
          needsRepair: true,
        );
        return;
      }
      if (directionDecision.kind ==
          ChatBootstrapDirectionDecisionKind.mismatch) {
        final mismatchResolution = directionDecision.resolution;
        if (mismatchResolution == null) {
          _setBootstrapFailure(
            StateError('This conversation needs repair.'),
            needsRepair: true,
          );
          return;
        }
        _setBootstrapFailure(
          StateError(
            'This chat belongs to a different speaker/listener direction.',
          ),
          mismatch: _ChatDirectionMismatchState(
            resolution: mismatchResolution,
            message: directionDecision.message,
          ),
        );
        return;
      }

      final resolvedDocId = _asString(
        session['docId'],
        fallback: ensuredSessionId,
      );

      final effectiveDocId =
          resolvedDocId.isNotEmpty ? resolvedDocId : ensuredSessionId;

      if (effectiveDocId.isEmpty) {
        throw StateError('Resolved chat session id is empty.');
      }

      if (effectiveDocId != _directionalSessionId) {
        throw StateError('Non-canonical chat session id resolved.');
      }

      final ref =
          _db.collection(FirestorePaths.chatSessions).doc(effectiveDocId);

      if (mounted) {
        setState(() {
          _resolvedSessionDocId = effectiveDocId;
          _resolvedSessionRef = ref;
        });
      } else {
        _resolvedSessionDocId = effectiveDocId;
        _resolvedSessionRef = ref;
      }
    } catch (error) {
      if (_isRepairableChatSessionError(error)) {
        _setBootstrapFailure(
          StateError('This conversation needs repair.'),
          needsRepair: true,
        );
      } else {
        _setBootstrapFailure(error);
      }
    } finally {
      if (mounted) {
        setState(() => _bootstrapping = false);
      } else {
        _bootstrapping = false;
      }
    }
  }

  void _retryBootstrap() {
    _dismissComposerFocus();
    setState(() {
      _bootstrapping = true;
      _clearBootstrapError();
      _bootstrapFuture = _prepareStableSession();
    });
  }

  void _retryMessages() {
    setState(() => _messageStreamRetryToken++);
  }

  Future<void> _openExistingConversationDirection() async {
    final mismatch = _bootstrapDirectionMismatch;
    if (mismatch == null) return;

    final resolution = mismatch.resolution;
    if (!resolution.isResolved) return;

    if (resolution.actualSpeakerId == _requestedSpeakerId &&
        resolution.actualListenerId == _requestedProductListenerId) {
      return;
    }

    _dismissComposerFocus();
    if (!mounted) return;
    _setNavigatingAway(true);

    try {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatConversationScreen(
            speakerId: resolution.actualSpeakerId,
            listenerId: resolution.actualListenerId,
            actualListenerId: resolution.actualListenerId,
            iAmListener: resolution.iAmListener,
            initialOtherUser: widget.initialOtherUser,
          ),
        ),
      );
    } finally {
      if (mounted) {
        _setNavigatingAway(false);
      }
    }
  }

  void _bindResolvedSession() {
    _sessionResolverSub?.cancel();

    if (!_validRequestedPair()) return;

    _sessionResolverSub = _callRepository
        .watchChatSessionByPair(
      speakerId: _requestedSpeakerId,
      listenerId: _requestedListenerId,
    )
        .listen((session) {
      if (!_sessionLooksCanonical(session)) return;

      final docId = _asString(
        session['docId'],
        fallback: _directionalSessionId,
      );
      if (docId.isEmpty || docId != _directionalSessionId) return;

      final nextRef = _db.collection(FirestorePaths.chatSessions).doc(docId);

      if (_resolvedSessionDocId == docId &&
          _resolvedSessionRef?.path == nextRef.path) {
        return;
      }

      if (!mounted) return;

      setState(() {
        _resolvedSessionDocId = docId;
        _resolvedSessionRef = nextRef;
      });
    });
  }

  Future<DocumentReference<Map<String, dynamic>>> _resolveSessionRef() async {
    if (_resolvedSessionRef != null &&
        _resolvedSessionDocId.isNotEmpty &&
        _resolvedSessionDocId == _directionalSessionId) {
      return _resolvedSessionRef!;
    }

    if (!_validRequestedPair()) {
      throw StateError('Invalid chat participants.');
    }

    if (_resolvingSession) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return _resolvedSessionRef ?? _directionalSessionRef;
    }

    _resolvingSession = true;
    try {
      final ensuredSessionId = await _ensureSessionBootstrap();
      final session = await _callRepository.getChatSessionByPair(
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );

      if (!_sessionLooksCanonical(session)) {
        throw StateError('Canonical chat session could not be resolved.');
      }

      final docId = _asString(
        session['docId'],
        fallback: ensuredSessionId,
      );
      final effectiveDocId = docId.isNotEmpty ? docId : ensuredSessionId;

      if (effectiveDocId != _directionalSessionId) {
        throw StateError('Non-canonical chat session id resolved.');
      }

      final ref =
          _db.collection(FirestorePaths.chatSessions).doc(effectiveDocId);

      if (mounted) {
        setState(() {
          _resolvedSessionDocId = effectiveDocId;
          _resolvedSessionRef = ref;
        });
      } else {
        _resolvedSessionDocId = effectiveDocId;
        _resolvedSessionRef = ref;
      }

      return ref;
    } finally {
      _resolvingSession = false;
    }
  }

  Future<void> _markVisibleMessagesSeen(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    if (_markingSeen || _myUid.isEmpty || docs.isEmpty || _hasBootstrapError) {
      return;
    }

    final unreadDocs = docs.where((doc) {
      final data = doc.data();
      final senderId =
          _asString(data[FirestorePaths.fieldMessageSenderId], fallback: '');
      final seen = data[FirestorePaths.fieldMessageSeen] == true;
      return senderId.isNotEmpty && senderId != _myUid && !seen;
    }).toList();

    if (unreadDocs.isEmpty) return;

    final cappedUnreadDocs = unreadDocs.length > _maxSeenUpdatesPerBatch
        ? unreadDocs.take(_maxSeenUpdatesPerBatch).toList()
        : unreadDocs;

    final signature = cappedUnreadDocs.map((doc) => doc.id).join('|');
    final now = DateTime.now();
    final throttled = signature == _lastSeenBatchSignature &&
        _lastSeenBatchAt != null &&
        now.difference(_lastSeenBatchAt!) < _seenBatchThrottle;

    if (throttled || signature == _lastCommittedSeenBatchSignature) {
      return;
    }

    _lastSeenBatchSignature = signature;
    _lastSeenBatchAt = now;

    _markingSeen = true;

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final batch = _db.batch();

      for (final doc in cappedUnreadDocs) {
        batch.set(
          doc.reference,
          {
            FirestorePaths.fieldMessageSeen: true,
            FirestorePaths.fieldMessageSeenAt: FieldValue.serverTimestamp(),
            FirestorePaths.fieldMessageSeenAtMs: nowMs,
          },
          SetOptions(merge: true),
        );
      }

      await batch.commit();
      _lastCommittedSeenBatchSignature = signature;
    } catch (_) {
      // ignore
    } finally {
      _markingSeen = false;
    }
  }

  String _visibleUnreadSignature(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    if (_myUid.isEmpty || docs.isEmpty || _hasBootstrapError) {
      return '';
    }

    final unreadDocs = docs.where((doc) {
      final data = doc.data();
      final senderId =
          _asString(data[FirestorePaths.fieldMessageSenderId], fallback: '');
      final seen = data[FirestorePaths.fieldMessageSeen] == true;
      return senderId.isNotEmpty && senderId != _myUid && !seen;
    }).take(_maxSeenUpdatesPerBatch);

    return unreadDocs.map((doc) => doc.id).join('|');
  }

  void _scheduleVisibleMessagesSeen(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final signature = _visibleUnreadSignature(docs);
    if (signature.isEmpty) {
      _lastScheduledSeenBatchSignature = '';
      return;
    }

    if (_markingSeen ||
        signature == _lastCommittedSeenBatchSignature ||
        signature == _lastScheduledSeenBatchSignature) {
      return;
    }

    _lastScheduledSeenBatchSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await _markVisibleMessagesSeen(docs);
      } finally {
        if (_lastScheduledSeenBatchSignature == signature) {
          _lastScheduledSeenBatchSignature = '';
        }
      }
    });
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  bool _sessionIsBlocked(Map<String, dynamic> session) {
    return _asBool(session[FirestorePaths.fieldListenerBlocked]) ||
        _asBool(session[FirestorePaths.fieldSpeakerBlocked]);
  }

  bool _sessionExists(Map<String, dynamic> session) {
    return session['exists'] == true;
  }

  bool _sessionReadyForComposer(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return false;
    if (!_sessionLooksCanonical(session)) return false;
    final receiverId = _otherParticipantIdForSession(session);
    return _myUid.isNotEmpty && receiverId.isNotEmpty && receiverId != _myUid;
  }

  bool _sessionCallAllowed(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return false;
    return _asBool(
      session[FirestorePaths.fieldCallAllowed],
      fallback: false,
    );
  }

  bool _sessionStatusAccepted(Map<String, dynamic> session) {
    return _asString(session[FirestorePaths.fieldChatStatus]) ==
        FirestorePaths.chatStatusAccepted;
  }

  int _sessionCallAllowedAtMs(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return 0;
    final raw = session[FirestorePaths.fieldCallAllowedAtMs];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  bool _effectiveSessionCallAllowed(Map<String, dynamic> session) {
    final speakerId = _actualSpeakerIdForSession(session);
    final listenerId = _actualListenerIdForSession(session);
    final directionAllowed = _callRepository.sessionAllowsCallForDirection(
      session: session,
      speakerId: speakerId,
      listenerId: listenerId,
    );

    return chatSessionHasEffectiveStartCallAccessForUi(
      acceptedAccess: _sessionAcceptedForUi(session),
      directionAllowed: directionAllowed,
      allowedAtMs: _sessionCallAllowedAtMs(session),
      staleCallApprovalAtMs: _staleCallApprovalAtMs,
    );
  }

  bool _sessionCallRequestOpen(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return false;
    return _asBool(
      session[FirestorePaths.fieldCallRequestOpen],
      fallback: false,
    );
  }

  String _sessionCallRequestedBy(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return '';
    return _asString(
      session[FirestorePaths.fieldCallRequestedBy],
      fallback: _sessionRequesterId(session),
    );
  }

  Future<void> _sendMessage(Map<String, dynamic> session) async {
    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty || _sending || _myUid.isEmpty) return;

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is not available right now.');
      return;
    }

    debugPrint(
      'chat.send_begin '
      'sessionId=${AppLog.safeId(_directionalSessionId)} '
      'senderPresent=${_myUid.isNotEmpty} '
      'textPresent=${text.isNotEmpty}',
    );

    setState(() => _sending = true);

    var effectiveSession = session;
    var effectiveReceiverId = _otherUid;
    var effectiveSessionId = _resolvedSessionDocId.isNotEmpty
        ? _resolvedSessionDocId
        : _directionalSessionId;
    var identityComplete = _callRepository.sessionIdentityLooksComplete(
      session: effectiveSession,
      speakerId: _requestedSpeakerId,
      listenerId: _requestedListenerId,
    );
    var directionComplete = _callRepository.sessionDirectionLooksComplete(
      session: effectiveSession,
      speakerId: _requestedSpeakerId,
      listenerId: _requestedListenerId,
    );

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final canUseResolvedSession = !_bootstrapping &&
          _resolvedSessionRef != null &&
          _resolvedSessionDocId == _directionalSessionId &&
          _sessionLooksCanonical(session);
      if (canUseResolvedSession) {
        debugPrint(
          'chat.send_preflight_fast_path '
          'sessionId=${AppLog.safeId(_directionalSessionId)}',
        );
      } else {
        await _ensureSessionBootstrap();
        effectiveSession = await _callRepository.getChatSessionByPair(
          speakerId: _requestedSpeakerId,
          listenerId: _requestedListenerId,
        );
      }
      identityComplete = _callRepository.sessionIdentityLooksComplete(
        session: effectiveSession,
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );
      directionComplete = _callRepository.sessionDirectionLooksComplete(
        session: effectiveSession,
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );

      if (!_sessionLooksCanonical(effectiveSession)) {
        _setBootstrapFailure(
          StateError('This conversation needs repair.'),
          needsRepair: true,
        );
        return;
      }

      final ref = canUseResolvedSession
          ? _resolvedSessionRef!
          : await _resolveSessionRef();
      effectiveSessionId = ref.id;
      effectiveReceiverId = _otherParticipantIdForSession(effectiveSession);
      if (effectiveReceiverId.isEmpty || effectiveReceiverId == _myUid) {
        throw StateError('Chat recipient could not be resolved.');
      }
      final participantIds = _participantsForSession(effectiveSession);
      final participantsValid = participantIds.length == 2 &&
          participantIds.contains(_myUid) &&
          participantIds.contains(effectiveReceiverId);
      final messagesRef = ref.collection(FirestorePaths.messages);

      _debugLogMessageSendAttempt(
        sessionId: effectiveSessionId,
        senderId: _myUid,
        receiverId: effectiveReceiverId,
        identityComplete: identityComplete,
        directionComplete: directionComplete,
      );
      debugPrint(
        'chat.send_preflight_ok '
        'sessionId=${AppLog.safeId(effectiveSessionId)} '
        'identityComplete=$identityComplete '
        'directionComplete=$directionComplete '
        'participantsValid=$participantsValid '
        'senderIsCurrent=true '
        'receiverPresent=${effectiveReceiverId.isNotEmpty}',
      );

      debugPrint(
        'chat.send_write_begin '
        'sessionId=${AppLog.safeId(effectiveSessionId)}',
      );
      final messageRef = await messagesRef.add({
        FirestorePaths.fieldMessageText: text,
        FirestorePaths.fieldMessageType: FirestorePaths.messageTypeText,
        FirestorePaths.fieldMessageSenderId: _myUid,
        FirestorePaths.fieldMessageReceiverId: effectiveReceiverId,
        FirestorePaths.fieldMessageCreatedAt: FieldValue.serverTimestamp(),
        FirestorePaths.fieldMessageCreatedAtMs: nowMs,
        FirestorePaths.fieldMessageSeen: false,
      });
      debugPrint(
        'chat.send_write_success '
        'sessionId=${AppLog.safeId(effectiveSessionId)} '
        'messageId=${AppLog.safeId(messageRef.id)}',
      );

      _messageController.clear();
      if (mounted) setState(() {});
      _scrollToBottom();
    } catch (error) {
      identityComplete = _callRepository.sessionIdentityLooksComplete(
        session: effectiveSession,
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );
      directionComplete = _callRepository.sessionDirectionLooksComplete(
        session: effectiveSession,
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );
      effectiveSessionId = _asString(
        effectiveSession['docId'],
        fallback: effectiveSessionId,
      );
      if (effectiveSessionId.isEmpty) {
        effectiveSessionId = _directionalSessionId;
      }
      if (effectiveReceiverId.isEmpty) {
        effectiveReceiverId = _otherUid;
      }

      _debugLogMessageSendFailure(
        error: error,
        sessionId: effectiveSessionId,
        senderId: _myUid,
        receiverId: effectiveReceiverId,
        identityComplete: identityComplete,
        directionComplete: directionComplete,
      );

      debugPrint(
        'chat.send_write_failed '
        'sessionId=${AppLog.safeId(effectiveSessionId)} '
        'reason=${_safeChatSendFailureReason(
          error: error,
          identityComplete: identityComplete,
          directionComplete: directionComplete,
          receiverId: effectiveReceiverId,
        )}',
      );

      if (!identityComplete) {
        _setBootstrapFailure(
          StateError('This conversation needs repair.'),
          needsRepair: true,
        );
      }
      _showSnack('Message could not be sent. Your text is still here.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _chatComposerDisabledReason({
    required bool blocked,
    required bool sessionReadyForComposer,
  }) {
    if (blocked) return 'blocked';
    if (_sending) return 'sending';
    if (_bootstrapping && !sessionReadyForComposer) return 'bootstrapping';
    if (_hasBootstrapError) return 'bootstrap_error';
    if (_navigatingAway) return 'navigating_away';
    return '';
  }

  void _handleComposerTextChanged(String value) {
    final textPresent = value.trim().isNotEmpty;
    if (_lastComposerTextPresent != textPresent) {
      _lastComposerTextPresent = textPresent;
      debugPrint('chat.composer_text_changed textPresent=$textPresent');
    }
    if (mounted) setState(() {});
  }

  void _handleComposerTap({String disabledReason = ''}) {
    final canRequestFocus = _messageFocusNode.canRequestFocus;
    debugPrint(
      'chat.composer_tap '
      'canRequestFocus=$canRequestFocus '
      'hasFocus=${_messageFocusNode.hasFocus} '
      'disabled=${disabledReason.isNotEmpty} '
      'reason=${disabledReason.isEmpty ? 'none' : disabledReason}',
    );
    if (disabledReason.isNotEmpty) {
      debugPrint(
        'chat.composer_tap_blocked '
        'reason=$disabledReason '
        'canRequestFocus=$canRequestFocus',
      );
      return;
    }
    if (!_messageFocusNode.hasFocus && canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
    _scrollToBottom();
  }

  void _useStarterMessage(String text) {
    final safe = text.trim();
    if (safe.isEmpty || _hasBootstrapError || _navigatingAway) return;
    _messageController.text = safe;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    _handleComposerTextChanged(safe);
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
  }

  void _handleSendPressed(
    Map<String, dynamic> session, {
    required String disabledReason,
  }) {
    final textPresent = _messageController.text.trim().isNotEmpty;
    debugPrint(
      'chat.send_tap '
      'textPresent=$textPresent '
      'disabled=${disabledReason.isNotEmpty} '
      'reason=${disabledReason.isEmpty ? 'none' : disabledReason}',
    );
    if (disabledReason.isNotEmpty) {
      debugPrint(
        'chat.send_tap_blocked '
        'reason=$disabledReason '
        'textPresent=$textPresent',
      );
      return;
    }
    if (!textPresent) {
      debugPrint('chat.send_tap_blocked reason=empty_text textPresent=false');
      _messageFocusNode.requestFocus();
      return;
    }
    unawaited(_sendMessage(session));
  }

  Future<void> _requestCall(Map<String, dynamic> session) async {
    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    if (_requestingCall) return;

    _dismissComposerFocus(reason: 'focus.cleared_for_call_surface');

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is not available right now.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing. Open chat first.');
      return;
    }

    if (_sessionAcceptedForUi(session)) {
      _showSnack('Call is already approved. You can call now.');
      return;
    }

    if (_sessionCallRequestOpen(session)) {
      _showSnack('Call request already sent.');
      return;
    }

    debugPrint('call_request.request_begin');
    setState(() => _requestingCall = true);
    var requestListenerId = '';

    try {
      await _ensureSessionBootstrap();
      final actualListenerId = _otherParticipantIdForSession(session);
      requestListenerId = actualListenerId;
      if (actualListenerId.isEmpty || actualListenerId == _myUid) {
        _showSnack('The other person could not be resolved for this call.');
        return;
      }

      final result = await _callRepository
          .requestCallPermissionFromListener(
            listenerId: actualListenerId,
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      switch (result) {
        case CallPermissionRequestResult.sent:
          _applyLocalCallRequest(
            speakerId: _myUid,
            listenerId: actualListenerId,
          );
          debugPrint('call_request.request_success');
          debugPrint('call_request.state_refresh_begin');
          unawaited(_refreshCallRequestStateAfterRequest(
            speakerId: _myUid,
            listenerId: actualListenerId,
          ));
          _showSnack('Call request sent.');
          break;
        case CallPermissionRequestResult.alreadyAllowed:
          _applyLocalCallApproval(
            speakerId: _myUid,
            listenerId: actualListenerId,
          );
          debugPrint('call_request.request_success');
          debugPrint('call_request.state_refresh_success');
          _showSnack('Call is already approved. You can call now.');
          break;
        case CallPermissionRequestResult.alreadyPending:
          _applyLocalCallRequest(
            speakerId: _myUid,
            listenerId: actualListenerId,
          );
          debugPrint('call_request.request_success');
          _showSnack('Call request already sent.');
          break;
        case CallPermissionRequestResult.blocked:
          debugPrint('call_request.request_failed');
          _showSnack('Calling is unavailable for this chat.');
          break;
        case CallPermissionRequestResult.invalidTarget:
          debugPrint('call_request.request_failed');
          _showSnack('This call request is not valid for this chat.');
          break;
      }
    } on TimeoutException {
      debugPrint('call_request.request_timeout');
      final latestResult = await _refreshCallRequestResultAfterTimeout(
        speakerId: _myUid,
        listenerId: requestListenerId,
      );
      if (latestResult == CallPermissionRequestResult.alreadyAllowed) {
        if (!mounted) return;
        _applyLocalCallApproval(
          speakerId: _myUid,
          listenerId: requestListenerId,
        );
        debugPrint('call_request.request_late_success');
        _showSnack('Call is already approved. You can call now.');
        return;
      }
      if (latestResult == CallPermissionRequestResult.alreadyPending) {
        if (!mounted) return;
        _applyLocalCallRequest(
          speakerId: _myUid,
          listenerId: requestListenerId,
        );
        debugPrint('call_request.request_late_success');
        _showSnack('Call request sent.');
        return;
      }
      debugPrint('call_request.request_failed reason=timeout');
      _showSnack('Call request timed out. Please retry.');
    } catch (e) {
      debugPrint('call_request.request_failed');
      _showSnack(_humanizeCallError(e));
    } finally {
      if (mounted) {
        setState(() => _requestingCall = false);
      } else {
        _requestingCall = false;
      }
    }
  }

  Future<void> _acceptCallRequest(Map<String, dynamic> session) async {
    if (_acceptingCallRequest) return;

    _dismissComposerFocus(reason: 'focus.cleared_for_call_surface');

    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    if (!_amListenerForSession(session)) {
      _showSnack('Only the listener can approve this call request.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing.');
      return;
    }

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is not available right now.');
      return;
    }

    if (_sessionAcceptedForUi(session)) {
      debugPrint('call_request.accept_skipped_already_accepted');
      _showSnack('Call is already approved.');
      return;
    }

    final requestedBy = _sessionCallRequestedBy(session);
    if (!_sessionCallRequestOpen(session) || requestedBy.isEmpty) {
      _showSnack('There is no call request to approve right now.');
      return;
    }

    final speakerId = _actualRequesterIdForSession(session);
    final listenerId = _actualListenerIdForSession(session);
    if (speakerId.isEmpty || listenerId.isEmpty || speakerId == listenerId) {
      _showSnack('This call request is not valid for this chat.');
      return;
    }

    debugPrint('call_request.accept_begin');
    setState(() => _acceptingCallRequest = true);

    try {
      await _ensureSessionBootstrap();

      await _callRepository
          .markListenerAllowedCall(
            speakerId: speakerId,
            listenerId: listenerId,
          )
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      _applyLocalCallApproval(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      debugPrint('call_request.accept_success');
      debugPrint('call_request.state_refresh_begin');
      unawaited(_refreshCallRequestStateAfterAccept(
        speakerId: speakerId,
        listenerId: listenerId,
      ));
      _showSnack('Call approved.');
    } on TimeoutException {
      debugPrint('call_request.accept_timeout');
      debugPrint('call_request.accept_timeout_refresh_begin');
      final acceptedAfterTimeout = await _refreshAcceptedCallStateAfterTimeout(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      if (acceptedAfterTimeout) {
        if (!mounted) return;
        _applyLocalCallApproval(
          speakerId: speakerId,
          listenerId: listenerId,
        );
        debugPrint('call_request.accept_timeout_resolved_as_success');
        debugPrint('call_request.accept_success');
        _showSnack('Call approved.');
        return;
      }
      debugPrint('call_request.accept_late_success_pending');
      _showSnack('Still syncing call approval. Please wait a moment.');
      unawaited(
        Future<void>.delayed(const Duration(seconds: 3)).then((_) async {
          if (!mounted) return;
          final acceptedLater = await _refreshAcceptedCallStateAfterTimeout(
            speakerId: speakerId,
            listenerId: listenerId,
          );
          if (!mounted || !acceptedLater) return;
          _applyLocalCallApproval(
            speakerId: speakerId,
            listenerId: listenerId,
          );
          debugPrint('call_request.accept_late_success');
          _showSnack('Call approved.');
        }),
      );
    } catch (e) {
      debugPrint('call_request.accept_failed');
      _showSnack(_humanizeCallError(e));
    } finally {
      if (mounted) {
        setState(() => _acceptingCallRequest = false);
      } else {
        _acceptingCallRequest = false;
      }
    }
  }

  /// The chat Call action opens this person's call-setup step (matching the
  /// prototype): pick a duration, see the estimated max cost, then Start. The
  /// setup screen runs the same createCallToListener flow. Falls back to the
  /// direct start only if the users aren't resolved yet.
  void _openCallSetup(
    Map<String, dynamic> session, {
    String otherName = 'The other person',
    AppUserModel? me,
    AppUserModel? otherUser,
  }) {
    if (me == null || otherUser == null) {
      _startCall(session, otherName: otherName, me: me, otherUser: otherUser);
      return;
    }
    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }
    _dismissComposerFocus(reason: 'focus.cleared_for_call_surface');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallSetupScreen(listener: otherUser, me: me),
      ),
    );
  }

  Future<void> _startCall(
    Map<String, dynamic> session, {
    String otherName = 'The other person',
    AppUserModel? me,
    AppUserModel? otherUser,
  }) async {
    debugPrint('call.start_tap');
    debugPrint('call.tap_call_now');
    _dismissComposerFocus(reason: 'focus.cleared_for_call_surface');

    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    debugPrint('call.start_local_preflight_begin');
    final localFailure = _startLocalPreflightFailureReason(
      session,
      me: me,
      otherUser: otherUser,
    );
    if (localFailure == 'pending_start') {
      if (_loadingCall || _callStartInFlight) {
        debugPrint('call.start_tap_locked');
      }
      debugPrint('call.start_duplicate_tap_ignored');
      return;
    }
    if (localFailure.isNotEmpty) {
      _blockStartLocally(localFailure, otherName: otherName);
      return;
    }

    if (_loadingCall || _callStartInFlight) {
      debugPrint('call.start_tap_locked');
      debugPrint('call.start_duplicate_tap_ignored');
      return;
    }

    if (_callStartCooldownActive) {
      debugPrint('call.start_duplicate_tap_ignored');
      return;
    }

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is not available right now.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing. Open chat first.');
      return;
    }

    if (!_effectiveSessionCallAllowed(session)) {
      debugPrint('call.start_local_preflight_blocked reason=not_accepted');
      _showSnack('This call is not approved yet. Send a request first.');
      return;
    }

    setState(() {
      _loadingCall = true;
      _callStartInFlight = true;
    });

    try {
      final actualListenerId = _actualListenerIdForSession(session);
      debugPrint('call.start_callable_begin');
      final callStart = await _callRepository.createCallToListener(
        listenerId: actualListenerId,
      );

      if (callStart == null) {
        debugPrint('call.start_callable_failed reason=null_result');
        _showSnack('Call could not be started.');
        _beginCallStartCooldown();
        return;
      }

      if (!callStart.canOpenWaitingScreen) {
        debugPrint('call.start_callable_failed reason=missing_channel');
        _showSnack('Call setup is incomplete. Please try again.');
        _beginCallStartCooldown();
        return;
      }

      if (!mounted) return;

      debugPrint(
        'call.start_outgoing_flow_begin '
        'callId=${AppLog.safeId(callStart.callRef.id)} '
        'tokenPresent=${callStart.agoraToken.trim().isNotEmpty} '
        'channelIdPresent=${callStart.channelId.trim().isNotEmpty} '
        'agoraUidPresent=${callStart.agoraUid > 0}',
      );

      _dismissComposerFocus(reason: 'focus.cleared_for_call_surface');
      _setNavigatingAway(true);
      try {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallerWaitingScreen(
              callDocRef: callStart.callRef,
              initialAgoraToken: callStart.agoraToken,
              initialAgoraUid: callStart.agoraUid,
              initialChannelId: callStart.channelId,
            ),
          ),
        );
      } finally {
        if (mounted) {
          _setNavigatingAway(false);
        }
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('call.start_callable_failed reason=${e.code}');
      _showSnack(_humanizeCallError(e, otherName: otherName));
      _beginCallStartCooldown();
    } catch (e) {
      debugPrint(
        'call.start_callable_failed reason=unknown '
        '${_formatCallStartErrorDebugDetails(e)}',
      );
      _showSnack(_humanizeCallError(e, otherName: otherName));
      _beginCallStartCooldown();
    } finally {
      if (mounted) {
        setState(() {
          _loadingCall = false;
          _callStartInFlight = false;
        });
      } else {
        _loadingCall = false;
        _callStartInFlight = false;
      }
    }
  }

  Color _statusColor(Map<String, dynamic> session) {
    if (_sessionIsBlocked(session)) return const Color(0xFFDC2626);
    if (_hasBlockingCallState) return AppPalette.blue;
    if (!_sessionExists(session)) return AppPalette.textSecondary;
    if (_sessionAcceptedForUi(session)) return AppPalette.online;
    if (_sessionCallRequestOpen(session)) return const Color(0xFFF59E0B);
    return AppPalette.blue;
  }

  String _statusText(Map<String, dynamic> session) {
    final amListenerForSession = _amListenerForSession(session);
    if (_sessionIsBlocked(session)) return 'Chat unavailable';
    if (_hasBlockingCallState) return 'Call in progress';
    if (!_sessionExists(session)) return 'Start chatting first';
    if (_sessionAcceptedForUi(session)) {
      return amListenerForSession ? 'Call approved' : 'Ready to call';
    }
    if (_sessionCallRequestOpen(session)) {
      return amListenerForSession
          ? 'Approve call request?'
          : 'Approval pending';
    }
    return 'Chat active';
  }

  Future<String> _recentSharedCallId(String otherUserId) async {
    final safeOtherUserId = otherUserId.trim();
    if (safeOtherUserId.isEmpty || _myUid.isEmpty) return '';

    final activeCallId = _callSession.callDocRef?.id.trim() ?? '';
    if (activeCallId.isNotEmpty) {
      final activeCall = _callSession.call;
      final callerId = _asString(activeCall[FirestorePaths.fieldCallerId]);
      final calleeId = _asString(activeCall[FirestorePaths.fieldCalleeId]);
      final matchesActiveCall =
          (callerId == _myUid && calleeId == safeOtherUserId) ||
              (callerId == safeOtherUserId && calleeId == _myUid);
      if (matchesActiveCall) {
        return activeCallId;
      }
    }

    final recentCalls = await _callRepository.fetchRecentCalls(limit: 50);
    for (final call in recentCalls) {
      final matches =
          (call.callerId == _myUid && call.calleeId == safeOtherUserId) ||
              (call.callerId == safeOtherUserId && call.calleeId == _myUid);
      if (matches) {
        return call.id.trim();
      }
    }

    return '';
  }

  Future<void> _openHelpResources() async {
    _dismissComposerFocus();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const CrisisHelpScreen(),
      ),
    );
  }

  Future<void> _reportOtherUser(AppUserModel? otherUser) async {
    if (_reportingUser) return;

    final otherUserId = (otherUser?.uid ?? _otherUid).trim();
    if (otherUserId.isEmpty) {
      _showSnack('Unable to identify the other user.');
      return;
    }

    final reason = await showUserSafetyReportReasonSheet(
      context,
      title: 'Report user',
    );
    if (!mounted) return;
    if (reason == null || reason.trim().isEmpty) return;

    setState(() => _reportingUser = true);

    try {
      final callId = await _recentSharedCallId(otherUserId);
      if (callId.isEmpty) {
        _showSnack('Report is available after you have a call with this user.');
        return;
      }

      await FirestoreService.report(
        reportedUserId: otherUserId,
        callId: callId,
        reason: reason,
      );

      _showSnack('Report submitted.');
    } catch (e) {
      _showSnack('Report failed. Please try again.');
      if (kDebugMode) {
        debugPrint('Chat report failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _reportingUser = false);
      } else {
        _reportingUser = false;
      }
    }
  }

  Future<void> _refreshCallRequestStateAfterRequest({
    required String speakerId,
    required String listenerId,
  }) async {
    try {
      await _callRepository.getChatSessionByPair(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      debugPrint('call_request.state_refresh_success');
    } catch (_) {
      debugPrint('call_request.state_refresh_failed');
    }
  }

  Future<void> _refreshCallRequestStateAfterAccept({
    required String speakerId,
    required String listenerId,
  }) async {
    try {
      await _callRepository.getChatSessionByPair(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      debugPrint('call_request.state_refresh_success');
    } catch (_) {
      debugPrint('call_request.state_refresh_failed');
    }
  }

  Future<CallPermissionRequestResult?> _refreshCallRequestResultAfterTimeout({
    required String speakerId,
    required String listenerId,
  }) async {
    try {
      final session = await _callRepository
          .getChatSessionByPair(
            speakerId: speakerId,
            listenerId: listenerId,
          )
          .timeout(const Duration(seconds: 4));

      if (_callRepository.sessionAllowsCallForDirection(
        session: session,
        speakerId: speakerId,
        listenerId: listenerId,
      )) {
        debugPrint('call_request.state_refresh_success');
        return CallPermissionRequestResult.alreadyAllowed;
      }

      if (_callRepository.sessionHasPendingRequestForDirection(
        session: session,
        speakerId: speakerId,
        listenerId: listenerId,
      )) {
        debugPrint('call_request.state_refresh_success');
        return CallPermissionRequestResult.alreadyPending;
      }

      return null;
    } catch (_) {
      debugPrint('call_request.state_refresh_failed');
      return null;
    }
  }

  Future<bool> _refreshAcceptedCallStateAfterTimeout({
    required String speakerId,
    required String listenerId,
  }) async {
    try {
      final session = await _callRepository
          .getChatSessionByPair(
            speakerId: speakerId,
            listenerId: listenerId,
          )
          .timeout(const Duration(seconds: 4));

      final accepted = _callRepository.sessionAllowsCallForDirection(
        session: session,
        speakerId: speakerId,
        listenerId: listenerId,
      );
      if (accepted) {
        debugPrint('call_request.state_refresh_success');
      }
      return accepted;
    } catch (_) {
      debugPrint('call_request.state_refresh_failed');
      return false;
    }
  }

  Future<void> _blockOtherUser(AppUserModel? otherUser) async {
    if (_blockingUser) return;

    final otherUserId = (otherUser?.uid ?? _otherUid).trim();
    if (otherUserId.isEmpty) {
      _showSnack('Unable to identify the other user.');
      return;
    }

    final confirmed = await showBlockUserConfirmationDialog(
      context,
      userName: userSafetyDisplayName(otherUser),
    );
    if (!mounted || !confirmed) return;

    setState(() => _blockingUser = true);

    try {
      await FirestoreService.blockUser(otherUserId);
      _dismissComposerFocus();
      _showSnack('User blocked. Chat unavailable.');
    } catch (e) {
      _showSnack('Could not block this user. Please try again.');
      if (kDebugMode) {
        debugPrint('Chat block failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _blockingUser = false);
      } else {
        _blockingUser = false;
      }
    }
  }

  Map<String, dynamic> _sessionWithSafetyOverrides({
    required Map<String, dynamic> session,
    AppUserModel? me,
    AppUserModel? otherUser,
  }) {
    final blockedByUsers = userSafetyBlockApplies(
      myUid: _myUid,
      otherUserId: (otherUser?.uid ?? _otherUid).trim(),
      myBlockedUserIds: me?.blocked ?? const <String>[],
      otherBlockedUserIds: otherUser?.blocked ?? const <String>[],
    );

    final speakerId = _actualSpeakerIdForSession(session);
    final listenerId = _actualListenerIdForSession(session);
    final localApprovalApplies = _localCallApprovalAtMs > 0 &&
        _localCallApprovalSpeakerId == speakerId &&
        _localCallApprovalListenerId == listenerId;
    final participantIds = _participantsForSession(session);
    final localRequestApplies = _localCallRequestAtMs > 0 &&
        !_sessionCallAllowed(session) &&
        participantIds.contains(_localCallRequestSpeakerId) &&
        participantIds.contains(_localCallRequestListenerId) &&
        _localCallRequestSpeakerId != _localCallRequestListenerId;

    if (!blockedByUsers && !localApprovalApplies && !localRequestApplies) {
      return session;
    }

    final effective = <String, dynamic>{
      ...session,
    };

    if (blockedByUsers) {
      effective[FirestorePaths.fieldSpeakerBlocked] = true;
      effective[FirestorePaths.fieldListenerBlocked] = true;
    }

    if (localApprovalApplies) {
      effective[FirestorePaths.fieldCallAllowed] = true;
      effective[FirestorePaths.fieldCallAllowedAtMs] = _localCallApprovalAtMs;
      effective[FirestorePaths.fieldCallRequestOpen] = false;
      effective[FirestorePaths.fieldCallRequestedBy] = speakerId;
      effective[FirestorePaths.fieldRequesterId] = speakerId;
      effective[FirestorePaths.fieldResponderId] = listenerId;
      effective[FirestorePaths.fieldActualListenerId] = listenerId;
    } else if (localRequestApplies) {
      effective[FirestorePaths.fieldCallAllowed] = false;
      effective[FirestorePaths.fieldCallAllowedAtMs] = 0;
      effective[FirestorePaths.fieldCallRequestOpen] = true;
      effective[FirestorePaths.fieldCallRequestedBy] =
          _localCallRequestSpeakerId;
      effective[FirestorePaths.fieldRequesterId] = _localCallRequestSpeakerId;
      effective[FirestorePaths.fieldResponderId] = _localCallRequestListenerId;
      effective[FirestorePaths.fieldPendingFor] = _localCallRequestListenerId;
      effective[FirestorePaths.fieldActualListenerId] =
          _localCallRequestListenerId;
      effective[FirestorePaths.fieldCallRequestAtMs] = _localCallRequestAtMs;
    }

    return effective;
  }

  String _callRequestUiStateName(_CallRequestUiState state) {
    switch (state) {
      case _CallRequestUiState.none:
        return 'none';
      case _CallRequestUiState.pendingByMe:
        return 'pending_by_me';
      case _CallRequestUiState.pendingForMe:
        return 'pending_for_me';
      case _CallRequestUiState.acceptedSpeaker:
        return 'accepted_speaker';
      case _CallRequestUiState.acceptedListener:
        return 'accepted_listener';
      case _CallRequestUiState.acceptedSpeakerPaused:
        return 'accepted_speaker_paused';
      case _CallRequestUiState.acceptedListenerPaused:
        return 'accepted_listener_paused';
      case _CallRequestUiState.syncingAccepted:
        return 'syncing_accepted';
      case _CallRequestUiState.selfOnlyChatMode:
        return 'self_only_chat_mode';
      case _CallRequestUiState.peerOnlyChatMode:
        return 'peer_only_chat_mode';
      case _CallRequestUiState.blockedOrUnavailable:
        return 'blocked_or_unavailable';
      case _CallRequestUiState.loading:
        return 'loading';
      case _CallRequestUiState.error:
        return 'error';
    }
  }

  String _currentUserRoleForSession(Map<String, dynamic> session) {
    if (!_sessionHasCallRoleState(session)) return 'none';
    final explicitRole = _explicitCallRoleForCurrentUser(session);
    if (explicitRole.isNotEmpty) return explicitRole;
    if (_actualSpeakerIdForSession(session) == _myUid) return 'speaker';
    if (_actualListenerIdForSession(session) == _myUid) return 'listener';
    return 'none';
  }

  String _explicitCallRoleForCurrentUser(Map<String, dynamic> session) {
    final myUid = _myUid.trim();
    if (myUid.isEmpty || !_sessionHasCallRoleState(session)) return '';

    final requesterId = _sessionRequesterId(session);
    final responderId = _sessionResponderId(session);
    final pendingFor = _asString(session[FirestorePaths.fieldPendingFor]);
    final requestedBy = _sessionCallRequestedBy(session);
    final participants = _participantsForSession(session).toSet();

    if (requesterId.isNotEmpty) {
      if (requesterId == myUid) return 'speaker';
      if (responderId == myUid || pendingFor == myUid) return 'listener';
      if (participants.contains(myUid) && requesterId != myUid) {
        return 'listener';
      }
    }

    if (requestedBy.isNotEmpty) {
      if (requestedBy == myUid) return 'speaker';
      if (pendingFor == myUid) return 'listener';
      if (participants.contains(myUid) && requestedBy != myUid) {
        return 'listener';
      }
    }

    return '';
  }

  bool _sessionAcceptedForUi(Map<String, dynamic> session) {
    return chatSessionHasAcceptedCallAccessForUi(session);
  }

  void _scheduleAcceptedStateRepair(Map<String, dynamic> session) {
    final inferredSpeakerId = _actualSpeakerIdForSession(session).isNotEmpty
        ? _actualSpeakerIdForSession(session)
        : _requestedSpeakerId;
    final inferredListenerId = _actualListenerIdForSession(session).isNotEmpty
        ? _actualListenerIdForSession(session)
        : _requestedProductListenerId;
    final participants = _participantsForSession(session);

    if (inferredSpeakerId.isEmpty ||
        inferredListenerId.isEmpty ||
        inferredSpeakerId == inferredListenerId) {
      return;
    }
    if (participants.isNotEmpty &&
        (!participants.contains(inferredSpeakerId) ||
            !participants.contains(inferredListenerId))) {
      return;
    }

    final key = '$inferredSpeakerId::$inferredListenerId';
    if (_acceptedStateRepairLastAttemptAt.containsKey(key)) return;
    if (!_acceptedStateRepairInFlight.add(key)) return;
    _acceptedStateRepairLastAttemptAt[key] = DateTime.now();

    unawaited(() async {
      try {
        debugPrint('call_request.accepted_state_repair_once');
        await _callRepository.ensureChatSessionByPair(
          speakerId: inferredSpeakerId,
          listenerId: inferredListenerId,
        );
        debugPrint('call_request.accepted_state_repair_success');
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'call_request.accepted_state_repair_failed error=${e.runtimeType}',
          );
        }
      } finally {
        _acceptedStateRepairInFlight.remove(key);
      }
    }());
  }

  void _tracePartialAcceptedState(
    String eventName,
    Map<String, dynamic> session,
  ) {
    final requestOpen = _sessionCallRequestOpen(session);
    final callAllowed = _sessionCallAllowed(session);
    final effectiveCallAllowed = _effectiveSessionCallAllowed(session);
    final signature = [
      eventName,
      _asString(session[FirestorePaths.fieldChatStatus]),
      _sessionCallRequestedBy(session).isNotEmpty,
      _asString(session[FirestorePaths.fieldPendingFor]).isNotEmpty,
      requestOpen,
      callAllowed,
      effectiveCallAllowed,
      _actualSpeakerIdForSession(session).isNotEmpty,
      _actualListenerIdForSession(session).isNotEmpty,
    ].join('|');
    if (_lastPartialAcceptedTrace == signature) return;
    _lastPartialAcceptedTrace = signature;
    debugPrint(
      '$eventName '
      'chatStatus=${_asString(session[FirestorePaths.fieldChatStatus])} '
      'requestedByPresent=${_sessionCallRequestedBy(session).isNotEmpty} '
      'requestedToPresent=${_asString(session[FirestorePaths.fieldPendingFor]).isNotEmpty} '
      'requestOpen=$requestOpen '
      'callAllowed=$callAllowed '
      'effectiveCallAllowed=$effectiveCallAllowed '
      'speakerUidPresent=${_actualSpeakerIdForSession(session).isNotEmpty} '
      'listenerUidPresent=${_actualListenerIdForSession(session).isNotEmpty}',
    );
  }

  _CallRequestUiState _resolveCallRequestUiState({
    required Map<String, dynamic> session,
    required AppUserModel? me,
    required AppUserModel? otherUser,
  }) {
    if (_hasBootstrapError) return _CallRequestUiState.error;
    if (!_sessionExists(session)) return _CallRequestUiState.loading;
    if (_sessionIsBlocked(session)) {
      return _CallRequestUiState.blockedOrUnavailable;
    }

    final requestedBy = _sessionCallRequestedBy(session);
    if (_sessionAcceptedForUi(session)) {
      final effectiveCallAllowed = _effectiveSessionCallAllowed(session);
      if (_sessionCallRequestOpen(session) ||
          !effectiveCallAllowed ||
          _actualSpeakerIdForSession(session).isEmpty ||
          _actualListenerIdForSession(session).isEmpty) {
        _tracePartialAcceptedState(
          'call_request.accepted_state_conflict_detected',
          session,
        );
        _scheduleAcceptedStateRepair(session);
      }

      _CallRequestUiState pauseIfNeeded(_CallRequestUiState state) {
        if (state == _CallRequestUiState.acceptedSpeaker) {
          if (_isOnlyChatMode(me) || _isOnlyChatMode(otherUser)) {
            return _CallRequestUiState.acceptedSpeakerPaused;
          }
        }
        if (state == _CallRequestUiState.acceptedListener) {
          if (_isOnlyChatMode(me) || _isOnlyChatMode(otherUser)) {
            return _CallRequestUiState.acceptedListenerPaused;
          }
        }
        return state;
      }

      _CallRequestUiState rememberStable(_CallRequestUiState state) {
        _lastStableAcceptedCallRequestState = state;
        return state;
      }

      _CallRequestUiState safeFallback() {
        _tracePartialAcceptedState(
          'call_request.accepted_state_safe_fallback',
          session,
        );
        _scheduleAcceptedStateRepair(session);
        final lastStable = _lastStableAcceptedCallRequestState;
        if (lastStable != null) return lastStable;
        return _CallRequestUiState.syncingAccepted;
      }

      final explicitRole = _explicitCallRoleForCurrentUser(session);
      if (explicitRole == 'speaker') {
        return rememberStable(
          pauseIfNeeded(_CallRequestUiState.acceptedSpeaker),
        );
      }
      if (explicitRole == 'listener') {
        return rememberStable(
          pauseIfNeeded(_CallRequestUiState.acceptedListener),
        );
      }

      final actualSpeakerId = _actualSpeakerIdForSession(session);
      final actualListenerId = _actualListenerIdForSession(session);
      if (actualSpeakerId == _myUid) {
        return rememberStable(
          pauseIfNeeded(_CallRequestUiState.acceptedSpeaker),
        );
      }
      if (actualListenerId == _myUid) {
        return rememberStable(
          pauseIfNeeded(_CallRequestUiState.acceptedListener),
        );
      }

      return safeFallback();
    }

    if (_callBlockedByLocalOrProfile(me: me, otherUser: otherUser)) {
      return _CallRequestUiState.blockedOrUnavailable;
    }

    if (_isOnlyChatMode(me)) return _CallRequestUiState.selfOnlyChatMode;
    if (_isOnlyChatMode(otherUser)) return _CallRequestUiState.peerOnlyChatMode;

    if (_sessionCallRequestOpen(session) && requestedBy.isNotEmpty) {
      return requestedBy == _myUid
          ? _CallRequestUiState.pendingByMe
          : _CallRequestUiState.pendingForMe;
    }

    return _CallRequestUiState.none;
  }

  void _traceCallRequestRender({
    required _CallRequestUiState state,
    required Map<String, dynamic> session,
    required bool startEnabled,
    required bool startButtonVisible,
    required String startButtonDisabledReason,
  }) {
    final stateName = _callRequestUiStateName(state);
    final callActorRole = _currentUserRoleForSession(session);
    final signature = [
      'state=$stateName',
      'chatStatus=${_asString(session[FirestorePaths.fieldChatStatus])}',
      'requestedBy=${_sessionCallRequestedBy(session).isNotEmpty}',
      'requestedTo=${_asString(session[FirestorePaths.fieldPendingFor]).isNotEmpty}',
      'requestOpen=${_sessionCallRequestOpen(session)}',
      'callAllowed=${_sessionCallAllowed(session)}',
      'callAccessApproved=${_sessionAcceptedForUi(session)}',
      'effectiveAllowed=${_effectiveSessionCallAllowed(session)}',
      'speaker=${_actualSpeakerIdForSession(session).isNotEmpty}',
      'listener=${_actualListenerIdForSession(session).isNotEmpty}',
      'actorRole=$callActorRole',
      'start=$startEnabled',
      'startVisible=$startButtonVisible',
      'startDisabledReason=$startButtonDisabledReason',
    ].join('|');
    if (_lastCallRequestRenderTrace == signature) return;
    _lastCallRequestRenderTrace = signature;

    debugPrint(
      'call_request.render_state '
      'state=$stateName '
      'chatStatus=${_asString(session[FirestorePaths.fieldChatStatus])} '
      'requestedByPresent=${_sessionCallRequestedBy(session).isNotEmpty} '
      'requestedToPresent=${_asString(session[FirestorePaths.fieldPendingFor]).isNotEmpty} '
      'requestOpen=${_sessionCallRequestOpen(session)} '
      'callAllowed=${_sessionCallAllowed(session)} '
      'callAccessApproved=${_sessionAcceptedForUi(session)} '
      'effectiveCallAllowed=${_effectiveSessionCallAllowed(session)} '
      'speakerUidPresent=${_actualSpeakerIdForSession(session).isNotEmpty} '
      'listenerUidPresent=${_actualListenerIdForSession(session).isNotEmpty} '
      'callActorRole=$callActorRole',
    );
    debugPrint('call_request.role_resolved callActorRole=$callActorRole');
    if (startButtonVisible) {
      debugPrint('call.start_button_visible');
      if (!startEnabled) {
        debugPrint(
          'call.start_button_disabled reason=$startButtonDisabledReason',
        );
      }
    }
    if (startEnabled) {
      debugPrint('call_request.call_now_enabled');
    }
  }

  String _statusSubtitle(Map<String, dynamic> session) {
    final amListenerForSession = _amListenerForSession(session);
    if (_sessionIsBlocked(session)) {
      return 'Chat and calling are unavailable for this conversation.';
    }
    if (_hasBlockingCallState) {
      return 'Finish your current call before starting another one.';
    }
    if (!_sessionExists(session)) {
      return 'Send a message first to start this chat.';
    }
    if (_sessionAcceptedForUi(session)) {
      return amListenerForSession
          ? 'You approved this call.'
          : 'Your call is approved and ready to start.';
    }
    if (_sessionCallRequestOpen(session)) {
      return amListenerForSession
          ? 'The other person wants to call you.'
          : 'Your call request was sent. Waiting for approval.';
    }
    return 'You can keep chatting here. Calls need listener approval first.';
  }

  Widget _statusBanner(Map<String, dynamic> session) {
    final color = _statusColor(session);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.info_outline_rounded, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusText(session),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _statusSubtitle(session),
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isOnlyChatMode(AppUserModel? user) {
    return user?.onlyChatMode == true;
  }

  Widget _callSection(
    Map<String, dynamic> session, {
    AppUserModel? me,
    AppUserModel? otherUser,
  }) {
    final exists = _sessionExists(session);
    final currentUserOnlyChat = _isOnlyChatMode(me);
    final otherUserOnlyChat = _isOnlyChatMode(otherUser);
    final callModeBlocked = currentUserOnlyChat || otherUserOnlyChat;
    final callBlockedByState = _callBlockedByLocalOrProfile(
      me: me,
      otherUser: otherUser,
    );
    final otherName = otherUser?.safeDisplayName.trim().isNotEmpty == true
        ? otherUser!.safeDisplayName
        : 'The other person';
    final uiState = _resolveCallRequestUiState(
      session: session,
      me: me,
      otherUser: otherUser,
    );

    final effectiveCallAllowed = _effectiveSessionCallAllowed(session);
    final acceptedSpeaker = uiState == _CallRequestUiState.acceptedSpeaker;
    final acceptedListener = uiState == _CallRequestUiState.acceptedListener;
    final acceptedSpeakerPaused =
        uiState == _CallRequestUiState.acceptedSpeakerPaused;
    final acceptedListenerPaused =
        uiState == _CallRequestUiState.acceptedListenerPaused;
    final pendingForMe = uiState == _CallRequestUiState.pendingForMe;
    final pendingByMe = uiState == _CallRequestUiState.pendingByMe;
    final canRequest = uiState == _CallRequestUiState.none;
    final showStartButton = acceptedSpeaker;
    final showActionButton = canRequest || pendingForMe || showStartButton;
    final requiredUsableCredit = _minimumRequiredUsableCredit(otherUser);
    final knownInsufficientCredit = acceptedSpeaker &&
        me != null &&
        otherUser != null &&
        me.usableCredits < requiredUsableCredit;

    final title = switch (uiState) {
      _CallRequestUiState.none => 'Request Call',
      _CallRequestUiState.pendingByMe => 'Request sent',
      _CallRequestUiState.pendingForMe =>
        _acceptingCallRequest ? 'Accepting...' : 'Accept Call Request',
      _CallRequestUiState.acceptedSpeaker => 'You are the Speaker',
      _CallRequestUiState.acceptedListener => 'You are the Listener',
      _CallRequestUiState.acceptedSpeakerPaused => 'Only Chat Mode is ON',
      _CallRequestUiState.acceptedListenerPaused => 'Only Chat Mode is ON',
      _CallRequestUiState.syncingAccepted => 'Syncing call access...',
      _CallRequestUiState.selfOnlyChatMode => 'Only Chat Mode is ON',
      _CallRequestUiState.peerOnlyChatMode => '$otherName is in Only Chat Mode',
      _CallRequestUiState.blockedOrUnavailable =>
        callBlockedByState ? 'Call already active' : 'Calls unavailable',
      _CallRequestUiState.loading => 'Chat is getting ready',
      _CallRequestUiState.error => 'Call request unavailable',
    };

    final subtitle = switch (uiState) {
      _CallRequestUiState.none =>
        'Ask $otherName to open voice calling for this chat.',
      _CallRequestUiState.pendingByMe => 'Waiting for $otherName to accept.',
      _CallRequestUiState.pendingForMe =>
        '$otherName wants to open a voice call with you.',
      _CallRequestUiState.acceptedSpeaker =>
        'Share your thoughts when you feel ready.',
      _CallRequestUiState.acceptedListener =>
        'Wait for the speaker to start the call. You can keep chatting meanwhile.',
      _CallRequestUiState.acceptedSpeakerPaused => currentUserOnlyChat
          ? 'Calls are paused while Only Chat Mode is ON.'
          : '$otherName is in Only Chat Mode. You can keep chatting.',
      _CallRequestUiState.acceptedListenerPaused => currentUserOnlyChat
          ? 'Calls are paused while Only Chat Mode is ON.'
          : '$otherName is in Only Chat Mode. You can keep chatting.',
      _CallRequestUiState.syncingAccepted =>
        'Call access is approved. Waiting for the latest role details.',
      _CallRequestUiState.selfOnlyChatMode =>
        'Turn it off from Home to request or receive calls.',
      _CallRequestUiState.peerOnlyChatMode =>
        'You can keep chatting, but calls are paused for now.',
      _CallRequestUiState.blockedOrUnavailable => callBlockedByState
          ? 'Finish your current call flow before starting another.'
          : 'This chat is not available right now.',
      _CallRequestUiState.loading => exists
          ? 'Loading call permissions for this chat.'
          : 'Send a message first to start this chat.',
      _CallRequestUiState.error =>
        'Could not update call request. Please try again.',
    };

    final effectiveSubtitle = knownInsufficientCredit
        ? 'Add credits before starting a call.'
        : subtitle;
    final startButtonLabel = knownInsufficientCredit
        ? 'Add credits'
        : callModeBlocked
            ? 'Calls paused'
            : (_loadingCall || _callStartInFlight
                ? 'Starting...'
                : 'Start Call');
    final buttonLabel = acceptedSpeaker
        ? startButtonLabel
        : pendingForMe
            ? (_acceptingCallRequest ? 'Accepting...' : 'Accept Call Request')
            : (_requestingCall ? 'Sending...' : 'Request Call');

    final startButtonDisabledReason = _startButtonDisabledReason(
      exists: exists,
      acceptedSpeaker: acceptedSpeaker,
      effectiveCallAllowed: effectiveCallAllowed,
      callBlockedByState: callBlockedByState,
      callModeBlocked: callModeBlocked,
      knownInsufficientCredit: knownInsufficientCredit,
    );
    final startEnabled = showStartButton &&
        startButtonDisabledReason.isEmpty &&
        !_sessionIsBlocked(session);

    final disabledStartMessage = _startButtonDisabledMessage(
      startButtonDisabledReason,
      otherName: otherName,
    );

    final effectiveStartSubtitle =
        showStartButton && !startEnabled && disabledStartMessage.isNotEmpty
            ? disabledStartMessage
            : effectiveSubtitle;

    final requestEnabled = !_hasBootstrapError &&
        !callBlockedByState &&
        exists &&
        !_sessionIsBlocked(session) &&
        !callModeBlocked &&
        canRequest &&
        !_requestingCall;

    final acceptEnabled = !_hasBootstrapError &&
        !callBlockedByState &&
        exists &&
        !_sessionIsBlocked(session) &&
        !callModeBlocked &&
        pendingForMe &&
        !_acceptingCallRequest;

    _traceCallRequestRender(
      state: uiState,
      session: session,
      startEnabled: startEnabled,
      startButtonVisible: showStartButton,
      startButtonDisabledReason: startButtonDisabledReason,
    );

    final tile = Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: acceptedSpeaker && !_hasBlockingCallState
            ? AppPalette.blueTint
            : AppPalette.feedBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: acceptedSpeaker && !_hasBlockingCallState
              ? AppPalette.blue.withValues(alpha: 0.30)
              : AppPalette.border,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackVertically = constraints.maxWidth < 360;

          final info = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (pendingByMe ||
                          pendingForMe ||
                          acceptedListener ||
                          acceptedSpeakerPaused ||
                          acceptedListenerPaused)
                      ? AppPalette.online.withValues(alpha: 0.14)
                      : AppPalette.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  acceptedSpeaker
                      ? Icons.call_rounded
                      : acceptedListener ||
                              acceptedSpeakerPaused ||
                              acceptedListenerPaused
                          ? Icons.check_rounded
                          : pendingForMe
                              ? Icons.phone_in_talk_rounded
                              : pendingByMe
                                  ? Icons.hourglass_top_rounded
                                  : uiState ==
                                              _CallRequestUiState
                                                  .selfOnlyChatMode ||
                                          uiState ==
                                              _CallRequestUiState
                                                  .peerOnlyChatMode
                                      ? Icons.chat_bubble_outline_rounded
                                      : Icons.call_outlined,
                  color: (pendingByMe ||
                          pendingForMe ||
                          acceptedListener ||
                          acceptedSpeakerPaused ||
                          acceptedListenerPaused)
                      ? AppPalette.online
                      : AppPalette.blue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: _hasBlockingCallState || acceptedSpeaker
                            ? AppPalette.blue
                            : AppPalette.textPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      effectiveStartSubtitle,
                      style: TextStyle(
                        color: _hasBlockingCallState
                            ? AppPalette.blue
                            : AppPalette.textSecondary,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

          final button = showActionButton
              ? SizedBox(
                  width: stackVertically ? double.infinity : null,
                  child: ElevatedButton(
                    onPressed: startEnabled
                        ? () => _openCallSetup(
                              session,
                              otherName: otherName,
                              me: me,
                              otherUser: otherUser,
                            )
                        : requestEnabled
                            ? () => _requestCall(session)
                            : acceptEnabled
                                ? () => _acceptCallRequest(session)
                                : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppPalette.blue,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppPalette.border,
                      disabledForegroundColor: AppPalette.textMuted,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      buttonLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
              : const SizedBox.shrink();

          final startHint = acceptedSpeaker && startEnabled
              ? Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.phone_in_talk_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                )
              : const SizedBox.shrink();

          if (!showActionButton && startEnabled) {
            return Row(
              children: [
                Expanded(child: info),
                const SizedBox(width: 10),
                startHint,
              ],
            );
          }

          if (!showActionButton) {
            return info;
          }

          if (stackVertically) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                info,
                const SizedBox(height: 12),
                button,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 10),
              Flexible(child: button),
            ],
          );
        },
      ),
    );

    return tile;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      final position = _scrollController.position.maxScrollExtent;
      _scrollController.animateTo(
        position,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  String _formatTime(dynamic createdAtMsValue) {
    return _formatChatMessageTime(createdAtMsValue);
  }

  Widget _avatarForUser(AppUserModel? user) {
    final hasPhoto = (user?.photoURL.trim() ?? '').isNotEmpty;
    final label = (user?.safeDisplayName ?? 'User').trim();
    final first = label.isNotEmpty ? label[0].toUpperCase() : 'U';

    if (hasPhoto) {
      return CircleAvatar(
        radius: 20,
        backgroundImage: NetworkImage(user!.photoURL.trim()),
      );
    }

    return CircleAvatar(
      radius: 20,
      backgroundColor: AppPalette.blueTint,
      child: Text(
        first,
        style: const TextStyle(
          color: AppPalette.blue,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _loadingIdentityLine({
    required double width,
    double height = 12,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppPalette.divider,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  Widget _loadingHeaderAvatar() {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        color: AppPalette.divider,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildAppBarTitle(
    AppUserModel? otherUser, {
    required bool blocked,
    required bool loadingIdentity,
  }) {
    if (loadingIdentity) {
      final subtitleText = blocked
          ? 'Chat unavailable'
          : _hasBlockingCallState
              ? 'Call active'
              : null;

      return Row(
        children: [
          _loadingHeaderAvatar(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _loadingIdentityLine(width: 132, height: 14),
                const SizedBox(height: 6),
                if (subtitleText != null)
                  Text(
                    subtitleText,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          blocked ? const Color(0xFFDC2626) : AppPalette.blue,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  )
                else
                  _loadingIdentityLine(width: 92, height: 10),
              ],
            ),
          ),
        ],
      );
    }

    final name = otherUser?.safeDisplayName ?? 'Friendify User';
    final availability = otherUser == null
        ? null
        : ListenerAvailabilityResolver.resolve(
            isAvailable: otherUser.isAvailable,
            isOnCall: otherUser.isOnCall,
            activeCallId: otherUser.activeCallId,
            lastSeen: otherUser.lastSeen,
          );

    final subtitle = blocked
        ? 'Chat unavailable'
        : _hasBlockingCallState
            ? 'Call active'
            : availability?.label ?? 'Identity unavailable';

    final subtitleColor = blocked
        ? const Color(0xFFDC2626)
        : _hasBlockingCallState
            ? AppPalette.blue
            : switch (availability?.kind) {
                ListenerAvailabilityKind.available => AppPalette.online,
                ListenerAvailabilityKind.onAnotherCall =>
                  const Color(0xFFDC2626),
                ListenerAvailabilityKind.checking => const Color(0xFFF59E0B),
                ListenerAvailabilityKind.offline => AppPalette.textSecondary,
                null => AppPalette.textSecondary,
              };

    return Row(
      children: [
        _avatarForUser(otherUser),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: subtitleColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _isSystemType(String type) {
    return isChatSystemMessageType(type);
  }

  Widget _systemTile(Map<String, dynamic> msg) {
    return _buildChatSystemTile(msg, formatTime: _formatTime);
  }

  Widget _messageBubble(
    Map<String, dynamic> msg, {
    required bool showTopSpacing,
  }) {
    final type = _asString(msg[FirestorePaths.fieldMessageType]);
    if (_isSystemType(type)) {
      return _systemTile(msg);
    }

    return _buildChatMessageBubble(
      msg,
      myUid: _myUid,
      showTopSpacing: showTopSpacing,
      formatTime: _formatTime,
    );
  }

  Widget _emptyState(AppUserModel? otherUser) {
    final name = otherUser?.safeDisplayName ?? '';
    final topics = otherUser?.topics.take(3).toList() ?? const <String>[];
    final starterMessages = _starterMessagesFor(otherUser);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    color: AppPalette.blue,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 24,
                        color: AppPalette.blue.withValues(
                          alpha: 0.24,
                        ),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 34,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Start your conversation',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  otherUser == null
                      ? 'Send your first message to begin the chat.'
                      : topics.isEmpty
                          ? 'Send a message to $name and begin the chat.'
                          : 'Send your first message. $name can help with ${topics.join(', ')}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: starterMessages
                      .map((message) => _starterMessageChip(message))
                      .toList(growable: false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<String> _starterMessagesFor(AppUserModel? otherUser) {
    final name = otherUser?.safeDisplayName.trim() ?? '';
    final firstName = name.isEmpty ? 'there' : name.split(RegExp(r'\s+')).first;
    final topics = otherUser?.topics
            .map((topic) => topic.trim())
            .where((topic) => topic.isNotEmpty)
            .take(2)
            .toList(growable: false) ??
        const <String>[];

    final topicText = topics.isEmpty ? '' : topics.join(' and ');
    return <String>[
      'Hi $firstName, I would like to talk for a few minutes.',
      if (topicText.isNotEmpty)
        'I saw you listen around $topicText. Can we chat?'
      else
        'I am looking for someone calm to talk to. Are you available?',
      'Can I share what is on my mind first?',
    ];
  }

  Widget _starterMessageChip(String message) {
    return ActionChip(
      label: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      avatar: const Icon(Icons.add_comment_outlined, size: 18),
      visualDensity: VisualDensity.compact,
      backgroundColor: AppPalette.blueTint,
      side: const BorderSide(
        color: AppPalette.blueTint,
      ),
      labelStyle: const TextStyle(
        color: AppPalette.blue,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
      onPressed: () => _useStarterMessage(message),
    );
  }

  Widget _composer(Map<String, dynamic> session) {
    final blocked = _sessionIsBlocked(session);

    final sessionReadyForComposer = _sessionReadyForComposer(session);
    final disabledReason = _chatComposerDisabledReason(
      blocked: blocked,
      sessionReadyForComposer: sessionReadyForComposer,
    );
    final disabled = disabledReason.isNotEmpty;
    final textPresent = _messageController.text.trim().isNotEmpty;
    final sendReady = !disabled && textPresent;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: AppPalette.card,
          border: const Border(
            top: BorderSide(color: AppPalette.border),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _handleComposerTap(
                  disabledReason: disabledReason,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppPalette.feedBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppPalette.border,
                    ),
                  ),
                  child: TextField(
                    controller: _messageController,
                    focusNode: _messageFocusNode,
                    autofocus: false,
                    canRequestFocus: !disabled,
                    enabled: !disabled,
                    cursorColor: AppPalette.blue,
                    style: const TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    minLines: 1,
                    maxLines: 5,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(2000),
                    ],
                    textInputAction: TextInputAction.newline,
                    onChanged: _handleComposerTextChanged,
                    onTap: () => _handleComposerTap(
                      disabledReason: disabledReason,
                    ),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: AppPalette.textMuted,
                        size: 20,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 42,
                        minHeight: 42,
                      ),
                      hintText: blocked
                          ? 'Chat unavailable'
                          : _hasBootstrapError
                              ? 'Chat failed to load'
                              : disabledReason == 'bootstrapping'
                                  ? 'Preparing chat...'
                                  : 'Type your message...',
                      hintStyle: const TextStyle(
                        color: AppPalette.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              height: 52,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: sendReady ? AppPalette.blue : AppPalette.feedBg,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: sendReady
                      ? [
                          BoxShadow(
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                            color: AppPalette.blue.withValues(alpha: 0.28),
                          ),
                        ]
                      : const [],
                ),
                child: IconButton(
                  onPressed: () => _handleSendPressed(
                    session,
                    disabledReason: disabledReason,
                  ),
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          Icons.send_rounded,
                          color:
                              sendReady ? Colors.white : AppPalette.textMuted,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isCollapsibleCallSystemMessage(Map<String, dynamic> message) {
    final type = _asString(message[FirestorePaths.fieldMessageType]);
    if (type == FirestorePaths.messageTypeAccessRequest ||
        type == FirestorePaths.messageTypeAccessApproved) {
      return true;
    }

    final action = _asString(message[FirestorePaths.fieldMessageSystemAction]);
    if (action == 'request_call' ||
        action == 'allow_call' ||
        action == 'call_request_sent') {
      return true;
    }

    final text = _asString(message[FirestorePaths.fieldMessageText])
        .trim()
        .toLowerCase();
    return text == 'call request sent' || text == 'call access allowed';
  }

  String _callSystemDedupKey(Map<String, dynamic> message) {
    final action = _asString(message[FirestorePaths.fieldMessageSystemAction]);
    if (action.isNotEmpty) return 'action:$action';
    final type = _asString(message[FirestorePaths.fieldMessageType]);
    final text = _asString(message[FirestorePaths.fieldMessageText])
        .trim()
        .toLowerCase();
    return '$type:$text';
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _visibleChatDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final seenCallSystemKeys = <String>{};
    var suppressed = 0;
    final visible = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    for (final doc in docs) {
      final message = doc.data();
      if (!_isCollapsibleCallSystemMessage(message)) {
        visible.add(doc);
        continue;
      }

      final key = _callSystemDedupKey(message);
      if (key.isNotEmpty && !seenCallSystemKeys.add(key)) {
        suppressed++;
        continue;
      }
      visible.add(doc);
    }

    if (suppressed > 0) {
      final signature =
          '${docs.length}|$suppressed|${seenCallSystemKeys.length}';
      if (_lastCallSystemDuplicateSignature != signature) {
        _lastCallSystemDuplicateSignature = signature;
        debugPrint(
          'call_system_message.duplicate_suppressed count=$suppressed',
        );
      }
    }

    return visible;
  }

  void _logPeerSnapshotIfVisible(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final peerDocs = docs.where((doc) {
      final senderId =
          _asString(doc.data()[FirestorePaths.fieldMessageSenderId]);
      return senderId.isNotEmpty && senderId != _myUid;
    }).toList(growable: false);
    if (peerDocs.isEmpty) return;

    final latestPeerDoc = peerDocs.last;
    final signature = '$_directionalSessionId|${peerDocs.length}|'
        '${latestPeerDoc.id}';
    if (_lastPeerSnapshotSignature == signature) return;
    _lastPeerSnapshotSignature = signature;
    debugPrint(
      'chat.peer_snapshot_received '
      'sessionId=${AppLog.safeId(_directionalSessionId)} '
      'peerMessageCount=${peerDocs.length} '
      'latestMessageId=${AppLog.safeId(latestPeerDoc.id)}',
    );
  }

  Widget _chatBody(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    AppUserModel? otherUser,
  ) {
    if (docs.isEmpty) {
      return _emptyState(otherUser);
    }

    if (docs.length != _lastRenderedMessageCount) {
      _lastRenderedMessageCount = docs.length;
      _scrollToBottom();
    }

    _scheduleVisibleMessagesSeen(docs);
    _logPeerSnapshotIfVisible(docs);
    final visibleDocs = _visibleChatDocs(docs);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      itemCount: visibleDocs.length,
      itemBuilder: (_, index) {
        final current = visibleDocs[index].data();
        final currentType = _asString(current[FirestorePaths.fieldMessageType]);
        final currentSender =
            _asString(current[FirestorePaths.fieldMessageSenderId]);

        final previousData = index > 0 ? visibleDocs[index - 1].data() : null;
        final previousSender = _asString(
          previousData?[FirestorePaths.fieldMessageSenderId],
        );
        final previousType = _asString(
          previousData?[FirestorePaths.fieldMessageType],
        );

        final showTopSpacing = index == 0 ||
            previousSender != currentSender ||
            _isSystemType(currentType) ||
            _isSystemType(previousType);

        return _messageBubble(
          current,
          showTopSpacing: showTopSpacing,
        );
      },
    );
  }

  Widget _bootstrapFailureView(AppUserModel? otherUser) {
    final mismatch = _bootstrapDirectionMismatch;
    final canOpenExisting = mismatch?.resolution.isResolved == true;
    final title = _bootstrapNeedsRepair
        ? 'This conversation needs repair'
        : mismatch != null
            ? 'Existing conversation found'
            : 'Chat could not open';
    final subtitle = _bootstrapNeedsRepair
        ? 'We could not confirm the saved speaker/listener direction for this conversation yet. Please go back and repair it before opening the chat.'
        : mismatch != null
            ? 'We stopped before opening the wrong conversation path. You can open the existing conversation safely or go back.'
            : 'Something went wrong while getting this chat ready.';

    return SafeArea(
      top: false,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: const Color(0xFFDC2626).withValues(alpha: 0.22),
                    ),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 38,
                    color: Color(0xFFDC2626),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
                if ((_bootstrapErrorMessage ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.feedBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppPalette.border,
                      ),
                    ),
                    child: Text(
                      _bootstrapErrorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppPalette.textSecondary,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (canOpenExisting)
                  ElevatedButton.icon(
                    onPressed: _openExistingConversationDirection,
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    label: const Text('Open conversation'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: _retryBootstrap,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () {
                    _dismissComposerFocus();
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bootstrapLoadingView() {
    return const Center(
      child: CircularProgressIndicator(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _callSession,
      builder: (_, __) {
        return StreamBuilder<AppUserModel?>(
          stream: _otherUserStream,
          initialData: widget.initialOtherUser,
          builder: (_, otherUserSnap) {
            final otherUser = otherUserSnap.data;
            final loadingIdentity = otherUser == null &&
                otherUserSnap.connectionState == ConnectionState.waiting;

            return FutureBuilder<void>(
              future: _bootstrapFuture,
              builder: (_, bootstrapSnap) {
                final bootstrapWaiting =
                    bootstrapSnap.connectionState == ConnectionState.waiting ||
                        _bootstrapping;
                final bootstrapFailed =
                    bootstrapSnap.hasError || _hasBootstrapError;

                return StreamBuilder<Map<String, dynamic>>(
                  stream: _callRepository.watchChatSessionByPair(
                    speakerId: _requestedSpeakerId,
                    listenerId: _requestedListenerId,
                  ),
                  builder: (_, sessionSnap) {
                    final session = sessionSnap.data ??
                        <String, dynamic>{
                          FirestorePaths.fieldSpeakerId: _requestedSpeakerId,
                          FirestorePaths.fieldListenerId: _requestedListenerId,
                          FirestorePaths.fieldParticipantIds:
                              _canonicalRequestedPair,
                          FirestorePaths.fieldPairKey: _directionalSessionId,
                          FirestorePaths.fieldActualListenerId:
                              _actualListenerIdForSession(),
                          FirestorePaths.fieldChatStatus:
                              FirestorePaths.chatStatusNone,
                          FirestorePaths.fieldCallAllowed: false,
                          FirestorePaths.fieldCallRequestOpen: false,
                          FirestorePaths.fieldCallRequestedBy: '',
                          FirestorePaths.fieldSpeakerBlocked: false,
                          FirestorePaths.fieldListenerBlocked: false,
                          'exists': false,
                          'docId': _directionalSessionId,
                          'canonicalDocId': _directionalSessionId,
                        };
                    return StreamBuilder<AppUserModel?>(
                      stream: _meStream,
                      builder: (_, meSnap) {
                        final me = meSnap.data;
                        final effectiveSession = _sessionWithSafetyOverrides(
                          session: session,
                          me: me,
                          otherUser: otherUser,
                        );
                        final sessionDocId = _asString(
                          effectiveSession['docId'],
                          fallback: _directionalSessionId,
                        );
                        final useCanonicalSession =
                            _sessionLooksCanonical(effectiveSession) &&
                                sessionDocId == _directionalSessionId;
                        final effectiveSessionRef = _db
                            .collection(FirestorePaths.chatSessions)
                            .doc(_directionalSessionId);
                        final blocked = _sessionIsBlocked(effectiveSession);

                        if (!bootstrapFailed &&
                            useCanonicalSession &&
                            (_resolvedSessionDocId != _directionalSessionId ||
                                _resolvedSessionRef?.path !=
                                    effectiveSessionRef.path)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            setState(() {
                              _resolvedSessionDocId = _directionalSessionId;
                              _resolvedSessionRef = effectiveSessionRef;
                            });
                          });
                        }

                        return GestureDetector(
                          onTap: _dismissComposerFocus,
                          child: PopScope(
                            canPop: true,
                            onPopInvokedWithResult: (didPop, result) {
                              _dismissComposerFocus();
                            },
                            child: Scaffold(
                              backgroundColor: AppPalette.pageBg,
                              appBar: AppBar(
                                elevation: 0,
                                scrolledUnderElevation: 0,
                                backgroundColor: AppPalette.card,
                                foregroundColor: AppPalette.textPrimary,
                                surfaceTintColor: Colors.transparent,
                                systemOverlayStyle: SystemUiOverlayStyle.dark,
                                titleSpacing: 8,
                                title: _buildAppBarTitle(
                                  otherUser,
                                  blocked: blocked,
                                  loadingIdentity: loadingIdentity,
                                ),
                                actions: [
                                  PopupMenuButton<UserSafetyAction>(
                                    tooltip: 'Safety actions',
                                    icon: const Icon(
                                      Icons.shield_outlined,
                                      color: AppPalette.blue,
                                    ),
                                    color: AppPalette.card,
                                    surfaceTintColor: Colors.transparent,
                                    onSelected: (action) async {
                                      switch (action) {
                                        case UserSafetyAction.reportUser:
                                          await _reportOtherUser(otherUser);
                                          break;
                                        case UserSafetyAction.blockUser:
                                          await _blockOtherUser(otherUser);
                                          break;
                                        case UserSafetyAction.help:
                                          await _openHelpResources();
                                          break;
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem<UserSafetyAction>(
                                        value: UserSafetyAction.reportUser,
                                        enabled: !_reportingUser,
                                        child: const Text(
                                          'Report user',
                                          style: TextStyle(
                                            color: AppPalette.textPrimary,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      PopupMenuItem<UserSafetyAction>(
                                        value: UserSafetyAction.blockUser,
                                        enabled: !_blockingUser,
                                        child: const Text(
                                          'Block user',
                                          style: TextStyle(
                                            color: AppPalette.textPrimary,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      const PopupMenuItem<UserSafetyAction>(
                                        value: UserSafetyAction.help,
                                        child: Text(
                                          'Help / Crisis resources',
                                          style: TextStyle(
                                            color: AppPalette.textPrimary,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              body: DecoratedBox(
                                decoration: const BoxDecoration(
                                  color: AppPalette.pageBg,
                                ),
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: bootstrapFailed
                                          ? _bootstrapFailureView(otherUser)
                                          : bootstrapWaiting
                                              ? _bootstrapLoadingView()
                                              : StreamBuilder<
                                                  QuerySnapshot<
                                                      Map<String, dynamic>>>(
                                                  key: ValueKey<String>(
                                                    'chat_messages_${effectiveSessionRef.id}_$_messageStreamRetryToken',
                                                  ),
                                                  stream: effectiveSessionRef
                                                      .collection(
                                                        FirestorePaths.messages,
                                                      )
                                                      .orderBy(
                                                        FirestorePaths
                                                            .fieldMessageCreatedAtMs,
                                                        descending: true,
                                                      )
                                                      .limit(_messagesPageSize)
                                                      .snapshots(),
                                                  builder: (_, snap) {
                                                    if (snap.hasError) {
                                                      return Center(
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                            horizontal: 24,
                                                          ),
                                                          child:
                                                              SingleChildScrollView(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              vertical: 24,
                                                            ),
                                                            child:
                                                                ConstrainedBox(
                                                              constraints:
                                                                  const BoxConstraints(
                                                                maxWidth: 420,
                                                              ),
                                                              child: Column(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  const Icon(
                                                                    Icons
                                                                        .chat_bubble_outline_rounded,
                                                                    size: 42,
                                                                    color:
                                                                        Color(
                                                                      0xFFDC2626,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 12,
                                                                  ),
                                                                  const Text(
                                                                    'Messages could not be loaded.',
                                                                    textAlign:
                                                                        TextAlign
                                                                            .center,
                                                                    style:
                                                                        TextStyle(
                                                                      fontSize:
                                                                          18,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w800,
                                                                      color: AppPalette
                                                                          .textPrimary,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 8,
                                                                  ),
                                                                  Text(
                                                                    _humanizeError(
                                                                      snap.error ??
                                                                          'Unknown message stream error.',
                                                                    ),
                                                                    textAlign:
                                                                        TextAlign
                                                                            .center,
                                                                    style:
                                                                        const TextStyle(
                                                                      color: AppPalette
                                                                          .textSecondary,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                      height:
                                                                          1.4,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 16,
                                                                  ),
                                                                  ElevatedButton
                                                                      .icon(
                                                                    onPressed:
                                                                        _retryMessages,
                                                                    icon:
                                                                        const Icon(
                                                                      Icons
                                                                          .refresh_rounded,
                                                                    ),
                                                                    label:
                                                                        const Text(
                                                                      'Retry',
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    }

                                                    final rawDocs =
                                                        snap.data?.docs ?? [];
                                                    final docs =
                                                        rawDocs.reversed.toList(
                                                            growable: false);
                                                    final hideTopBanner =
                                                        docs.isNotEmpty;

                                                    if (snap.connectionState ==
                                                            ConnectionState
                                                                .waiting &&
                                                        docs.isEmpty) {
                                                      return Column(
                                                        children: [
                                                          if (!hideTopBanner)
                                                            _statusBanner(
                                                              effectiveSession,
                                                            ),
                                                          _callSection(
                                                            effectiveSession,
                                                            me: me,
                                                            otherUser:
                                                                otherUser,
                                                          ),
                                                          const Expanded(
                                                            child: Center(
                                                              child:
                                                                  CircularProgressIndicator(),
                                                            ),
                                                          ),
                                                        ],
                                                      );
                                                    }

                                                    return Column(
                                                      children: [
                                                        if (!hideTopBanner)
                                                          _statusBanner(
                                                            effectiveSession,
                                                          ),
                                                        _callSection(
                                                          effectiveSession,
                                                          me: me,
                                                          otherUser: otherUser,
                                                        ),
                                                        Expanded(
                                                          child: _chatBody(
                                                            docs,
                                                            otherUser,
                                                          ),
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                    ),
                                    ChatComposerVisibilityGate(
                                      bootstrapping: bootstrapWaiting,
                                      hasBootstrapError: bootstrapFailed,
                                      navigatingAway: _navigatingAway,
                                      onVisibilityChanged: (
                                        composerVisible,
                                        routeTransitionActive,
                                      ) {
                                        _debugLogComposerState(
                                          composerVisible: composerVisible,
                                          bootstrapping: bootstrapWaiting,
                                          hasBootstrapError: bootstrapFailed,
                                          routeTransitionActive:
                                              routeTransitionActive,
                                        );
                                      },
                                      child: _composer(effectiveSession),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ChatDirectionMismatchState {
  const _ChatDirectionMismatchState({
    required this.resolution,
    required this.message,
  });

  final ChatSessionDirectionResolution resolution;
  final String message;
}
