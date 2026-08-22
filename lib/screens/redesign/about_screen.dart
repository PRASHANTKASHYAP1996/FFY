import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../legal_policy_screen.dart';
import '../help_support_screen.dart';

/// Standalone "About" surface: identity, version, what Friendify is, and links
/// to the legal policies and support. Reached from Settings › About.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  // Keep this in step with `version:` in pubspec.yaml (currently 1.0.0+1).
  static const String appVersion = '1.0.0';
  static const String buildNumber = '1';

  void _openPolicy(BuildContext context, LegalPolicyKind kind) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LegalPolicyScreen(kind: kind)),
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
        title: const Text('About'),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            _identityCard(),
            const SizedBox(height: 16),
            _infoCard(
              title: 'What Friendify is',
              body: 'Friendify connects you with real people for private, paid '
                  'voice calls and chat when you want someone to talk to. It is '
                  'emotional support and companionship — not professional '
                  'therapy, medical, or crisis care.',
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text(
                'LEGAL',
                style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                  color: AppPalette.textMuted,
                ),
              ),
            ),
            _linksCard(context),
            const SizedBox(height: 16),
            _row(
              icon: Icons.help_outline_rounded,
              label: 'Help & Support',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HelpSupportScreen()),
              ),
              standalone: true,
            ),
            const SizedBox(height: 24),
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

  Widget _identityCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      decoration: AppPalette.cardDecoration(radius: 20),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppPalette.blueTint,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.favorite_rounded,
                color: AppPalette.blue, size: 36),
          ),
          const SizedBox(height: 14),
          const Text(
            'Friendify',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'by PowerX',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: AppPalette.pageBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppPalette.border),
            ),
            child: const Text(
              'Version $appVersion ($buildNumber)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard({required String title, required String body}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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

  Widget _linksCard(BuildContext context) {
    const links = <(IconData, String, LegalPolicyKind)>[
      (Icons.description_outlined, 'Terms & Conditions', LegalPolicyKind.terms),
      (Icons.privacy_tip_outlined, 'Privacy Policy', LegalPolicyKind.privacy),
      (
        Icons.receipt_long_outlined,
        'Refund & Payment Policy',
        LegalPolicyKind.refund
      ),
      (
        Icons.volunteer_activism_outlined,
        'Community Guidelines',
        LegalPolicyKind.communityGuidelines
      ),
      (
        Icons.delete_outline_rounded,
        'Account Deletion',
        LegalPolicyKind.accountDeletion
      ),
    ];
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppPalette.divider),
            _row(
              icon: links[i].$1,
              label: links[i].$2,
              onTap: () => _openPolicy(context, links[i].$3),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool standalone = false,
  }) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppPalette.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              size: 20, color: AppPalette.textMuted),
        ],
      ),
    );
    if (standalone) {
      return Container(
        decoration: AppPalette.cardDecoration(radius: 18),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: content,
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}
