import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/admin_repository.dart';
import '../../repositories/user_repository.dart';
import '../../shared/models/app_user_model.dart';
import '../admin_dashboard_screen.dart';
import '../analytics_dashboard_screen.dart';
import '../call_history_screen.dart';
import '../developer_diagnostics_screen.dart';
import '../earnings_screen.dart';
import '../help_support_screen.dart';
import '../profile_screen.dart';
import '../wallet_details_screen.dart';
import 'blocked_users_screen.dart';
import 'saved_listeners_screen.dart';

/// Opens the Settings hub as a bottom sheet (matches the prototype). Holds
/// account, money, saved people, history, safety, and support — plus admin
/// entries for admins and diagnostics in debug builds.
Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppPalette.card,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  final Future<bool> _isAdmin = AdminRepository.instance.isCurrentUserAdmin();
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  bool _availabilityBusy = false;

  /// Close the sheet, then open the destination on the same navigator.
  void _open(Widget screen) {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _logout() async {
    final nav = Navigator.of(context);
    await UserRepository.instance.signOut();
    nav.pop();
  }

  Future<void> _setAvailability(bool value) async {
    if (_availabilityBusy) return;
    setState(() => _availabilityBusy = true);
    try {
      await UserRepository.instance.setAvailability(value);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _availabilityBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.86;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppPalette.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 10, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded,
                        color: AppPalette.textSecondary),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                children: [
                  _section('Account'),
                  _availabilityRow(),
                  _row(Icons.person_outline_rounded, 'Edit profile',
                      () => _open(const ProfileScreen())),
                  const SizedBox(height: 14),
                  _section('Money'),
                  _row(
                      Icons.account_balance_wallet_outlined,
                      'Wallet & Payments',
                      () => _open(const WalletDetailsScreen()),
                      sub: 'Balance, transactions & top-ups'),
                  _row(Icons.payments_outlined, 'Earnings',
                      () => _open(const EarningsScreen()),
                      sub: 'Your listener payouts'),
                  const SizedBox(height: 14),
                  _section('People & history'),
                  _row(Icons.favorite_border_rounded, 'Saved Listeners',
                      () => _open(const SavedListenersScreen()),
                      sub: 'People you trust'),
                  _row(Icons.access_time_rounded, 'Call History',
                      () => _open(const CallHistoryScreen()),
                      sub: 'Your private conversations'),
                  const SizedBox(height: 14),
                  _section('Safety & support'),
                  _row(Icons.shield_outlined, 'Safety & Privacy',
                      () => _open(const BlockedUsersScreen()),
                      sub: 'Blocks, reports & account controls'),
                  _row(Icons.help_outline_rounded, 'Help & Support',
                      () => _open(const HelpSupportScreen()),
                      sub: 'Support & crisis resources'),
                  FutureBuilder<bool>(
                    future: _isAdmin,
                    builder: (context, snap) {
                      if (snap.data != true) return const SizedBox.shrink();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 14),
                          _section('Admin'),
                          _row(
                              Icons.admin_panel_settings_outlined,
                              'Admin dashboard',
                              () => _open(const AdminDashboardScreen())),
                          _row(Icons.insights_outlined, 'Analytics',
                              () => _open(const AnalyticsDashboardScreen())),
                        ],
                      );
                    },
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 14),
                    _section('Developer'),
                    _row(Icons.bug_report_outlined, 'Developer diagnostics',
                        () => _open(const DeveloperDiagnosticsScreen())),
                  ],
                  const SizedBox(height: 18),
                  _row(Icons.logout_rounded, 'Log out', _logout, danger: true),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 16, 4, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Friendify — by PowerX',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.textSecondary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Emotional support, not professional therapy.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.textMuted,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _availabilityRow() {
    return StreamBuilder<AppUserModel?>(
      stream: _me,
      builder: (context, snap) {
        final me = snap.data;
        if (me == null || !me.isListener) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              const Icon(Icons.podcasts_rounded,
                  size: 22, color: AppPalette.textSecondary),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  'Available for calls',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              Semantics(
                label: 'Available for calls',
                child: Switch(
                  value: me.isAvailable,
                  onChanged: _availabilityBusy ? null : _setAvailability,
                ),
              ),
            ],
          ),
        );
      },
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
      {bool danger = false, String? sub}) {
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppPalette.textMuted,
                      ),
                    ),
                  ],
                ],
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
