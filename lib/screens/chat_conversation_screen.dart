import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/call_session_manager.dart';
import '../shared/models/app_user_model.dart';
import 'caller_waiting_screen.dart';

class ChatConversationScreen extends StatefulWidget {
  final String speakerId;
  final String listenerId;
  final bool iAmListener;
  final AppUserModel? initialOtherUser;

  const ChatConversationScreen({
    super.key,
    required this.speakerId,
    required this.listenerId,
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

  late final Future<AppUserModel?> _otherUserFuture;
  late Future<void> _bootstrapFuture;

  StreamSubscription<Map<String, dynamic>>? _sessionResolverSub;

  bool _sending = false;
  bool _loadingCall = false;
  bool _callStartInFlight = false;
  bool _bootstrapping = true;
  bool _markingSeen = false;
  bool _resolvingSession = false;
  bool _requestingCall = false;
  bool _acceptingCallRequest = false;

  Object? _bootstrapError;
  String? _bootstrapErrorMessage;
  int _lastRenderedMessageCount = 0;
  String _lastSeenBatchSignature = '';
  DateTime? _lastSeenBatchAt;

  static const int _messagesPageSize = 250;
  static const Duration _seenBatchThrottle = Duration(seconds: 2);

  DocumentReference<Map<String, dynamic>>? _resolvedSessionRef;
  String _resolvedSessionDocId = '';

  String get _myUid => _auth.currentUser?.uid ?? '';

  String get _requestedSpeakerId => widget.speakerId.trim();

  String get _requestedListenerId => widget.listenerId.trim();

  bool get _amListenerForThisChat =>
      widget.iAmListener || _myUid == _requestedListenerId;

  bool get _hasBlockingCallState =>
      _callSession.active ||
      _callSession.state == CallState.preparing ||
      _callSession.state == CallState.joining ||
      _callSession.state == CallState.reconnecting ||
      _callSession.state == CallState.ending;

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
    return _db.collection(FirestorePaths.chatSessions).doc(_directionalSessionId);
  }

  @override
  void initState() {
    super.initState();
    _otherUserFuture = _loadOtherUser();
    _bootstrapFuture = _prepareStableSession();
    _bindResolvedSession();
  }

  @override
  void dispose() {
    _sessionResolverSub?.cancel();
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<AppUserModel?> _loadOtherUser() async {
    if (widget.initialOtherUser != null) {
      return widget.initialOtherUser;
    }

    final otherUid = _otherUid;
    if (otherUid.isEmpty) return null;
    return _userRepository.getUser(otherUid);
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

  void _clearBootstrapError() {
    _bootstrapError = null;
    _bootstrapErrorMessage = null;
  }

  String _humanizeError(Object error) {
    final raw = error.toString().trim();
    if (raw.isEmpty) return 'Unknown error.';
    if (raw.contains('permission-denied')) {
      return 'You do not have permission to open this chat.';
    }
    if (raw.contains('unavailable')) {
      return 'Service is temporarily unavailable. Please retry.';
    }
    if (raw.contains('invalid-argument')) {
      return 'Invalid chat details were provided.';
    }
    return raw;
  }

  String _humanizeCallError(Object error) {
    if (error is FirebaseFunctionsException) {
      final code = error.code.trim();
      final message = (error.message ?? '').trim();

      switch (code) {
        case 'failed-precondition':
          return message.isNotEmpty ? message : 'Call cannot be started right now.';
        case 'permission-denied':
          return 'You are not allowed to do this.';
        case 'unavailable':
          return 'Call service is temporarily unavailable.';
        case 'resource-exhausted':
          return 'A call is already active.';
        default:
          return message.isNotEmpty ? message : 'Call action failed.';
      }
    }

    final raw = error.toString().trim();
    return raw.isEmpty ? 'Call action failed.' : raw;
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
    final canonicalRequestedPair = _canonicalRequestedPair;
    final canonicalSpeakerId = canonicalRequestedPair[0];
    final canonicalListenerId = canonicalRequestedPair[1];

    if (!_isCanonicalDirectionalPairValid) return false;
    if (speakerId != canonicalSpeakerId) return false;
    if (listenerId != canonicalListenerId) return false;
    if (canonicalDocId != _directionalSessionId) return false;
    if (docId != _directionalSessionId) return false;

    return true;
  }

  Future<void> _prepareStableSession() async {
    _clearBootstrapError();

    if (!_validRequestedPair()) {
      _bootstrapError = StateError('Invalid chat participants.');
      _bootstrapErrorMessage = _humanizeError(_bootstrapError!);
      if (mounted) {
        setState(() => _bootstrapping = false);
      } else {
        _bootstrapping = false;
      }
      return;
    }

    if (_myUid.isEmpty) {
      _bootstrapError = StateError('User is not signed in.');
      _bootstrapErrorMessage = _humanizeError(_bootstrapError!);
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

      final ref = _db.collection(FirestorePaths.chatSessions).doc(effectiveDocId);

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
      _bootstrapError = error;
      _bootstrapErrorMessage = _humanizeError(error);
      rethrow;
    } finally {
      if (mounted) {
        setState(() => _bootstrapping = false);
      } else {
        _bootstrapping = false;
      }
    }
  }

  void _retryBootstrap() {
    FocusScope.of(context).unfocus();
    setState(() {
      _bootstrapping = true;
      _clearBootstrapError();
      _bootstrapFuture = _prepareStableSession();
    });
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

      final ref = _db.collection(FirestorePaths.chatSessions).doc(effectiveDocId);

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

    final signature = unreadDocs.map((doc) => doc.id).join('|');
    final now = DateTime.now();
    final throttled =
        signature == _lastSeenBatchSignature &&
        _lastSeenBatchAt != null &&
        now.difference(_lastSeenBatchAt!) < _seenBatchThrottle;

    if (throttled) {
      return;
    }

    _lastSeenBatchSignature = signature;
    _lastSeenBatchAt = now;

    _markingSeen = true;

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final batch = _db.batch();

      for (final doc in unreadDocs) {
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
    } catch (_) {
      // ignore
    } finally {
      _markingSeen = false;
    }
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

  bool _sessionCallAllowed(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return false;
    return _asBool(
      session[FirestorePaths.fieldCallAllowed],
      fallback: false,
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
      fallback: '',
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
      _showSnack('This chat is unavailable.');
      return;
    }

    setState(() => _sending = true);

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await _ensureSessionBootstrap();
      final ref = await _resolveSessionRef();
      final messagesRef = ref.collection(FirestorePaths.messages);

      await messagesRef.add({
        FirestorePaths.fieldMessageText: text,
        FirestorePaths.fieldMessageType: FirestorePaths.messageTypeText,
        FirestorePaths.fieldMessageSenderId: _myUid,
        FirestorePaths.fieldMessageReceiverId: _otherUid,
        FirestorePaths.fieldMessageCreatedAt: FieldValue.serverTimestamp(),
        FirestorePaths.fieldMessageCreatedAtMs: nowMs,
        FirestorePaths.fieldMessageSeen: false,
      });

      _messageController.clear();
      if (mounted) setState(() {});
      _scrollToBottom();
    } catch (_) {
      _showSnack('Message failed.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _requestCall(Map<String, dynamic> session) async {
    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    if (_requestingCall) return;

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is unavailable.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing. Open chat first.');
      return;
    }

    if (_sessionCallAllowed(session)) {
      _showSnack('Call is already approved. You can tap Call now.');
      return;
    }

    if (_sessionCallRequestOpen(session)) {
      _showSnack('Call request already sent.');
      return;
    }

    setState(() => _requestingCall = true);

    try {
      await _ensureSessionBootstrap();
      await _callRepository.requestCallPermissionFromListener(
        listenerId: _requestedListenerId,
      );

      if (!mounted) return;
      _showSnack('Request sent.');
    } catch (e) {
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

    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    if (!_amListenerForThisChat) {
      _showSnack('Only the receiver can accept this call request.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing.');
      return;
    }

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is unavailable.');
      return;
    }

    final requestedBy = _sessionCallRequestedBy(session);
    if (!_sessionCallRequestOpen(session) || requestedBy != _requestedSpeakerId) {
      _showSnack('No pending call request to accept.');
      return;
    }

    setState(() => _acceptingCallRequest = true);

    try {
      await _ensureSessionBootstrap();
      await _callRepository.markListenerAllowedCall(
        speakerId: _requestedSpeakerId,
        listenerId: _requestedListenerId,
      );

      if (!mounted) return;
      _showSnack('Call request accepted.');
    } catch (e) {
      _showSnack(_humanizeCallError(e));
    } finally {
      if (mounted) {
        setState(() => _acceptingCallRequest = false);
      } else {
        _acceptingCallRequest = false;
      }
    }
  }

  Future<void> _startCall(Map<String, dynamic> session) async {
    if (_hasBootstrapError) {
      _showSnack('Chat is not ready. Please retry.');
      return;
    }

    if (_loadingCall || _callStartInFlight) return;

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    if (_sessionIsBlocked(session)) {
      _showSnack('This chat is unavailable.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing. Open chat first.');
      return;
    }

    if (!_sessionCallAllowed(session)) {
      _showSnack('Call is not approved yet. Send request first.');
      return;
    }

    setState(() {
      _loadingCall = true;
      _callStartInFlight = true;
    });

    try {
      final canCall = await _callRepository.canCurrentUserCallListener(
        listenerId: widget.listenerId,
      );

      if (!canCall) {
        _showSnack('Call is not allowed for this chat yet.');
        return;
      }

      final callRef = await _callRepository.createCallToListener(
        listenerId: widget.listenerId,
      );

      if (callRef == null) {
        _showSnack('Call could not be started.');
        return;
      }

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CallerWaitingScreen(callDocRef: callRef),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      _showSnack(_humanizeCallError(e));
    } catch (e) {
      _showSnack(_humanizeCallError(e));
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
    if (_hasBlockingCallState) return const Color(0xFF4F46E5);
    if (!_sessionExists(session)) return const Color(0xFF6B7280);
    if (_sessionCallAllowed(session)) return const Color(0xFF15803D);
    if (_sessionCallRequestOpen(session)) return const Color(0xFFD97706);
    return const Color(0xFF4F46E5);
  }

  String _statusText(Map<String, dynamic> session) {
    if (_sessionIsBlocked(session)) return 'Chat unavailable';
    if (_hasBlockingCallState) return 'Call in progress';
    if (!_sessionExists(session)) return 'Chat not started';
    if (_sessionCallAllowed(session)) {
      return _amListenerForThisChat ? 'Call request accepted' : 'Call approved';
    }
    if (_sessionCallRequestOpen(session)) {
      return _amListenerForThisChat ? 'Accept call request?' : 'Request sent';
    }
    return 'Chat active';
  }

  String _statusSubtitle(Map<String, dynamic> session) {
    if (_sessionIsBlocked(session)) {
      return 'This conversation is blocked for this chat pair.';
    }
    if (_hasBlockingCallState) {
      return 'New call attempts are paused until your current call flow finishes.';
    }
    if (!_sessionExists(session)) {
      return 'This chat pair has not been created yet.';
    }
    if (_sessionCallAllowed(session)) {
      return _amListenerForThisChat
          ? 'You accepted the call request.'
          : 'Call approval received. You can call now.';
    }
    if (_sessionCallRequestOpen(session)) {
      return _amListenerForThisChat
          ? 'The other person wants to call you.'
          : 'Call request sent. Waiting for approval.';
    }
    return 'You can chat freely. Calling is locked until listener approval.';
  }

  Widget _statusBanner(Map<String, dynamic> session) {
    final color = _statusColor(session);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.18)),
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
                    color: Color(0xFF6B7280),
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

  Widget _callSection(Map<String, dynamic> session) {
    final blocked = _sessionIsBlocked(session);
    if (blocked) return const SizedBox.shrink();

    final exists = _sessionExists(session);
    final callAllowed = _sessionCallAllowed(session);
    final pending = _sessionCallRequestOpen(session);
    final requestedBy = _sessionCallRequestedBy(session);

    final listenerNeedsToAccept =
        _amListenerForThisChat && pending && requestedBy == _requestedSpeakerId;
    final senderWaiting =
        !_amListenerForThisChat && pending && requestedBy == _requestedSpeakerId;

    final title = _hasBlockingCallState
        ? 'Call already active'
        : !exists
            ? 'Chat not started'
            : callAllowed
                ? (_amListenerForThisChat ? 'Accepted' : 'Call now')
                : listenerNeedsToAccept
                    ? 'Accept call request?'
                    : senderWaiting
                        ? 'Request sent'
                        : 'Request call';

    final subtitle = _hasBlockingCallState
        ? 'Finish your current call flow before starting another.'
        : !exists
            ? 'Open chat first to bootstrap the canonical session.'
            : callAllowed
                ? (_amListenerForThisChat
                    ? 'You approved this call request.'
                    : 'Call is approved. You can start now.')
                : listenerNeedsToAccept
                    ? 'The other person asked to call you.'
                    : senderWaiting
                        ? 'Waiting for the other person to approve your call request.'
                        : 'Ask for call approval from this chat.';

    final buttonLabel = _hasBlockingCallState
        ? 'Call Active'
        : !exists
            ? 'Chat First'
            : callAllowed
                ? (_amListenerForThisChat
                    ? '✓ Accepted'
                    : (_loadingCall ? 'Calling...' : 'Call now'))
                : listenerNeedsToAccept
                    ? (_acceptingCallRequest ? 'Accepting...' : 'Accept request')
                    : senderWaiting
                        ? '✓ Request sent'
                        : (_requestingCall ? 'Sending...' : 'Request call');

    final startEnabled = !_hasBootstrapError &&
        !_hasBlockingCallState &&
        exists &&
        !blocked &&
        !pending &&
        callAllowed &&
        !_amListenerForThisChat &&
        !_loadingCall &&
        !_callStartInFlight;

    final requestEnabled = !_hasBootstrapError &&
        !_hasBlockingCallState &&
        exists &&
        !blocked &&
        !callAllowed &&
        !pending &&
        !_requestingCall;

    final acceptEnabled = !_hasBootstrapError &&
        !_hasBlockingCallState &&
        exists &&
        !blocked &&
        listenerNeedsToAccept &&
        !_acceptingCallRequest;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: _hasBlockingCallState
            ? null
            : callAllowed && !_amListenerForThisChat
                ? const LinearGradient(
                    colors: [
                      Color(0xFF4F46E5),
                      Color(0xFF7C3AED),
                    ],
                  )
                : listenerNeedsToAccept
                    ? const LinearGradient(
                        colors: [
                          Color(0xFFEEF2FF),
                          Color(0xFFF5F3FF),
                        ],
                      )
                    : null,
        color: _hasBlockingCallState
            ? const Color(0xFFEEF2FF)
            : callAllowed && !_amListenerForThisChat
                ? null
                : pending
                    ? const Color(0xFFF8FAFC)
                    : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(20),
        border: callAllowed && !_amListenerForThisChat && !_hasBlockingCallState
            ? null
            : Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: callAllowed && !_amListenerForThisChat && !_hasBlockingCallState
            ? const [
                BoxShadow(
                  blurRadius: 20,
                  offset: Offset(0, 8),
                  color: Color(0x224F46E5),
                ),
              ]
            : const [],
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
                  color: _hasBlockingCallState
                      ? const Color(0xFFDDE4FF)
                      : callAllowed && !_amListenerForThisChat
                          ? Colors.white.withValues(alpha: 0.16)
                          : pending
                              ? const Color(0xFFECFDF3)
                              : const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  callAllowed
                      ? (_amListenerForThisChat
                          ? Icons.check_rounded
                          : Icons.call_rounded)
                      : listenerNeedsToAccept
                          ? Icons.phone_in_talk_rounded
                          : pending
                              ? Icons.check_rounded
                              : Icons.call_outlined,
                  color: _hasBlockingCallState
                      ? const Color(0xFF4F46E5)
                      : callAllowed && !_amListenerForThisChat
                          ? Colors.white
                          : pending
                              ? const Color(0xFF15803D)
                              : const Color(0xFF6B7280),
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
                        color: _hasBlockingCallState
                            ? const Color(0xFF4F46E5)
                            : callAllowed && !_amListenerForThisChat
                                ? Colors.white
                                : const Color(0xFF111827),
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _hasBlockingCallState
                            ? const Color(0xFF4F46E5)
                            : callAllowed && !_amListenerForThisChat
                                ? const Color(0xFFEDE9FE)
                                : const Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

          final button = SizedBox(
            width: stackVertically ? double.infinity : null,
            child: ElevatedButton(
              onPressed: startEnabled
                  ? () => _startCall(session)
                  : requestEnabled
                      ? () => _requestCall(session)
                      : acceptEnabled
                          ? () => _acceptCallRequest(session)
                          : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: callAllowed && !_amListenerForThisChat
                    ? Colors.white
                    : pending && !listenerNeedsToAccept
                        ? const Color(0xFFECFDF3)
                        : const Color(0xFF4F46E5),
                foregroundColor: callAllowed && !_amListenerForThisChat
                    ? const Color(0xFF4F46E5)
                    : pending && !listenerNeedsToAccept
                        ? const Color(0xFF15803D)
                        : Colors.white,
                disabledBackgroundColor: pending && !listenerNeedsToAccept
                    ? const Color(0xFFECFDF3)
                    : const Color(0xFFE5E7EB),
                disabledForegroundColor: pending && !listenerNeedsToAccept
                    ? const Color(0xFF15803D)
                    : const Color(0xFF9CA3AF),
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
          );

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
      backgroundColor: const Color(0xFFE0E7FF),
      child: Text(
        first,
        style: const TextStyle(
          color: Color(0xFF312E81),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildAppBarTitle(AppUserModel? otherUser) {
    final name = otherUser?.safeDisplayName ?? 'Chat';
    final isListener = otherUser?.isListener == true;
    final available =
        otherUser?.isAvailable == true && !(otherUser?.hasActiveCall ?? false);

    final subtitle = _hasBlockingCallState
        ? 'Call active'
        : isListener
            ? (available ? 'Available now' : 'Currently busy')
            : 'Conversation';

    final subtitleColor = _hasBlockingCallState
        ? const Color(0xFF4F46E5)
        : isListener
            ? (available ? const Color(0xFF15803D) : const Color(0xFFD97706))
            : const Color(0xFF6B7280);

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
                  color: Color(0xFF111827),
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
    return type == FirestorePaths.messageTypeCallStart ||
        type == FirestorePaths.messageTypeCallEnd ||
        type == FirestorePaths.messageTypeMissedCall ||
        type == FirestorePaths.messageTypeCallCharge ||
        type == FirestorePaths.messageTypeSystem;
  }

  Widget _systemTile(Map<String, dynamic> msg) {
    final text = _asString(msg[FirestorePaths.fieldMessageText]);
    final time = _formatTime(msg[FirestorePaths.fieldMessageCreatedAtMs]);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            children: [
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF374151),
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                ),
              ),
              if (time.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  time,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
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

  Widget _messageBubble(
    Map<String, dynamic> msg, {
    required bool showTopSpacing,
  }) {
    final type = _asString(msg[FirestorePaths.fieldMessageType]);
    if (_isSystemType(type)) {
      return _systemTile(msg);
    }

    final isMine =
        _asString(msg[FirestorePaths.fieldMessageSenderId]) == _myUid;

    final text = _asString(msg[FirestorePaths.fieldMessageText]);
    final time = _formatTime(msg[FirestorePaths.fieldMessageCreatedAtMs]);
    final seen = msg[FirestorePaths.fieldMessageSeen] == true;

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 290),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: isMine
            ? const LinearGradient(
                colors: [
                  Color(0xFF4F46E5),
                  Color(0xFF6366F1),
                ],
              )
            : null,
        color: isMine ? null : Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMine ? 18 : 6),
          bottomRight: Radius.circular(isMine ? 6 : 18),
        ),
        border: isMine ? null : Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            blurRadius: 16,
            offset: Offset(0, 4),
            color: Color(0x12000000),
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
              color: isMine ? Colors.white : const Color(0xFF111827),
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
                      : const Color(0xFF6B7280),
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
        top: showTopSpacing ? 10 : 4,
        bottom: 2,
      ),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: bubble,
      ),
    );
  }

  Widget _emptyState(AppUserModel? otherUser) {
    final name = otherUser?.safeDisplayName ?? 'this user';
    final topics = otherUser?.topics.take(3).toList() ?? const <String>[];

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
                    color: const Color(0xFFEEF2FF),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 34,
                    color: Color(0xFF4F46E5),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Start your conversation',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  topics.isEmpty
                      ? 'Send a message to $name and begin the chat.'
                      : 'Send your first message. $name can help with ${topics.join(', ')}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer(Map<String, dynamic> session) {
    final blocked = _sessionIsBlocked(session);

    final disabled = blocked || _sending || _bootstrapping || _hasBootstrapError;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFC),
          border: Border(
            top: BorderSide(color: Color(0xFFE5E7EB)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 12,
                      offset: Offset(0, 4),
                      color: Color(0x0D000000),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _messageController,
                  focusNode: _messageFocusNode,
                  enabled: !disabled,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                  onTap: _scrollToBottom,
                  decoration: InputDecoration(
                    hintText: blocked
                        ? 'Chat unavailable'
                        : _hasBootstrapError
                            ? 'Chat failed to load'
                            : _bootstrapping
                                ? 'Preparing chat...'
                                : 'Type your message...',
                    hintStyle: const TextStyle(
                      color: Color(0xFF9CA3AF),
                      fontWeight: FontWeight.w600,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
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
                  gradient: disabled || _messageController.text.trim().isEmpty
                      ? null
                      : const LinearGradient(
                          colors: [
                            Color(0xFF4F46E5),
                            Color(0xFF6366F1),
                          ],
                        ),
                  color: disabled || _messageController.text.trim().isEmpty
                      ? const Color(0xFFE5E7EB)
                      : null,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: disabled || _messageController.text.trim().isEmpty
                      ? const []
                      : const [
                          BoxShadow(
                            blurRadius: 14,
                            offset: Offset(0, 6),
                            color: Color(0x224F46E5),
                          ),
                        ],
                ),
                child: IconButton(
                  onPressed: disabled || _messageController.text.trim().isEmpty
                      ? null
                      : () => _sendMessage(session),
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
                              disabled || _messageController.text.trim().isEmpty
                                  ? const Color(0xFF9CA3AF)
                                  : Colors.white,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markVisibleMessagesSeen(docs);
    });

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      itemCount: docs.length,
      itemBuilder: (_, index) {
        final current = docs[index].data();
        final currentType = _asString(current[FirestorePaths.fieldMessageType]);
        final currentSender =
            _asString(current[FirestorePaths.fieldMessageSenderId]);

        final previousData = index > 0 ? docs[index - 1].data() : null;
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
    final name = otherUser?.safeDisplayName ?? 'this conversation';

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
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 38,
                    color: Color(0xFFDC2626),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Could not open chat',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Something went wrong while preparing $name.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
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
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(
                      _bootstrapErrorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
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
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('Go back'),
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
        return FutureBuilder<AppUserModel?>(
          future: _otherUserFuture,
          builder: (_, otherUserSnap) {
            final otherUser = otherUserSnap.data;

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

                    final sessionDocId = _asString(
                      session['docId'],
                      fallback: _directionalSessionId,
                    );

                    final useCanonicalSession = _sessionLooksCanonical(session) &&
                        sessionDocId == _directionalSessionId;

                    final effectiveSessionRef = _db
                        .collection(FirestorePaths.chatSessions)
                        .doc(_directionalSessionId);

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
                      onTap: () => FocusScope.of(context).unfocus(),
                      child: Scaffold(
                        backgroundColor: const Color(0xFFF8FAFC),
                        appBar: AppBar(
                          elevation: 0,
                          scrolledUnderElevation: 0,
                          backgroundColor: Colors.white,
                          surfaceTintColor: Colors.white,
                          titleSpacing: 8,
                          title: _buildAppBarTitle(otherUser),
                        ),
                        body: Column(
                          children: [
                            Expanded(
                              child: bootstrapFailed
                                  ? _bootstrapFailureView(otherUser)
                                  : bootstrapWaiting
                                      ? _bootstrapLoadingView()
                                      : StreamBuilder<
                                          QuerySnapshot<Map<String, dynamic>>
                                        >(
                                          stream: effectiveSessionRef
                                              .collection(FirestorePaths.messages)
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
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 24,
                                                  ),
                                                  child: SingleChildScrollView(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                      vertical: 24,
                                                    ),
                                                    child: ConstrainedBox(
                                                      constraints:
                                                          const BoxConstraints(
                                                        maxWidth: 420,
                                                      ),
                                                      child: Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          const Icon(
                                                            Icons
                                                                .chat_bubble_outline_rounded,
                                                            size: 42,
                                                            color:
                                                                Color(0xFFDC2626),
                                                          ),
                                                          const SizedBox(height: 12),
                                                          const Text(
                                                            'Messages could not be loaded.',
                                                            textAlign:
                                                                TextAlign.center,
                                                            style: TextStyle(
                                                              fontSize: 18,
                                                              fontWeight:
                                                                  FontWeight.w800,
                                                              color:
                                                                  Color(0xFF111827),
                                                            ),
                                                          ),
                                                          const SizedBox(height: 8),
                                                          Text(
                                                            _humanizeError(
                                                              snap.error ??
                                                                  'Unknown message stream error.',
                                                            ),
                                                            textAlign:
                                                                TextAlign.center,
                                                            style: const TextStyle(
                                                              color:
                                                                  Color(0xFF6B7280),
                                                              fontWeight:
                                                                  FontWeight.w600,
                                                              height: 1.4,
                                                            ),
                                                          ),
                                                          const SizedBox(height: 16),
                                                          ElevatedButton.icon(
                                                            onPressed:
                                                                _retryBootstrap,
                                                            icon: const Icon(
                                                              Icons.refresh_rounded,
                                                            ),
                                                            label:
                                                                const Text('Retry'),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }

                                            final rawDocs = snap.data?.docs ?? [];
                                            final docs = rawDocs.reversed
                                                .toList(growable: false);
                                            final hideTopBanner = docs.isNotEmpty;

                                            if (snap.connectionState ==
                                                    ConnectionState.waiting &&
                                                docs.isEmpty) {
                                              return Column(
                                                children: [
                                                  if (!hideTopBanner)
                                                    _statusBanner(session),
                                                  _callSection(session),
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
                                                  _statusBanner(session),
                                                _callSection(session),
                                                Expanded(
                                                  child:
                                                      _chatBody(docs, otherUser),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                            ),
                            _composer(session),
                          ],
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
  }
}