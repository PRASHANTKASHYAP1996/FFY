class DailyAnalyticsModel {
  final String dayKey;

  final int newUsers;
  final int totalCalls;
  final int answeredCalls;
  final int missedCalls;
  final int paidCalls;
  final int freeAnsweredCalls;

  final int totalSpeakerCharge;
  final int totalListenerPayout;
  final int totalPlatformProfit;

  final int walletTransactions;
  final int withdrawalRequests;
  final int pendingWithdrawalRequests;

  const DailyAnalyticsModel({
    required this.dayKey,
    required this.newUsers,
    required this.totalCalls,
    required this.answeredCalls,
    required this.missedCalls,
    required this.paidCalls,
    required this.freeAnsweredCalls,
    required this.totalSpeakerCharge,
    required this.totalListenerPayout,
    required this.totalPlatformProfit,
    required this.walletTransactions,
    required this.withdrawalRequests,
    required this.pendingWithdrawalRequests,
  });

  factory DailyAnalyticsModel.empty({required String dayKey}) {
    return DailyAnalyticsModel(
      dayKey: dayKey,
      newUsers: 0,
      totalCalls: 0,
      answeredCalls: 0,
      missedCalls: 0,
      paidCalls: 0,
      freeAnsweredCalls: 0,
      totalSpeakerCharge: 0,
      totalListenerPayout: 0,
      totalPlatformProfit: 0,
      walletTransactions: 0,
      withdrawalRequests: 0,
      pendingWithdrawalRequests: 0,
    );
  }

  double get answerRate {
    if (totalCalls <= 0) return 0;
    return answeredCalls / totalCalls;
  }

  double get missedRate {
    if (totalCalls <= 0) return 0;
    return missedCalls / totalCalls;
  }

  String get answerRateLabel => '${(answerRate * 100).toStringAsFixed(1)}%';
  String get missedRateLabel => '${(missedRate * 100).toStringAsFixed(1)}%';

  Map<String, dynamic> toMap() {
    return {
      'dayKey': dayKey,
      'newUsers': newUsers,
      'totalCalls': totalCalls,
      'answeredCalls': answeredCalls,
      'missedCalls': missedCalls,
      'paidCalls': paidCalls,
      'freeAnsweredCalls': freeAnsweredCalls,
      'totalSpeakerCharge': totalSpeakerCharge,
      'totalListenerPayout': totalListenerPayout,
      'totalPlatformProfit': totalPlatformProfit,
      'walletTransactions': walletTransactions,
      'withdrawalRequests': withdrawalRequests,
      'pendingWithdrawalRequests': pendingWithdrawalRequests,
    };
  }
}