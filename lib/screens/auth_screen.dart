import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../repositories/user_repository.dart';
import 'crisis_help_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final UserRepository _userRepository = UserRepository.instance;

  final TextEditingController _email = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _name = TextEditingController();

  bool isLogin = true;
  bool loading = false;
  bool _obscurePassword = true;
  String? error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _name.dispose();
    super.dispose();
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

    setState(() {
      isLogin = !isLogin;
      error = null;
    });
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

  Widget _heroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF6366F1),
            Color(0xFF8B5CF6),
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
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
        color: const Color(0xFFF3F4F8),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
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
        Icon(icon, size: 18, color: const Color(0xFF6B7280)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFF6B7280),
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
    Color iconColor = const Color(0xFF4F46E5),
    Color iconBg = const Color(0xFFEEF2FF),
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
          color: Color(0xFF111827),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Color(0xFF9CA3AF),
      ),
      onTap: onTap,
    );
  }

  Widget _launchInfoCard() {
    return Card(
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
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Visible legal and support surfaces for the current launch-prep build.',
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: const Text(
                'Current truth: these surfaces are intentionally visible, but final legal text, support channels, grievance details, and production payment/refund operations still need founder/business completion before launch.',
                style: TextStyle(
                  color: Color(0xFF92400E),
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _launchLinkTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              subtitle: 'Placeholder until final approved policy is linked.',
              onTap: () {
                _showInfoSheet(
                  title: 'Privacy Policy',
                  body:
                      'Privacy Policy page is not finalized in this build yet.\n\nBefore launch, add the final approved Privacy Policy text and public link here.',
                );
              },
            ),
            const Divider(height: 1),
            _launchLinkTile(
              icon: Icons.description_outlined,
              title: 'Terms of Service',
              subtitle: 'Placeholder until final approved terms are linked.',
              iconColor: const Color(0xFF374151),
              iconBg: const Color(0xFFF3F4F6),
              onTap: () {
                _showInfoSheet(
                  title: 'Terms of Service',
                  body:
                      'Terms of Service page is not finalized in this build yet.\n\nBefore launch, add final consumer terms, listener rules, prohibited conduct, moderation, billing terms, and dispute language here.',
                );
              },
            ),
            const Divider(height: 1),
            _launchLinkTile(
              icon: Icons.receipt_long_outlined,
              title: 'Refund Policy',
              subtitle: 'Shows the current truth for this launch-prep build.',
              iconColor: const Color(0xFFD97706),
              iconBg: const Color(0xFFFFFBEB),
              onTap: () {
                _showInfoSheet(
                  title: 'Refund Policy',
                  body:
                      'Refund Policy is still placeholder-only in this build.\n\nCurrent truth: parts of payment flow are still test oriented, so this should not be treated as a fully live production refund system yet.',
                );
              },
            ),
            const Divider(height: 1),
            _launchLinkTile(
              icon: Icons.support_agent_rounded,
              title: 'Support / Grievance Contact',
              subtitle: 'Placeholder until final support channels are configured.',
              iconColor: const Color(0xFF15803D),
              iconBg: const Color(0xFFECFDF3),
              onTap: () {
                _showInfoSheet(
                  title: 'Support / Grievance Contact',
                  body:
                      'Support and grievance contact details are not finalized in this build yet.\n\nBefore launch, configure support email, support hours, grievance officer/contact, and escalation path.',
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
    return Scaffold(
      appBar: AppBar(title: const Text('Friendify')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            children: [
              _heroCard(),
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _modeSwitch(),
                        const SizedBox(height: 18),
                        Text(
                          isLogin ? 'Login to continue' : 'Create your account',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isLogin
                              ? 'Access your chats, calls, wallet, history, and profile tools.'
                              : 'Set up your profile and start using Friendify in minutes.',
                          style: const TextStyle(
                            color: Color(0xFF6B7280),
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!isLogin) ...[
                          TextField(
                            controller: _name,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.name],
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              hintText: 'Enter your full name',
                              prefixIcon: Icon(Icons.person_outline_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            hintText: 'Enter your email address',
                            prefixIcon: Icon(Icons.mail_outline_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pass,
                          obscureText: _obscurePassword,
                          autofillHints: isLogin
                              ? const [AutofillHints.password]
                              : const [AutofillHints.newPassword],
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            hintText: 'Minimum 6 characters',
                            prefixIcon:
                                const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              onPressed: loading
                                  ? null
                                  : () {
                                      setState(() {
                                        _obscurePassword = !_obscurePassword;
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
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFFECACA),
                              ),
                            ),
                            child: Text(
                              error!,
                              style: const TextStyle(
                                color: Color(0xFFB91C1C),
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
                                      : Icons.person_add_alt_1_rounded),
                            ),
                            label: Text(
                              loading
                                  ? 'Please wait...'
                                  : (isLogin ? 'Login' : 'Create Account'),
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
              const SizedBox(height: 12),
              _launchInfoCard(),
              const SizedBox(height: 12),
              Card(
                color: const Color(0xFFFFFBEB),
                child: ListTile(
                  leading: const Icon(
                    Icons.support_rounded,
                    color: Color(0xFFD97706),
                  ),
                  title: const Text('Crisis Help'),
                  subtitle: const Text(
                    'If you feel unsafe or overwhelmed, get immediate help now.',
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
  final String text;
  final bool selected;
  final VoidCallback? onTap;

  const _ModeButton({
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: selected
                    ? const Color(0xFF111827)
                    : const Color(0xFF6B7280),
              ),
            ),
          ),
        ),
      ),
    );
  }
}