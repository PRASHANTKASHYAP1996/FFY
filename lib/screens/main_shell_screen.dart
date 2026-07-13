import 'package:flutter/material.dart';

import 'redesign/redesign_shell.dart';

/// Thin wrapper kept so BootGate keeps a stable entry point.
/// The pre-redesign tabbed shell (HomeScreen + FriendifyBottomNav) was
/// removed after the redesign shipped; see git history to recover it.
class MainShellScreen extends StatelessWidget {
  const MainShellScreen({super.key});

  @override
  Widget build(BuildContext context) => const RedesignShell();
}
