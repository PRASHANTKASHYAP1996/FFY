import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/admin_repository.dart';
import '../../repositories/user_repository.dart';
import '../admin_dashboard_screen.dart';
import '../analytics_dashboard_screen.dart';
import '../call_history_screen.dart';
import '../earnings_screen.dart';
import '../developer_diagnostics_screen.dart';
import '../help_support_screen.dart';
import '../profile_screen.dart';
import '../wallet_details_screen.dart';
import 'blocked_users_screen.dart';
import 'saved_listeners_screen.dart';

/// The Settings hub, opened from the top-right of the You tab. Holds account,
/// money, saved people, history, safety, and support — plus admin entries for
/// admins and diagnostics in debug builds.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Resolved once: a server round-trip that only the real admin passes.
  final Future<bool> _isAdmin = AdminRepository.instance.isCurrentUserAdmin();

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _logout() async {
    await UserRepository.instance.signOut();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: AppPalette.textPrimary,
        surfaceTintColor: Colors.transparent,
        title: const Text('Settings'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _section('Account'),
            _row(Icons.person_outline_rounded, 'Edit profile',
                () => _open(const ProfileScreen())),
            const SizedBox(height: 16),
            _section('Money'),
            _row(Icons.account_balance_wallet_outlined, 'Wallet & Payments',
                () => _open(const WalletDetailsScreen())),
            _row(Icons.payments_outlined, 'Earnings',
                () => _open(const EarningsScreen())),
            const SizedBox(height: 16),
            _section('People & history'),
            _row(Icons.favorite_border_rounded, 'Saved Listeners',
                () => _open(const SavedListenersScreen())),
            _row(Icons.access_time_rounded, 'Call History',
                () => _open(const CallHistoryScreen())),
            const SizedBox(height: 16),
            _section('Safety & support'),
            _row(Icons.shield_outlined, 'Safety & Privacy',
                () => _open(const BlockedUsersScreen())),
            _row(Icons.help_outline_rounded, 'Help & Support',
                () => _open(const HelpSupportScreen())),
            FutureBuilder<bool>(
              future: _isAdmin,
              builder: (context, snap) {
                if (snap.data != true) return const SizedBox.shrink();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 16),
                    _section('Admin'),
                    _row(Icons.admin_panel_settings_outlined, 'Admin dashboard',
                        () => _open(const AdminDashboardScreen())),
                    _row(Icons.insights_outlined, 'Analytics',
                        () => _open(const AnalyticsDashboardScreen())),
                  ],
                );
              },
            ),
            if (kDebugMode) ...[
              const SizedBox(height: 16),
              _section('Developer'),
              _row(Icons.bug_report_outlined, 'Developer diagnostics',
                  () => _open(const DeveloperDiagnosticsScreen())),
            ],
            const SizedBox(height: 22),
            _row(Icons.logout_rounded, 'Log out', _logout, danger: true),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11.5,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
          color: AppPalette.textMuted,
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, VoidCallback onTap,
      {bool danger = false}) {
    final color = danger ? AppPalette.rose : AppPalette.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Icon(icon,
                size: 22,
                color: danger ? AppPalette.rose : AppPalette.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
            if (!danger)
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppPalette.textMuted),
          ],
        ),
      ),
    );
  }
}
