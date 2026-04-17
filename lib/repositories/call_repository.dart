import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/firestore_paths.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../shared/models/call_model.dart';

class CallRepository {
  CallRepository._();

  static final CallRepository instance = CallRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  final Set<String> _endingCallIds = <String>{};
  final Set<String> _rejectingCallIds = <String>{};
  final Set<String> _acceptingCallIds = <String>{};
  final Set<String> _cancelingCallIds = <String>{};
  final Map<String, Future<String>> _pendingChatSessionEnsures =
      <String, Future<String>>{};
  final Map<String, int> _recentlyEnsuredChatSessionsMs = <String, int>{};

  static const int _chatSessionEnsureTtlMs = 45000;

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

  Map<String, dynamic> _emptyChatSession({
    required String speakerId,
    required String listenerId,
  }) {
    final ids = <String>[speakerId.trim(), listenerId.trim()]..sort();
    final canonicalId = chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );

    return <String, dynamic>{
      FirestorePaths.fieldChatSessionId: canonicalId,
      FirestorePaths.fieldSpeakerId: ids[0],
      FirestorePaths.fieldListenerId: ids[1],
      FirestorePaths.fieldPairUserA: ids[0],
      FirestorePaths.fieldPairUserB: ids[1],
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
    final ids = <String>[requestedSpeakerId.trim(), requestedListenerId.trim()]..sort();
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
    merged[FirestorePaths.fieldPairUserA] = _asString(
      data[FirestorePaths.fieldPairUserA],
      fallback: ids[0],
    );
    merged[FirestorePaths.fieldPairUserB] = _asString(
      data[FirestorePaths.fieldPairUserB],
      fallback: ids[1],
    );
    final requestedBy = _asString(
      data[FirestorePaths.fieldRequesterId],
      fallback: _asString(data[FirestorePaths.fieldCallRequestedBy]),
    );
    final responderId = requestedBy == ids[0]
        ? ids[1]
        : requestedBy == ids[1]
            ? ids[0]
            : '';
    merged[FirestorePaths.fieldRequesterId] = requestedBy;
    merged[FirestorePaths.fieldResponderId] = _asString(
      data[FirestorePaths.fieldResponderId],
      fallback: responderId,
    );
    merged[FirestorePaths.fieldPendingFor] = _asString(
      data[FirestorePaths.fieldPendingFor],
      fallback: _asBool(data[FirestorePaths.fieldCallRequestOpen]) ? responderId : '',
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

  Future<DocumentReference<Map<String, dynamic>>?> createCallToListener({
    required String listenerId,
  }) async {
    final safeListener = listenerId.trim();
    if (safeListener.isEmpty) return null;
    if (hasBlockingCallState) {
      debugPrint(
        'createCallToListener blocked by local call session state for listener=$safeListener',
      );
      return null;
    }

    try {
      return await FirestoreService.createCallToListener(
        listenerId: safeListener,
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'createCallToListener functions failure: '
        'code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    } catch (e) {
      debugPrint('createCallToListener unexpected failure: $e');
      rethrow;
    }
  }

  Future<void> acceptCallById(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty) return;
    if (hasBlockingCallState) return;
    if (_acceptingCallIds.contains(safeCallId)) return;

    _acceptingCallIds.add(safeCallId);
    try {
      final call = await _getFreshCallOrNull(safeCallId);
      if (call == null) return;
      if (!_isSafeParticipant(call)) return;
      if (!_isRingingLiveCall(call)) return;
      if (!amICallee(call)) return;

      await FirestoreService.acceptCall(callDoc(safeCallId));
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
            rejectedReason:
                reason ?? FirestorePaths.reasonCalleeRejectCallkit,
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

    return canonicalRef.snapshots().map((snap) {
      if (!snap.exists) {
        return _emptyChatSession(
          speakerId: safeSpeakerId,
          listenerId: safeListenerId,
        );
      }

      return _normalizeChatSessionPayload(
        requestedSpeakerId: safeSpeakerId,
        requestedListenerId: safeListenerId,
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

    return _normalizeChatSessionPayload(
      requestedSpeakerId: safeSpeakerId,
      requestedListenerId: safeListenerId,
      docId: canonicalRef.id,
      data: snap.data() ?? <String, dynamic>{},
      exists: true,
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
    if (canonicalId.isNotEmpty) {
      final ensuredAtMs = _recentlyEnsuredChatSessionsMs[canonicalId] ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (ensuredAtMs > 0 && nowMs - ensuredAtMs <= _chatSessionEnsureTtlMs) {
        return canonicalId;
      }

      final existingSnap = await _chatSessions.doc(canonicalId).get();
      if (existingSnap.exists) {
        _recentlyEnsuredChatSessionsMs[canonicalId] = nowMs;
        return canonicalId;
      }
    }

    final future = () async {
      final ensured = await _ensureChatSessionViaCallable(
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
      );

      final sessionId = _asString(ensured['sessionId']);
      if (sessionId.isNotEmpty) {
        _recentlyEnsuredChatSessionsMs[sessionId] =
            DateTime.now().millisecondsSinceEpoch;
        return sessionId;
      }

      final fallbackId = chatSessionIdForPair(
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
      );
      if (fallbackId.isEmpty) return '';

      final snap = await _chatSessions.doc(fallbackId).get();
      if (!snap.exists) return '';

      _recentlyEnsuredChatSessionsMs[fallbackId] =
          DateTime.now().millisecondsSinceEpoch;
      return fallbackId;
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

    debugPrint(
      'canCurrentUserCallListener '
      'listener=$safeListenerId '
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

    if (!exists) return false;
    if (listenerBlocked || speakerBlocked) return false;
    if (!callAllowed) return false;
    if (requestedBy != speakerId) return false;

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

  Future<void> requestCallPermissionFromListener({
    required String listenerId,
  }) async {
    final safeListenerId = listenerId.trim();
    final speakerId = myUid;

    if (!_isValidPairIds(
      speakerId: speakerId,
      listenerId: safeListenerId,
    )) {
      return;
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
      return;
    }

    final callAllowed = _asBool(
      currentSession[FirestorePaths.fieldCallAllowed],
      fallback: false,
    );
    if (callAllowed) {
      debugPrint(
        'requestCallPermissionFromListener skipped because call is already allowed '
        'for speaker=$speakerId listener=$safeListenerId',
      );
      return;
    }

    final callRequestOpen = _asBool(
      currentSession[FirestorePaths.fieldCallRequestOpen],
      fallback: false,
    );
    final callRequestedBy = _asString(
      currentSession[FirestorePaths.fieldCallRequestedBy],
      fallback: '',
    );
    if (callRequestOpen && callRequestedBy == speakerId) {
      debugPrint(
        'requestCallPermissionFromListener skipped because request is already open '
        'for speaker=$speakerId listener=$safeListenerId',
      );
      return;
    }

    await _invokeChatActionCallable(
      name: 'speakerRequestChatAccess_v1',
      payload: <String, dynamic>{
        'listenerId': safeListenerId,
      },
    );
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

    return _calls
        .where(
          FirestorePaths.fieldStatus,
          isEqualTo: FirestorePaths.statusRejected,
        )
        .where(
          FirestorePaths.fieldEndedReason,
          whereIn: const <String>[
            FirestorePaths.reasonTimeout,
            'missed',
            'no_answer',
          ],
        )
        .limit(safeLimit)
        .snapshots()
        .map(
          (query) => query.docs
              .map((doc) => CallModel.fromMap(doc.id, doc.data()))
              .where(_isSafeParticipant)
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
