import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/theme/app_palette.dart';
import 'repositories/user_repository.dart';
import 'screens/auth_screen.dart';
import 'screens/main_shell_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/app_log.dart';
import 'shared/models/app_user_model.dart';
import 'widgets/incoming_call_overlay.dart';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class FriendifyApp extends StatelessWidget {
  const FriendifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = AppPalette.blue;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: AppPalette.card,
      onSurface: AppPalette.textPrimary,
    );

    final baseTheme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppPalette.pageBg,
      splashFactory: InkRipple.splashFactory,
      // Poppins via google_fonts: fetched on first launch and cached on device
      // (the app needs network anyway). Drop the .ttf files into assets and
      // declare them in pubspec to make this fully offline / no first-load flash.
      fontFamily: GoogleFonts.poppins().fontFamily,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    return MaterialApp(
      title: 'Friendify',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootMessengerKey,
      navigatorKey: rootNavigatorKey,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final clampedTextScaler = media.textScaler.clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.4,
        );

        return MediaQuery(
          data: media.copyWith(textScaler: clampedTextScaler),
          child: WithForegroundTask(
            child: Stack(
              children: [
                child ?? const SizedBox.shrink(),
                StreamBuilder<User?>(
                  stream: FirebaseAuth.instance.authStateChanges(),
                  builder: (context, snap) {
                    final uid = snap.data?.uid.trim() ?? '';
                    if (uid.isEmpty) return const SizedBox.shrink();
                    return IncomingCallOverlay(myUid: uid);
                  },
                ),
              ],
            ),
          ),
        );
      },
      theme: baseTheme.copyWith(
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: AppPalette.card,
          foregroundColor: AppPalette.textPrimary,
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: SystemUiOverlayStyle.dark,
          titleTextStyle: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: AppPalette.card,
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppPalette.border),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: AppPalette.divider,
          thickness: 1,
          space: 1,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 0,
            backgroundColor: AppPalette.blue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            elevation: 0,
            foregroundColor: AppPalette.blue,
            side: const BorderSide(color: AppPalette.border),
            backgroundColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: AppPalette.blue,
            foregroundColor: Colors.white,
            disabledBackgroundColor: AppPalette.border,
            disabledForegroundColor: AppPalette.textMuted,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppPalette.blue,
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppPalette.feedBg,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
          labelStyle: const TextStyle(
            color: AppPalette.textSecondary,
            fontWeight: FontWeight.w600,
          ),
          hintStyle: const TextStyle(
            color: AppPalette.textMuted,
            fontWeight: FontWeight.w500,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppPalette.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppPalette.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: AppPalette.blue,
              width: 1.4,
            ),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          iconColor: AppPalette.textSecondary,
          titleTextStyle: TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
          subtitleTextStyle: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: AppPalette.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) => Colors.white),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return AppPalette.blue;
            }
            return const Color(0xFFD7DBE7);
          }),
        ),
        dropdownMenuTheme: const DropdownMenuThemeData(),
      ),
      navigatorObservers: <NavigatorObserver>[FriendifyRouteObserver()],
      home: const BootGate(),
    );
  }
}

class FriendifyRouteObserver extends NavigatorObserver {
  String _routeLabel(Route<dynamic>? route) {
    final name = route?.settings.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    return route?.runtimeType.toString() ?? 'unknown';
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.trace(
      'route.push',
      area: 'navigation',
      fields: <String, Object?>{
        'route': _routeLabel(route),
        'previousRoute': _routeLabel(previousRoute),
      },
    );
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.trace(
      'route.pop',
      area: 'navigation',
      fields: <String, Object?>{
        'route': _routeLabel(route),
        'previousRoute': _routeLabel(previousRoute),
      },
    );
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLog.trace(
      'route.replace',
      area: 'navigation',
      fields: <String, Object?>{
        'route': _routeLabel(newRoute),
        'previousRoute': _routeLabel(oldRoute),
      },
    );
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

class BootGate extends StatefulWidget {
  const BootGate({super.key});

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> {
  bool _loading = true;
  bool _onboardingDone = false;
  bool _onboardingDismissedThisLaunch = false;
  bool _openingOnboarding = false;
  bool _onboardingLaunchQueued = false;

  @override
  void initState() {
    super.initState();
    _loadBootState();
  }

  Future<void> _loadBootState() async {
    try {
      final done = await OnboardingScreen.isDone();
      if (!mounted) return;

      setState(() {
        _onboardingDone = done;
        _loading = false;
      });

      AppLog.trace('boot.onboarding_state_loaded',
          area: 'boot', fields: <String, Object?>{'onboardingDone': done});
      if (!done) {
        _queueOnboardingLaunch();
      }
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _onboardingDone = true;
        _loading = false;
      });
    }
  }

  void _queueOnboardingLaunch() {
    if (!mounted) return;
    if (_loading ||
        _onboardingDone ||
        _onboardingDismissedThisLaunch ||
        _openingOnboarding ||
        _onboardingLaunchQueued) {
      return;
    }

    _onboardingLaunchQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _onboardingLaunchQueued = false;
      if (!mounted || _loading || _onboardingDone || _openingOnboarding) {
        return;
      }
      await _openOnboarding();
    });
  }

  Future<void> _openOnboarding() async {
    if (_openingOnboarding) return;
    _openingOnboarding = true;
    FocusManager.instance.primaryFocus?.unfocus();

    final finished = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const OnboardingScreen(),
      ),
    );

    if (!mounted) return;

    setState(() {
      _onboardingDone = finished == true;
      _onboardingDismissedThisLaunch = finished != true;
    });

    _openingOnboarding = false;
    if (!_onboardingDone && !_onboardingDismissedThisLaunch) {
      _queueOnboardingLaunch();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const _FullScreenLoader(message: 'Checking app setup...');
    }

    if (!_onboardingDone && !_onboardingDismissedThisLaunch) {
      return const _FullScreenLoader(message: 'Opening onboarding...');
    }

    return const AuthGate();
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (_, snap) {
        if (snap.hasError) {
          AppLog.trace('auth.state_error',
              area: 'auth',
              fields: <String, Object?>{'error': snap.error?.runtimeType});
          return const _AuthErrorView();
        }

        if (snap.connectionState == ConnectionState.waiting) {
          return const _FullScreenLoader(message: 'Checking your session...');
        }

        final user = snap.data;
        AppLog.trace('auth.state_resolved',
            area: 'auth',
            fields: <String, Object?>{
              'signedIn': user != null,
              'uid': user?.uid
            });
        if (user == null) {
          return const AuthScreen();
        }

        return const _SignedInGate();
      },
    );
  }
}

class _SignedInGate extends StatefulWidget {
  const _SignedInGate();

  @override
  State<_SignedInGate> createState() => _SignedInGateState();
}

class _SignedInGateState extends State<_SignedInGate> {
  bool _repairAttempted = false;
  bool _repairingProfile = false;
  Object? _repairError;

  void _queueProfileRepair() {
    if (_repairAttempted || _repairingProfile) return;
    _repairAttempted = true;
    Future<void>.microtask(_repairProfile);
  }

  Future<void> _repairProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (mounted) {
      setState(() {
        _repairAttempted = true;
        _repairingProfile = true;
        _repairError = null;
      });
    } else {
      _repairAttempted = true;
      _repairingProfile = true;
      _repairError = null;
    }

    try {
      await UserRepository.instance.ensureProfile(
        email: user.email?.trim() ?? '',
        displayName: user.displayName?.trim(),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _repairError = error);
    } finally {
      if (mounted) {
        setState(() => _repairingProfile = false);
      } else {
        _repairingProfile = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUserModel?>(
      stream: UserRepository.instance.watchMe(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const _FullScreenLoader(message: 'Loading your account...');
        }

        final me = snap.data;
        if (me != null && me.isAdminBlocked) {
          return _BlockedAccountView(reason: me.adminBlockReason);
        }

        if (me == null) {
          if (_repairError != null ||
              (_repairAttempted && !_repairingProfile)) {
            return _ProfileRecoveryView(
              onRetry: _repairingProfile ? null : _repairProfile,
              onSignOut: _signOutAfterProfileFailure,
            );
          }

          _queueProfileRepair();
          return const _FullScreenLoader(message: 'Finishing your profile...');
        }

        return const MainShellScreen();
      },
    );
  }

  Future<void> _signOutAfterProfileFailure() async {
    try {
      AuthScreen.clearNextFormOnOpen();
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // The auth stream will keep the recovery screen visible if sign out fails.
    }
  }
}

class _ProfileRecoveryView extends StatelessWidget {
  const _ProfileRecoveryView({
    required this.onRetry,
    required this.onSignOut,
  });

  final VoidCallback? onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppPalette.blue.withValues(
                              alpha: 0.12,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.person_search_rounded,
                            color: AppPalette.blue,
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Profile setup needs attention',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'We could not finish loading your Friendify profile. Retry setup, or sign out and sign in again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Retry setup'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: onSignOut,
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Sign out'),
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
      ),
    );
  }
}

class _BlockedAccountView extends StatelessWidget {
  const _BlockedAccountView({required this.reason});

  final String reason;

  Future<void> _signOut() async {
    try {
      AuthScreen.clearNextFormOnOpen();
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // The auth stream will keep this screen visible if sign out fails.
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeReason = reason.trim();

    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626).withValues(
                              alpha: 0.12,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.block_rounded,
                            color: Color(0xFFDC2626),
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Account restricted',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          safeReason.isEmpty
                              ? 'Your account is currently restricted by the Friendify team. Please contact support if you think this is a mistake.'
                              : 'Your account is currently restricted. Reason: $safeReason',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppPalette.textSecondary,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _signOut,
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Sign out'),
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
      ),
    );
  }
}

class _FullScreenLoader extends StatelessWidget {
  final String message;

  const _FullScreenLoader({
    this.message = 'Getting Friendify ready...',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDE9FE),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: Color(0xFF5B5BD6),
                    size: 34,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Friendify',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthErrorView extends StatelessWidget {
  const _AuthErrorView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 54),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not load your session',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please sign in again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: () async {
                        try {
                          AuthScreen.clearNextFormOnOpen();
                          await FirebaseAuth.instance.signOut();
                        } catch (_) {
                          // ignore sign out failure
                        }
                      },
                      child: const Text('Go to Login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
