class CallTiming {
  const CallTiming._();

  static const int incomingRingTimeoutSeconds = 45;
  static const int callerWaitingTimeoutSeconds = incomingRingTimeoutSeconds;
  static const int fcmTtlSeconds = incomingRingTimeoutSeconds;
  static const int billingGraceSeconds = 60;
  static const int autoCancelDisplaySeconds = incomingRingTimeoutSeconds;

  static const Duration incomingRingTimeout =
      Duration(seconds: incomingRingTimeoutSeconds);
  static const Duration callerWaitingTimeout =
      Duration(seconds: callerWaitingTimeoutSeconds);
  static const Duration fcmTtl = Duration(seconds: fcmTtlSeconds);
  static const Duration billingGrace = Duration(seconds: billingGraceSeconds);
}
