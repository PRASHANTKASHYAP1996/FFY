import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_palette.dart';
import '../repositories/analytics_repository.dart';
import '../shared/models/listener_leaderboard_item.dart';
import '../shared/wallet_amount_formatter.dart';

class ListenerLeaderboardScreen extends StatefulWidget {
  const ListenerLeaderboardScreen({super.key});

  @override
  State<ListenerLeaderboardScreen> createState() =>
      _ListenerLeaderboardScreenState();
}

class _ListenerLeaderboardScreenState extends State<ListenerLeaderboardScreen> {
  final AnalyticsRepository _repository = AnalyticsRepository.instance;

  late Future<List<ListenerLeaderboardItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _repository.loadListenerLeaderboard();
  }

  Future<void> _reload() async {
    setState(() {
      _future = _repository.loadListenerLeaderboard();
    });
  }

  Widget _sectionTitle(
    String text, {
    String? subtitle,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: AppPalette.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _rankChip(int rank) {
    final isTop3 = rank <= 3;

    final bg = isTop3
        ? const Color(0xFFF59E0B).withValues(alpha: 0.14)
        : AppPalette.feedBg;
    final border = isTop3
        ? const Color(0xFFF59E0B).withValues(alpha: 0.28)
        : AppPalette.border;
    final fg = isTop3 ? const Color(0xFFB45309) : AppPalette.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        '#$rank',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          color: fg,
        ),
      ),
    );
  }

  Widget _availabilityChip(bool available) {
    final color = available ? AppPalette.online : const Color(0xFFDC2626);
    final text = available ? 'Available' : 'Unavailable';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _softChip({
    required IconData icon,
    required String text,
    Color? bg,
    Color? fg,
  }) {
    final chipBg = bg ?? AppPalette.feedBg;
    final chipFg = fg ?? AppPalette.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: chipFg.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: chipFg),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: chipFg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricTile({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statLine({
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppPalette.textPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _listenerTile({
    required int rank,
    required ListenerLeaderboardItem item,
    required String metricTitle,
    required String metricValue,
  }) {
    final safeName = item.displayName.trim().isNotEmpty
        ? item.displayName.trim()
        : 'Listener';

    final firstLetter = safeName[0].toUpperCase();

    final avatarBg = rank <= 3
        ? const Color(0xFFF59E0B).withValues(alpha: 0.16)
        : AppPalette.blueTint;

    final avatarFg = rank <= 3 ? const Color(0xFFB45309) : AppPalette.blue;

    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _rankChip(rank),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 25,
                backgroundColor: avatarBg,
                child: Text(
                  firstLetter,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: avatarFg,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      safeName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _availabilityChip(item.isAvailable),
                        _softChip(
                          icon: Icons.people_alt_rounded,
                          text: '${item.followersCount} followers',
                        ),
                        _softChip(
                          icon: Icons.star_rounded,
                          text: item.ratingCount > 0
                              ? '${item.ratingAvg.toStringAsFixed(1)} (${item.ratingCount})'
                              : 'Not rated yet',
                          bg: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                          fg: const Color(0xFFB45309),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppPalette.feedBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppPalette.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$metricTitle: $metricValue',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                _statLine(
                  label: 'Paid calls',
                  value: '${item.paidCalls}',
                ),
                _statLine(
                  label: 'Total earned',
                  value: formatWalletAmount(item.totalEarned),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _leaderboardSection({
    required String title,
    required String subtitle,
    required List<ListenerLeaderboardItem> items,
    required String Function(ListenerLeaderboardItem item) metricValueBuilder,
    required String metricTitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          title,
          subtitle: subtitle,
        ),
        const SizedBox(height: 10),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            decoration: AppPalette.cardDecoration(radius: 18),
            padding: const EdgeInsets.all(18),
            child: const Column(
              children: [
                Icon(
                  Icons.bar_chart_rounded,
                  size: 42,
                  color: AppPalette.blue,
                ),
                SizedBox(height: 10),
                Text(
                  'No data available yet.',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          )
        else
          ...List.generate(items.length, (index) {
            final item = items[index];
            return Padding(
              padding: EdgeInsets.only(
                bottom: index == items.length - 1 ? 0 : 10,
              ),
              child: _listenerTile(
                rank: index + 1,
                item: item,
                metricTitle: metricTitle,
                metricValue: metricValueBuilder(item),
              ),
            );
          }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppPalette.pageBg,
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: AppPalette.textPrimary,
          surfaceTintColor: Colors.transparent,
          title: const Text('Listener Leaderboard'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: DecoratedBox(
          decoration: const BoxDecoration(color: AppPalette.pageBg),
          child: FutureBuilder<List<ListenerLeaderboardItem>>(
            future: _future,
            builder: (_, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snap.hasError) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Could not load leaderboard. Please try again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppPalette.textSecondary),
                    ),
                  ),
                );
              }

              final allItems = snap.data ?? const <ListenerLeaderboardItem>[];

              final topEarners = _repository.topEarners(allItems);
              final topRated = _repository.topRated(allItems);
              final mostFollowed = _repository.mostFollowed(allItems);

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                children: [
                  Container(
                    decoration: AppPalette.cardDecoration(radius: 18),
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Listener Leaderboard',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'See top listeners by earnings, ratings, and followers.',
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 16),
                        GridView.count(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          childAspectRatio: 1.45,
                          children: [
                            _metricTile(
                              label: 'Leaderboard users',
                              value: '${allItems.length}',
                              color: AppPalette.blue,
                            ),
                            _metricTile(
                              label: 'Top earners shown',
                              value: '${topEarners.length}',
                              color: AppPalette.online,
                            ),
                            _metricTile(
                              label: 'Top rated shown',
                              value: '${topRated.length}',
                              color: const Color(0xFFB45309),
                            ),
                            _metricTile(
                              label: 'Most followed shown',
                              value: '${mostFollowed.length}',
                              color: AppPalette.blueDark,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _leaderboardSection(
                    title: 'Top Earners',
                    subtitle:
                        'Listeners generating the highest total earnings.',
                    items: topEarners,
                    metricTitle: 'Total earned',
                    metricValueBuilder: (item) =>
                        formatWalletAmount(item.totalEarned),
                  ),
                  const SizedBox(height: 18),
                  _leaderboardSection(
                    title: 'Top Rated',
                    subtitle:
                        'Listeners with the strongest rating performance.',
                    items: topRated,
                    metricTitle: 'Rating',
                    metricValueBuilder: (item) =>
                        '${item.ratingAvg.toStringAsFixed(1)}★',
                  ),
                  const SizedBox(height: 18),
                  _leaderboardSection(
                    title: 'Most Followed',
                    subtitle: 'Listeners attracting the largest audience.',
                    items: mostFollowed,
                    metricTitle: 'Followers',
                    metricValueBuilder: (item) => '${item.followersCount}',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
