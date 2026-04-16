class CallModel {
  final String id;

  final String callerId;
  final String callerName;

  final String calleeId;
  final String calleeName;

  final String channelId;

  final String agoraTokenCaller;
  final String agoraTokenCallee;

  final String status;

  final int speakerRate;
  final int listenerRate;
  final int platformPercent;

  final int reservedUpfront;

  final int createdAtMs;
  final int expiresAtMs;

  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  final int endedAtMs;

  final String endedBy;
  final String endedReason;
  final String rejectedReason;

  final int endedSeconds;

  final bool reserveReleased;
  final DateTime? reserveReleasedAt;

  final bool settled;
  final DateTime? settledAt;

  final bool listenerCredited;
  final DateTime? listenerCreditedAt;

  final int seconds;
  final int billedMinutes;
  final int paidMinutes;

  final int speakerCharge;
  final int listenerPayout;
  final int platformProfit;

  final bool missedCallPushSent;
  final DateTime? missedCallPushSentAt;
  final int missedCallPushSentAtMs;

  final bool incomingPushAttempted;
  final bool incomingPushDelivered;
  final int incomingPushSuccessCount;
  final int incomingPushFailureCount;
  final DateTime? incomingPushAttemptedAt;
  final int incomingPushAttemptedAtMs;
  final bool incomingPushNoTokens;
  final String incomingPushError;

  final bool cancelSignalSent;
  final DateTime? cancelSignalSentAt;
  final int cancelSignalSentAtMs;

  // New commercial settlement compatibility fields
  final int settlementVersion;
  final String settlementIdempotencyKey;
  final String reserveReleaseIdempotencyKey;
  final String callerChargeTxId;
  final String listenerPayoutTxId;
  final String platformRevenueTxId;
  final String refundTxId;
  final String currency;
  final Map<String, dynamic> gatewayContext;
  final String settlementSource;

  const CallModel({
    required this.id,
    required this.callerId,
    required this.callerName,
    required this.calleeId,
    required this.calleeName,
    required this.channelId,
    required this.agoraTokenCaller,
    required this.agoraTokenCallee,
    required this.status,
    required this.speakerRate,
    required this.listenerRate,
    required this.platformPercent,
    required this.reservedUpfront,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.createdAt,
    required this.startedAt,
    required this.endedAt,
    required this.endedAtMs,
    required this.endedBy,
    required this.endedReason,
    required this.rejectedReason,
    required this.endedSeconds,
    required this.reserveReleased,
    required this.reserveReleasedAt,
    required this.settled,
    required this.settledAt,
    required this.listenerCredited,
    required this.listenerCreditedAt,
    required this.seconds,
    required this.billedMinutes,
    required this.paidMinutes,
    required this.speakerCharge,
    required this.listenerPayout,
    required this.platformProfit,
    required this.missedCallPushSent,
    required this.missedCallPushSentAt,
    required this.missedCallPushSentAtMs,
    required this.incomingPushAttempted,
    required this.incomingPushDelivered,
    required this.incomingPushSuccessCount,
    required this.incomingPushFailureCount,
    required this.incomingPushAttemptedAt,
    required this.incomingPushAttemptedAtMs,
    required this.incomingPushNoTokens,
    required this.incomingPushError,
    required this.cancelSignalSent,
    required this.cancelSignalSentAt,
    required this.cancelSignalSentAtMs,
    required this.settlementVersion,
    required this.settlementIdempotencyKey,
    required this.reserveReleaseIdempotencyKey,
    required this.callerChargeTxId,
    required this.listenerPayoutTxId,
    required this.platformRevenueTxId,
    required this.refundTxId,
    required this.currency,
    required this.gatewayContext,
    required this.settlementSource,
  });

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  static bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    return fallback;
  }

  static String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;

    final type = value.runtimeType.toString();
    if (type == 'Timestamp') {
      try {
        return value.toDate() as DateTime;
      } catch (_) {
        return null;
      }
    }

    try {
      final converted = value.toDate();
      if (converted is DateTime) return converted;
    } catch (_) {
      // ignore malformed timestamp-like values
    }

    return null;
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return value.map(
        (key, val) => MapEntry(key.toString(), val),
      );
    }
    return <String, dynamic>{};
  }

  factory CallModel.fromMap(String id, Map<String, dynamic> data) {
    return CallModel(
      id: id.trim(),
      callerId: _asString(data['callerId']),
      callerName: _asString(data['callerName'], fallback: 'User'),
      calleeId: _asString(data['calleeId']),
      calleeName: _asString(data['calleeName'], fallback: 'Listener'),
      channelId: _asString(data['channelId']),
      agoraTokenCaller: _asString(data['agoraTokenCaller']),
      agoraTokenCallee: _asString(data['agoraTokenCallee']),
      status: _asString(data['status']),
      speakerRate: _asInt(data['speakerRate'], fallback: 5),
      listenerRate: _asInt(data['listenerRate'], fallback: 4),
      platformPercent: _asInt(data['platformPercent'], fallback: 20),
      reservedUpfront: _asInt(data['reservedUpfront']),
      createdAtMs: _asInt(data['createdAtMs']),
      expiresAtMs: _asInt(data['expiresAtMs']),
      createdAt: _asDateTime(data['createdAt']),
      startedAt: _asDateTime(data['startedAt']),
      endedAt: _asDateTime(data['endedAt']),
      endedAtMs: _asInt(data['endedAtMs']),
      endedBy: _asString(data['endedBy']),
      endedReason: _asString(data['endedReason']),
      rejectedReason: _asString(data['rejectedReason']),
      endedSeconds: _asInt(data['endedSeconds']),
      reserveReleased: _asBool(data['reserveReleased']),
      reserveReleasedAt: _asDateTime(data['reserveReleasedAt']),
      settled: _asBool(data['settled']),
      settledAt: _asDateTime(data['settledAt']),
      listenerCredited: _asBool(data['listenerCredited']),
      listenerCreditedAt: _asDateTime(data['listenerCreditedAt']),
      seconds: _asInt(data['seconds']),
      billedMinutes: _asInt(data['billedMinutes']),
      paidMinutes: _asInt(data['paidMinutes']),
      speakerCharge: _asInt(data['speakerCharge']),
      listenerPayout: _asInt(data['listenerPayout']),
      platformProfit: _asInt(data['platformProfit']),
      missedCallPushSent: _asBool(data['missedCallPushSent']),
      missedCallPushSentAt: _asDateTime(data['missedCallPushSentAt']),
      missedCallPushSentAtMs: _asInt(data['missedCallPushSentAtMs']),
      incomingPushAttempted: _asBool(data['incomingPushAttempted']),
      incomingPushDelivered: _asBool(data['incomingPushDelivered']),
      incomingPushSuccessCount: _asInt(data['incomingPushSuccessCount']),
      incomingPushFailureCount: _asInt(data['incomingPushFailureCount']),
      incomingPushAttemptedAt: _asDateTime(data['incomingPushAttemptedAt']),
      incomingPushAttemptedAtMs: _asInt(data['incomingPushAttemptedAtMs']),
      incomingPushNoTokens: _asBool(data['incomingPushNoTokens']),
      incomingPushError: _asString(data['incomingPushError']),
      cancelSignalSent: _asBool(data['cancelSignalSent']),
      cancelSignalSentAt: _asDateTime(data['cancelSignalSentAt']),
      cancelSignalSentAtMs: _asInt(data['cancelSignalSentAtMs']),
      settlementVersion: _asInt(data['settlementVersion']),
      settlementIdempotencyKey: _asString(data['settlementIdempotencyKey']),
      reserveReleaseIdempotencyKey:
          _asString(data['reserveReleaseIdempotencyKey']),
      callerChargeTxId: _asString(data['callerChargeTxId']),
      listenerPayoutTxId: _asString(data['listenerPayoutTxId']),
      platformRevenueTxId: _asString(data['platformRevenueTxId']),
      refundTxId: _asString(data['refundTxId']),
      currency: _asString(data['currency'], fallback: 'INR'),
      gatewayContext: _asMap(data['gatewayContext']),
      settlementSource: _asString(data['settlementSource']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'callerId': callerId,
      'callerName': callerName,
      'calleeId': calleeId,
      'calleeName': calleeName,
      'channelId': channelId,
      'agoraTokenCaller': agoraTokenCaller,
      'agoraTokenCallee': agoraTokenCallee,
      'status': status,
      'speakerRate': speakerRate,
      'listenerRate': listenerRate,
      'platformPercent': platformPercent,
      'reservedUpfront': reservedUpfront,
      'createdAtMs': createdAtMs,
      'expiresAtMs': expiresAtMs,
      'createdAt': createdAt,
      'startedAt': startedAt,
      'endedAt': endedAt,
      'endedAtMs': endedAtMs,
      'endedBy': endedBy,
      'endedReason': endedReason,
      'rejectedReason': rejectedReason,
      'endedSeconds': endedSeconds,
      'reserveReleased': reserveReleased,
      'reserveReleasedAt': reserveReleasedAt,
      'settled': settled,
      'settledAt': settledAt,
      'listenerCredited': listenerCredited,
      'listenerCreditedAt': listenerCreditedAt,
      'seconds': seconds,
      'billedMinutes': billedMinutes,
      'paidMinutes': paidMinutes,
      'speakerCharge': speakerCharge,
      'listenerPayout': listenerPayout,
      'platformProfit': platformProfit,
      'missedCallPushSent': missedCallPushSent,
      'missedCallPushSentAt': missedCallPushSentAt,
      'missedCallPushSentAtMs': missedCallPushSentAtMs,
      'incomingPushAttempted': incomingPushAttempted,
      'incomingPushDelivered': incomingPushDelivered,
      'incomingPushSuccessCount': incomingPushSuccessCount,
      'incomingPushFailureCount': incomingPushFailureCount,
      'incomingPushAttemptedAt': incomingPushAttemptedAt,
      'incomingPushAttemptedAtMs': incomingPushAttemptedAtMs,
      'incomingPushNoTokens': incomingPushNoTokens,
      'incomingPushError': incomingPushError,
      'cancelSignalSent': cancelSignalSent,
      'cancelSignalSentAt': cancelSignalSentAt,
      'cancelSignalSentAtMs': cancelSignalSentAtMs,
      'settlementVersion': settlementVersion,
      'settlementIdempotencyKey': settlementIdempotencyKey,
      'reserveReleaseIdempotencyKey': reserveReleaseIdempotencyKey,
      'callerChargeTxId': callerChargeTxId,
      'listenerPayoutTxId': listenerPayoutTxId,
      'platformRevenueTxId': platformRevenueTxId,
      'refundTxId': refundTxId,
      'currency': currency,
      'gatewayContext': gatewayContext,
      'settlementSource': settlementSource,
    };
  }

  bool get isRinging => status == 'ringing';
  bool get isAccepted => status == 'accepted';
  bool get isEnded => status == 'ended';
  bool get isRejected => status == 'rejected';

  bool get isLiveCall => isRinging || isAccepted;
  bool get isFinal => isEnded || isRejected;

  bool get wasAnswered => startedAt != null || endedSeconds > 0 || isAccepted;

  bool get isFreeCall {
    final safeSeconds = endedSeconds < 0 ? 0 : endedSeconds;
    return safeSeconds < 60;
  }

  bool get isPaidCall {
    final safeSeconds = endedSeconds < 0 ? 0 : endedSeconds;
    return safeSeconds >= 60 && speakerCharge > 0;
  }

  int get fullMinutes {
    final safeSeconds = endedSeconds < 0 ? 0 : endedSeconds;
    if (safeSeconds < 60) return 0;
    return safeSeconds ~/ 60;
  }

  String get safeCallerName =>
      callerName.trim().isEmpty ? 'User' : callerName.trim();

  String get safeCalleeName =>
      calleeName.trim().isEmpty ? 'Listener' : calleeName.trim();

  String get otherPartyFallbackName {
    if (safeCallerName.isNotEmpty) return safeCallerName;
    if (safeCalleeName.isNotEmpty) return safeCalleeName;
    return 'User';
  }

  bool get hasCommercialSettlementMetadata {
    return settlementVersion > 0 ||
        settlementIdempotencyKey.isNotEmpty ||
        reserveReleaseIdempotencyKey.isNotEmpty ||
        callerChargeTxId.isNotEmpty ||
        listenerPayoutTxId.isNotEmpty ||
        platformRevenueTxId.isNotEmpty ||
        refundTxId.isNotEmpty ||
        settlementSource.isNotEmpty;
  }

  CallModel copyWith({
    String? id,
    String? callerId,
    String? callerName,
    String? calleeId,
    String? calleeName,
    String? channelId,
    String? agoraTokenCaller,
    String? agoraTokenCallee,
    String? status,
    int? speakerRate,
    int? listenerRate,
    int? platformPercent,
    int? reservedUpfront,
    int? createdAtMs,
    int? expiresAtMs,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? endedAt,
    int? endedAtMs,
    String? endedBy,
    String? endedReason,
    String? rejectedReason,
    int? endedSeconds,
    bool? reserveReleased,
    DateTime? reserveReleasedAt,
    bool? settled,
    DateTime? settledAt,
    bool? listenerCredited,
    DateTime? listenerCreditedAt,
    int? seconds,
    int? billedMinutes,
    int? paidMinutes,
    int? speakerCharge,
    int? listenerPayout,
    int? platformProfit,
    bool? missedCallPushSent,
    DateTime? missedCallPushSentAt,
    int? missedCallPushSentAtMs,
    bool? incomingPushAttempted,
    bool? incomingPushDelivered,
    int? incomingPushSuccessCount,
    int? incomingPushFailureCount,
    DateTime? incomingPushAttemptedAt,
    int? incomingPushAttemptedAtMs,
    bool? incomingPushNoTokens,
    String? incomingPushError,
    bool? cancelSignalSent,
    DateTime? cancelSignalSentAt,
    int? cancelSignalSentAtMs,
    int? settlementVersion,
    String? settlementIdempotencyKey,
    String? reserveReleaseIdempotencyKey,
    String? callerChargeTxId,
    String? listenerPayoutTxId,
    String? platformRevenueTxId,
    String? refundTxId,
    String? currency,
    Map<String, dynamic>? gatewayContext,
    String? settlementSource,
  }) {
    return CallModel(
      id: id ?? this.id,
      callerId: callerId ?? this.callerId,
      callerName: callerName ?? this.callerName,
      calleeId: calleeId ?? this.calleeId,
      calleeName: calleeName ?? this.calleeName,
      channelId: channelId ?? this.channelId,
      agoraTokenCaller: agoraTokenCaller ?? this.agoraTokenCaller,
      agoraTokenCallee: agoraTokenCallee ?? this.agoraTokenCallee,
      status: status ?? this.status,
      speakerRate: speakerRate ?? this.speakerRate,
      listenerRate: listenerRate ?? this.listenerRate,
      platformPercent: platformPercent ?? this.platformPercent,
      reservedUpfront: reservedUpfront ?? this.reservedUpfront,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      endedAtMs: endedAtMs ?? this.endedAtMs,
      endedBy: endedBy ?? this.endedBy,
      endedReason: endedReason ?? this.endedReason,
      rejectedReason: rejectedReason ?? this.rejectedReason,
      endedSeconds: endedSeconds ?? this.endedSeconds,
      reserveReleased: reserveReleased ?? this.reserveReleased,
      reserveReleasedAt: reserveReleasedAt ?? this.reserveReleasedAt,
      settled: settled ?? this.settled,
      settledAt: settledAt ?? this.settledAt,
      listenerCredited: listenerCredited ?? this.listenerCredited,
      listenerCreditedAt: listenerCreditedAt ?? this.listenerCreditedAt,
      seconds: seconds ?? this.seconds,
      billedMinutes: billedMinutes ?? this.billedMinutes,
      paidMinutes: paidMinutes ?? this.paidMinutes,
      speakerCharge: speakerCharge ?? this.speakerCharge,
      listenerPayout: listenerPayout ?? this.listenerPayout,
      platformProfit: platformProfit ?? this.platformProfit,
      missedCallPushSent: missedCallPushSent ?? this.missedCallPushSent,
      missedCallPushSentAt: missedCallPushSentAt ?? this.missedCallPushSentAt,
      missedCallPushSentAtMs:
          missedCallPushSentAtMs ?? this.missedCallPushSentAtMs,
      incomingPushAttempted:
          incomingPushAttempted ?? this.incomingPushAttempted,
      incomingPushDelivered:
          incomingPushDelivered ?? this.incomingPushDelivered,
      incomingPushSuccessCount:
          incomingPushSuccessCount ?? this.incomingPushSuccessCount,
      incomingPushFailureCount:
          incomingPushFailureCount ?? this.incomingPushFailureCount,
      incomingPushAttemptedAt:
          incomingPushAttemptedAt ?? this.incomingPushAttemptedAt,
      incomingPushAttemptedAtMs:
          incomingPushAttemptedAtMs ?? this.incomingPushAttemptedAtMs,
      incomingPushNoTokens:
          incomingPushNoTokens ?? this.incomingPushNoTokens,
      incomingPushError: incomingPushError ?? this.incomingPushError,
      cancelSignalSent: cancelSignalSent ?? this.cancelSignalSent,
      cancelSignalSentAt: cancelSignalSentAt ?? this.cancelSignalSentAt,
      cancelSignalSentAtMs: cancelSignalSentAtMs ?? this.cancelSignalSentAtMs,
      settlementVersion: settlementVersion ?? this.settlementVersion,
      settlementIdempotencyKey:
          settlementIdempotencyKey ?? this.settlementIdempotencyKey,
      reserveReleaseIdempotencyKey:
          reserveReleaseIdempotencyKey ?? this.reserveReleaseIdempotencyKey,
      callerChargeTxId: callerChargeTxId ?? this.callerChargeTxId,
      listenerPayoutTxId: listenerPayoutTxId ?? this.listenerPayoutTxId,
      platformRevenueTxId:
          platformRevenueTxId ?? this.platformRevenueTxId,
      refundTxId: refundTxId ?? this.refundTxId,
      currency: currency ?? this.currency,
      gatewayContext: gatewayContext ?? this.gatewayContext,
      settlementSource: settlementSource ?? this.settlementSource,
    );
  }
}