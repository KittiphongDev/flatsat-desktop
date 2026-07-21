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
  final Color header; // top app-bar background (black, NBSPACE style)
  final Color onHeader; // text/icons on the header

  // ---- Text ----
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // ---- Brand + status accents ----
  final Color accent; // primary brand (NBSPACE red)
  final Color secondary; // secondary brand (violet)
  final Color info; // neutral informational blue
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
    required this.header,
    required this.onHeader,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.secondary,
    required this.info,
    required this.success,
    required this.warning,
    required this.error,
    required this.yellow,
    required this.pink,
  });

  // -------------------------------------------------------------------
  // Palette discipline
  //
  // Ground-station software should spend color on *meaning*, not decoration.
  // The palette is therefore only:
  //   neutrals  — structure, labels, and any value that is merely a number
  //   green     — nominal / powered / online
  //   red       — fault, alert, and the NBSPACE brand accent
  //
  // The old violet/blue/orange/yellow/pink accents were decorative, so they
  // now resolve to neutrals. The fields are kept (rather than deleted) so
  // existing call sites keep compiling and simply stop emitting stray hues.
  // -------------------------------------------------------------------

  /// Dark "mission control" palette.
  static const dark = AppColors(
    scaffold: Color(0xFF0B0D10),
    surface: Color(0xFF15181D),
    surfaceAlt: Color(0xFF090B0E),
    border: Color(0x1FFFFFFF), // white @ ~12%, hairline
    header: Color(0xFF000000),
    onHeader: Color(0xFFFFFFFF),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0x99FFFFFF), // white @ 60%
    textMuted: Color(0x66FFFFFF), // white @ 40%
    accent: Color(0xFFEE3B2B), // NBSPACE red
    success: Color(0xFF34C77B), // nominal — calmer than the old neon green
    error: Color(0xFFEE3B2B), // faults share the brand red
    warning: Color(0xFFEE3B2B), // no amber tier; weight conveys severity
    // ---- decorative accents, now neutral ----
    secondary: Color(0x99FFFFFF),
    info: Color(0x99FFFFFF),
    yellow: Color(0x99FFFFFF),
    pink: Color(0x99FFFFFF),
  );

  /// Light "documentation" palette: white content, black header, red accent.
  static const light = AppColors(
    scaffold: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFF15181D), // terminal stays dark for readability
    border: Color(0xFFDDE1E7),
    header: Color(0xFF0D0D0D),
    onHeader: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF14181F),
    textSecondary: Color(0xFF4B5563),
    textMuted: Color(0xFF98A2B3),
    accent: Color(0xFFD93A2B), // NBSPACE red
    success: Color(0xFF0E8A4F),
    error: Color(0xFFD93A2B),
    warning: Color(0xFFD93A2B),
    // ---- decorative accents, now neutral ----
    secondary: Color(0xFF4B5563),
    info: Color(0xFF4B5563),
    yellow: Color(0xFF4B5563),
    pink: Color(0xFF4B5563),
  );

  @override
  AppColors copyWith({
    Color? scaffold,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? header,
    Color? onHeader,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? secondary,
    Color? info,
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
      header: header ?? this.header,
      onHeader: onHeader ?? this.onHeader,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      secondary: secondary ?? this.secondary,
      info: info ?? this.info,
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
      header: Color.lerp(header, other.header, t)!,
      onHeader: Color.lerp(onHeader, other.onHeader, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      info: Color.lerp(info, other.info, t)!,
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

/// Categorical colors for **chart series only**.
///
/// Kept deliberately separate from [AppColors]. The UI chrome stays
/// red/green/neutral so color always means state, but a multi-channel chart
/// genuinely needs series you can tell apart — that's data encoding, not
/// decoration. Do not reuse these for buttons, badges or status text.
///
/// Tuned to be readable side by side without going neon.
List<Color> chartSeriesColors(Brightness brightness) {
  return brightness == Brightness.dark
      ? const [
          Color(0xFFEE3B2B), // red
          Color(0xFF34C77B), // green
          Color(0xFF4A9EFF), // blue
          Color(0xFFE8A33D), // amber
          Color(0xFF9B7BFF), // violet
          Color(0xFF3FC1C9), // cyan
        ]
      : const [
          Color(0xFFD93A2B),
          Color(0xFF0E8A4F),
          Color(0xFF2D7FF9),
          Color(0xFFB9761A),
          Color(0xFF6D4AFF),
          Color(0xFF0E8C95),
        ];
}

/// Corner-radius tokens. Kept modest on purpose — heavily rounded panels read
/// as consumer-app styling, which is what made the dashboard feel generated
/// rather than operational.
const double kRadiusCard = 10;
const double kRadiusControl = 7;

/// Monospaced style for numeric readouts.
///
/// Telemetry digits change constantly; a proportional font makes the whole
/// value jitter sideways on every update. Tabular monospace keeps columns
/// steady and is the convention in real instrumentation.
TextStyle monoStyle({
  required Color color,
  double fontSize = 13,
  FontWeight fontWeight = FontWeight.w600,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.robotoMono(
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    height: height,
  );
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
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusCard)),
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
