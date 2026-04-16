class AnalyticsSummaryModel {
  final int totalUsers;
  final int totalListeners;
  final int availableListeners;

  final int totalCalls;
  final int ringingCalls;
  final int acceptedCalls;
  final int endedCalls;
  final int rejectedCalls;

  final int answeredCalls;
  final int missedCalls;
  final int paidCalls;
  final int freeCallsUnder60;

  final int totalSpeakerCharge;
  final int totalListenerPayout;
  final int totalPlatformProfit;

  final int totalReviews;
  final double averageReviewStars;

  final int totalWalletTransactions;
  final int totalWithdrawalRequests;
  final int pendingWithdrawalRequests;

  const AnalyticsSummaryModel({
    required this.totalUsers,
    required this.totalListeners,
    required this.availableListeners,
    required this.totalCalls,
    required this.ringingCalls,
    required this.acceptedCalls,
    required this.endedCalls,
    required this.rejectedCalls,
    required this.answeredCalls,
    required this.missedCalls,
    required this.paidCalls,
    required this.freeCallsUnder60,
    required this.totalSpeakerCharge,
    required this.totalListenerPayout,
    required this.totalPlatformProfit,
    required this.totalReviews,
    required this.averageReviewStars,
    required this.totalWalletTransactions,
    required this.totalWithdrawalRequests,
    required this.pendingWithdrawalRequests,
  });

  factory AnalyticsSummaryModel.empty() {
    return const AnalyticsSummaryModel(
      totalUsers: 0,
      totalListeners: 0,
      availableListeners: 0,
      totalCalls: 0,
      ringingCalls: 0,
      acceptedCalls: 0,
      endedCalls: 0,
      rejectedCalls: 0,
      answeredCalls: 0,
      missedCalls: 0,
      paidCalls: 0,
      freeCallsUnder60: 0,
      totalSpeakerCharge: 0,
      totalListenerPayout: 0,
      totalPlatformProfit: 0,
      totalReviews: 0,
      averageReviewStars: 0,
      totalWalletTransactions: 0,
      totalWithdrawalRequests: 0,
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

  double get paidCallRate {
    if (answeredCalls <= 0) return 0;
    return paidCalls / answeredCalls;
  }

  String get answerRateLabel => '${(answerRate * 100).toStringAsFixed(1)}%';
  String get missedRateLabel => '${(missedRate * 100).toStringAsFixed(1)}%';
  String get paidCallRateLabel =>
      '${(paidCallRate * 100).toStringAsFixed(1)}%';

  Map<String, dynamic> toMap() {
    return {
      'totalUsers': totalUsers,
      'totalListeners': totalListeners,
      'availableListeners': availableListeners,
      'totalCalls': totalCalls,
      'ringingCalls': ringingCalls,
      'acceptedCalls': acceptedCalls,
      'endedCalls': endedCalls,
      'rejectedCalls': rejectedCalls,
      'answeredCalls': answeredCalls,
      'missedCalls': missedCalls,
      'paidCalls': paidCalls,
      'freeCallsUnder60': freeCallsUnder60,
      'totalSpeakerCharge': totalSpeakerCharge,
      'totalListenerPayout': totalListenerPayout,
      'totalPlatformProfit': totalPlatformProfit,
      'totalReviews': totalReviews,
      'averageReviewStars': averageReviewStars,
      'totalWalletTransactions': totalWalletTransactions,
      'totalWithdrawalRequests': totalWithdrawalRequests,
      'pendingWithdrawalRequests': pendingWithdrawalRequests,
    };
  }
}