import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants/legal_links.dart';
import '../core/theme/app_palette.dart';

class CrisisHelpScreen extends StatelessWidget {
  const CrisisHelpScreen({super.key});

  void _copyNumber(BuildContext context, String label, String number) {
    Clipboard.setData(ClipboardData(text: number));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label number copied: $number'),
        backgroundColor: AppPalette.card,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showInfoSheet(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppPalette.card,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.of(sheetContext).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    style: const TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _heroCard() {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(18),
      child: const Column(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Color(0xFFDC2626),
            child: Icon(
              Icons.health_and_safety_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          SizedBox(height: 14),
          Text(
            'Get immediate help now',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'If you are in immediate danger, feel unsafe, or think you may harm yourself or someone else, stop using the app and contact emergency or crisis support right away.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _warningChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFB45309),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _helplineCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String number,
    required String body,
    required Color iconBg,
    required Color iconColor,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: iconBg.withValues(alpha: 0.18),
            child: Icon(icon, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  number,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _copyNumber(context, title, number),
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy number'),
                    ),
                  ],
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

  Widget _stepCard({
    required IconData icon,
    required String title,
    required String body,
    required Color iconBg,
    required Color iconColor,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: iconBg.withValues(alpha: 0.18),
            child: Icon(icon, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _copyRow(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const CircleAvatar(
        backgroundColor: AppPalette.blue,
        child: Icon(Icons.copy_rounded, color: Colors.white),
      ),
      title: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: AppPalette.textPrimary,
        ),
      ),
      subtitle: Text(
        value,
        style: const TextStyle(
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppPalette.textSecondary,
      ),
      onTap: () => _copyNumber(context, label, value),
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
        title: const Text('Crisis Help'),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          children: [
            _heroCard(),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _warningChip('India emergency numbers'),
                _warningChip('Safety first'),
                _warningChip('Not a therapy service'),
              ],
            ),
            const SizedBox(height: 12),
            _helplineCard(
              context: context,
              icon: Icons.local_police_rounded,
              title: 'Emergency response',
              number: '112',
              body:
                  'Use this first if there is immediate danger, violence, self-harm risk, or urgent safety threat.',
              iconBg: AppPalette.blue,
              iconColor: AppPalette.blue,
            ),
            const SizedBox(height: 10),
            _helplineCard(
              context: context,
              icon: Icons.psychology_rounded,
              title: 'Tele-MANAS mental health support',
              number: '14416',
              body:
                  'Use this for immediate mental health support and crisis counselling in India when you need to speak to a counsellor.',
              iconBg: AppPalette.online,
              iconColor: AppPalette.online,
            ),
            const SizedBox(height: 10),
            _helplineCard(
              context: context,
              icon: Icons.support_agent_rounded,
              title: 'Tele-MANAS alternate number',
              number: '1-800-891-4416',
              body:
                  'Alternate Tele-MANAS number for mental health support if needed.',
              iconBg: const Color(0xFF14B8A6),
              iconColor: const Color(0xFF14B8A6),
            ),
            const SizedBox(height: 10),
            _helplineCard(
              context: context,
              icon: Icons.woman_rounded,
              title: 'NCW women helpline',
              number: '14490',
              body:
                  'For women facing violence, harassment, emotional distress, or needing legal/support escalation.',
              iconBg: const Color(0xFFDC2626),
              iconColor: const Color(0xFFDC2626),
            ),
            const SizedBox(height: 12),
            _stepCard(
              icon: Icons.people_alt_rounded,
              title: 'Contact a trusted person immediately',
              body:
                  'Call or message a family member, close friend, partner, roommate, or someone nearby and tell them you need support right now.',
              iconBg: AppPalette.online,
              iconColor: AppPalette.online,
            ),
            const SizedBox(height: 10),
            _stepCard(
              icon: Icons.local_hospital_rounded,
              title: 'Go to the nearest hospital or emergency department',
              body:
                  'If you are at risk of harming yourself or are unable to stay safe, go to the nearest hospital, clinic, or emergency room immediately.',
              iconBg: const Color(0xFFDC2626),
              iconColor: const Color(0xFFDC2626),
            ),
            const SizedBox(height: 12),
            _infoCard(
              title: 'Important',
              body:
                  'Friendify is not therapy, not a medical service, and cannot provide emergency rescue, psychiatric treatment, ambulance response, or crisis intervention.',
              accent: const Color(0xFFF59E0B),
            ),
            const SizedBox(height: 12),
            _infoCard(
              title: 'What you should do next',
              body:
                  'Move away from anything dangerous, do not stay alone if possible, contact real-world support immediately, and use professional emergency or crisis services in your area.',
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: AppPalette.cardDecoration(radius: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick copy list',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _copyRow(
                    context,
                    label: 'Emergency',
                    value: '112',
                  ),
                  _copyRow(
                    context,
                    label: 'Tele-MANAS',
                    value: '14416',
                  ),
                  _copyRow(
                    context,
                    label: 'Tele-MANAS alternate',
                    value: '1-800-891-4416',
                  ),
                  _copyRow(
                    context,
                    label: 'NCW women helpline',
                    value: '14490',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _infoCard(
              title: 'Friendify support',
              body: LegalLinks.hasSupport
                  ? 'For account or app support, use the Friendify support details below.\n\n${LegalLinks.supportMessage}'
                  : 'Support details are available from Profile > Support.',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  _showInfoSheet(
                    context,
                    title: 'Why this screen exists',
                    body:
                        'This screen is meant to make crisis and emergency direction clearly reachable inside the app. It is not a substitute for emergency services, therapy, medical care, or official crisis intervention.',
                  );
                },
                icon: const Icon(Icons.info_outline_rounded),
                label: const Text('About this screen'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
