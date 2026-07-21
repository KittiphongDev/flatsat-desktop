import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Semantic color tokens for the FlatSat dashboard, exposed as a
/// [ThemeExtension] so every widget can adapt to the active brightness.
///
/// Brand/status colors are tuned to read well on BOTH the light
/// (documentation-style) surface and the dark mission-control surface.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  // ---- Structural surfaces ----
  final Color scaffold;
  final Color surface; // cards
  final Color surfaceAlt; // terminal / log panel
  final Color border;

  // ---- Text ----
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // ---- Brand + status accents ----
  final Color accent; // primary brand
  final Color secondary; // secondary brand (violet)
  final Color success;
  final Color warning;
  final Color error;
  final Color yellow;
  final Color pink;

  const AppColors({
    required this.scaffold,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.secondary,
    required this.success,
    required this.warning,
    required this.error,
    required this.yellow,
    required this.pink,
  });

  /// Dark "mission control" palette (original look, refined).
  static const dark = AppColors(
    scaffold: Color(0xFF0A0E1A),
    surface: Color(0xFF111827),
    surfaceAlt: Color(0xFF080C15),
    border: Color(0x14FFFFFF), // white @ ~8%
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0x99FFFFFF), // white @ 60%
    textMuted: Color(0x66FFFFFF), // white @ 40%
    accent: Color(0xFF00D4FF),
    secondary: Color(0xFF7B61FF),
    success: Color(0xFF00E676),
    warning: Color(0xFFFFAB40),
    error: Color(0xFFFF4D6A),
    yellow: Color(0xFFFFD166),
    pink: Color(0xFFFF6EC7),
  );

  /// Light "documentation" palette, matching the clean Material-for-MkDocs
  /// aesthetic of the FlatSat docs site.
  static const light = AppColors(
    scaffold: Color(0xFFF5F7FA),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFF0F1729), // terminal stays dark for readability
    border: Color(0xFFE2E8F0),
    textPrimary: Color(0xFF15202B),
    textSecondary: Color(0xFF475569),
    textMuted: Color(0xFF94A3B8),
    accent: Color(0xFF0091C7),
    secondary: Color(0xFF6D4AFF),
    success: Color(0xFF10A56A),
    warning: Color(0xFFE08600),
    error: Color(0xFFE11D48),
    yellow: Color(0xFFC98A00),
    pink: Color(0xFFDB2A8B),
  );

  @override
  AppColors copyWith({
    Color? scaffold,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? secondary,
    Color? success,
    Color? warning,
    Color? error,
    Color? yellow,
    Color? pink,
  }) {
    return AppColors(
      scaffold: scaffold ?? this.scaffold,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      secondary: secondary ?? this.secondary,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      yellow: yellow ?? this.yellow,
      pink: pink ?? this.pink,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      scaffold: Color.lerp(scaffold, other.scaffold, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      yellow: Color.lerp(yellow, other.yellow, t)!,
      pink: Color.lerp(pink, other.pink, t)!,
    );
  }
}

/// Convenience accessor: `context.colors.accent`, etc.
extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

/// Builds the [ThemeData] for a given [AppColors] palette + brightness.
ThemeData _buildTheme(AppColors c, Brightness brightness) {
  final baseTextTheme = brightness == Brightness.dark
      ? ThemeData.dark().textTheme
      : ThemeData.light().textTheme;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: c.scaffold,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
    ).copyWith(
      primary: c.accent,
      secondary: c.secondary,
      surface: c.surface,
      onSurface: c.textPrimary,
      error: c.error,
    ),
    // Roboto to match the Material-for-MkDocs documentation typography.
    textTheme: GoogleFonts.robotoTextTheme(baseTextTheme).apply(
      bodyColor: c.textPrimary,
      displayColor: c.textPrimary,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
    ),
    dividerColor: c.border,
    extensions: <ThemeExtension<dynamic>>[c],
  );
}

class AppTheme {
  static ThemeData get light => _buildTheme(AppColors.light, Brightness.light);
  static ThemeData get dark => _buildTheme(AppColors.dark, Brightness.dark);
}

/// Holds and toggles the active [ThemeMode]. Defaults to light to match the
/// documentation site; users can flip to the dark mission-control theme.
class ThemeProvider extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.light;

  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  void toggle() {
    _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
  }

  void setDark(bool dark) {
    _mode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }
}
