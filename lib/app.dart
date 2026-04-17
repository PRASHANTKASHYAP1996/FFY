import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();

class FriendifyApp extends StatelessWidget {
  const FriendifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B5BD6);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFF6F7FB),
    );

    final baseTheme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFFF6F7FB),
      splashFactory: InkRipple.splashFactory,
      fontFamily: null,
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
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      theme: baseTheme.copyWith(
        appBarTheme: AppBarTheme(
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: const Color(0xFFF6F7FB),
          foregroundColor: const Color(0xFF111827),
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
            letterSpacing: -0.4,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(
              color: Colors.black.withValues(alpha: 0.05),
            ),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: Colors.black.withValues(alpha: 0.08),
          thickness: 1,
          space: 1,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 0,
            backgroundColor: const Color(0xFF5B5BD6),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 14,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            elevation: 0,
            foregroundColor: const Color(0xFF3F3F8C),
            side: BorderSide(
              color: Colors.black.withValues(alpha: 0.10),
            ),
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 14,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF9FAFC),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          labelStyle: const TextStyle(
            fontWeight: FontWeight.w600,
          ),
          hintStyle: TextStyle(
            color: Colors.black.withValues(alpha: 0.45),
            fontWeight: FontWeight.w500,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: Colors.black.withValues(alpha: 0.10),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: Colors.black.withValues(alpha: 0.10),
            ),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
            borderSide: BorderSide(
              color: Color(0xFF5B5BD6),
              width: 1.4,
            ),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          iconColor: Color(0xFF4B5563),
          titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Color(0xFF111827),
          ),
          subtitleTextStyle: TextStyle(
            fontSize: 14,
            height: 1.35,
            color: Color(0xFF6B7280),
            fontWeight: FontWeight.w500,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return Colors.white;
            return Colors.white;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF5B5BD6);
            }
            return const Color(0xFFD7DBE7);
          }),
        ),
        dropdownMenuTheme: const DropdownMenuThemeData(),
      ),
      home: const BootGate(),
    );
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
  bool _openingOnboarding = false;

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
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _onboardingDone = true;
        _loading = false;
      });
    }
  }

  Future<void> _openOnboarding() async {
    if (_openingOnboarding) return;
    _openingOnboarding = true;

    final finished = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const OnboardingScreen(),
      ),
    );

    if (!mounted) return;

    if (finished == true) {
      setState(() => _onboardingDone = true);
    }

    _openingOnboarding = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const _FullScreenLoader();
    }

    if (!_onboardingDone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openOnboarding();
        }
      });

      return const _FullScreenLoader();
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
          return _AuthErrorView(error: '${snap.error}');
        }

        if (snap.connectionState == ConnectionState.waiting) {
          return const _FullScreenLoader();
        }

        final user = snap.data;
        if (user == null) {
          return const AuthScreen();
        }

        return const HomeScreen();
      },
    );
  }
}

class _FullScreenLoader extends StatelessWidget {
  const _FullScreenLoader();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class _AuthErrorView extends StatelessWidget {
  final String error;

  const _AuthErrorView({
    required this.error,
  });

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
                      'Auth error',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: () async {
                        try {
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
