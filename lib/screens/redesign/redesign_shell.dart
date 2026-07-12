import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';

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
    _PlaceholderPage(
      icon: Icons.chat_bubble_outline_rounded,
      title: 'Chats',
      subtitle: 'Talk first, then request a call.',
    ),
    _PlaceholderPage(
      icon: Icons.phone_rounded,
      title: 'Call',
      subtitle: 'Quick match and your call history.',
    ),
    _PlaceholderPage(
      icon: Icons.auto_awesome_rounded,
      title: 'Feed',
      subtitle: 'Posts from people you follow.',
    ),
    _PlaceholderPage(
      icon: Icons.person_outline_rounded,
      title: 'Me',
      subtitle: 'Your profile, wallet, and earnings.',
    ),
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

class _Listener {
  const _Listener(this.name, this.initials, this.rating, this.rate);
  final String name;
  final String initials;
  final String rating;
  final int rate;
}

class _DiscoverPage extends StatelessWidget {
  const _DiscoverPage();

  static const List<_Listener> _demo = <_Listener>[
    _Listener('Meera', 'MK', '4.9', 10),
    _Listener('Aarav', 'AR', '4.7', 5),
    _Listener('Sana', 'SD', '4.8', 20),
    _Listener('Rahul', 'RJ', '4.6', 10),
    _Listener('Isha', 'IK', '5.0', 20),
    _Listener('Kabir', 'KB', '4.5', 5),
  ];

  static const List<String> _moods = <String>[
    'Lonely',
    'Stressed',
    'Breakup',
    'Just talk',
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      _OnlineDot(),
                      SizedBox(width: 6),
                      Text(
                        '14 here for you now',
                        style: TextStyle(
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
                    children:
                        _demo.map((l) => _ListenerCard(listener: l)).toList(),
                  ),
                ],
              ),
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
  const _ListenerCard({required this.listener});
  final _Listener listener;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppPalette.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Avatar(initials: listener.initials, size: 40),
              const Spacer(),
              const _OnlineDot(),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            listener.name,
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
              Text(
                '${listener.rating} · ₹${listener.rate}/min',
                style: const TextStyle(
                    fontSize: 12, color: AppPalette.textSecondary),
              ),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {},
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
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, this.size = 40});
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
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

// ---------------------------------------------------------------------------
// Placeholder tabs (real screens land in later phases)
// ---------------------------------------------------------------------------

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: const BoxDecoration(
                color: AppPalette.blueTint,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: AppPalette.blue, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, color: AppPalette.textSecondary),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: AppPalette.feedBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                'Coming in the next phase',
                style: TextStyle(fontSize: 11, color: AppPalette.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
