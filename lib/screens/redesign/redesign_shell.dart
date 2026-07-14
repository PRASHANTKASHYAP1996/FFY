import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/firestore_paths.dart';
import '../../core/theme/app_palette.dart';
import '../../repositories/call_repository.dart';
import '../../repositories/social_repository.dart';
import '../../repositories/user_repository.dart';
import '../../shared/models/app_user_model.dart';
import '../../shared/models/social_post_model.dart';
import '../call_history_screen.dart';
import '../caller_waiting_screen.dart';
import '../chat_conversation_screen.dart';
import '../earnings_screen.dart';
import '../help_support_screen.dart';
import '../listener_profile_screen.dart';
import '../match_and_call_screen.dart';
import '../notifications_center_screen.dart';
import '../post_detail_screen.dart';
import '../profile_screen.dart';
import '../wallet_details_screen.dart';
import 'blocked_users_screen.dart';

/// Phase 1 of the redesign: the new 5-tab shell + light-blue theme.
/// Discover is built out to match the agreed direction; the other tabs are
/// themed placeholders that get their real screens in later phases.
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
  List<Widget> get _pages => <Widget>[
        const _DiscoverPage(),
        const _ChatsPage(),
        const _CallPage(),
        _FeedPage(onGoToDiscover: () => setState(() => _index = 0)),
        const _MePage(),
      ];

  final Stream<List<Map<String, dynamic>>> _sessions =
      CallRepository.instance.watchCurrentUserChatSessions();
  final String _myUid = UserRepository.instance.myUidOrNull ?? '';

  /// Number of conversations with unread messages (for the Chats tab badge).
  int _unreadChats(List<Map<String, dynamic>> sessions) {
    var count = 0;
    for (final s in sessions) {
      final unread = s['speakerId'] == _myUid
          ? s['speakerUnreadCount']
          : s['listenerUnreadCount'];
      if (unread is num && unread > 0) count++;
    }
    return count;
  }

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
            chatsUnread:
                _unreadChats(snap.data ?? const <Map<String, dynamic>>[]),
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
              _navItem(0, Icons.explore_outlined, 'Discover'),
              _navItem(1, Icons.chat_bubble_outline_rounded, 'Chats',
                  badge: chatsUnread),
              _callButton(),
              _navItem(3, Icons.auto_awesome_outlined, 'Feed'),
              _navItem(4, Icons.person_outline_rounded, 'Me'),
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

  Widget _callButton() {
    return Expanded(
      child: Center(
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: () => onTap(2),
          child: Container(
            width: 50,
            height: 50,
            decoration: const BoxDecoration(
              color: AppPalette.blue,
              shape: BoxShape.circle,
            ),
            child:
                const Icon(Icons.phone_rounded, color: Colors.white, size: 24),
          ),
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

class _DiscoverPage extends StatefulWidget {
  const _DiscoverPage();

  @override
  State<_DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<_DiscoverPage> {
  static const List<String> _moods = <String>[
    'Lonely',
    'Stressed',
    'Breakup',
    'Just talk',
  ];

  /// Keywords matched (case-insensitive) against a listener's topics + bio.
  /// An empty list means "matches everyone" (used by 'Just talk').
  static const Map<String, List<String>> _moodKeywords = <String, List<String>>{
    'Lonely': <String>[
      'lonely',
      'loneliness',
      'alone',
      'friend',
      'company',
      'companion',
      'listen',
    ],
    'Stressed': <String>[
      'stress',
      'anxiety',
      'anxious',
      'pressure',
      'work',
      'career',
      'study',
      'exam',
      'calm',
      'overthink',
    ],
    'Breakup': <String>[
      'breakup',
      'break-up',
      'break up',
      'relationship',
      'heartbreak',
      'love',
      'dating',
      'divorce',
      'marriage',
    ],
    'Just talk': <String>[],
  };

  String _mood = '';

  final Stream<List<AppUserModel>> _stream =
      UserRepository.instance.watchAvailableListeners();
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String _languageFilter = '';
  bool _sortLowToHigh = false;

  static const List<String> _filterLanguages = <String>[
    'English',
    'Hindi',
    'Tamil',
    'Telugu',
    'Bengali',
    'Marathi',
    'Punjabi',
    'Kannada',
  ];

  bool get _filtersActive =>
      _query.trim().isNotEmpty || _languageFilter.isNotEmpty || _sortLowToHigh;

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _languageFilter = '';
      _sortLowToHigh = false;
    });
  }

  /// Narrow the available list by the search text and language chip. Mood and
  /// price sort are applied afterwards on the result.
  List<AppUserModel> _applyFilters(List<AppUserModel> all) {
    final query = _query.trim().toLowerCase();
    final lang = _languageFilter.toLowerCase();
    if (query.isEmpty && lang.isEmpty) return all;
    return all.where((u) {
      if (query.isNotEmpty) {
        final hay = <String>[
          u.safeDisplayName,
          u.bio,
          u.city,
          u.state,
          ...u.topics,
          ...u.languages,
        ].join(' ').toLowerCase();
        if (!hay.contains(query)) return false;
      }
      if (lang.isNotEmpty &&
          !u.languages.any((l) => l.toLowerCase() == lang)) {
        return false;
      }
      return true;
    }).toList(growable: false);
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

  /// True when a mood is picked that actually filters ('Just talk' has no
  /// keywords, so it never narrows the list).
  bool get _moodActive =>
      _mood.isNotEmpty && (_moodKeywords[_mood]?.isNotEmpty ?? false);

  bool _matchesMood(AppUserModel u) {
    final keywords = _moodKeywords[_mood] ?? const <String>[];
    if (keywords.isEmpty) return true;
    final haystack = '${u.topics.join(' ')} ${u.bio}'.toLowerCase();
    return keywords.any(haystack.contains);
  }

  /// Moods re-order (best matches first) but never hide anyone, so the front
  /// door always shows real people. Returns the ordered list + how many
  /// actually matched the mood.
  ({List<AppUserModel> ordered, int matchCount}) _orderByMood(
    List<AppUserModel> all,
  ) {
    if (!_moodActive) return (ordered: all, matchCount: 0);
    final matched = all.where(_matchesMood).toList(growable: false);
    final matchedUids = matched.map((u) => u.uid).toSet();
    return (
      ordered: <AppUserModel>[
        ...matched,
        ...all.where((u) => !matchedUids.contains(u.uid)),
      ],
      matchCount: matched.length,
    );
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

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppPalette.blue : AppPalette.feedBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppPalette.blue : AppPalette.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 14,
                  color: selected ? Colors.white : AppPalette.textSecondary),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppPalette.textSecondary,
              ),
            ),
          ],
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
                final filtered = _applyFilters(all);
                // Mood re-orders the filtered set (best matches first) but
                // never hides anyone within it.
                final result = _orderByMood(filtered);
                var listeners = result.ordered;
                if (_sortLowToHigh) {
                  listeners = [...listeners]
                    ..sort((a, b) => a.listenerRate.compareTo(b.listenerRate));
                }
                final String statusText;
                if (_filtersActive) {
                  final n = filtered.length;
                  statusText =
                      n == 0 ? 'No matches' : '$n ${n == 1 ? 'match' : 'matches'}';
                } else if (!_moodActive) {
                  statusText = '${all.length} here for you now';
                } else if (result.matchCount == 0) {
                  statusText = "No one's tagged for \"$_mood\" yet — "
                      'here are all ${all.length} available';
                } else {
                  statusText = '${result.matchCount} great for "$_mood" · '
                      '${all.length} here now';
                }
                return StreamBuilder<AppUserModel?>(
                  stream: _me,
                  builder: (context, meSnap) {
                    final me = meSnap.data;
                    final favUids =
                        me?.favoriteListeners.toSet() ?? const <String>{};
                    final favorites = favUids.isEmpty
                        ? const <AppUserModel>[]
                        : all
                            .where((u) => favUids.contains(u.uid))
                            .toList(growable: false);
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
                            GridView.count(
                              crossAxisCount: 2,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.92,
                              children: listeners.map((u) {
                                final fav = favUids.contains(u.uid);
                                return _ListenerCard(
                                  user: u,
                                  onTap: () => _openProfile(u),
                                  isFavorite: fav,
                                  onToggleFavorite: me == null
                                      ? null
                                      : () => _toggleFavorite(u.uid, fav),
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
            'How are you feeling?',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            "someone's here for you 🌙",
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
            spacing: 7,
            children: List.generate(_moods.length, (i) {
              final mood = _moods[i];
              final selected = _mood == mood;
              return InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => setState(() => _mood = selected ? '' : mood),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: selected ? AppPalette.blue : AppPalette.blueTint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    mood,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: selected ? Colors.white : AppPalette.blue,
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              children: [
                _filterChip(
                  label: 'Low price',
                  icon: Icons.sort_rounded,
                  selected: _sortLowToHigh,
                  onTap: () =>
                      setState(() => _sortLowToHigh = !_sortLowToHigh),
                ),
                const SizedBox(width: 7),
                for (final lang in _filterLanguages) ...[
                  _filterChip(
                    label: lang,
                    selected:
                        _languageFilter.toLowerCase() == lang.toLowerCase(),
                    onTap: () => setState(() {
                      _languageFilter =
                          _languageFilter.toLowerCase() == lang.toLowerCase()
                              ? ''
                              : lang;
                    }),
                  ),
                  const SizedBox(width: 7),
                ],
              ],
            ),
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
  });
  final AppUserModel user;
  final VoidCallback onTap;
  final bool isFavorite;

  /// Null while the current user is still loading — the heart is hidden then.
  final VoidCallback? onToggleFavorite;

  String get _ratingLabel =>
      user.ratingCount <= 0 ? 'New' : user.ratingAvg.toStringAsFixed(1);

  bool get _online => user.isAvailable && !user.isOnCall;

  /// Up to two topic chips (falls back to languages), plus a "+N" pill when
  /// there are more. Fills the card's dead space and tells people at a glance
  /// what a listener is here for. Collapses to nothing when neither is set.
  Widget _chipsRow() {
    final source = user.topics.isNotEmpty ? user.topics : user.languages;
    final tags = source
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (tags.isEmpty) return const SizedBox.shrink();
    final shown = tags.take(2).toList();
    final extra = tags.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          for (final t in shown) ...[
            Flexible(child: _chip(t)),
            const SizedBox(width: 5),
          ],
          if (extra > 0) _chip('+$extra', strong: true),
        ],
      ),
    );
  }

  Widget _chip(String label, {bool strong = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppPalette.blueTint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
          color: AppPalette.blue,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: AppPalette.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(
                  initials: _initialsFromName(user.safeDisplayName),
                  photoUrl: user.photoURL,
                  size: 40,
                ),
                const Spacer(),
                if (_online) const _OnlineDot(),
                if (onToggleFavorite != null) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggleFavorite,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 20,
                        color: isFavorite
                            ? AppPalette.rose
                            : AppPalette.textMuted,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              user.safeDisplayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.star_rounded,
                    size: 14, color: AppPalette.star),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    '$_ratingLabel · ₹${user.listenerRate}/min',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppPalette.textSecondary),
                  ),
                ),
              ],
            ),
            _chipsRow(),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.blue,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Talk',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
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
  bool _availabilityBusy = false;

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _logout() async {
    await UserRepository.instance.signOut();
  }

  /// Listeners can step away and come back. Toggling off hides their online
  /// state and makes new calls fail readiness ("not available right now"); it
  /// does not touch listener mode or discoverability. Backed by the existing
  /// UserRepository.setAvailability; the watchMe stream reflects the write.
  Future<void> _setAvailability(bool value) async {
    if (_availabilityBusy) return;
    setState(() => _availabilityBusy = true);
    try {
      await UserRepository.instance.setAvailability(value);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update availability. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _availabilityBusy = false);
    }
  }

  Widget _availabilityCard(AppUserModel me) {
    final available = me.isAvailable;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: AppPalette.cardDecoration(radius: 16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: available
                  ? AppPalette.online.withValues(alpha: 0.14)
                  : AppPalette.feedBg,
              shape: BoxShape.circle,
            ),
            child: Icon(
              available
                  ? Icons.podcasts_rounded
                  : Icons.pause_circle_outline_rounded,
              color: available ? AppPalette.online : AppPalette.textMuted,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  available ? 'Available now' : 'Unavailable',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  available
                      ? 'People see you online and can start calls.'
                      : "You're hidden as online and new calls are paused.",
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: available,
            onChanged: _availabilityBusy ? null : _setAvailability,
          ),
        ],
      ),
    );
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              Row(
                children: [
                  _Avatar(
                    initials: _initialsFromName(name),
                    photoUrl: me?.photoURL,
                    size: 56,
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
                        const SizedBox(height: 2),
                        Text(
                          me?.isListener == true ? 'Listener' : 'Member',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppPalette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (me != null && me.isListener) ...[
                const SizedBox(height: 16),
                _availabilityCard(me),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _moneyCard(
                      label: 'Wallet',
                      value: '₹${me?.credits ?? 0}',
                      action: 'Add money',
                      onTap: () => _open(const WalletDetailsScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _moneyCard(
                      label: 'Earnings',
                      value: '₹${me?.earningsCredits ?? 0}',
                      action: 'Withdraw',
                      onTap: () => _open(const WalletDetailsScreen()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _menuRow(Icons.person_outline_rounded, 'Edit profile',
                  () => _open(const ProfileScreen())),
              _menuRow(Icons.notifications_none_rounded, 'Notifications',
                  () => _open(const NotificationsCenterScreen())),
              _menuRow(
                  Icons.account_balance_wallet_outlined,
                  'Wallet and transactions',
                  () => _open(const WalletDetailsScreen())),
              _menuRow(Icons.payments_outlined, 'Earnings and safety',
                  () => _open(const EarningsScreen())),
              _menuRow(Icons.access_time_rounded, 'Call history',
                  () => _open(const CallHistoryScreen())),
              _menuRow(Icons.block_rounded, 'Blocked users',
                  () => _open(const BlockedUsersScreen())),
              _menuRow(Icons.help_outline_rounded, 'Help and support',
                  () => _open(const HelpSupportScreen())),
              _menuRow(Icons.logout_rounded, 'Log out', _logout, danger: true),
            ],
          );
        },
      ),
    );
  }

  Widget _moneyCard({
    required String label,
    required String value,
    required String action,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppPalette.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: AppPalette.blue,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                action,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, VoidCallback onTap,
      {bool danger = false}) {
    const dangerColor = Color(0xFFDC2626);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 2),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppPalette.divider, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 20,
                color: danger ? dangerColor : AppPalette.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: danger ? dangerColor : AppPalette.textPrimary,
                ),
              ),
            ),
            if (!danger)
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppPalette.textMuted),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chats (conversations + call requests)
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
  int _int(dynamic v) => v is num ? v.toInt() : 0;

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
    final iAmSpeaker = speakerId == _myUid;
    final unread = iAmSpeaker
        ? _int(s['speakerUnreadCount'])
        : _int(s['listenerUnreadCount']);
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
// Call (the primary action — fast path into a match + call)
// ---------------------------------------------------------------------------

class _CallPage extends StatefulWidget {
  const _CallPage();

  @override
  State<_CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<_CallPage> {
  final CallRepository _callRepository = CallRepository.instance;
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Stream<List<AppUserModel>> _listeners =
      UserRepository.instance.watchAvailableListeners(limit: 200);
  late final Stream<List<Map<String, dynamic>>> _sessions =
      _callRepository.watchCurrentUserChatSessions(limit: 100);

  // uid of the listener whose call is currently being set up.
  String _callingFor = '';

  void _talkNow() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MatchAndCallScreen()),
    );
  }

  void _history() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CallHistoryScreen()),
    );
  }

  void _openListenerProfile(AppUserModel listener) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(
          listenerId: listener.uid,
          initialUser: listener,
        ),
      ),
    );
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Listeners the current user already has an accepted (call-allowed) chat
  /// session with — ported verbatim from the old Wallet "Calls hub" so the
  /// underlying access rules are unchanged.
  List<AppUserModel> _callReadyListeners({
    required AppUserModel me,
    required List<AppUserModel> listeners,
    required List<Map<String, dynamic>> sessions,
  }) {
    final candidates = listeners
        .where((u) => u.uid.trim().isNotEmpty && u.uid != me.uid)
        .toList(growable: false);

    final sessionByListener = <String, Map<String, dynamic>>{};
    for (final session in sessions) {
      if (session['exists'] != true) continue;
      final ids = _callRepository.sessionParticipantIds(session).toSet();
      if (!ids.contains(me.uid)) continue;
      for (final listener in candidates) {
        if (ids.contains(listener.uid)) {
          sessionByListener[listener.uid] = session;
        }
      }
    }

    return candidates.where((listener) {
      final session = sessionByListener[listener.uid];
      if (session == null) return false;
      final blocked = session[FirestorePaths.fieldSpeakerBlocked] == true ||
          session[FirestorePaths.fieldListenerBlocked] == true;
      if (blocked) return false;
      return _sessionAllowsCallAccess(
        session: session,
        me: me,
        listener: listener,
      );
    }).toList(growable: false);
  }

  bool _sessionAllowsCallAccess({
    required Map<String, dynamic> session,
    required AppUserModel me,
    required AppUserModel listener,
  }) {
    final strictAllowed = _callRepository.sessionAllowsCallForDirection(
      session: session,
      speakerId: me.uid,
      listenerId: listener.uid,
    );
    if (strictAllowed) return true;

    final status = (session[FirestorePaths.fieldChatStatus] ?? '').toString();
    if (status != FirestorePaths.chatStatusAccepted) return false;

    final actualListenerId =
        (session[FirestorePaths.fieldActualListenerId] ?? '').toString().trim();
    return actualListenerId == listener.uid.trim() &&
        _callRepository.sessionIdentityLooksComplete(
          session: session,
          speakerId: me.uid,
          listenerId: listener.uid,
        );
  }

  Future<void> _startCall(AppUserModel me, AppUserModel listener) async {
    if (_callingFor.isNotEmpty) return;
    final safeId = listener.uid.trim();
    if (safeId.isEmpty || safeId == me.uid) return;
    if (_callRepository.hasBlockingCallState) {
      _showMessage('Finish your current call flow first.');
      return;
    }

    setState(() => _callingFor = safeId);
    try {
      final canCall =
          await _callRepository.canCurrentUserCallListener(listenerId: safeId);
      if (!mounted) return;
      final readiness = _callRepository.callReadinessForKnownUsers(
        me: me,
        listener: listener,
        hasCallAccess: canCall,
        requiredCredits: listener.listenerRate > 0 ? listener.listenerRate : 5,
      );
      if (!readiness.canStart) {
        _showMessage(readiness.message);
        return;
      }

      final callStart =
          await _callRepository.createCallToListener(listenerId: safeId);
      if (!mounted) return;
      if (callStart == null || !callStart.canOpenWaitingScreen) {
        _showMessage('Call could not start. Please try again.');
        return;
      }

      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => CallerWaitingScreen(
            callDocRef: callStart.callRef,
            initialAgoraToken: callStart.agoraToken,
            initialAgoraUid: callStart.agoraUid,
            initialChannelId: callStart.channelId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage(_callRepository.humanizeCallActionError(e));
    } finally {
      if (mounted) {
        setState(() => _callingFor = '');
      } else {
        _callingFor = '';
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: StreamBuilder<AppUserModel?>(
        stream: _me,
        builder: (context, meSnap) {
          final me = meSnap.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              _hero(),
              const SizedBox(height: 26),
              _quickCallSection(me),
            ],
          );
        },
      ),
    );
  }

  Widget _hero() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(
              color: AppPalette.blueTint,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.headset_mic_rounded,
                color: AppPalette.blue, size: 40),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Need to talk?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          "Someone's ready to listen — privately, just the two of you.",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _talkNow,
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.phone_rounded, size: 20),
            label: const Text(
              'Talk now',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 50,
          child: OutlinedButton.icon(
            onPressed: _history,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppPalette.textPrimary,
              side: const BorderSide(color: AppPalette.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.access_time_rounded,
                size: 18, color: AppPalette.textSecondary),
            label: const Text(
              'Call history',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _quickCallSection(AppUserModel? me) {
    if (me == null) return const SizedBox.shrink();
    return StreamBuilder<List<AppUserModel>>(
      stream: _listeners,
      builder: (context, listenersSnap) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _sessions,
          builder: (context, sessionsSnap) {
            final listeners = listenersSnap.data ?? const <AppUserModel>[];
            final sessions =
                sessionsSnap.data ?? const <Map<String, dynamic>>[];
            final loading = (listenersSnap.connectionState ==
                        ConnectionState.waiting &&
                    listeners.isEmpty) ||
                (sessionsSnap.connectionState == ConnectionState.waiting &&
                    sessions.isEmpty);
            final ready = _callReadyListeners(
              me: me,
              listeners: listeners,
              sessions: sessions,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Quick call',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'People who accepted your chat — tap Call to reach them.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppPalette.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                if (loading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: AppPalette.blue,
                          strokeWidth: 2.5,
                        ),
                      ),
                    ),
                  )
                else if (ready.isEmpty)
                  _emptyQuickCall()
                else
                  ...ready.map(
                    (u) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _quickCallTile(me, u),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _emptyQuickCall() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppPalette.cardDecoration(radius: 16),
      child: Column(
        children: [
          const Icon(Icons.call_outlined, color: AppPalette.blue, size: 28),
          const SizedBox(height: 10),
          const Text(
            "No accepted contacts yet.\n"
            'Find someone in Discover and start a chat — once they accept, '
            'they show up here for one-tap calling.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: _talkNow,
            child: const Text('Find listeners'),
          ),
        ],
      ),
    );
  }

  Widget _quickCallTile(AppUserModel me, AppUserModel listener) {
    final calling = _callingFor == listener.uid;
    final rate = listener.listenerRate > 0 ? listener.listenerRate : 5;
    final readiness = _callRepository.callReadinessForKnownUsers(
      me: me,
      listener: listener,
      hasCallAccess: true,
      requiredCredits: rate,
    );
    final canCall = readiness.canStart;
    final ratingLabel = listener.ratingCount <= 0
        ? 'New'
        : listener.ratingAvg.toStringAsFixed(1);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _openListenerProfile(listener),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: AppPalette.cardDecoration(radius: 16),
        child: Row(
          children: [
            _Avatar(
              initials: _initialsFromName(listener.safeDisplayName),
              photoUrl: listener.photoURL,
              size: 44,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listener.safeDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '⭐ $ratingLabel · ₹$rate/min'
                    '${canCall ? '' : ' · ${readiness.label}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: canCall
                          ? AppPalette.textSecondary
                          : AppPalette.rose,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 38,
              child: FilledButton.icon(
                onPressed:
                    (calling || !canCall) ? null : () => _startCall(me, listener),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  backgroundColor: AppPalette.blue,
                  disabledBackgroundColor: AppPalette.feedBg,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: AppPalette.textMuted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: calling
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.call_rounded, size: 18),
                label: Text(calling ? 'Wait' : 'Call'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Feed (posts from people you follow — every post routes back to a call)
// ---------------------------------------------------------------------------

String _timeAgo(int ms) {
  if (ms <= 0) return '';
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  if (diff < 60000) return 'now';
  final mins = diff ~/ 60000;
  if (mins < 60) return '${mins}m';
  final hours = mins ~/ 60;
  if (hours < 24) return '${hours}h';
  final days = hours ~/ 24;
  if (days < 7) return '${days}d';
  if (days < 35) return '${days ~/ 7}w';
  if (days < 365) return '${days ~/ 30}mo';
  return '${days ~/ 365}y';
}

class _FeedPage extends StatefulWidget {
  const _FeedPage({required this.onGoToDiscover});

  /// Jumps the shell to the Discover tab (used by the empty-state CTA).
  final VoidCallback onGoToDiscover;

  @override
  State<_FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<_FeedPage> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Stream<List<SocialPostModel>> _posts =
      SocialRepository.instance.watchFeedPosts();

  void _openComposer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ProfileScreen(openComposer: true),
      ),
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
              'Your feed is quiet 🌙',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Follow people from Discover to see what they share — '
              'and reach them with a tap.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: widget.onGoToDiscover,
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
                'Find people to follow',
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
          // While the profile is still loading we don't know who is followed,
          // so keep showing the spinner instead of a false "quiet feed".
          final meLoading =
              me == null && meSnap.connectionState == ConnectionState.waiting;
          final myUid = me?.uid ?? '';
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
                    final visible = all
                        .where((p) =>
                            p.ownerId == myUid || following.contains(p.ownerId))
                        .toList(growable: false);
                    if (visible.isEmpty) {
                      return _emptyFeed();
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.only(top: 10, bottom: 24),
                      itemCount: visible.length,
                      // Keyed by postId so card state (like override, liked
                      // stream) never carries over to a different post when
                      // the list shifts.
                      itemBuilder: (context, i) => _FeedPostCard(
                        key: ValueKey(visible[i].postId),
                        post: visible[i],
                      ),
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
                  'Feed',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textPrimary,
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
}

class _FeedPostCard extends StatefulWidget {
  const _FeedPostCard({super.key, required this.post});
  final SocialPostModel post;

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
              child: Text(
                _post.ownerName.isEmpty ? 'Someone' : _post.ownerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
            ),
            Text(
              _timeAgo(_post.createdAtMs),
              style: const TextStyle(fontSize: 12, color: AppPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    var firstName = _post.ownerName.trim().split(RegExp(r'\s+')).first;
    if (firstName.length > 12) firstName = '${firstName.substring(0, 12)}…';
    final talkLabel = firstName.isEmpty ? 'Talk' : 'Talk to $firstName';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 10),
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
              return InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => _toggleLike(liked),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 22,
                        color:
                            liked ? AppPalette.rose : AppPalette.textSecondary,
                      ),
                      if (_post.likeCount > 0) ...[
                        const SizedBox(width: 5),
                        Text(
                          '${_post.likeCount}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppPalette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: _openDetail,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline_rounded,
                      size: 20, color: AppPalette.textSecondary),
                  if (_post.commentCount > 0) ...[
                    const SizedBox(width: 5),
                    Text(
                      '${_post.commentCount}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _openOwner,
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.phone_rounded, size: 16),
            label: Text(
              talkLabel,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
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
        return InkWell(
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
