import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/call_repository.dart';
import '../../repositories/history_repository.dart';
import '../../repositories/social_repository.dart';
import '../../repositories/user_repository.dart';
import '../../shared/chat_unread.dart';
import '../../shared/discover_ranking.dart';
import '../../shared/level_utils.dart';
import '../../shared/people_match.dart';
import '../../shared/relative_time.dart';
import '../../shared/models/app_user_model.dart';
import '../../shared/models/social_post_model.dart';
import '../chat_conversation_screen.dart';
import '../listener_profile_screen.dart';
import '../notifications_center_screen.dart';
import '../post_detail_screen.dart';
import '../profile_screen.dart';
import 'call_setup_screen.dart';
import 'settings_screen.dart';

/// The app's main shell: a 5-tab IndexedStack (Discover, Chats, Call center,
/// Feed, Me) on the light-blue theme. Reached via MainShellScreen once the
/// user is signed in.
class RedesignShell extends StatefulWidget {
  const RedesignShell({super.key});

  @override
  State<RedesignShell> createState() => _RedesignShellState();
}

class _RedesignShellState extends State<RedesignShell> {
  int _index = 0;

  // Built each frame so _FeedPage can carry a tab-switch callback. IndexedStack
  // keeps each child's State alive (same runtime type per slot), so rebuilding
  // the list does not reset any tab.
  // New nav direction: Home · Explore · Talk · Chats · You.
  // (Home = the social feed, Explore = people discovery, Talk = the call hub.)
  List<Widget> get _pages => <Widget>[
        _FeedPage(onGoToExplore: () => setState(() => _index = 1)),
        const _DiscoverPage(),
        const _CallPage(),
        const _ChatsPage(),
        const _MePage(),
      ];

  final Stream<List<Map<String, dynamic>>> _sessions =
      CallRepository.instance.watchCurrentUserChatSessions();
  final String _myUid = UserRepository.instance.myUidOrNull ?? '';

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark, // Android: dark icons
        statusBarBrightness: Brightness.light, // iOS: dark icons
      ),
      child: Scaffold(
        backgroundColor: AppPalette.pageBg,
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _sessions,
          builder: (context, snap) => _BottomNav(
            index: _index,
            onTap: (i) => setState(() => _index = i),
            chatsUnread: ChatUnread.conversationsWithUnread(
              snap.data ?? const <Map<String, dynamic>>[],
              _myUid,
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.index,
    required this.onTap,
    this.chatsUnread = 0,
  });

  final int index;
  final ValueChanged<int> onTap;
  final int chatsUnread;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppPalette.card,
        border: Border(top: BorderSide(color: AppPalette.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              _navItem(0, Icons.home_outlined, 'Home'),
              _navItem(1, Icons.explore_outlined, 'Explore'),
              _navItem(2, Icons.call_outlined, 'Talk'),
              _navItem(3, Icons.chat_bubble_outline_rounded, 'Chats',
                  badge: chatsUnread),
              _navItem(4, Icons.person_outline_rounded, 'You'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label, {int badge = 0}) {
    final selected = index == i;
    final color = selected ? AppPalette.blue : AppPalette.textMuted;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 23, color: color),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 15),
                      decoration: BoxDecoration(
                        color: AppPalette.rose,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Discover (front door)
// ---------------------------------------------------------------------------

String _initialsFromName(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return 'U';
  if (parts.length == 1) {
    final p = parts.first;
    return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

/// Compact count, e.g. 1234 -> "1.2k", 2_000_000 -> "2M".
String _compactCount(int n) {
  if (n >= 1000000) {
    final v = n / 1000000;
    return '${v.toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M';
  }
  // 999_950–999_999 would round to a malformed "1000.0k"; show "1M".
  if (n >= 999950) return '1M';
  if (n >= 1000) {
    final v = n / 1000;
    return '${v.toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k';
  }
  return '$n';
}

/// Explore filter chips, matching the prototype (For you / Mutuals / Hindi /
/// Rising).
enum _ExploreFilter { forYou, mutuals, hindi, rising }

const Map<_ExploreFilter, String> _exploreFilterLabels =
    <_ExploreFilter, String>{
  _ExploreFilter.forYou: 'For you',
  _ExploreFilter.mutuals: 'Mutuals',
  _ExploreFilter.hindi: 'Hindi',
  _ExploreFilter.rising: 'Rising',
};

class _DiscoverPage extends StatefulWidget {
  const _DiscoverPage();

  @override
  State<_DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<_DiscoverPage> {
  final Stream<List<AppUserModel>> _stream =
      UserRepository.instance.watchAvailableListeners();
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  _ExploreFilter _exFilter = _ExploreFilter.forYou;

  bool get _filtersActive =>
      _query.trim().isNotEmpty || _exFilter != _ExploreFilter.forYou;

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _exFilter = _ExploreFilter.forYou;
    });
  }

  int _matchWith(AppUserModel me, AppUserModel u) => PeopleMatch.percent(
        myTopics: me.topics,
        myLanguages: me.languages,
        theirTopics: u.topics,
        theirLanguages: u.languages,
      );

  /// Applies the active Explore chip to the (already search-filtered) [base].
  /// Filters that need the follow graph or match use [me].
  /// - For you: everyone, best match first.
  /// - Mutuals: people I already follow (real follow data; the "who follows me"
  ///   side isn't in the public projection — reported as a limitation).
  /// - Hindi: Hindi speakers.
  /// - Rising: rising-level people (level 1–2).
  List<AppUserModel> _applyExploreFilter(
      List<AppUserModel> base, AppUserModel? me) {
    final myUid = me?.uid ?? '';
    final following = me?.following.toSet() ?? const <String>{};
    final people = base.where((u) => u.uid != myUid);
    switch (_exFilter) {
      case _ExploreFilter.forYou:
        final list = people.toList();
        if (me != null) {
          // Decorate-sort-undecorate: compute each match% once, not O(n log n)
          // times inside the comparator on every keystroke.
          final scored = [for (final u in list) (u, _matchWith(me, u))];
          scored.sort((a, b) => b.$2.compareTo(a.$2));
          return [for (final e in scored) e.$1];
        }
        return list;
      case _ExploreFilter.mutuals:
        return people
            .where((u) => following.contains(u.uid))
            .toList(growable: false);
      case _ExploreFilter.hindi:
        return people
            .where((u) =>
                u.languages.any((l) => l.trim().toLowerCase() == 'hindi'))
            .toList(growable: false);
      case _ExploreFilter.rising:
        return people
            .where((u) => LevelUtils.levelForFollowers(u.followersCount) <= 2)
            .toList(growable: false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // uids with an in-flight favorite toggle, to swallow rapid double-taps.
  final Set<String> _favBusy = <String>{};

  Future<void> _toggleFavorite(String uid, bool isFavoriteNow) async {
    final id = uid.trim();
    if (id.isEmpty || _favBusy.contains(id)) return;
    setState(() => _favBusy.add(id));
    try {
      await UserRepository.instance.toggleFavoriteListener(
        listenerId: id,
        isFavoriteNow: isFavoriteNow,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update favorites. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _favBusy.remove(id));
    }
  }

  // uids with an in-flight follow toggle.
  final Set<String> _followBusy = <String>{};

  Future<void> _toggleFollow(String uid, bool isFollowingNow) async {
    final id = uid.trim();
    if (id.isEmpty || _followBusy.contains(id)) return;
    setState(() => _followBusy.add(id));
    try {
      if (isFollowingNow) {
        await UserRepository.instance.unfollowUser(id);
      } else {
        await UserRepository.instance.followUser(id);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update follow. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _followBusy.remove(id));
    }
  }

  void _openProfile(AppUserModel user) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(
          listenerId: user.uid,
          initialUser: user,
        ),
      ),
    );
  }

  Widget _noMatches() {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        children: [
          const Icon(Icons.search_off_rounded,
              size: 34, color: AppPalette.textMuted),
          const SizedBox(height: 12),
          const Text(
            'No listeners match your filters.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: _clearFilters,
            child: const Text('Clear filters'),
          ),
        ],
      ),
    );
  }

  /// Horizontal strip of the speaker's favourited listeners who are available
  /// right now — one tap back to someone they already trust.
  Widget _yourPeopleRow(List<AppUserModel> favorites) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your people',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 90,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: favorites.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final u = favorites[i];
              final online = u.isAvailable && !u.isOnCall;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openProfile(u),
                child: SizedBox(
                  width: 62,
                  child: Column(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _Avatar(
                            initials: _initialsFromName(u.safeDisplayName),
                            photoUrl: u.photoURL,
                            size: 56,
                          ),
                          if (online)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  color: AppPalette.online,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppPalette.card,
                                    width: 2.5,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        u.safeDisplayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: StreamBuilder<List<AppUserModel>>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        color: AppPalette.blue,
                        strokeWidth: 2.5,
                      ),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return const _DiscoverMessage(
                    'Could not load listeners.\n'
                    'Check your connection and try again.',
                  );
                }
                final all = snapshot.data ?? const <AppUserModel>[];
                if (all.isEmpty) {
                  return const _DiscoverMessage(
                    "No one's around right now 🌙\n"
                    'Check back in a little while.',
                  );
                }
                final base = DiscoverRanking.applyFilters(all, query: _query);
                return StreamBuilder<AppUserModel?>(
                  stream: _me,
                  builder: (context, meSnap) {
                    final me = meSnap.data;
                    final favUids =
                        me?.favoriteListeners.toSet() ?? const <String>{};
                    final followUids =
                        me?.following.toSet() ?? const <String>{};
                    final favorites = favUids.isEmpty
                        ? const <AppUserModel>[]
                        : all
                            .where((u) => favUids.contains(u.uid))
                            .toList(growable: false);
                    final listeners = _applyExploreFilter(base, me);
                    final String statusText;
                    if (_filtersActive) {
                      final n = listeners.length;
                      statusText = n == 0
                          ? 'No matches'
                          : '$n ${n == 1 ? 'person' : 'people'}';
                    } else {
                      statusText = '${listeners.length} suggested for you';
                    }
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (favorites.isNotEmpty) ...[
                            _yourPeopleRow(favorites),
                            const SizedBox(height: 18),
                          ],
                          Row(
                            children: [
                              const _OnlineDot(),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  statusText,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppPalette.textSecondary,
                                  ),
                                ),
                              ),
                              if (_filtersActive && listeners.isNotEmpty)
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _clearFilters,
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 2),
                                    child: Text(
                                      'Clear',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: AppPalette.blue,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (listeners.isEmpty)
                            _noMatches()
                          else
                            Column(
                              children: listeners.map((u) {
                                final fav = favUids.contains(u.uid);
                                final following = followUids.contains(u.uid);
                                final match = me == null
                                    ? 0
                                    : PeopleMatch.percent(
                                        myTopics: me.topics,
                                        myLanguages: me.languages,
                                        theirTopics: u.topics,
                                        theirLanguages: u.languages,
                                      );
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _ListenerCard(
                                    user: u,
                                    onTap: () => _openProfile(u),
                                    isFavorite: fav,
                                    onToggleFavorite: me == null
                                        ? null
                                        : () => _toggleFavorite(u.uid, fav),
                                    isFollowing: following,
                                    matchPercent: match,
                                    onToggleFollow: me == null
                                        ? null
                                        : () => _toggleFollow(u.uid, following),
                                    followBusy: _followBusy.contains(u.uid),
                                  ),
                                );
                              }).toList(),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      color: AppPalette.card,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Explore',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Find your people · follow, then message or call',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14, color: AppPalette.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppPalette.feedBg,
              hintText: 'Search name, topic, language',
              hintStyle:
                  const TextStyle(fontSize: 14, color: AppPalette.textMuted),
              prefixIcon: const Icon(Icons.search_rounded,
                  size: 20, color: AppPalette.textMuted),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded,
                          size: 18, color: AppPalette.textMuted),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppPalette.blue, width: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _ExploreFilter.values.map((f) {
              final selected = _exFilter == f;
              return InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => setState(() => _exFilter = f),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppPalette.blue : AppPalette.feedBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: selected ? AppPalette.blue : AppPalette.border,
                    ),
                  ),
                  child: Text(
                    _exploreFilterLabels[f]!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppPalette.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ListenerCard extends StatelessWidget {
  const _ListenerCard({
    required this.user,
    required this.onTap,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.isFollowing = false,
    this.matchPercent = 0,
    this.onToggleFollow,
    this.followBusy = false,
  });
  final AppUserModel user;
  final VoidCallback onTap;
  final bool isFavorite;

  /// Null while the current user is still loading — the heart is hidden then.
  final VoidCallback? onToggleFavorite;

  final bool isFollowing;
  final int matchPercent;

  /// Null while the current user is still loading — the Follow button hides.
  final VoidCallback? onToggleFollow;
  final bool followBusy;

  bool get _online => user.isAvailable && !user.isOnCall;

  Widget _followButton() {
    if (isFollowing) {
      return OutlinedButton(
        onPressed: followBusy ? null : onToggleFollow,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.textSecondary,
          side: const BorderSide(color: AppPalette.border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Following',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      );
    }
    return FilledButton(
      onPressed: followBusy ? null : onToggleFollow,
      style: FilledButton.styleFrom(
        backgroundColor: AppPalette.blue,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        minimumSize: const Size(0, 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('Follow',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topic = user.topics.isNotEmpty
        ? user.topics.first
        : (user.languages.isNotEmpty ? user.languages.first : '');
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: AppPalette.cardDecoration(radius: 16),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _Avatar(
                  initials: _initialsFromName(user.safeDisplayName),
                  photoUrl: user.photoURL,
                  size: 52,
                ),
                if (_online)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: AppPalette.online,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppPalette.card, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.safeDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    LevelUtils.levelTag(user.followersCount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.blue,
                    ),
                  ),
                  if (topic.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      topic,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    matchPercent > 0
                        ? '${_compactCount(user.followersCount)} followers · '
                            '$matchPercent% match'
                        : '${_compactCount(user.followersCount)} followers',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppPalette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (onToggleFavorite != null)
              MergeSemantics(
                child: Semantics(
                  button: true,
                  label: isFavorite ? 'Remove from saved' : 'Save',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggleFavorite,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 20,
                        color:
                            isFavorite ? AppPalette.rose : AppPalette.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            if (onToggleFollow != null) _followButton(),
          ],
        ),
      ),
    );
  }
}

class _DiscoverMessage extends StatelessWidget {
  const _DiscoverMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            height: 1.5,
            color: AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Me (own profile + wallet + settings hub)
// ---------------------------------------------------------------------------

class _MePage extends StatefulWidget {
  const _MePage();

  @override
  State<_MePage> createState() => _MePageState();
}

class _MePageState extends State<_MePage> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final String _myUid = UserRepository.instance.myUidOrNull ?? '';
  // Broadcast: the You tab subscribes from two StreamBuilders at once (the
  // stats post-count and the posts grid). watchUserPosts' signed-in path is a
  // single-subscription Firestore stream, so a second listen would throw.
  late final Stream<List<SocialPostModel>> _myPosts =
      SocialRepository.instance.watchUserPosts(_myUid).asBroadcastStream();

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: StreamBuilder<AppUserModel?>(
        stream: _me,
        builder: (context, snapshot) {
          final me = snapshot.data;
          final name = me?.safeDisplayName ?? '...';
          final followers = me?.followersCount ?? 0;
          final following = me?.following.length ?? 0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'You',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: () => showSettingsSheet(context),
                    icon: const Icon(Icons.settings_outlined,
                        color: AppPalette.textSecondary, size: 24),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _Avatar(
                    initials: _initialsFromName(name),
                    photoUrl: me?.photoURL,
                    size: 64,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                        if ((me?.bio ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            me!.bio.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                        ],
                        const SizedBox(height: 5),
                        _LevelBadge(followers),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              StreamBuilder<List<SocialPostModel>>(
                stream: _myPosts,
                builder: (context, postsSnap) {
                  final postCount =
                      (postsSnap.data ?? const <SocialPostModel>[]).length;
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: AppPalette.cardDecoration(radius: 16),
                    child: Row(
                      children: [
                        _stat('Posts', '$postCount'),
                        _statDivider(),
                        _stat('Followers', _compactCount(followers)),
                        _statDivider(),
                        _stat('Following', _compactCount(following)),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _open(const ProfileScreen()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppPalette.textPrimary,
                    side: const BorderSide(color: AppPalette.border),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Edit profile',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'My posts',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              _myPostsGrid(),
            ],
          );
        },
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statDivider() {
    return Container(
      width: 0.5,
      height: 30,
      color: AppPalette.divider,
    );
  }

  Widget _myPostsGrid() {
    return StreamBuilder<List<SocialPostModel>>(
      stream: _myPosts,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: AppPalette.blue, strokeWidth: 2.5),
              ),
            ),
          );
        }
        final posts = snap.data ?? const <SocialPostModel>[];
        if (posts.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(22),
            decoration: AppPalette.cardDecoration(radius: 16),
            child: const Text(
              "You haven't posted yet.\n"
              'Share something from Home to see it here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }
        return GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: posts
              .map((p) => GestureDetector(
                    onTap: () => _open(PostDetailScreen(initialPost: p)),
                    child: Container(
                      color: AppPalette.feedBg,
                      child: Image.network(
                        p.imageURL,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.image_not_supported_outlined,
                          color: AppPalette.textMuted,
                        ),
                      ),
                    ),
                  ))
              .toList(),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _ChatsPage extends StatefulWidget {
  const _ChatsPage();

  @override
  State<_ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<_ChatsPage> {
  final Stream<List<Map<String, dynamic>>> _sessions =
      CallRepository.instance.watchCurrentUserChatSessions();
  final String _myUid = UserRepository.instance.myUidOrNull ?? '';
  // Cache the Future itself: concurrent rows asking for the same uid share one
  // fetch, and the stable Future identity stops FutureBuilder re-firing on
  // every list rebuild.
  final Map<String, Future<AppUserModel?>> _userFutures =
      <String, Future<AppUserModel?>>{};

  Future<AppUserModel?> _resolve(String uid) => _userFutures.putIfAbsent(
        uid,
        () => UserRepository.instance.getUser(uid),
      );

  String _str(dynamic v) => v is String ? v : '';

  void _openChat(Map<String, dynamic> s, AppUserModel? other) {
    final speakerId = _str(s['speakerId']);
    final listenerId = _str(s['listenerId']);
    if (speakerId.isEmpty || listenerId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatConversationScreen(
          speakerId: speakerId,
          listenerId: listenerId,
          actualListenerId: _str(s['actualListenerId']),
          iAmListener: _myUid == listenerId,
          initialOtherUser: other,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: AppPalette.card,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: const Text(
              'Chats',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _sessions,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: AppPalette.blue,
                        strokeWidth: 2.5,
                      ),
                    ),
                  );
                }
                final sessions =
                    (snapshot.data ?? const <Map<String, dynamic>>[])
                        .where((s) =>
                            _str(s['speakerId']).isNotEmpty &&
                            _str(s['listenerId']).isNotEmpty)
                        .toList();
                if (sessions.isEmpty) {
                  return const _DiscoverMessage(
                    "No chats yet 🌙\n"
                    "Start one from a listener's profile.",
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) => _chatRow(sessions[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatRow(Map<String, dynamic> s) {
    final speakerId = _str(s['speakerId']);
    final listenerId = _str(s['listenerId']);
    final otherUid = speakerId == _myUid ? listenerId : speakerId;
    final lastMessage = _str(s['lastMessageText']);
    // Same tested source of truth as the Chats-tab badge.
    final unread = ChatUnread.unreadFor(s, _myUid);
    final wantsCall =
        s['callRequestOpen'] == true && _str(s['pendingFor']) == _myUid;

    return FutureBuilder<AppUserModel?>(
      future: _resolve(otherUid),
      builder: (context, snap) {
        final other = snap.data;
        final name = other?.safeDisplayName ?? 'Someone';
        return InkWell(
          onTap: () => _openChat(s, other),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppPalette.divider, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                _Avatar(
                  initials: _initialsFromName(name),
                  photoUrl: other?.photoURL,
                  size: 46,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.textPrimary,
                              ),
                            ),
                          ),
                          if (wantsCall)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppPalette.blueTint,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'wants to call',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppPalette.blue,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastMessage.isEmpty ? 'Say hi 👋' : lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unread > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: AppPalette.blue,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$unread',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Talk (call hub: weekly totals, online contacts, call history)
// ---------------------------------------------------------------------------

enum _CallHistoryFilter { all, paid, earned }

class _CallPage extends StatefulWidget {
  const _CallPage();

  @override
  State<_CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<_CallPage> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Stream<List<AppUserModel>> _listeners =
      UserRepository.instance.watchAvailableListeners(limit: 200);
  final Stream<List<CallHistoryItem>> _history =
      HistoryRepository.instance.watchMyCallHistory(limit: 200);

  _CallHistoryFilter _filter = _CallHistoryFilter.all;

  void _openProfile(AppUserModel u) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ListenerProfileScreen(listenerId: u.uid, initialUser: u),
      ),
    );
  }

  void _openSetup(AppUserModel me, AppUserModel listener) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallSetupScreen(listener: listener, me: me),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: StreamBuilder<AppUserModel?>(
        stream: _me,
        builder: (context, meSnap) {
          final me = meSnap.data;
          return StreamBuilder<List<AppUserModel>>(
            stream: _listeners,
            builder: (context, listSnap) {
              final listeners = listSnap.data ?? const <AppUserModel>[];
              return StreamBuilder<List<CallHistoryItem>>(
                stream: _history,
                builder: (context, histSnap) {
                  final history = histSnap.data ?? const <CallHistoryItem>[];
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    children: [
                      const Text(
                        'Talk',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Your call hub — track paid & earned minutes.',
                        style: TextStyle(
                            fontSize: 13, color: AppPalette.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      _weekCards(history),
                      const SizedBox(height: 22),
                      _onlineSection(me, listeners),
                      const SizedBox(height: 24),
                      _historySection(history),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  // ---- Paid / Earned this week ----
  Widget _weekCards(List<CallHistoryItem> history) {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - 7 * 24 * 60 * 60 * 1000;
    var paid = 0;
    var earned = 0;
    var paidSeconds = 0;
    var earnedCalls = 0;
    for (final it in history) {
      if (it.amount <= 0 || it.endedAtMs < cutoff) continue;
      if (it.isIncoming) {
        earned += it.amount;
        earnedCalls += 1;
      } else {
        paid += it.amount;
        paidSeconds += it.seconds < 0 ? 0 : it.seconds;
      }
    }
    final paidMinutes = paidSeconds ~/ 60;
    return Row(
      children: [
        Expanded(
          child: _summaryCard(
            'Paid this week',
            '₹$paid',
            '$paidMinutes ${paidMinutes == 1 ? 'minute' : 'minutes'}',
            Icons.call_made_rounded,
            AppPalette.blue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _summaryCard(
            'Earned this week',
            '₹$earned',
            '$earnedCalls listener ${earnedCalls == 1 ? 'call' : 'calls'}',
            Icons.call_received_rounded,
            AppPalette.online,
          ),
        ),
      ],
    );
  }

  Widget _summaryCard(
      String label, String value, String sub, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppPalette.cardDecoration(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppPalette.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  // ---- Online people I follow ----
  Widget _onlineSection(AppUserModel? me, List<AppUserModel> listeners) {
    final following = me?.following.toSet() ?? const <String>{};
    final online = listeners
        .where((u) =>
            u.uid != me?.uid &&
            following.contains(u.uid) &&
            u.isAvailable &&
            !u.isOnCall)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Online now',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        const Text(
          'People you follow who can talk right now.',
          style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
        ),
        const SizedBox(height: 12),
        if (me == null)
          const SizedBox.shrink()
        else if (online.isEmpty)
          _onlineEmpty()
        else
          ...online.map((u) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _onlineTile(me, u),
              )),
      ],
    );
  }

  Widget _onlineEmpty() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: AppPalette.cardDecoration(radius: 16),
      child: const Text(
        'None of the people you follow are online right now.\n'
        'Follow more people in Explore, or check back soon.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 1.4,
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _onlineTile(AppUserModel me, AppUserModel u) {
    final rate = u.listenerRate > 0 ? u.listenerRate : 5;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppPalette.cardDecoration(radius: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _openProfile(u),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _Avatar(
                  initials: _initialsFromName(u.safeDisplayName),
                  photoUrl: u.photoURL,
                  size: 44,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: AppPalette.online,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppPalette.card, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  u.safeDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  u.topics.isNotEmpty
                      ? '₹$rate/min · ${u.topics.first}'
                      : '₹$rate/min',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => _openSetup(me, u),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.call_rounded, size: 16),
            label: const Text('Call',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ---- Call history (All / Paid / Earned) ----
  List<CallHistoryItem> _applyFilter(List<CallHistoryItem> history) {
    switch (_filter) {
      case _CallHistoryFilter.all:
        return history;
      case _CallHistoryFilter.paid:
        return history
            .where((it) => !it.isIncoming && it.amount > 0)
            .toList(growable: false);
      case _CallHistoryFilter.earned:
        return history
            .where((it) => it.isIncoming && it.amount > 0)
            .toList(growable: false);
    }
  }

  Widget _historySection(List<CallHistoryItem> history) {
    final filtered = _applyFilter(history);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Call history',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _filterTab('All', _CallHistoryFilter.all),
            const SizedBox(width: 8),
            _filterTab('Paid', _CallHistoryFilter.paid),
            const SizedBox(width: 8),
            _filterTab('Earned', _CallHistoryFilter.earned),
          ],
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: AppPalette.cardDecoration(radius: 16),
            child: const Text(
              'No calls to show here yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          )
        else
          ...filtered.take(40).map((it) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _historyTile(it),
              )),
      ],
    );
  }

  Widget _filterTab(String label, _CallHistoryFilter value) {
    final selected = _filter == value;
    return GestureDetector(
      onTap: () => setState(() => _filter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppPalette.blue : AppPalette.feedBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _historyTile(CallHistoryItem it) {
    final earned = it.isIncoming;
    final hasAmount = it.amount > 0;
    final tagLabel = hasAmount
        ? (earned ? 'Earned' : 'Paid')
        : (it.wasAnswered ? 'Free' : 'Missed');
    final tagColor = !hasAmount
        ? AppPalette.textMuted
        : (earned ? AppPalette.online : AppPalette.blue);
    final name = it.name.trim().isEmpty ? 'Someone' : it.name.trim();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppPalette.cardDecoration(radius: 16),
      child: Row(
        children: [
          _Avatar(initials: _initialsFromName(name), size: 42),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${RelativeTime.format(it.endedAtMs)} · ${_dur(it.seconds)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                hasAmount ? '₹${it.amount}' : '—',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: hasAmount ? tagColor : AppPalette.textMuted,
                ),
              ),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: tagColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tagLabel,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: tagColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _dur(int seconds) {
    if (seconds <= 0) return '0s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m <= 0) return '${s}s';
    return '${m}m ${s}s';
  }
}

class _FeedPage extends StatefulWidget {
  const _FeedPage({required this.onGoToExplore});

  /// Jumps the shell to the Explore tab (empty-state CTA + "find people").
  final VoidCallback onGoToExplore;

  @override
  State<_FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<_FeedPage> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Stream<List<SocialPostModel>> _posts =
      SocialRepository.instance.watchFeedPosts();

  // Future-cache: one shared fetch per uid, used for post-owner levels and the
  // story circles. Stable identity stops FutureBuilders re-firing on rebuild.
  final Map<String, Future<AppUserModel?>> _userFutures =
      <String, Future<AppUserModel?>>{};
  Future<AppUserModel?> _resolveUser(String uid) => _userFutures.putIfAbsent(
        uid,
        () => UserRepository.instance.getUser(uid),
      );

  void _openComposer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ProfileScreen(openComposer: true),
      ),
    );
  }

  void _openProfile(String uid) {
    if (uid.trim().isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ListenerProfileScreen(listenerId: uid)),
    );
  }

  Widget _emptyFeed() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(
                color: AppPalette.blueTint,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.groups_2_rounded,
                  color: AppPalette.blue, size: 36),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your Home is quiet 🌙',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Posts from people you follow show up here.\n'
              'Find people to follow in Explore.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: widget.onGoToExplore,
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.blue,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.explore_rounded, size: 18),
              label: const Text(
                'Go to Explore',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: StreamBuilder<AppUserModel?>(
        stream: _me,
        builder: (context, meSnap) {
          final me = meSnap.data;
          final meLoading =
              me == null && meSnap.connectionState == ConnectionState.waiting;
          final following = me?.following ?? const <String>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(me),
              Expanded(
                child: StreamBuilder<List<SocialPostModel>>(
                  stream: _posts,
                  builder: (context, snap) {
                    if (meLoading ||
                        (snap.connectionState == ConnectionState.waiting &&
                            !snap.hasData)) {
                      return const Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            color: AppPalette.blue,
                            strokeWidth: 2.5,
                          ),
                        ),
                      );
                    }
                    final all = snap.data ?? const <SocialPostModel>[];
                    // Only posts from people I follow (my own show under You).
                    final visible = all
                        .where((p) => following.contains(p.ownerId))
                        .toList(growable: false);
                    final stories = me == null
                        ? const SizedBox.shrink()
                        : _storyCircles(me);
                    if (visible.isEmpty) {
                      return Column(
                        children: [stories, Expanded(child: _emptyFeed())],
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: visible.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) return stories;
                        final post = visible[i - 1];
                        // Keyed by postId so card state never carries across
                        // posts when the list shifts.
                        return _FeedPostCard(
                          key: ValueKey(post.postId),
                          post: post,
                          resolveOwner: _resolveUser,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(AppUserModel? me) {
    final name = me?.safeDisplayName ?? '';
    return Container(
      color: AppPalette.card,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'friendify',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: AppPalette.blue,
                  ),
                ),
              ),
              _NotificationsBell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NotificationsCenterScreen(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _openComposer,
            borderRadius: BorderRadius.circular(999),
            child: Row(
              children: [
                _Avatar(
                  initials: _initialsFromName(name.isEmpty ? 'U' : name),
                  photoUrl: me?.photoURL,
                  size: 38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppPalette.feedBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      "Share what's on your mind…",
                      style:
                          TextStyle(fontSize: 13, color: AppPalette.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Story circles: me first (tap → composer), then everyone I follow
  /// (tap → their profile). Ephemeral stories were dropped from the product,
  /// so these are follow shortcuts rendered in the familiar row.
  Widget _storyCircles(AppUserModel me) {
    final following =
        me.following.where((u) => u.trim().isNotEmpty).toList(growable: false);
    return Container(
      color: AppPalette.card,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: SizedBox(
        height: 86,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            _storyBubble(
              name: 'You',
              photoUrl: me.photoURL,
              initials: _initialsFromName(me.safeDisplayName),
              onTap: _openComposer,
              isSelf: true,
            ),
            for (final uid in following)
              FutureBuilder<AppUserModel?>(
                future: _resolveUser(uid),
                builder: (context, snap) {
                  final u = snap.data;
                  final nm = u?.safeDisplayName ?? '…';
                  return _storyBubble(
                    name: nm,
                    photoUrl: u?.photoURL,
                    initials: _initialsFromName(nm),
                    onTap: () => _openProfile(uid),
                    online: u?.isAvailable == true && u?.isOnCall == false,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _storyBubble({
    required String name,
    required String initials,
    required VoidCallback onTap,
    String? photoUrl,
    bool isSelf = false,
    bool online = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 14),
        child: SizedBox(
          width: 60,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelf ? AppPalette.blueTint : null,
                      gradient: isSelf
                          ? null
                          : const LinearGradient(
                              colors: [AppPalette.blue, AppPalette.rose],
                            ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppPalette.card,
                      ),
                      child: _Avatar(
                        initials: initials,
                        photoUrl: photoUrl,
                        size: 48,
                      ),
                    ),
                  ),
                  if (isSelf)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: AppPalette.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppPalette.card, width: 2),
                        ),
                        child: const Icon(Icons.add_rounded,
                            size: 13, color: Colors.white),
                      ),
                    ),
                  if (online && !isSelf)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: AppPalette.online,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppPalette.card, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                isSelf ? 'You' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "Lv N" pill derived from a follower count. Reused across Home posts,
/// Explore people, and the You profile.
class _LevelBadge extends StatelessWidget {
  const _LevelBadge(this.followers);
  final int followers;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.blueTint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        LevelUtils.levelTag(followers),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: AppPalette.blue,
        ),
      ),
    );
  }
}

class _FeedPostCard extends StatefulWidget {
  const _FeedPostCard({
    super.key,
    required this.post,
    required this.resolveOwner,
  });
  final SocialPostModel post;

  /// Resolves the post owner (cached) so the card can show their level.
  final Future<AppUserModel?> Function(String uid) resolveOwner;

  @override
  State<_FeedPostCard> createState() => _FeedPostCardState();
}

class _FeedPostCardState extends State<_FeedPostCard> {
  final SocialRepository _social = SocialRepository.instance;
  bool? _likedOverride;
  bool _busy = false;

  // Created once per card (cards are keyed by postId): recreating the stream
  // on every rebuild would resubscribe the listener and flicker the heart.
  late final Stream<bool> _likedStream =
      _social.watchPostLikedByMe(widget.post.postId);

  SocialPostModel get _post => widget.post;

  void _openDetail() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PostDetailScreen(initialPost: _post)),
    );
  }

  void _openOwner() {
    if (_post.ownerId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(listenerId: _post.ownerId),
      ),
    );
  }

  Future<void> _toggleLike(bool liked) async {
    if (_busy) return;
    setState(() {
      _likedOverride = !liked;
      _busy = true;
    });
    try {
      if (liked) {
        await _social.unlikePost(_post.postId);
      } else {
        await _social.likePost(_post.postId);
      }
    } catch (_) {
      if (mounted) setState(() => _likedOverride = liked);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: AppPalette.cardDecoration(radius: 16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(),
          GestureDetector(
            onTap: _openDetail,
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                _post.imageURL,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: AppPalette.feedBg,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_not_supported_outlined,
                      color: AppPalette.textMuted, size: 30),
                ),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : Container(
                        color: AppPalette.feedBg,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: AppPalette.blue,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          if (_post.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Text(
                _post.caption,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  color: AppPalette.textPrimary,
                ),
              ),
            ),
          _actions(),
        ],
      ),
    );
  }

  Widget _cardHeader() {
    return InkWell(
      onTap: _openOwner,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Row(
          children: [
            _Avatar(
              initials: _initialsFromName(
                  _post.ownerName.isEmpty ? 'U' : _post.ownerName),
              photoUrl: _post.ownerPhotoURL,
              size: 40,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _post.ownerName.isEmpty ? 'Someone' : _post.ownerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  FutureBuilder<AppUserModel?>(
                    future: widget.resolveOwner(_post.ownerId),
                    builder: (context, snap) => Text(
                      '${_compactCount(snap.data?.followersCount ?? 0)} followers',
                      style: const TextStyle(
                          fontSize: 12, color: AppPalette.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              RelativeTime.format(_post.createdAtMs),
              style: const TextStyle(fontSize: 12, color: AppPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  // Per the new Home spec: only a Like button + count — no comment or share.
  Widget _actions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 10),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: _likedStream,
            builder: (context, snap) {
              final serverLiked = snap.data ?? false;
              // Once the server confirms the optimistic value, drop the
              // override so later changes (e.g. from another device) show.
              if (!_busy && snap.hasData && _likedOverride == serverLiked) {
                _likedOverride = null;
              }
              final liked = _likedOverride ?? serverLiked;
              return MergeSemantics(
                child: Semantics(
                  button: true,
                  label: liked ? 'Unlike' : 'Like',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => _toggleLike(liked),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            liked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            size: 22,
                            color: liked
                                ? AppPalette.rose
                                : AppPalette.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_post.likeCount}',
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const Spacer(),
          // The person's level, immediately beside the Like area.
          FutureBuilder<AppUserModel?>(
            future: widget.resolveOwner(_post.ownerId),
            builder: (context, snap) =>
                _LevelBadge(snap.data?.followersCount ?? 0),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, this.photoUrl, this.size = 40});
  final String initials;
  final String? photoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = (photoUrl ?? '').trim();
    if (url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initialsCircle(),
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : _initialsCircle(),
        ),
      );
    }
    return _initialsCircle();
  }

  Widget _initialsCircle() {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFFDCE7FA),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.32,
          fontWeight: FontWeight.w600,
          color: AppPalette.blue,
        ),
      ),
    );
  }
}

/// Bell icon with a live unread-count badge; opens the notifications center.
class _NotificationsBell extends StatefulWidget {
  const _NotificationsBell({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_NotificationsBell> createState() => _NotificationsBellState();
}

class _NotificationsBellState extends State<_NotificationsBell> {
  // Created once: recreating the stream on every rebuild would resubscribe
  // the Firestore listener and flicker the badge.
  final Stream<int> _unread =
      SocialRepository.instance.watchUnreadNotificationCount();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _unread,
      builder: (context, snap) {
        final unread = snap.data ?? 0;
        return MergeSemantics(
          child: Semantics(
            button: true,
            label: 'Notifications',
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(
                      Icons.notifications_none_rounded,
                      size: 24,
                      color: AppPalette.textSecondary,
                    ),
                    if (unread > 0)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          constraints: const BoxConstraints(minWidth: 16),
                          decoration: BoxDecoration(
                            color: AppPalette.rose,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OnlineDot extends StatelessWidget {
  const _OnlineDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        color: AppPalette.online,
        shape: BoxShape.circle,
      ),
    );
  }
}
