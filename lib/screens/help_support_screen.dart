import 'package:flutter/material.dart';

import '../core/constants/legal_links.dart';
import '../core/theme/app_palette.dart';
import 'crisis_help_screen.dart';
import 'legal_policy_screen.dart';

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static const List<_SupportCategory> _categories = [
    _SupportCategory(
      title: 'Account',
      body:
          'Login, profile, safety settings, account deletion request, or access issues.',
      icon: Icons.person_outline_rounded,
    ),
    _SupportCategory(
      title: 'Payment / wallet',
      body:
          'Top-up, wallet balance, call charge, refund, duplicate payment, or orderId issue.',
      icon: Icons.account_balance_wallet_outlined,
    ),
    _SupportCategory(
      title: 'Call / chat issue',
      body:
          'Call connection, missed call, notification, chat session, or message delivery issue.',
      icon: Icons.call_outlined,
    ),
    _SupportCategory(
      title: 'Report abuse',
      body:
          'Harassment, unsafe content, scam, payment pressure, inappropriate behavior, or threat.',
      icon: Icons.flag_outlined,
    ),
    _SupportCategory(
      title: 'Withdrawal',
      body:
          'Withdrawal request, payout review, rejected request, pending hold, or payout reference.',
      icon: Icons.payments_outlined,
    ),
    _SupportCategory(
      title: 'Other',
      body: 'Anything else that does not fit the categories above.',
      icon: Icons.help_outline_rounded,
    ),
  ];

  Widget _categoryCard(_SupportCategory category) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: AppPalette.blueTint,
                borderRadius: BorderRadius.circular(14)),
            child: Icon(category.icon, color: AppPalette.blue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  category.body,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard({
    required String title,
    required String body,
    Color? accent,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (accent != null) ...[
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
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
        title: const Text('Help & Support'),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _infoCard(
              title: 'Contact support',
              body: '${LegalLinks.supportMessage}\n\n'
                  'When reporting a bug, include the category, date, amount if relevant, and a short description. Do not send tokens, secrets, signatures, or full bank details.',
              accent: AppPalette.blue,
            ),
            const SizedBox(height: 16),
            const Text(
              'Choose the closest category',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            ..._categories.map(
              (category) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _categoryCard(category),
              ),
            ),
            const SizedBox(height: 2),
            _infoCard(
              title: 'Emergency and crisis support',
              body:
                  'Friendify is not an emergency service. If you are in immediate danger, feel unsafe, or may harm yourself or someone else, contact local emergency services now.',
              accent: const Color(0xFFDC2626),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CrisisHelpScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.health_and_safety_rounded),
              label: const Text('Open Crisis Help'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LegalPolicyScreen(
                      kind: LegalPolicyKind.accountDeletion,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Account deletion information'),
            ),
            const SizedBox(height: 24),
            const Center(
              child: Text(
                'Friendify — by PowerX',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text(
                'An independent product, owned & published by PowerX.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: AppPalette.textMuted,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupportCategory {
  const _SupportCategory({
    required this.title,
    required this.body,
    required this.icon,
  });

  final String title;
  final String body;
  final IconData icon;
}
