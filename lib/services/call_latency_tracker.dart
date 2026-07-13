import 'package:flutter/foundation.dart';

import 'app_log.dart';

class CallLatencyTracker {
  CallLatencyTracker._();

  static final Map<String, Map<String, int>> _eventsByCall =
      <String, Map<String, int>>{};
  static final Set<String> _registeredPendingKeys = <String>{};
  static final Map<String, String> _pendingToRealCallIds = <String, String>{};

  static String safeLogId(String value) {
    return AppLog.safeId(value);
  }

  static String outgoingPendingKey(String listenerId) {
    final safe = listenerId.trim();
    return safe.isEmpty ? 'pending:outgoing' : 'pending:outgoing:$safe';
  }

  static bool get hasPendingStarts => _registeredPendingKeys.isNotEmpty;

  static bool registerPending(String pendingKey) {
    final safePendingKey = pendingKey.trim();
    if (safePendingKey.isEmpty) return false;
    if (_registeredPendingKeys.contains(safePendingKey) ||
        _pendingToRealCallIds.containsKey(safePendingKey)) {
      debugPrint(
        'call.pending_duplicate_key_ignored '
        'pendingKey=${safeLogId(safePendingKey)}',
      );
      return false;
    }

    _registeredPendingKeys.add(safePendingKey);
    return true;
  }

  static void trace(
    String eventName, {
    required String callId,
    required String actorRole,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final safeEvent = eventName.trim();
    final safeCallId = callId.trim();
    if (safeEvent.isEmpty || safeCallId.isEmpty) return;

    final timestampMs = DateTime.now().millisecondsSinceEpoch;
    final events = _eventsByCall.putIfAbsent(
      safeCallId,
      () => <String, int>{},
    );
    events[safeEvent] = timestampMs;

    final safeRole = actorRole.trim().isEmpty ? 'unknown' : actorRole.trim();
    final extras = extra.entries
        .where((entry) => entry.value != null)
        .map((entry) => '${entry.key}=${_safeExtraValue(entry)}')
        .join(' ');

    debugPrint(
      'CallTrace event=$safeEvent callId=${safeLogId(safeCallId)} '
      'actorRole=$safeRole '
      'timestampMs=$timestampMs platform=${defaultTargetPlatform.name}'
      '${extras.isEmpty ? '' : ' $extras'}',
    );

    AppLog.trace(
      safeEvent,
      area: 'call',
      traceId: safeCallId,
      fields: <String, Object?>{
        'callId': safeCallId,
        'actorRole': safeRole,
        'timestampMs': timestampMs,
        ...extra,
      },
    );

    _logSummaryIfReady(safeCallId);
  }

  static void attachPending({
    required String pendingKey,
    required String callId,
  }) {
    final safePendingKey = pendingKey.trim();
    final safeCallId = callId.trim();
    if (safePendingKey.isEmpty || safeCallId.isEmpty) return;
    if (safePendingKey == safeCallId) return;

    final existingCallId = _pendingToRealCallIds[safePendingKey];
    if (existingCallId != null && existingCallId != safeCallId) {
      debugPrint(
        'call.pending_attach_conflict_ignored '
        'pendingKey=${safeLogId(safePendingKey)} '
        'callId=${safeLogId(safeCallId)}',
      );
      return;
    }

    _registeredPendingKeys.add(safePendingKey);
    _pendingToRealCallIds[safePendingKey] = safeCallId;

    final pendingEvents = _eventsByCall.remove(safePendingKey);
    if (pendingEvents == null || pendingEvents.isEmpty) {
      debugPrint(
        'call.pending_attached_real_call_id '
        'pendingKey=${safeLogId(safePendingKey)} '
        'callId=${safeLogId(safeCallId)}',
      );
      return;
    }

    final events = _eventsByCall.putIfAbsent(
      safeCallId,
      () => <String, int>{},
    );
    pendingEvents.forEach((key, value) {
      events.putIfAbsent(key, () => value);
    });

    debugPrint(
      'call.pending_attached_real_call_id '
      'pendingKey=${safeLogId(safePendingKey)} '
      'callId=${safeLogId(safeCallId)}',
    );
    _logSummaryIfReady(safeCallId);
  }

  static void clearPending(String pendingKey) {
    final safePendingKey = pendingKey.trim();
    if (safePendingKey.isEmpty) return;
    final realCallId = _pendingToRealCallIds.remove(safePendingKey);
    final wasRegistered = _registeredPendingKeys.remove(safePendingKey);
    _eventsByCall.remove(safePendingKey);
    if (!wasRegistered && realCallId == null) return;

    debugPrint(
      'call.pending_mapping_cleared '
      'pendingKey=${safeLogId(safePendingKey)}'
      '${realCallId == null ? '' : ' callId=${safeLogId(realCallId)}'}',
    );
  }

  static String _safeExtraValue(MapEntry<String, Object?> entry) {
    final key = entry.key.toLowerCase();
    final value = entry.value;
    if (value is String &&
        (key.contains('uid') ||
            key.contains('id') ||
            key.contains('token') ||
            key.contains('secret'))) {
      if (key.contains('token') || key.contains('secret')) return 'redacted';
      return AppLog.safeId(value);
    }
    return value.toString();
  }

  static void _logSummaryIfReady(String callId) {
    final events = _eventsByCall[callId];
    if (events == null || events.isEmpty) return;

    final parts = <String>[];
    void addDuration(String label, String startEvent, String endEvent) {
      final start = events[startEvent];
      final end = events[endEvent];
      if (start == null || end == null || end < start) return;
      parts.add('$label=${end - start}');
    }

    addDuration(
      'callSetupMs',
      'call.tap_call_now',
      'call.connected',
    );
    addDuration(
      'notificationMs',
      'call.fcm_send_success',
      'call.incoming_notification_shown',
    );
    addDuration(
      'fcmToCallkitMs',
      'call.incoming_fcm_received',
      'call.incoming_callkit_show_success',
    );
    addDuration(
      'acceptCallableMs',
      'call.accept_callable_begin',
      'call.accept_callable_success',
    );
    addDuration(
      'acceptToVoiceOpenMs',
      'call.accept_tap',
      'call.accept_open_voice_success',
    );
    addDuration(
      'acceptSuccessToJoinBeginMs',
      'call.accept_callable_success',
      'call.agora_join_begin',
    );
    addDuration(
      'agoraJoinMs',
      'call.agora_join_begin',
      'call.agora_join_success',
    );
    addDuration(
      'remoteJoinMs',
      'call.agora_join_success',
      'call.remote_user_joined',
    );

    if (parts.isEmpty) return;

    debugPrint(
      'CallTrace summary callId=${safeLogId(callId)} ${parts.join(' ')}',
    );
    AppLog.trace(
      'call.trace_summary',
      area: 'call',
      traceId: callId,
      fields: <String, Object?>{
        'callId': callId,
        'summary': parts.join(','),
      },
    );
  }
}
