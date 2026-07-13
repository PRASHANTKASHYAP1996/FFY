import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants/legal_links.dart';
import '../core/theme/app_palette.dart';
import '../repositories/user_repository.dart';
import 'crisis_help_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  static bool _clearFormOnNextBuild = false;

  static void clearNextFormOnOpen() {
    _clearFormOnNextBuild = true;
  }

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final UserRepository _userRepository = UserRepository.instance;

  final TextEditingController _email = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final FocusNode _screenFocusNode = FocusNode(
    debugLabel: 'auth_screen_root',
    skipTraversal: true,
    canRequestFocus: false,
  );
  final FocusNode _signUpNameFocusNode = FocusNode(debugLabel: 'signup_name');
  final FocusNode _loginEmailFocusNode = FocusNode(debugLabel: 'login_email');
  final FocusNode _loginPasswordFocusNode = FocusNode(
    debugLabel: 'login_password',
  );
  final FocusNode _signUpEmailFocusNode = FocusNode(
    debugLabel: 'signup_email',
  );
  final FocusNode _signUpPasswordFocusNode = FocusNode(
    debugLabel: 'signup_password',
  );

  bool isLogin = true;
  bool loading = false;
  bool _obscurePassword = true;
  String? error;

  FocusNode get _activeEmailFocusNode =>
      isLogin ? _loginEmailFocusNode : _signUpEmailFocusNode;

  FocusNode get _activePasswordFocusNode =>
      isLogin ? _loginPasswordFocusNode : _signUpPasswordFocusNode;

  @override
  void initState() {
    super.initState();
    if (AuthScreen._clearFormOnNextBuild) {
      AuthScreen._clearFormOnNextBuild = false;
      _clearFormAfterSignOut();
    }
    _dismissAnyFocusAfterBuild();
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _name.dispose();
    _screenFocusNode.dispose();
    _signUpNameFocusNode.dispose();
    _loginEmailFocusNode.dispose();
    _loginPasswordFocusNode.dispose();
    _signUpEmailFocusNode.dispose();
    _signUpPasswordFocusNode.dispose();
    super.dispose();
  }

  void _dismissAnyFocus() {
    for (final node in <FocusNode>[
      _signUpNameFocusNode,
      _loginEmailFocusNode,
      _loginPasswordFocusNode,
      _signUpEmailFocusNode,
      _signUpPasswordFocusNode,
    ]) {
      node.unfocus(disposition: UnfocusDisposition.scope);
    }
    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );
  }

  void _dismissAnyFocusAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dismissAnyFocus();
    });
  }

  void _clearFormAfterSignOut() {
    _email.clear();
    _pass.clear();
    _name.clear();
    isLogin = true;
    loading = false;
    _obscurePassword = true;
    error = null;
    debugPrint('auth.form_cleared_after_signout');
  }

  String _friendlyAuthError(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'user-disabled':
          return 'This account has been disabled.';
        case 'user-not-found':
          return 'No account found with this email.';
        case 'wrong-password':
        case 'invalid-credential':
          return 'Incorrect email or password.';
        case 'email-already-in-use':
          return 'This email is already registered.';
        case 'weak-password':
          return 'Password is too weak. Use at least 6 characters.';
        case 'too-many-requests':
          return 'Too many attempts. Please try again later.';
        case 'network-request-failed':
          return 'Network error. Check your internet connection.';
        default:
          return e.message?.trim().isNotEmpty == true
              ? e.message!.trim()
              : 'Authentication failed. Please try again.';
      }
    }

    final text = e.toString().trim();
    if (text.startsWith('Exception:')) {
      return text.replaceFirst('Exception:', '').trim();
    }
    return 'Something went wrong. Please try again.';
  }

  bool _isValidEmail(String value) {
    final email = value.trim();
    if (email.isEmpty) return false;
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
  }

  Future<void> submit() async {
    if (loading) return;

    final email = _email.text.trim();
    final pass = _pass.text.trim();
    final name = _name.text.trim();

    if (!_isValidEmail(email)) {
      setState(() => error = 'Please enter a valid email address.');
      return;
    }

    if (pass.length < 6) {
      setState(() => error = 'Password must be at least 6 characters.');
      return;
    }

    if (!isLogin && name.isEmpty) {
      setState(() => error = 'Please enter your name.');
      return;
    }

    if (!isLogin && name.length > 40) {
      setState(() => error = 'Name must be 40 characters or less.');
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      if (isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: pass,
        );
        await _userRepository.ensureProfile(email: email);
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: pass,
        );
        await _userRepository.ensureProfile(
          email: email,
          displayName: name,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => error = _friendlyAuthError(e));
    }

    if (!mounted) return;
    setState(() => loading = false);
  }

  void _toggleMode() {
    if (loading) return;

    _dismissAnyFocus();
    setState(() {
      isLogin = !isLogin;
      error = null;
    });
    _dismissAnyFocusAfterBuild();
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
        return Theme(
          data: AppPalette.lightSheetTheme(sheetContext),
          child: SafeArea(
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
          ),
        );
      },
    );
  }

  Widget _heroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF2F6FED),
            Color(0xFF5B8DEF),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(32),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.favorite_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Friendify',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isLogin
                ? 'Welcome back. Talk, listen, and reconnect in a cleaner premium experience.'
                : 'Create your account and start chatting, calling, or earning as a listener.',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroChip(
                icon: Icons.call_rounded,
                text: 'Voice calls',
              ),
              _HeroChip(
                icon: Icons.people_alt_rounded,
                text: 'Real people',
              ),
              _HeroChip(
                icon: Icons.account_balance_wallet_rounded,
                text: 'Speak & earn',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeSwitch() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
              tapTargetKey: const ValueKey('auth_mode_login_button'),
              text: 'Login',
              selected: isLogin,
              onTap: loading
                  ? null
                  : () {
                      if (!isLogin) {
                        _toggleMode();
                      }
                    },
            ),
          ),
          Expanded(
            child: _ModeButton(
              tapTargetKey: const ValueKey('auth_mode_signup_button'),
              text: 'Sign Up',
              selected: !isLogin,
              onTap: loading
                  ? null
                  : () {
                      if (isLogin) {
                        _toggleMode();
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoLine(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppPalette.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _launchLinkTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color iconColor = AppPalette.blue,
    Color iconBg = AppPalette.blueTint,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: iconBg,
        child: Icon(icon, color: iconColor),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: AppPalette.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppPalette.textMuted,
      ),
      onTap: onTap,
    );
  }

  Widget _launchInfoCard() {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Important information',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Review policies and support information before you continue.',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            _launchLinkTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              subtitle: 'Learn how Friendify handles your data.',
              onTap: () {
                _showInfoSheet(
                  title: 'Privacy Policy',
                  body: LegalLinks.privacyPolicyMessage,
                );
              },
            ),
            const Divider(
              height: 1,
              color: AppPalette.divider,
            ),
            _launchLinkTile(
              icon: Icons.description_outlined,
              title: 'Terms of Service',
              subtitle: 'Read the rules for using Friendify.',
              iconColor: AppPalette.textSecondary,
              iconBg: AppPalette.feedBg,
              onTap: () {
                _showInfoSheet(
                  title: 'Terms of Service',
                  body: LegalLinks.termsOfServiceMessage,
                );
              },
            ),
            const Divider(
              height: 1,
              color: AppPalette.divider,
            ),
            _launchLinkTile(
              icon: Icons.receipt_long_outlined,
              title: 'Refund / Cancellation Policy',
              subtitle: 'See refund and cancellation details.',
              iconColor: const Color(0xFFD97706),
              iconBg: const Color(0xFFFFFBEB),
              onTap: () {
                _showInfoSheet(
                  title: 'Refund / Cancellation Policy',
                  body: LegalLinks.refundCancellationPolicyMessage,
                );
              },
            ),
            const Divider(
              height: 1,
              color: AppPalette.divider,
            ),
            _launchLinkTile(
              icon: Icons.support_agent_rounded,
              title: 'Support',
              subtitle: 'Get help with account or payment issues.',
              iconColor: const Color(0xFF15803D),
              iconBg: const Color(0xFFECFDF3),
              onTap: () {
                _showInfoSheet(
                  title: 'Support',
                  body: LegalLinks.supportMessage,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _screenFocusNode,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
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
            title: const Text('Friendify'),
          ),
          body: Theme(
            data: AppPalette.lightSheetTheme(context),
            child: DecoratedBox(
              decoration: const BoxDecoration(color: AppPalette.pageBg),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    children: [
                      _heroCard(),
                      const SizedBox(height: 14),
                      Container(
                        key: ValueKey('auth_form_card_$isLogin'),
                        decoration: AppPalette.cardDecoration(radius: 18),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: FocusScope(
                            key: ValueKey('auth_form_scope_$isLogin'),
                            child: AutofillGroup(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _modeSwitch(),
                                  const SizedBox(height: 18),
                                  Text(
                                    isLogin
                                        ? 'Login to continue'
                                        : 'Create your account',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      color: AppPalette.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    isLogin
                                        ? 'Access your chats, calls, wallet, history, and profile tools.'
                                        : 'Set up your profile and start using Friendify in minutes.',
                                    style: const TextStyle(
                                      color: AppPalette.textSecondary,
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  if (!isLogin) ...[
                                    TextField(
                                      key: const ValueKey('auth_name_field'),
                                      controller: _name,
                                      focusNode: _signUpNameFocusNode,
                                      autofocus: false,
                                      cursorColor: AppPalette.blue,
                                      style: const TextStyle(
                                        color: AppPalette.textPrimary,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      textInputAction: TextInputAction.next,
                                      onSubmitted: (_) =>
                                          _signUpEmailFocusNode.requestFocus(),
                                      autofillHints: const [AutofillHints.name],
                                      onTapOutside: (_) => _dismissAnyFocus(),
                                      decoration: const InputDecoration(
                                        labelText: 'Name',
                                        hintText: 'Enter your full name',
                                        prefixIcon:
                                            Icon(Icons.person_outline_rounded),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  TextField(
                                    key: ValueKey('auth_email_field_$isLogin'),
                                    controller: _email,
                                    focusNode: _activeEmailFocusNode,
                                    autofocus: false,
                                    cursorColor: AppPalette.blue,
                                    style: const TextStyle(
                                      color: AppPalette.textPrimary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.next,
                                    autofillHints: const [AutofillHints.email],
                                    onSubmitted: (_) =>
                                        _activePasswordFocusNode.requestFocus(),
                                    onTapOutside: (_) => _dismissAnyFocus(),
                                    decoration: const InputDecoration(
                                      labelText: 'Email',
                                      hintText: 'Enter your email address',
                                      prefixIcon:
                                          Icon(Icons.mail_outline_rounded),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    key: ValueKey(
                                        'auth_password_field_$isLogin'),
                                    controller: _pass,
                                    focusNode: _activePasswordFocusNode,
                                    autofocus: false,
                                    cursorColor: AppPalette.blue,
                                    style: const TextStyle(
                                      color: AppPalette.textPrimary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    obscureText: _obscurePassword,
                                    autofillHints: isLogin
                                        ? const [AutofillHints.password]
                                        : const [AutofillHints.newPassword],
                                    onSubmitted: (_) => submit(),
                                    onTapOutside: (_) => _dismissAnyFocus(),
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      hintText: 'Minimum 6 characters',
                                      prefixIcon: const Icon(
                                          Icons.lock_outline_rounded),
                                      suffixIcon: IconButton(
                                        onPressed: loading
                                            ? null
                                            : () {
                                                setState(() {
                                                  _obscurePassword =
                                                      !_obscurePassword;
                                                });
                                              },
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_off_rounded
                                              : Icons.visibility_rounded,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  if (error != null)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color:
                                            const Color(0xFFDC2626).withValues(
                                          alpha: 0.10,
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: const Color(0xFFDC2626)
                                              .withValues(
                                            alpha: 0.26,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        error!,
                                        style: const TextStyle(
                                          color: Color(0xFFDC2626),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  if (error != null) const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: loading ? null : submit,
                                      icon: Icon(
                                        loading
                                            ? Icons.hourglass_top_rounded
                                            : (isLogin
                                                ? Icons.login_rounded
                                                : Icons
                                                    .person_add_alt_1_rounded),
                                      ),
                                      label: Text(
                                        loading
                                            ? 'Please wait...'
                                            : (isLogin
                                                ? 'Login'
                                                : 'Create Account'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  _infoLine(
                                    Icons.shield_outlined,
                                    'Safe profile creation and protected login flow.',
                                  ),
                                  const SizedBox(height: 8),
                                  _infoLine(
                                    Icons.call_rounded,
                                    'Start chatting, calling, or receiving requests after login.',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 12),
                        _launchInfoCard(),
                      ],
                      const SizedBox(height: 12),
                      Container(
                        decoration: AppPalette.cardDecoration(radius: 18),
                        child: ListTile(
                          leading: const Icon(
                            Icons.support_rounded,
                            color: Color(0xFFF59E0B),
                          ),
                          title: const Text(
                            'Crisis Help',
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          subtitle: const Text(
                            'If you feel unsafe or overwhelmed, get immediate help now.',
                            style: TextStyle(
                              color: AppPalette.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CrisisHelpScreen(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HeroChip({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final Key? tapTargetKey;
  final String text;
  final bool selected;
  final VoidCallback? onTap;

  const _ModeButton({
    this.tapTargetKey,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppPalette.blueTint : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          key: tapTargetKey,
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: selected ? AppPalette.blue : AppPalette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
