import 'package:flutter/material.dart';

/// Redesign palette: clean white + a friendly blue, soft and easy on the eyes.
/// Warmth comes from soft shapes and copy, not loud color. A single rose accent
/// is used only for warm touches (the like heart).
class AppPalette {
  const AppPalette._();

  // Surfaces
  static const Color pageBg = Color(0xFFF4F7FB);
  static const Color feedBg = Color(0xFFEEF2F7);
  static const Color card = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE7ECF3);
  static const Color divider = Color(0xFFEAEEF4);

  // Text
  static const Color textPrimary = Color(0xFF1B2430);
  static const Color textSecondary = Color(0xFF6A7686);
  static const Color textMuted = Color(0xFF9AA4B2);

  // Accents
  static const Color blue = Color(0xFF2F6FED);
  static const Color blueDark = Color(0xFF255CD1);
  static const Color blueTint = Color(0xFFEAF1FE);
  static const Color rose = Color(0xFFF0668E); // warm touch (like heart)
  static const Color online = Color(0xFF22C08A);
  static const Color star = Color(0xFFF5A623);

  static BoxDecoration cardDecoration({double radius = 14}) {
    return BoxDecoration(
      color: card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border, width: 0.5),
    );
  }

  // Immersive call screens: a calm deep-blue gradient with light content on top.
  // Purpose-built for the ringing + live-call screens (not the light surfaces).
  static const LinearGradient callGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF17357E), Color(0xFF244FBE), Color(0xFF2F6FED)],
  );
  static const Color callAccent = Color(0xFFBFD4FF); // light blue on gradient
  static const Color callSuccess = Color(0xFF6FE0BE); // light green
  static const Color callDanger = Color(0xFFFF6B6B); // light red

  /// Frosted translucent card used on top of [callGradient].
  static BoxDecoration callCardDecoration({double radius = 18}) {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
    );
  }
}
