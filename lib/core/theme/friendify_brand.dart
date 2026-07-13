import 'package:flutter/material.dart';

class FriendifyBrand {
  const FriendifyBrand._();

  static const Color deepIndigo = Color(0xFF0B0F2F);
  static const Color midnightBlue = Color(0xFF121A3A);
  static const Color darkSurface = Color(0xFF12162A);
  static const Color darkSurfaceElevated = Color(0xFF171B32);
  static const Color softViolet = Color(0xFF7C6CFF);
  static const Color magenta = Color(0xFFD83AD8);
  static const Color lavenderGlow = Color(0xFFAFA7FF);
  static const Color mintGreen = Color(0xFF3ED7B8);
  static const Color softTeal = Color(0xFF5FD3C6);
  static const Color pureWhite = Color(0xFFFFFFFF);
  static const Color softGrey = Color(0xFFF5F6FA);
  static const Color slate = Color(0xFFA1A6B3);
  static const Color darkStroke = Color(0xFF2A3150);
  static const Color danger = Color(0xFFFF4D5E);
  static const Color warning = Color(0xFFFFA53D);

  static const LinearGradient appBackgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      deepIndigo,
      Color(0xFF080B1D),
      midnightBlue,
    ],
  );

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0xFF4967FF),
      softViolet,
      magenta,
    ],
  );

  static const LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF171B32),
      Color(0xFF101529),
    ],
  );

  static BoxDecoration brandedBackground() {
    return const BoxDecoration(
      gradient: appBackgroundGradient,
    );
  }

  static double screenGutter(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 360) return 6;
    if (width < 430) return 8;
    if (width < 600) return 12;
    return 16;
  }

  static double navGutter(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 360) return 6;
    if (width < 430) return 8;
    if (width < 600) return 12;
    return 18;
  }

  static EdgeInsets screenPadding(
    BuildContext context, {
    double top = 0,
    double bottom = 0,
  }) {
    final gutter = screenGutter(context);
    return EdgeInsets.fromLTRB(gutter, top, gutter, bottom);
  }

  static BoxDecoration panelDecoration({
    double radius = 18,
    bool glow = false,
  }) {
    return BoxDecoration(
      gradient: cardGradient,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: pureWhite.withValues(alpha: 0.09)),
      boxShadow: [
        if (glow)
          BoxShadow(
            blurRadius: 26,
            offset: const Offset(0, 12),
            color: softViolet.withValues(alpha: 0.22),
          ),
        BoxShadow(
          blurRadius: 18,
          offset: const Offset(0, 10),
          color: Colors.black.withValues(alpha: 0.24),
        ),
      ],
    );
  }

  static BoxDecoration iconTileDecoration({
    Color? color,
    double radius = 14,
  }) {
    return BoxDecoration(
      color: (color ?? pureWhite).withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: pureWhite.withValues(alpha: 0.08)),
    );
  }
}
