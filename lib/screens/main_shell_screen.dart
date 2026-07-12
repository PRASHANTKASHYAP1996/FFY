import 'package:flutter/material.dart';

import '../core/theme/friendify_brand.dart';
import '../widgets/friendify_bottom_nav.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'redesign/redesign_shell.dart';
import 'wallet_details_screen.dart';

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  // Phase 1 redesign: flip to `false` to instantly restore the old shell.
  static const bool _useRedesign = true;

  int _currentIndex = 0;

  late final List<Widget> _tabs = <Widget>[
    HomeScreen(onOpenChats: () => _selectTab(3)),
    const HomeScreen(mode: HomeScreenMode.discovery),
    const WalletDetailsScreen(),
    const HomeScreen(mode: HomeScreenMode.chats),
    const ProfileScreen(),
  ];

  void _selectTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  static const List<FriendifyBottomNavItem> _items = <FriendifyBottomNavItem>[
    FriendifyBottomNavItem(
      icon: Icons.home_rounded,
      label: 'Home',
    ),
    FriendifyBottomNavItem(
      icon: Icons.search_rounded,
      label: 'Search',
    ),
    FriendifyBottomNavItem(
      icon: Icons.call_rounded,
      label: 'Calls',
    ),
    FriendifyBottomNavItem(
      icon: Icons.chat_bubble_outline_rounded,
      label: 'Chats',
    ),
    FriendifyBottomNavItem(
      icon: Icons.person_outline_rounded,
      label: 'Profile',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (_useRedesign) {
      return const RedesignShell();
    }
    return Scaffold(
      backgroundColor: FriendifyBrand.deepIndigo,
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: FriendifyBottomNav(
        currentIndex: _currentIndex,
        items: _items,
        onTap: _selectTab,
      ),
    );
  }
}
