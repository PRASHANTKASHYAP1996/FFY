class AnalyticsDayPoint {
  final String dayKey;
  final String shortLabel;

  final int newUsers;
  final int totalCalls;
  final int answeredCalls;
  final int missedCalls;
  final int paidCalls;

  final int totalSpeakerCharge;
  final int totalListenerPayout;
  final int totalPlatformProfit;

  const AnalyticsDayPoint({
    required this.dayKey,
    required this.shortLabel,
    required this.newUsers,
    required this.totalCalls,
    required this.answeredCalls,
    required this.missedCalls,
    required this.paidCalls,
    required this.totalSpeakerCharge,
    required this.totalListenerPayout,
    required this.totalPlatformProfit,
  });

  Map<String, dynamic> toMap() {
    return {
      'dayKey': dayKey,
      'shortLabel': shortLabel,
      'newUsers': newUsers,
      'totalCalls': totalCalls,
      'answeredCalls': answeredCalls,
      'missedCalls': missedCalls,
      'paidCalls': paidCalls,
      'totalSpeakerCharge': totalSpeakerCharge,
      'totalListenerPayout': totalListenerPayout,
      'totalPlatformProfit': totalPlatformProfit,
    };
  }

  Map<String, dynamic> toJson() => toMap();
}

class AnalyticsTimeseriesModel {
  final List<AnalyticsDayPoint> points;

  const AnalyticsTimeseriesModel({
    required this.points,
  });

  factory AnalyticsTimeseriesModel.empty() {
    return const AnalyticsTimeseriesModel(points: <AnalyticsDayPoint>[]);
  }

  Map<String, dynamic> toMap() {
    return {
      'points': points.map((e) => e.toMap()).toList(),
    };
  }
}