class RepeatPairItem {
  final String callerId;
  final String callerName;
  final String listenerId;
  final String listenerName;
  final int totalCalls;
  final int answeredCalls;
  final int paidCalls;

  const RepeatPairItem({
    required this.callerId,
    required this.callerName,
    required this.listenerId,
    required this.listenerName,
    required this.totalCalls,
    required this.answeredCalls,
    required this.paidCalls,
  });

  Map<String, dynamic> toMap() {
    return {
      'callerId': callerId,
      'callerName': callerName,
      'listenerId': listenerId,
      'listenerName': listenerName,
      'totalCalls': totalCalls,
      'answeredCalls': answeredCalls,
      'paidCalls': paidCalls,
    };
  }
}

class RetentionAnalyticsModel {
  final int uniqueCallers;
  final int uniqueListeners;
  final int repeatCallers;
  final int repeatListeners;
  final int usersWithMultipleCalls;
  final int repeatPairsCount;
  final List<RepeatPairItem> topRepeatPairs;

  const RetentionAnalyticsModel({
    required this.uniqueCallers,
    required this.uniqueListeners,
    required this.repeatCallers,
    required this.repeatListeners,
    required this.usersWithMultipleCalls,
    required this.repeatPairsCount,
    required this.topRepeatPairs,
  });

  factory RetentionAnalyticsModel.empty() {
    return const RetentionAnalyticsModel(
      uniqueCallers: 0,
      uniqueListeners: 0,
      repeatCallers: 0,
      repeatListeners: 0,
      usersWithMultipleCalls: 0,
      repeatPairsCount: 0,
      topRepeatPairs: <RepeatPairItem>[],
    );
  }

  double get repeatCallerRate {
    if (uniqueCallers <= 0) return 0;
    return repeatCallers / uniqueCallers;
  }

  double get repeatListenerRate {
    if (uniqueListeners <= 0) return 0;
    return repeatListeners / uniqueListeners;
  }

  String get repeatCallerRateLabel =>
      '${(repeatCallerRate * 100).toStringAsFixed(1)}%';

  String get repeatListenerRateLabel =>
      '${(repeatListenerRate * 100).toStringAsFixed(1)}%';

  Map<String, dynamic> toMap() {
    return {
      'uniqueCallers': uniqueCallers,
      'uniqueListeners': uniqueListeners,
      'repeatCallers': repeatCallers,
      'repeatListeners': repeatListeners,
      'usersWithMultipleCalls': usersWithMultipleCalls,
      'repeatPairsCount': repeatPairsCount,
      'topRepeatPairs': topRepeatPairs.map((e) => e.toMap()).toList(),
    };
  }
}