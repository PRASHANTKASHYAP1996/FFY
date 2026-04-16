import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  static const String prefKey = 'onboarding_done';

  static Future<bool> isDone() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(prefKey) ?? false;
  }

  static Future<void> markDone() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefKey, true);
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await OnboardingScreen.markDone();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _next() {
    if (_page >= 2) {
      _finish();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
  }

  void _previous() {
    if (_page <= 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _showInfoSheet({
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

  Widget _dot(bool active) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      height: 8,
      width: active ? 24 : 8,
      decoration: BoxDecoration(
        color: active ? const Color(0xFF5B5BD6) : const Color(0xFFD1D5DB),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  Widget _benefitChip({
    required IconData icon,
    required String text,
    Color bg = const Color(0xFFF3F4F8),
    Color fg = const Color(0xFF374151),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroIcon(IconData icon, List<Color> colors) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Icon(
        icon,
        size: 38,
        color: Colors.white,
      ),
    );
  }

  Widget _pageCard({
    required IconData icon,
    required List<Color> gradient,
    required String eyebrow,
    required String title,
    required String body,
    required List<Widget> chips,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _heroIcon(icon, gradient),
              const SizedBox(height: 22),
              Text(
                eyebrow,
                style: const TextStyle(
                  color: Color(0xFF5B5BD6),
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                  height: 1.15,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                  height: 1.45,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: chips,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noticeCard({
    required String title,
    required String body,
    List<Widget>? actions,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
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
          if (actions != null && actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }

  String _stepLabel() => 'Step ${_page + 1} of 3';

  @override
  Widget build(BuildContext context) {
    final isLast = _page == 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome to Friendify'),
        actions: [
          TextButton(
            onPressed: _finish,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Text(
            _stepLabel(),
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: PageView(
              controller: _controller,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                Column(
                  children: [
                    Expanded(
                      child: _pageCard(
                        icon: Icons.people_alt_rounded,
                        gradient: const [
                          Color(0xFF6366F1),
                          Color(0xFF8B5CF6),
                        ],
                        eyebrow: 'REAL CONNECTIONS',
                        title: 'Talk to real people who are ready to listen',
                        body:
                            'Friendify helps you connect with listeners for real conversations. '
                            'You can chat first, request a paid call, or accept a call and earn.',
                        chips: [
                          _benefitChip(
                            icon: Icons.call_rounded,
                            text: 'Real conversations',
                            bg: const Color(0xFFEEF2FF),
                            fg: const Color(0xFF4338CA),
                          ),
                          _benefitChip(
                            icon: Icons.public_rounded,
                            text: 'Global listeners',
                          ),
                          _benefitChip(
                            icon: Icons.account_balance_wallet_rounded,
                            text: 'Earn as listener',
                            bg: const Color(0xFFECFDF3),
                            fg: const Color(0xFF15803D),
                          ),
                        ],
                      ),
                    ),
                    _noticeCard(
                      title: 'Before launch',
                      body:
                          'Privacy Policy, Terms of Service, Refund Policy, Support / Grievance contact, and account deletion handling must stay visible and be finalized before production launch.',
                      actions: [
                        OutlinedButton(
                          onPressed: () {
                            _showInfoSheet(
                              title: 'Launch readiness note',
                              body:
                                  'These surfaces are intentionally visible in the current build so they are not forgotten before launch. Final text, links, and operational processes still need founder/business/legal completion.',
                            );
                          },
                          child: const Text('Why this matters'),
                        ),
                      ],
                    ),
                  ],
                ),
                Column(
                  children: [
                    Expanded(
                      child: _pageCard(
                        icon: Icons.call_rounded,
                        gradient: const [
                          Color(0xFF0EA5E9),
                          Color(0xFF2563EB),
                        ],
                        eyebrow: 'SIMPLE CALLING',
                        title: 'Clear calling flow with simple pricing',
                        body:
                            'Choose a listener, place a call, and start talking.\n\n'
                            'Billing is easy:\n'
                            'Under 60 seconds is free.\n'
                            'After that, full minutes only.',
                        chips: [
                          _benefitChip(
                            icon: Icons.flash_on_rounded,
                            text: 'Fast flow',
                            bg: const Color(0xFFEFF6FF),
                            fg: const Color(0xFF1D4ED8),
                          ),
                          _benefitChip(
                            icon: Icons.sell_rounded,
                            text: 'Clear pricing',
                          ),
                          _benefitChip(
                            icon: Icons.timer_outlined,
                            text: '60s free start',
                            bg: const Color(0xFFFFF7ED),
                            fg: const Color(0xFFC2410C),
                          ),
                        ],
                      ),
                    ),
                    _noticeCard(
                      title: 'Current payment truth',
                      body:
                          'This launch-prep build still includes test-oriented payment surfaces in parts of the wallet flow. Do not present it as fully live production money flow yet.',
                      actions: [
                        OutlinedButton(
                          onPressed: () {
                            _showInfoSheet(
                              title: 'Payment phase note',
                              body:
                                  'Wallet visibility, settlement visibility, test payment orders, and manual/test withdrawal workflows may exist in the product, but real commercial payment launch still needs final payment, operational, and legal readiness.',
                            );
                          },
                          child: const Text('Payment phase'),
                        ),
                      ],
                    ),
                  ],
                ),
                Column(
                  children: [
                    Expanded(
                      child: _pageCard(
                        icon: Icons.health_and_safety_rounded,
                        gradient: const [
                          Color(0xFFF59E0B),
                          Color(0xFFEF4444),
                        ],
                        eyebrow: 'SAFETY FIRST',
                        title: 'Built with safety tools from the start',
                        body:
                            'You can report and block users anytime.\n'
                            'If you feel unsafe or overwhelmed, use Crisis Help immediately.\n\n'
                            'Harassment, scams, and sexual misconduct are not allowed.',
                        chips: [
                          _benefitChip(
                            icon: Icons.flag_rounded,
                            text: 'Report users',
                            bg: const Color(0xFFFEF2F2),
                            fg: const Color(0xFFB91C1C),
                          ),
                          _benefitChip(
                            icon: Icons.block_rounded,
                            text: 'Block anytime',
                          ),
                          _benefitChip(
                            icon: Icons.support_rounded,
                            text: 'Crisis help',
                            bg: const Color(0xFFFFFBEB),
                            fg: const Color(0xFFD97706),
                          ),
                        ],
                      ),
                    ),
                    _noticeCard(
                      title: 'Delete & support readiness',
                      body:
                          'Account deletion request flow, support contact, and grievance contact should remain visible in the product before launch, even if they start as controlled placeholders.',
                      actions: [
                        OutlinedButton(
                          onPressed: () {
                            _showInfoSheet(
                              title: 'Support and deletion note',
                              body:
                                  'Delete-account request, support contact, grievance contact, and crisis direction should be reachable in the app before launch. Controlled placeholders are acceptable temporarily, but they should never be hidden or falsely presented as fully complete.',
                            );
                          },
                          child: const Text('Learn more'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
            child: Row(
              children: [
                Row(
                  children: [
                    _dot(_page == 0),
                    _dot(_page == 1),
                    _dot(_page == 2),
                  ],
                ),
                const Spacer(),
                if (_page > 0) ...[
                  OutlinedButton(
                    onPressed: _previous,
                    child: const Text('Back'),
                  ),
                  const SizedBox(width: 10),
                ],
                FilledButton(
                  onPressed: _next,
                  child: Text(isLast ? 'Get Started' : 'Next'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}