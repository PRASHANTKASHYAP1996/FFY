import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_palette.dart';
import '../repositories/user_repository.dart';

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
  final _nameController = TextEditingController();
  final _topicsController = TextEditingController();
  final _languagesController = TextEditingController();
  int _page = 0;
  String _intent = 'talk';
  bool _callEnabled = true;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    _topicsController.dispose();
    _languagesController.dispose();
    super.dispose();
  }

  // Tappable presets. Topic wording deliberately contains the Discover mood
  // keywords (lonely, stress, work, breakup, relationship, listen) so a
  // listener who taps these actually shows up when someone picks that mood.
  static const List<String> _suggestedTopics = <String>[
    'Loneliness',
    'Stress & anxiety',
    'Work & career',
    'Breakup',
    'Relationships',
    'Study & exams',
    'Family',
    'Just listening',
  ];

  static const List<String> _suggestedLanguages = <String>[
    'English',
    'Hindi',
    'Tamil',
    'Telugu',
    'Bengali',
    'Marathi',
    'Punjabi',
    'Kannada',
  ];

  List<String> _splitCsv(String value) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in value.split(',')) {
      final item = raw.trim();
      if (item.isEmpty) continue;
      final key = item.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(item);
    }
    return out;
  }

  bool _csvContains(TextEditingController c, String value) => _splitCsv(c.text)
      .any((item) => item.toLowerCase() == value.toLowerCase());

  /// Add the preset if missing, remove it if already there, then rewrite the
  /// field so hand-typed entries are preserved and the caret stays at the end.
  void _toggleCsv(TextEditingController c, String value) {
    if (_saving) return;
    final items = _splitCsv(c.text);
    final idx = items.indexWhere((i) => i.toLowerCase() == value.toLowerCase());
    if (idx >= 0) {
      items.removeAt(idx);
    } else {
      items.add(value);
    }
    final text = items.join(', ');
    c.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  Widget _suggestionChips(TextEditingController c, List<String> options) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: options.map((option) {
          final selected = _csvContains(c, option);
          return InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _toggleCsv(c, option),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: selected ? AppPalette.blue : AppPalette.blueTint,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? Icons.check_rounded : Icons.add_rounded,
                    size: 14,
                    color: selected ? Colors.white : AppPalette.blue,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    option,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppPalette.blue,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _finish({bool skipProfileSave = false}) async {
    if (_saving) return;

    final currentUser = FirebaseAuth.instance.currentUser;
    final shouldSaveProfile = currentUser != null && !skipProfileSave;
    final name = _nameController.text.trim();
    final topics = _splitCsv(_topicsController.text);
    final languages = _splitCsv(_languagesController.text);

    if (shouldSaveProfile) {
      if (name.isEmpty) {
        _showSnack('Add your display name to continue.');
        if (_page != 0) {
          await _controller.animateToPage(
            0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
        return;
      }
      if (topics.isEmpty || languages.isEmpty) {
        _showSnack('Add at least one topic and one language.');
        if (_page != 0) {
          await _controller.animateToPage(
            0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
        return;
      }
    }

    setState(() => _saving = true);

    try {
      if (shouldSaveProfile) {
        final isListener = _intent == 'listen' || _intent == 'both';
        final existing = await UserRepository.instance.getMe();
        await UserRepository.instance.ensureProfile(
          email: currentUser.email?.trim() ?? '',
          displayName: name,
        );
        await UserRepository.instance.updateProfile(
          displayName: name,
          bio: existing?.bio ?? '',
          gender: existing?.gender ?? '',
          city: existing?.city ?? '',
          state: existing?.state ?? '',
          country: existing?.country ?? '',
          topics: topics,
          languages: languages,
        );
        await UserRepository.instance.setListenerMode(isListener);
        await UserRepository.instance.setOnlyChatMode(!_callEnabled);
        if (isListener) {
          await UserRepository.instance.setListenerRate(5);
        }
      }

      await OnboardingScreen.markDone();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not save onboarding. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
      backgroundColor: AppPalette.card,
      barrierColor: Colors.black.withValues(alpha: 0.45),
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

  Widget _dot(bool active) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      height: 8,
      width: active ? 24 : 8,
      decoration: BoxDecoration(
        color: active ? AppPalette.blue : AppPalette.border,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  Widget _benefitChip({
    required IconData icon,
    required String text,
    Color? bg,
    Color? fg,
  }) {
    final effectiveBg = bg ?? AppPalette.feedBg;
    final effectiveFg = fg ?? AppPalette.textSecondary;

    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 2,
        children: [
          Icon(icon, size: 15, color: effectiveFg),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              text,
              softWrap: true,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: effectiveFg,
              ),
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: AppPalette.cardDecoration(radius: 28),
                child: Column(
                  children: [
                    _heroIcon(icon, gradient),
                    const SizedBox(height: 22),
                    Text(
                      eyebrow,
                      style: const TextStyle(
                        color: AppPalette.blue,
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
                        color: AppPalette.textPrimary,
                        height: 1.15,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppPalette.textSecondary,
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
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppPalette.border,
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 14,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: 0.04),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
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

  Widget _intentChoice({
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _intent == value;
    return InkWell(
      onTap: _saving ? null : () => setState(() => _intent = value),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppPalette.blueTint : AppPalette.feedBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? AppPalette.blue.withValues(alpha: 0.48)
                : AppPalette.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : icon,
              color: selected ? AppPalette.blue : AppPalette.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
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

  Widget _profileSetupCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Set up your profile',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'These basics power discovery, chat requests, and call matching.',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _nameController,
            enabled: !_saving,
            textInputAction: TextInputAction.next,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'How people should see you',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _topicsController,
            enabled: !_saving,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Topics',
              hintText: 'Stress, career, relationships',
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Tap what you can talk about — the more you add, the more people find you.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
          _suggestionChips(_topicsController, _suggestedTopics),
          const SizedBox(height: 14),
          TextField(
            controller: _languagesController,
            enabled: !_saving,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Languages',
              hintText: 'English, Hindi',
            ),
          ),
          _suggestionChips(_languagesController, _suggestedLanguages),
          const SizedBox(height: 14),
          _intentChoice(
            value: 'talk',
            icon: Icons.chat_bubble_outline_rounded,
            title: 'I want to talk',
            subtitle: 'Use Friendify mainly to find people and start chats.',
          ),
          const SizedBox(height: 8),
          _intentChoice(
            value: 'listen',
            icon: Icons.hearing_rounded,
            title: 'I want to listen',
            subtitle: 'Appear in discovery as a listener when available.',
          ),
          const SizedBox(height: 8),
          _intentChoice(
            value: 'both',
            icon: Icons.compare_arrows_rounded,
            title: 'Both',
            subtitle: 'Talk to people and also be discoverable as a listener.',
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _callEnabled,
            onChanged: _saving
                ? null
                : (value) => setState(() => _callEnabled = value),
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Allow voice-call flow',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontWeight: FontWeight.w900,
              ),
            ),
            subtitle: const Text(
              'Turn this off if you want chat-only mode for now.',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageViewport({
    required Widget card,
    required Widget notice,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                card,
                notice,
              ],
            ),
          ),
        );
      },
    );
  }

  String _stepLabel() => 'Step ${_page + 1} of 3';

  Widget _pageDots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(_page == 0),
        _dot(_page == 1),
        _dot(_page == 2),
      ],
    );
  }

  Widget _pageActions(bool isLast) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: [
        if (_page > 0) ...[
          OutlinedButton(
            onPressed: _saving ? null : _previous,
            child: const Text('Back'),
          ),
        ],
        FilledButton(
          onPressed: _saving ? null : _next,
          child: Text(
            _saving
                ? 'Saving...'
                : isLast
                    ? 'Get Started'
                    : 'Next',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == 2;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppPalette.pageBg,
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: AppPalette.textPrimary,
          surfaceTintColor: Colors.transparent,
          title: const Text('Welcome to Friendify'),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => _finish(skipProfileSave: true),
              child: const Text('Skip'),
            ),
          ],
        ),
        body: DecoratedBox(
          decoration: const BoxDecoration(color: AppPalette.pageBg),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Text(
                _stepLabel(),
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    _pageViewport(
                      card: _pageCard(
                        icon: Icons.people_alt_rounded,
                        gradient: const [
                          Color(0xFF2F6FED),
                          Color(0xFF5B8DEF),
                        ],
                        eyebrow: 'REAL CONNECTIONS',
                        title:
                            'Talk, listen, and find the right kind of support',
                        body:
                            'Friendify helps people connect for meaningful conversations. '
                            'You can come here to talk, listen, or do both when that option is available for your account.',
                        chips: [
                          _benefitChip(
                            icon: Icons.chat_bubble_outline_rounded,
                            text: 'Talk when you need support',
                            bg: AppPalette.blueTint,
                            fg: AppPalette.blue,
                          ),
                          _benefitChip(
                            icon: Icons.hearing_rounded,
                            text: 'Listen for others',
                          ),
                          _benefitChip(
                            icon: Icons.translate_rounded,
                            text: 'Topics & languages',
                            bg: AppPalette.online.withValues(alpha: 0.14),
                            fg: AppPalette.online,
                          ),
                        ],
                      ),
                      notice: _profileSetupCard(),
                    ),
                    _pageViewport(
                      card: _pageCard(
                        icon: Icons.call_rounded,
                        gradient: const [
                          Color(0xFF22C08A),
                          Color(0xFF2FB0C0),
                        ],
                        eyebrow: 'SIMPLE CALLING',
                        title:
                            'Start with chat, then move to calls when you are ready',
                        body:
                            'You can chat first, request a call, and keep track of credits in your wallet.\n\n'
                            'Rates are shown before a paid call starts, and short calls may not use credits depending on the flow.',
                        chips: [
                          _benefitChip(
                            icon: Icons.flash_on_rounded,
                            text: 'Chat first',
                            bg: AppPalette.online.withValues(alpha: 0.14),
                            fg: AppPalette.online,
                          ),
                          _benefitChip(
                            icon: Icons.account_balance_wallet_rounded,
                            text: 'Wallet tracking',
                          ),
                          _benefitChip(
                            icon: Icons.timer_outlined,
                            text: 'See rates upfront',
                            bg: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                            fg: const Color(0xFFB45309),
                          ),
                        ],
                      ),
                      notice: _noticeCard(
                        title: 'Wallet and credits',
                        body:
                            'Your wallet helps you track credits for calling and '
                            'any listener earnings available to your account. '
                            'Available wallet options depend on your account and '
                            'support setup.',
                        actions: [
                          OutlinedButton(
                            onPressed: () {
                              _showInfoSheet(
                                title: 'How wallet features work',
                                body:
                                    'Before a paid call starts, you should be able to see the rate. Your wallet shows available balance and recent activity.\n\nSome payment or withdrawal features may be limited depending on your account or availability.',
                              );
                            },
                            child: const Text('Wallet details'),
                          ),
                        ],
                      ),
                    ),
                    _pageViewport(
                      card: _pageCard(
                        icon: Icons.health_and_safety_rounded,
                        gradient: const [
                          Color(0xFFF59E0B),
                          Color(0xFFEF6B6B),
                        ],
                        eyebrow: 'SAFETY FIRST',
                        title: 'Built with safety tools from the start',
                        body: 'You can report and block users anytime.\n'
                            'If you feel unsafe or overwhelmed, use Crisis Help immediately.\n\n'
                            'Policies, support, and account tools are available from Profile and Help.',
                        chips: [
                          _benefitChip(
                            icon: Icons.flag_rounded,
                            text: 'Report users',
                            bg: const Color(0xFFDC2626).withValues(alpha: 0.12),
                            fg: const Color(0xFFDC2626),
                          ),
                          _benefitChip(
                            icon: Icons.block_rounded,
                            text: 'Block anytime',
                          ),
                          _benefitChip(
                            icon: Icons.support_rounded,
                            text: 'Crisis help',
                            bg: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                            fg: const Color(0xFFB45309),
                          ),
                        ],
                      ),
                      notice: _noticeCard(
                        title: 'Need help?',
                        body:
                            'You can review policies, contact support, and submit a delete-account request from Profile and Help whenever you need them.',
                        actions: [
                          OutlinedButton(
                            onPressed: () {
                              _showInfoSheet(
                                title: 'Where to find help',
                                body:
                                    'Look in Profile and Help for Privacy Policy, Terms of Service, Refund / Cancellation Policy, Support, Crisis Help, and Delete Account Request.',
                              );
                            },
                            child: const Text('Where to look'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 360;
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(child: _pageDots()),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _pageActions(isLast),
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        _pageDots(),
                        const Spacer(),
                        _pageActions(isLast),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
