import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/call_repository.dart';
import '../../repositories/social_repository.dart';
import '../../repositories/user_repository.dart';
import '../../shared/models/app_user_model.dart';
import '../../shared/models/social_post_model.dart';
import '../call_history_screen.dart';
import '../chat_conversation_screen.dart';
import '../help_support_screen.dart';
import '../listener_profile_screen.dart';
import '../match_and_call_screen.dart';
import '../post_detail_screen.dart';
import '../profile_screen.dart';
import '../wallet_details_screen.dart';

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

  static const List<Widget> _pages = <Widget>[
    _DiscoverPage(),
    _ChatsPage(),
    _CallPage(),
    _FeedPage(),
    _MePage(),
  ];

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
        bottomNavigationBar: _BottomNav(
          index: _index,
          onTap: (i) => setState(() => _index = i),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

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
              _navItem(1, Icons.chat_bubble_outline_rounded, 'Chats'),
              _callButton(),
              _navItem(3, Icons.auto_awesome_outlined, 'Feed'),
              _navItem(4, Icons.person_outline_rounded, 'Me'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label) {
    final selected = index == i;
    final color = selected ? AppPalette.blue : AppPalette.textMuted;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 23, color: color),
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
            child: const Icon(Icons.phone_rounded, color: Colors.white, size: 24),
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

  final Stream<List<AppUserModel>> _stream =
      UserRepository.instance.watchAvailableListeners();

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
                final listeners = snapshot.data ?? const <AppUserModel>[];
                if (listeners.isEmpty) {
                  return const _DiscoverMessage(
                    "No one's around right now 🌙\n"
                    'Check back in a little while.',
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const _OnlineDot(),
                          const SizedBox(width: 6),
                          Text(
                            '${listeners.length} here for you now',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.92,
                        children: listeners
                            .map((u) => _ListenerCard(
                                  user: u,
                                  onTap: () => _openProfile(u),
                                ))
                            .toList(),
                      ),
                    ],
                  ),
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
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'How are you feeling?',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    "someone's here for you 🌙",
                    style:
                        TextStyle(fontSize: 13, color: AppPalette.textSecondary),
                  ),
                ],
              ),
              Icon(Icons.search_rounded,
                  color: AppPalette.textMuted, size: 22),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            children: List.generate(_moods.length, (i) {
              final selected = i == 0;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? AppPalette.blue : AppPalette.blueTint,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _moods[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: selected ? Colors.white : AppPalette.blue,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _ListenerCard extends StatelessWidget {
  const _ListenerCard({required this.user, required this.onTap});
  final AppUserModel user;
  final VoidCallback onTap;

  String get _ratingLabel =>
      user.ratingCount <= 0 ? 'New' : user.ratingAvg.toStringAsFixed(1);

  bool get _online => user.isAvailable && !user.isOnCall;

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
                const Icon(Icons.star_rounded, size: 14, color: AppPalette.star),
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

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _logout() async {
    await UserRepository.instance.signOut();
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
                          me?.isListener == true
                              ? 'Listener mode: on'
                              : 'Member',
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
              _menuRow(Icons.account_balance_wallet_outlined,
                  'Wallet and transactions',
                  () => _open(const WalletDetailsScreen())),
              _menuRow(Icons.access_time_rounded, 'Call history',
                  () => _open(const CallHistoryScreen())),
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
  final Map<String, AppUserModel?> _cache = <String, AppUserModel?>{};

  Future<AppUserModel?> _resolve(String uid) async {
    if (_cache.containsKey(uid)) return _cache[uid];
    final user = await UserRepository.instance.getUser(uid);
    _cache[uid] = user;
    return user;
  }

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
                final sessions = (snapshot.data ??
                        const <Map<String, dynamic>>[])
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
      initialData: _cache[otherUid],
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

class _CallPage extends StatelessWidget {
  const _CallPage();

  void _talkNow(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MatchAndCallScreen()),
    );
  }

  void _history(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CallHistoryScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(flex: 2),
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  color: AppPalette.blueTint,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.headset_mic_rounded,
                    color: AppPalette.blue, size: 44),
              ),
            ),
            const SizedBox(height: 22),
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
            const SizedBox(height: 26),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: () => _talkNow(context),
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
                onPressed: () => _history(context),
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
            const Spacer(flex: 3),
            const Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _CallTag('Private'),
                _CallTag('1-on-1'),
                _CallTag('Judgment-free'),
              ],
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _CallTag extends StatelessWidget {
  const _CallTag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11.5, color: AppPalette.textMuted),
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
  const _FeedPage();

  @override
  State<_FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<_FeedPage> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Stream<List<SocialPostModel>> _posts =
      SocialRepository.instance.watchFeedPosts();

  void _openComposer() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
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
                    if (snap.connectionState == ConnectionState.waiting &&
                        !snap.hasData) {
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
                      return const _DiscoverMessage(
                        'Your feed is quiet 🌙\n'
                        'Follow people from Discover to see what they share.',
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.only(top: 10, bottom: 24),
                      itemCount: visible.length,
                      itemBuilder: (context, i) =>
                          _FeedPostCard(post: visible[i]),
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
          const Text(
            'Feed',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
  const _FeedPostCard({required this.post});
  final SocialPostModel post;

  @override
  State<_FeedPostCard> createState() => _FeedPostCardState();
}

class _FeedPostCardState extends State<_FeedPostCard> {
  final SocialRepository _social = SocialRepository.instance;
  bool? _likedOverride;
  bool _busy = false;

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
              style:
                  const TextStyle(fontSize: 12, color: AppPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 10),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: _social.watchPostLikedByMe(_post.postId),
            builder: (context, snap) {
              final serverLiked = snap.data ?? false;
              final liked = _likedOverride ?? serverLiked;
              return InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => _toggleLike(liked),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 22,
                        color: liked ? AppPalette.rose : AppPalette.textSecondary,
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.phone_rounded, size: 16),
            label: const Text(
              'Talk to them',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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

