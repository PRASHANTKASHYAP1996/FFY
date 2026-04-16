import 'package:flutter/material.dart';

import '../repositories/analytics_repository.dart';
import '../shared/models/analytics_summary_model.dart';
import '../shared/models/analytics_timeseries_model.dart';
import '../shared/models/daily_analytics_model.dart';
import '../shared/models/retention_analytics_model.dart';
import 'listener_leaderboard_screen.dart';

class AnalyticsDashboardScreen extends StatefulWidget {
  const AnalyticsDashboardScreen({super.key});

  @override
  State<AnalyticsDashboardScreen> createState() =>
      _AnalyticsDashboardScreenState();
}

class _AnalyticsDashboardScreenState extends State<AnalyticsDashboardScreen> {
  final AnalyticsRepository _repository = AnalyticsRepository.instance;

  late Future<AnalyticsSummaryModel> _summaryFuture;
  late Future<DailyAnalyticsModel> _todayFuture;
  late Future<RetentionAnalyticsModel> _retentionFuture;
  late Future<AnalyticsTimeseriesModel> _timeseriesFuture;
  late Future<List<dynamic>> _leaderboardFuture;

  Map<String, dynamic>? _summaryMeta;
  Map<String, dynamic>? _todayMeta;
  Map<String, dynamic>? _retentionMeta;
  Map<String, dynamic>? _timeseriesMeta;
  Map<String, dynamic>? _leaderboardMeta;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  void _loadAll() {
    _summaryFuture = _loadSummaryWithMeta();
    _todayFuture = _loadTodayWithMeta();
    _retentionFuture = _loadRetentionWithMeta();
    _timeseriesFuture = _loadTimeseriesWithMeta();
    _leaderboardFuture = _loadLeaderboardWithMeta();
  }

  Future<AnalyticsSummaryModel> _loadSummaryWithMeta() async {
    final model = await _repository.loadSummary();
    try {
      final dynamic repo = _repository;
      final dynamic meta = repo.lastSummaryMeta;
      if (meta is Map) {
        _summaryMeta = Map<String, dynamic>.from(meta);
      } else {
        _summaryMeta = null;
      }
    } catch (_) {
      _summaryMeta = null;
    }
    return model;
  }

  Future<DailyAnalyticsModel> _loadTodayWithMeta() async {
    final model = await _repository.loadTodaySummary();
    try {
      final dynamic repo = _repository;
      final dynamic meta = repo.lastTodayMeta;
      if (meta is Map) {
        _todayMeta = Map<String, dynamic>.from(meta);
      } else {
        _todayMeta = null;
      }
    } catch (_) {
      _todayMeta = null;
    }
    return model;
  }

  Future<RetentionAnalyticsModel> _loadRetentionWithMeta() async {
    final model = await _repository.loadRetentionSummary();
    try {
      final dynamic repo = _repository;
      final dynamic meta = repo.lastRetentionMeta;
      if (meta is Map) {
        _retentionMeta = Map<String, dynamic>.from(meta);
      } else {
        _retentionMeta = null;
      }
    } catch (_) {
      _retentionMeta = null;
    }
    return model;
  }

  Future<AnalyticsTimeseriesModel> _loadTimeseriesWithMeta() async {
    final model = await _repository.loadLast7DaysTimeseries();
    try {
      final dynamic repo = _repository;
      final dynamic meta = repo.lastTimeseriesMeta;
      if (meta is Map) {
        _timeseriesMeta = Map<String, dynamic>.from(meta);
      } else {
        _timeseriesMeta = null;
      }
    } catch (_) {
      _timeseriesMeta = null;
    }
    return model;
  }

  Future<List<dynamic>> _loadLeaderboardWithMeta() async {
    final items = await _repository.loadListenerLeaderboard();
    try {
      final dynamic repo = _repository;
      final dynamic meta = repo.lastLeaderboardMeta;
      if (meta is Map) {
        _leaderboardMeta = Map<String, dynamic>.from(meta);
      } else {
        _leaderboardMeta = null;
      }
    } catch (_) {
      _leaderboardMeta = null;
    }
    return items;
  }

  Future<void> _reload() async {
    setState(() {
      _summaryMeta = null;
      _todayMeta = null;
      _retentionMeta = null;
      _timeseriesMeta = null;
      _leaderboardMeta = null;
      _loadAll();
    });
    await Future.wait<void>([
      _summaryFuture.then((_) {}),
      _todayFuture.then((_) {}),
      _retentionFuture.then((_) {}),
      _timeseriesFuture.then((_) {}),
      _leaderboardFuture.then((_) {}),
    ]);
  }

  bool _looksLikePermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission denied') ||
        text.contains('admin only') ||
        text.contains('unauthenticated');
  }

  int _pointInt(dynamic point, String field) {
    try {
      final value = (point as dynamic).toJson()[field];
      if (value is int) return value;
      if (value is num) return value.floor();
    } catch (_) {
      try {
        final value = (point as dynamic).toMap()[field];
        if (value is int) return value;
        if (value is num) return value.floor();
      } catch (_) {
        try {
          final dynamic value = switch (field) {
            'totalCalls' => (point as dynamic).totalCalls,
            'totalSpeakerCharge' => (point as dynamic).totalSpeakerCharge,
            'totalPlatformProfit' => (point as dynamic).totalPlatformProfit,
            'newUsers' => (point as dynamic).newUsers,
            _ => null,
          };
          if (value is int) return value;
          if (value is num) return value.floor();
        } catch (_) {
          // ignore
        }
      }
    }
    return 0;
  }

  String _pointLabel(dynamic point) {
    try {
      final value = (point as dynamic).toJson()['shortLabel'];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    } catch (_) {
      try {
        final value = (point as dynamic).toMap()['shortLabel'];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      } catch (_) {
        try {
          final value = (point as dynamic).shortLabel;
          if (value is String && value.trim().isNotEmpty) return value.trim();
        } catch (_) {
          // ignore
        }
      }
    }
    return '--';
  }

  bool _metaBool(
    Map<String, dynamic>? meta,
    List<String> path, {
    bool fallback = false,
  }) {
    dynamic current = meta;
    for (final segment in path) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return fallback;
      }
    }

    if (current is bool) return current;
    if (current is num) return current != 0;
    if (current is String) {
      final safe = current.trim().toLowerCase();
      if (safe == 'true') return true;
      if (safe == 'false') return false;
    }
    return fallback;
  }

  int _metaInt(
    Map<String, dynamic>? meta,
    List<String> path, {
    int fallback = 0,
  }) {
    dynamic current = meta;
    for (final segment in path) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return fallback;
      }
    }

    if (current is int) return current;
    if (current is num) return current.floor();
    if (current is String) return int.tryParse(current.trim()) ?? fallback;
    return fallback;
  }

  String _coverageMode(Map<String, dynamic>? meta) {
    final coverage = meta == null ? null : meta['coverage'];
    if (coverage is Map) {
      final value = coverage['mode'];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return '';
  }

  bool _isSampled(Map<String, dynamic>? meta) {
    final fromCoverage = _metaBool(meta, ['coverage', 'sampled']);
    if (fromCoverage) return true;
    return _metaBool(meta, ['truthFlags', 'summaryUsesSampledCalls']) ||
        _metaBool(meta, ['truthFlags', 'retentionUsesSampledCalls']) ||
        _metaBool(meta, ['truthFlags', 'leaderboardUsesSampledCalls']);
  }

  bool _isAuthoritativeMoney(Map<String, dynamic>? meta) {
    return _metaBool(
      meta,
      ['truthFlags', 'authoritativeMoneyTotals'],
      fallback: _metaBool(meta, ['coverage', 'authoritativeMoneyTotals']),
    );
  }

  bool _isAuthoritativeAnsweredMissed(Map<String, dynamic>? meta) {
    return _metaBool(
      meta,
      ['truthFlags', 'authoritativeAnsweredMissedTotals'],
      fallback: _metaBool(
        meta,
        ['coverage', 'authoritativeAnsweredMissedTotals'],
      ),
    );
  }

  String _metaBadgeText(Map<String, dynamic>? meta, {String fallback = ''}) {
    final mode = _coverageMode(meta);

    switch (mode) {
      case 'full_window':
        return 'Window-based';
      case 'recent_sample':
        return 'Sample-based';
      default:
        if (_isSampled(meta)) return 'Sample-based';
        return fallback;
    }
  }

  Widget _metaChip(
    String text, {
    Color bg = const Color(0xFFF3F4F8),
    Color fg = const Color(0xFF374151),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }

  Widget _truthNoticeCard() {
    final summarySampled = _isSampled(_summaryMeta);
    final retentionSampled = _isSampled(_retentionMeta);
    final leaderboardSampled = _isSampled(_leaderboardMeta);
    final timeseriesSampled = _isSampled(_timeseriesMeta);

    final sampledSummaryCount = _metaInt(
      _summaryMeta,
      ['coverage', 'sampledCalls'],
    );
    final sampledRetentionCount = _metaInt(
      _retentionMeta,
      ['coverage', 'sampledCalls'],
    );
    final sampledLeaderboardCount = _metaInt(
      _leaderboardMeta,
      ['coverage', 'sampledCalls'],
    );

    final points = <String>[];

    if (summarySampled) {
      points.add(
        sampledSummaryCount > 0
            ? 'Summary answered/missed/paid and money totals are based on a recent call sample ($sampledSummaryCount calls), not guaranteed full-history totals.'
            : 'Summary answered/missed/paid and money totals are sample-based, not guaranteed full-history totals.',
      );
    }

    if (!summarySampled &&
        (_isAuthoritativeMoney(_summaryMeta) ||
            _isAuthoritativeAnsweredMissed(_summaryMeta))) {
      points.add('Summary totals are being served from a stronger backend coverage mode.');
    }

    if (retentionSampled) {
      points.add(
        sampledRetentionCount > 0
            ? 'Retention and repeat usage are based on a recent call sample ($sampledRetentionCount calls).'
            : 'Retention and repeat usage are based on recent sampled calls.',
      );
    }

    if (leaderboardSampled) {
      points.add(
        sampledLeaderboardCount > 0
            ? 'Leaderboard earnings ranking is based on recent ended-call sample data ($sampledLeaderboardCount calls).'
            : 'Leaderboard earnings ranking is based on recent ended-call sample data.',
      );
    }

    if (timeseriesSampled) {
      points.add('Last 7 day trends are not full-window authoritative in this backend response.');
    } else if (_coverageMode(_timeseriesMeta) == 'full_window') {
      points.add('Last 7 day trend cards are calculated from explicit date-window queries.');
    }

    if (points.isEmpty) {
      points.add('This dashboard is backend-fed and intended to improve admin truthfulness over direct client-side collection reads.');
    }

    return Card(
      color: const Color(0xFFFFFBEB),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Truthfulness note',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 8),
            ...List.generate(points.length, (index) {
              return Padding(
                padding: EdgeInsets.only(bottom: index == points.length - 1 ? 0 : 8),
                child: Text(
                  '• ${points[index]}',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    String? subtitle,
    Color? color,
  }) {
    final safeColor = color ?? const Color(0xFF4F46E5);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: safeColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: safeColor.withValues(alpha: 0.20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: safeColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
            ),
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, {String? subtitle, List<Widget>? chips}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: Color(0xFF111827),
          ),
        ),
        if (subtitle != null && subtitle.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (chips != null && chips.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips,
          ),
        ],
      ],
    );
  }

  Widget _summaryLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barRow({
    required String label,
    required int value,
    required int maxValue,
    Color? color,
  }) {
    final safeColor = color ?? const Color(0xFF4F46E5);
    final ratio = maxValue <= 0 ? 0.0 : (value / maxValue).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 12,
                color: safeColor,
                backgroundColor: safeColor.withValues(alpha: 0.12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _moneyBarRow({
    required String label,
    required int value,
    required int maxValue,
    Color? color,
  }) {
    final safeColor = color ?? const Color(0xFF15803D);
    final ratio = maxValue <= 0 ? 0.0 : (value / maxValue).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 12,
                color: safeColor,
                backgroundColor: safeColor.withValues(alpha: 0.12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 56,
            child: Text(
              '₹$value',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _trendCard({
    required String title,
    required List<dynamic> points,
    required int Function(dynamic point) valueBuilder,
    required String Function(dynamic point) labelBuilder,
    required Color color,
    required bool money,
  }) {
    int maxValue = 0;
    for (final point in points) {
      final value = valueBuilder(point);
      if (value > maxValue) {
        maxValue = value;
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 10),
            if (points.isEmpty)
              const Text(
                'No trend data yet.',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              ...points.map((point) {
                final label = labelBuilder(point);
                final value = valueBuilder(point);

                return money
                    ? _moneyBarRow(
                        label: label,
                        value: value,
                        maxValue: maxValue,
                        color: color,
                      )
                    : _barRow(
                        label: label,
                        value: value,
                        maxValue: maxValue,
                        color: color,
                      );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendSection(AnalyticsTimeseriesModel t) {
    final points = List<dynamic>.from(t.points);
    final chips = <Widget>[];

    final badge = _metaBadgeText(_timeseriesMeta);
    if (badge.isNotEmpty) {
      chips.add(
        _metaChip(
          badge,
          bg: const Color(0xFFEEF2FF),
          fg: const Color(0xFF312E81),
        ),
      );
    }

    if (_coverageMode(_timeseriesMeta) == 'full_window') {
      chips.add(
        _metaChip(
          'Last 7 day window',
          bg: const Color(0xFFECFDF3),
          fg: const Color(0xFF15803D),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          'Last 7 Days Trends',
          subtitle:
              'Backend-generated daily view of calls, users, revenue, and profit.',
          chips: chips,
        ),
        const SizedBox(height: 10),
        _trendCard(
          title: 'Calls per day',
          points: points,
          valueBuilder: (point) => _pointInt(point, 'totalCalls'),
          labelBuilder: (point) => _pointLabel(point),
          color: const Color(0xFF4F46E5),
          money: false,
        ),
        const SizedBox(height: 10),
        _trendCard(
          title: 'Revenue per day',
          points: points,
          valueBuilder: (point) => _pointInt(point, 'totalSpeakerCharge'),
          labelBuilder: (point) => _pointLabel(point),
          color: const Color(0xFFDC2626),
          money: true,
        ),
        const SizedBox(height: 10),
        _trendCard(
          title: 'Profit per day',
          points: points,
          valueBuilder: (point) => _pointInt(point, 'totalPlatformProfit'),
          labelBuilder: (point) => _pointLabel(point),
          color: const Color(0xFFD97706),
          money: true,
        ),
        const SizedBox(height: 10),
        _trendCard(
          title: 'New users per day',
          points: points,
          valueBuilder: (point) => _pointInt(point, 'newUsers'),
          labelBuilder: (point) => _pointLabel(point),
          color: const Color(0xFF15803D),
          money: false,
        ),
      ],
    );
  }

  Widget _buildTodaySection(DailyAnalyticsModel d) {
    final chips = <Widget>[];

    final badge = _metaBadgeText(_todayMeta);
    if (badge.isNotEmpty) {
      chips.add(
        _metaChip(
          badge,
          bg: const Color(0xFFECFDF3),
          fg: const Color(0xFF15803D),
        ),
      );
    }

    if (_isAuthoritativeMoney(_todayMeta)) {
      chips.add(
        _metaChip(
          'Money totals stronger',
          bg: const Color(0xFFFFFBEB),
          fg: const Color(0xFFD97706),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          'Today (${d.dayKey})',
          subtitle: 'Current day backend summary.',
          chips: chips,
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.35,
          children: [
            _metricCard(
              title: 'New users',
              value: '${d.newUsers}',
              color: const Color(0xFF4F46E5),
            ),
            _metricCard(
              title: 'Today calls',
              value: '${d.totalCalls}',
              color: const Color(0xFF2563EB),
            ),
            _metricCard(
              title: 'Answered today',
              value: '${d.answeredCalls}',
              subtitle: 'Answer rate ${d.answerRateLabel}',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              title: 'Missed today',
              value: '${d.missedCalls}',
              subtitle: 'Missed rate ${d.missedRateLabel}',
              color: const Color(0xFFDC2626),
            ),
            _metricCard(
              title: 'Paid calls today',
              value: '${d.paidCalls}',
              color: const Color(0xFF7C3AED),
            ),
            _metricCard(
              title: 'Free answered (<60s)',
              value: '${d.freeAnsweredCalls}',
              color: const Color(0xFFD97706),
            ),
            _metricCard(
              title: 'Charged today',
              value: '₹${d.totalSpeakerCharge}',
              color: const Color(0xFFDC2626),
            ),
            _metricCard(
              title: 'Payout today',
              value: '₹${d.totalListenerPayout}',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              title: 'Profit today',
              value: '₹${d.totalPlatformProfit}',
              color: const Color(0xFFD97706),
            ),
            _metricCard(
              title: 'Wallet tx today',
              value: '${d.walletTransactions}',
              color: const Color(0xFF4F46E5),
            ),
            _metricCard(
              title: 'Withdrawals today',
              value: '${d.withdrawalRequests}',
              color: const Color(0xFF92400E),
            ),
            _metricCard(
              title: 'Pending withdrawals',
              value: '${d.pendingWithdrawalRequests}',
              color: const Color(0xFFF59E0B),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRetentionSection(RetentionAnalyticsModel r) {
    final chips = <Widget>[];

    final badge = _metaBadgeText(_retentionMeta);
    if (badge.isNotEmpty) {
      chips.add(
        _metaChip(
          badge,
          bg: const Color(0xFFFFFBEB),
          fg: const Color(0xFFD97706),
        ),
      );
    }

    final sampled = _metaInt(_retentionMeta, ['coverage', 'sampledCalls']);
    if (sampled > 0) {
      chips.add(
        _metaChip(
          'Sample $sampled calls',
          bg: const Color(0xFFF3F4F8),
          fg: const Color(0xFF374151),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          'Retention & Repeat Usage',
          subtitle: 'See whether users come back and reuse the platform.',
          chips: chips,
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.35,
          children: [
            _metricCard(
              title: 'Unique callers',
              value: '${r.uniqueCallers}',
              color: const Color(0xFF4F46E5),
            ),
            _metricCard(
              title: 'Repeat callers',
              value: '${r.repeatCallers}',
              subtitle: 'Rate ${r.repeatCallerRateLabel}',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              title: 'Unique listeners',
              value: '${r.uniqueListeners}',
              color: const Color(0xFF7C3AED),
            ),
            _metricCard(
              title: 'Repeat listeners',
              value: '${r.repeatListeners}',
              subtitle: 'Rate ${r.repeatListenerRateLabel}',
              color: const Color(0xFFD97706),
            ),
            _metricCard(
              title: 'Users with multiple calls',
              value: '${r.usersWithMultipleCalls}',
              color: const Color(0xFF2563EB),
            ),
            _metricCard(
              title: 'Repeat caller-listener pairs',
              value: '${r.repeatPairsCount}',
              color: const Color(0xFFDC2626),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Top Repeat Pairs',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 10),
                if (r.topRepeatPairs.isEmpty)
                  const Text(
                    'No repeat caller-listener pairs yet.',
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else
                  ...List.generate(r.topRepeatPairs.length, (index) {
                    final pair = r.topRepeatPairs[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == r.topRepeatPairs.length - 1 ? 0 : 10,
                      ),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFE5E7EB),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${pair.callerName} → ${pair.listenerName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Total calls: ${pair.totalCalls}',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Answered: ${pair.answeredCalls} • Paid: ${pair.paidCalls}',
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody({
    required AnalyticsSummaryModel summary,
    required DailyAnalyticsModel today,
    required RetentionAnalyticsModel retention,
    required AnalyticsTimeseriesModel timeseries,
  }) {
    final summaryChips = <Widget>[];
    final summaryBadge = _metaBadgeText(_summaryMeta);
    if (summaryBadge.isNotEmpty) {
      summaryChips.add(
        _metaChip(
          summaryBadge,
          bg: const Color(0xFFFFFBEB),
          fg: const Color(0xFFD97706),
        ),
      );
    }

    final sampledSummaryCount = _metaInt(_summaryMeta, ['coverage', 'sampledCalls']);
    if (sampledSummaryCount > 0) {
      summaryChips.add(
        _metaChip(
          'Sample $sampledSummaryCount calls',
          bg: const Color(0xFFF3F4F8),
          fg: const Color(0xFF374151),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Friendify Analytics Dashboard',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Backend-fed analytics for admins. This screen prefers truthful read-side visibility over pretending every metric is full-history exact.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh Analytics'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ListenerLeaderboardScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.emoji_events_outlined),
                      label: const Text('Open Leaderboard'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _truthNoticeCard(),
        const SizedBox(height: 16),
        _buildTrendSection(timeseries),
        const SizedBox(height: 16),
        _buildTodaySection(today),
        const SizedBox(height: 16),
        _buildRetentionSection(retention),
        const SizedBox(height: 16),
        _sectionTitle(
          'Users',
          subtitle: 'Platform size and listener availability snapshot.',
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.35,
          children: [
            _metricCard(
              title: 'Total users',
              value: '${summary.totalUsers}',
              color: const Color(0xFF4F46E5),
            ),
            _metricCard(
              title: 'Total listeners',
              value: '${summary.totalListeners}',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              title: 'Available listeners',
              value: '${summary.availableListeners}',
              color: const Color(0xFFD97706),
            ),
            _metricCard(
              title: 'Total reviews',
              value: '${summary.totalReviews}',
              subtitle: 'Avg ${summary.averageReviewStars.toStringAsFixed(2)}★',
              color: const Color(0xFFF59E0B),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionTitle(
          'Calls',
          subtitle: 'Main call status and billing classification overview.',
          chips: summaryChips,
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.35,
          children: [
            _metricCard(
              title: 'Total calls',
              value: '${summary.totalCalls}',
              color: const Color(0xFF4F46E5),
            ),
            _metricCard(
              title: 'Answered calls',
              value: '${summary.answeredCalls}',
              subtitle: 'Answer rate ${summary.answerRateLabel}',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              title: 'Missed calls',
              value: '${summary.missedCalls}',
              subtitle: 'Missed rate ${summary.missedRateLabel}',
              color: const Color(0xFFDC2626),
            ),
            _metricCard(
              title: 'Paid calls',
              value: '${summary.paidCalls}',
              subtitle: 'Paid rate ${summary.paidCallRateLabel}',
              color: const Color(0xFF7C3AED),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _summaryLine('Ringing calls', '${summary.ringingCalls}'),
                _summaryLine('Accepted calls', '${summary.acceptedCalls}'),
                _summaryLine('Ended calls', '${summary.endedCalls}'),
                _summaryLine('Rejected calls', '${summary.rejectedCalls}'),
                _summaryLine(
                  'Free answered calls (<60s)',
                  '${summary.freeCallsUnder60}',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle(
          'Money',
          subtitle: 'Charges, payouts, profit, and wallet activity.',
          chips: [
            if (_isSampled(_summaryMeta))
              _metaChip(
                'Sample-based',
                bg: const Color(0xFFFEF2F2),
                fg: const Color(0xFFB91C1C),
              )
            else if (_isAuthoritativeMoney(_summaryMeta))
              _metaChip(
                'Stronger backend coverage',
                bg: const Color(0xFFECFDF3),
                fg: const Color(0xFF15803D),
              ),
          ],
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.35,
          children: [
            _metricCard(
              title: 'Total charged',
              value: '₹${summary.totalSpeakerCharge}',
              color: const Color(0xFFDC2626),
            ),
            _metricCard(
              title: 'Listener payouts',
              value: '₹${summary.totalListenerPayout}',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              title: 'Platform profit',
              value: '₹${summary.totalPlatformProfit}',
              color: const Color(0xFFD97706),
            ),
            _metricCard(
              title: 'Wallet transactions',
              value: '${summary.totalWalletTransactions}',
              color: const Color(0xFF4F46E5),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionTitle(
          'Withdrawals',
          subtitle: 'Request count and pending manual review volume.',
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _summaryLine(
                  'Total withdrawal requests',
                  '${summary.totalWithdrawalRequests}',
                ),
                _summaryLine(
                  'Pending withdrawal requests',
                  '${summary.pendingWithdrawalRequests}',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionDeniedCard(Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.query_stats_rounded,
                  size: 52,
                  color: Color(0xFF9CA3AF),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Analytics access required',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'This dashboard is protected by backend admin checks.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics Dashboard'),
      ),
      body: FutureBuilder<List<Object>>(
        future: Future.wait<Object>([
          _summaryFuture,
          _todayFuture,
          _retentionFuture,
          _timeseriesFuture,
          _leaderboardFuture,
        ]),
        builder: (_, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snap.hasError) {
            if (_looksLikePermissionError(snap.error!)) {
              return _buildPermissionDeniedCard(snap.error!);
            }

            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load analytics.\n\n${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final values = snap.data ?? <Object>[];
          final summary = values.isNotEmpty
              ? values[0] as AnalyticsSummaryModel
              : AnalyticsSummaryModel.empty();
          final today = values.length > 1
              ? values[1] as DailyAnalyticsModel
              : DailyAnalyticsModel.empty(dayKey: 'today');
          final retention = values.length > 2
              ? values[2] as RetentionAnalyticsModel
              : RetentionAnalyticsModel.empty();
          final timeseries = values.length > 3
              ? values[3] as AnalyticsTimeseriesModel
              : AnalyticsTimeseriesModel.empty();

          return RefreshIndicator(
            onRefresh: _reload,
            child: _buildBody(
              summary: summary,
              today: today,
              retention: retention,
              timeseries: timeseries,
            ),
          );
        },
      ),
    );
  }
}