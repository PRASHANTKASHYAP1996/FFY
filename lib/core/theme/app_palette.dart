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

  /// The app's global input/button themes are tuned for dark surfaces
  /// (translucent-white fills, purple accents) and are nearly invisible on the
  /// light sheets used by the redesign. Wrap a light bottom sheet's content in
  /// `Theme(data: AppPalette.lightSheetTheme(context), child: ...)` so text
  /// fields and buttons stay visible and on-theme.
  static ThemeData lightSheetTheme(BuildContext context) {
    OutlineInputBorder border(Color color, [double width = 1]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return Theme.of(context).copyWith(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: feedBg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        labelStyle: const TextStyle(
          color: textSecondary,
          fontWeight: FontWeight.w600,
        ),
        hintStyle: const TextStyle(
          color: textMuted,
          fontWeight: FontWeight.w500,
        ),
        border: border(AppPalette.border),
        enabledBorder: border(AppPalette.border),
        focusedBorder: border(blue, 1.4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          backgroundColor: blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          elevation: 0,
          foregroundColor: blue,
          side: const BorderSide(color: AppPalette.border),
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: blue,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppPalette.border,
          disabledForegroundColor: textMuted,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: blue,
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
    );
  }
}
