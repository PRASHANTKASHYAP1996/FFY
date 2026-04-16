import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CrisisHelpScreen extends StatelessWidget {
  const CrisisHelpScreen({super.key});

  void _copyNumber(BuildContext context, String label, String number) {
    Clipboard.setData(ClipboardData(text: number));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label number copied: $number'),
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
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Color(0xFF374151),
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
    return Card(
      color: const Color(0xFFFEF2F2),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: const [
            CircleAvatar(
              radius: 28,
              backgroundColor: Color(0xFFFEE2E2),
              child: Icon(
                Icons.health_and_safety_rounded,
                color: Color(0xFFDC2626),
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
                color: Color(0xFF111827),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'If you are in immediate danger, feel unsafe, or think you may harm yourself or someone else, stop using the app and contact emergency or crisis support right away.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _warningChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFD97706),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: iconBg,
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
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    number,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
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
      ),
    );
  }

  Widget _infoCard({
    required String title,
    required String body,
    Color color = const Color(0xFFF8FAFC),
    Color border = const Color(0xFFE5E7EB),
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
              color: Color(0xFF6B7280),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: iconBg,
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
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.4,
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

  Widget _copyRow(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const CircleAvatar(
        backgroundColor: Color(0xFFF3F4F6),
        child: Icon(Icons.copy_rounded, color: Color(0xFF374151)),
      ),
      title: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: Color(0xFF111827),
        ),
      ),
      subtitle: Text(
        value,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w700,
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _copyNumber(context, label, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crisis Help'),
      ),
      body: ListView(
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
            iconBg: const Color(0xFFEEF2FF),
            iconColor: const Color(0xFF4F46E5),
          ),
          const SizedBox(height: 10),
          _helplineCard(
            context: context,
            icon: Icons.psychology_rounded,
            title: 'Tele-MANAS mental health support',
            number: '14416',
            body:
                'Use this for immediate mental health support and crisis counselling in India when you need to speak to a counsellor.',
            iconBg: const Color(0xFFECFDF3),
            iconColor: const Color(0xFF15803D),
          ),
          const SizedBox(height: 10),
          _helplineCard(
            context: context,
            icon: Icons.support_agent_rounded,
            title: 'Tele-MANAS alternate number',
            number: '1-800-891-4416',
            body:
                'Alternate Tele-MANAS number for mental health support if needed.',
            iconBg: const Color(0xFFF0F9FF),
            iconColor: const Color(0xFF0369A1),
          ),
          const SizedBox(height: 10),
          _helplineCard(
            context: context,
            icon: Icons.woman_rounded,
            title: 'NCW women helpline',
            number: '14490',
            body:
                'For women facing violence, harassment, emotional distress, or needing legal/support escalation.',
            iconBg: const Color(0xFFFEF2F2),
            iconColor: const Color(0xFFDC2626),
          ),
          const SizedBox(height: 12),
          _stepCard(
            icon: Icons.people_alt_rounded,
            title: 'Contact a trusted person immediately',
            body:
                'Call or message a family member, close friend, partner, roommate, or someone nearby and tell them you need support right now.',
            iconBg: const Color(0xFFECFDF3),
            iconColor: const Color(0xFF15803D),
          ),
          const SizedBox(height: 10),
          _stepCard(
            icon: Icons.local_hospital_rounded,
            title: 'Go to the nearest hospital or emergency department',
            body:
                'If you are at risk of harming yourself or are unable to stay safe, go to the nearest hospital, clinic, or emergency room immediately.',
            iconBg: const Color(0xFFFEF2F2),
            iconColor: const Color(0xFFDC2626),
          ),
          const SizedBox(height: 12),
          _infoCard(
            title: 'Important',
            body:
                'Friendify is not therapy, not a medical service, and cannot provide emergency rescue, psychiatric treatment, ambulance response, or crisis intervention.',
            color: const Color(0xFFFFFBEB),
            border: const Color(0xFFFDE68A),
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
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Quick copy list',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: Color(0xFF111827),
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
            title: 'Support / grievance launch note',
            body:
                'Friendify support contact, grievance officer/contact, Privacy Policy, Terms, and Refund Policy still need final approved production details before launch. This crisis screen only covers immediate emergency and crisis direction.',
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
    );
  }
}