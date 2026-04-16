import 'package:cloud_functions/cloud_functions.dart';

import '../shared/models/analytics_summary_model.dart';
import '../shared/models/analytics_timeseries_model.dart';
import '../shared/models/daily_analytics_model.dart';
import '../shared/models/listener_leaderboard_item.dart';
import '../shared/models/retention_analytics_model.dart';

class AnalyticsRepository {
  AnalyticsRepository._();

  static final AnalyticsRepository instance = AnalyticsRepository._();

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  double _asDouble(dynamic value, {double fallback = 0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    return fallback;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<Map<String, dynamic>> _callMap(
    String name, {
    Map<String, dynamic>? data,
  }) async {
    final callable = _functions.httpsCallable(name);
    final result = await callable.call<Map<String, dynamic>>(
      data ?? <String, dynamic>{},
    );
    return _asMap(result.data);
  }

  AnalyticsSummaryModel _summaryFromMap(Map<String, dynamic> map) {
    return AnalyticsSummaryModel(
      totalUsers: _asInt(map['totalUsers']),
      totalListeners: _asInt(map['totalListeners']),
      availableListeners: _asInt(map['availableListeners']),
      totalCalls: _asInt(map['totalCalls']),
      ringingCalls: _asInt(map['ringingCalls']),
      acceptedCalls: _asInt(map['acceptedCalls']),
      endedCalls: _asInt(map['endedCalls']),
      rejectedCalls: _asInt(map['rejectedCalls']),
      answeredCalls: _asInt(map['answeredCalls']),
      missedCalls: _asInt(map['missedCalls']),
      paidCalls: _asInt(map['paidCalls']),
      freeCallsUnder60: _asInt(map['freeCallsUnder60']),
      totalSpeakerCharge: _asInt(map['totalSpeakerCharge']),
      totalListenerPayout: _asInt(map['totalListenerPayout']),
      totalPlatformProfit: _asInt(map['totalPlatformProfit']),
      totalReviews: _asInt(map['totalReviews']),
      averageReviewStars: _asDouble(map['averageReviewStars']),
      totalWalletTransactions: _asInt(map['totalWalletTransactions']),
      totalWithdrawalRequests: _asInt(map['totalWithdrawalRequests']),
      pendingWithdrawalRequests: _asInt(map['pendingWithdrawalRequests']),
    );
  }

  DailyAnalyticsModel _dailyFromMap(Map<String, dynamic> map) {
    return DailyAnalyticsModel(
      dayKey: _asString(map['dayKey']),
      newUsers: _asInt(map['newUsers']),
      totalCalls: _asInt(map['totalCalls']),
      answeredCalls: _asInt(map['answeredCalls']),
      missedCalls: _asInt(map['missedCalls']),
      paidCalls: _asInt(map['paidCalls']),
      freeAnsweredCalls: _asInt(map['freeAnsweredCalls']),
      totalSpeakerCharge: _asInt(map['totalSpeakerCharge']),
      totalListenerPayout: _asInt(map['totalListenerPayout']),
      totalPlatformProfit: _asInt(map['totalPlatformProfit']),
      walletTransactions: _asInt(map['walletTransactions']),
      withdrawalRequests: _asInt(map['withdrawalRequests']),
      pendingWithdrawalRequests: _asInt(map['pendingWithdrawalRequests']),
    );
  }

  RepeatPairItem _repeatPairFromMap(Map<String, dynamic> map) {
    return RepeatPairItem(
      callerId: _asString(map['callerId']),
      callerName: _asString(map['callerName'], fallback: 'Caller'),
      listenerId: _asString(map['listenerId']),
      listenerName: _asString(map['listenerName'], fallback: 'Listener'),
      totalCalls: _asInt(map['totalCalls']),
      answeredCalls: _asInt(map['answeredCalls']),
      paidCalls: _asInt(map['paidCalls']),
    );
  }

  RetentionAnalyticsModel _retentionFromMap(Map<String, dynamic> map) {
    final topRepeatPairs = _asMapList(map['topRepeatPairs'])
        .map(_repeatPairFromMap)
        .toList();

    return RetentionAnalyticsModel(
      uniqueCallers: _asInt(map['uniqueCallers']),
      uniqueListeners: _asInt(map['uniqueListeners']),
      repeatCallers: _asInt(map['repeatCallers']),
      repeatListeners: _asInt(map['repeatListeners']),
      usersWithMultipleCalls: _asInt(map['usersWithMultipleCalls']),
      repeatPairsCount: _asInt(map['repeatPairsCount']),
      topRepeatPairs: topRepeatPairs,
    );
  }

  AnalyticsDayPoint _timeseriesPointFromMap(Map<String, dynamic> map) {
    return AnalyticsDayPoint(
      dayKey: _asString(map['dayKey']),
      shortLabel: _asString(map['shortLabel']),
      newUsers: _asInt(map['newUsers']),
      totalCalls: _asInt(map['totalCalls']),
      answeredCalls: _asInt(map['answeredCalls']),
      missedCalls: _asInt(map['missedCalls']),
      paidCalls: _asInt(map['paidCalls']),
      totalSpeakerCharge: _asInt(map['totalSpeakerCharge']),
      totalListenerPayout: _asInt(map['totalListenerPayout']),
      totalPlatformProfit: _asInt(map['totalPlatformProfit']),
    );
  }

  AnalyticsTimeseriesModel _timeseriesFromMap(Map<String, dynamic> map) {
    final points =
        _asMapList(map['points']).map(_timeseriesPointFromMap).toList();
    return AnalyticsTimeseriesModel(points: points);
  }

  ListenerLeaderboardItem _leaderboardItemFromMap(Map<String, dynamic> map) {
    return ListenerLeaderboardItem(
      uid: _asString(map['uid']),
      displayName: _asString(map['displayName'], fallback: 'Listener'),
      followersCount: _asInt(map['followersCount']),
      ratingAvg: _asDouble(map['ratingAvg']),
      ratingCount: _asInt(map['ratingCount']),
      totalEarned: _asInt(map['totalEarned']),
      paidCalls: _asInt(map['paidCalls']),
      isAvailable: _asBool(map['isAvailable']),
    );
  }

  Future<AnalyticsSummaryModel> loadSummary() async {
    final map = await _callMap('analyticsLoadSummary_v1');
    return _summaryFromMap(map);
  }

  Future<List<ListenerLeaderboardItem>> loadListenerLeaderboard() async {
    final map = await _callMap('analyticsLoadListenerLeaderboard_v1');
    return _asMapList(map['items']).map(_leaderboardItemFromMap).toList();
  }

  List<ListenerLeaderboardItem> topEarners(
    List<ListenerLeaderboardItem> items,
  ) {
    final out = [...items]
      ..sort((a, b) {
        final earnCompare = b.totalEarned.compareTo(a.totalEarned);
        if (earnCompare != 0) return earnCompare;

        final paidCompare = b.paidCalls.compareTo(a.paidCalls);
        if (paidCompare != 0) return paidCompare;

        return b.followersCount.compareTo(a.followersCount);
      });

    return out.take(10).toList();
  }

  List<ListenerLeaderboardItem> topRated(List<ListenerLeaderboardItem> items) {
    final out = items.where((e) => e.ratingCount > 0).toList()
      ..sort((a, b) {
        final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
        if (ratingCompare != 0) return ratingCompare;

        final ratingCountCompare = b.ratingCount.compareTo(a.ratingCount);
        if (ratingCountCompare != 0) return ratingCountCompare;

        return b.followersCount.compareTo(a.followersCount);
      });

    return out.take(10).toList();
  }

  List<ListenerLeaderboardItem> mostFollowed(
    List<ListenerLeaderboardItem> items,
  ) {
    final out = [...items]
      ..sort((a, b) {
        final followerCompare = b.followersCount.compareTo(a.followersCount);
        if (followerCompare != 0) return followerCompare;

        final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
        if (ratingCompare != 0) return ratingCompare;

        return b.totalEarned.compareTo(a.totalEarned);
      });

    return out.take(10).toList();
  }

  Future<DailyAnalyticsModel> loadTodaySummary() async {
    final map = await _callMap('analyticsLoadTodaySummary_v1');
    return _dailyFromMap(map);
  }

  Future<RetentionAnalyticsModel> loadRetentionSummary() async {
    final map = await _callMap('analyticsLoadRetentionSummary_v1');
    return _retentionFromMap(map);
  }

  Future<AnalyticsTimeseriesModel> loadLast7DaysTimeseries() async {
    final map = await _callMap('analyticsLoadLast7DaysTimeseries_v1');
    return _timeseriesFromMap(map);
  }
}