import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The Mynt design system, as already shipping in zebu_helpdesk.
///
/// Values are lifted from that app rather than re-invented so the two feel like
/// one product: Inter, brand blue #0037B7, flat surfaces with hairline outlines,
/// 12px cards / 8px controls / 50px buttons.
abstract final class AppColors {
  static const brand = Color(0xFF0037B7);
  static const brandDark = Color(0xFF002E9B);
  static const brandLight = Color(0xFF4A6CF7);

  /// Semantic. Green reads as "answered / synced", red as "missed / failed",
  /// amber as "waiting / needs review" — never decorative.
  static const answered = Color(0xFF00B14F);
  static const missed = Color(0xFFFF1717);
  static const missedDark = Color(0xFFFF6B6B);
  static const waiting = Color(0xFFFFB038);

  static const bgLight = Color(0xFFF8F9FA);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const textLight = Color(0xFF141414);
  static const mutedLight = Color(0xFF737373);
  static const outlineLight = Color(0xFFDDE2E7);
  static const containerLight = Color(0xFFE3EDFA);
  static const fieldLight = Color(0xFFF9F9F9);
  static const tabLight = Color(0xFFF1F3F8);

  static const bgDark = Color(0xFF181818);
  static const surfaceDark = Color(0xFF1A1A1A);
  static const mutedDark = Color(0xFF8A8A8A);
  static const outlineDark = Color(0xFF333333);
  static const containerDark = Color(0xFF1D242F);
  static const fieldDark = Color(0xFF1E1E1E);
  static const tabDark = Color(0xFF24242B);
}

/// Semantic colours that vary by brightness, reached from widgets via
/// `Theme.of(context).extension<AppPalette>()!`.
///
/// These live in an extension rather than as constants because "missed" is a
/// different red in dark mode — using the light red on #181818 fails contrast.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.answered,
    required this.missed,
    required this.waiting,
    required this.muted,
    required this.field,
    required this.tab,
    required this.tint,
  });

  final Color answered;
  final Color missed;
  final Color waiting;
  final Color muted;
  final Color field;
  final Color tab;

  /// Low-contrast wash for icon chips and progress tracks.
  final Color tint;

  static const _light = AppPalette(
    answered: AppColors.answered,
    missed: AppColors.missed,
    waiting: AppColors.waiting,
    muted: AppColors.mutedLight,
    field: AppColors.fieldLight,
    tab: AppColors.tabLight,
    tint: Color(0x0A141414),
  );

  static const _dark = AppPalette(
    answered: AppColors.answered,
    missed: AppColors.missedDark,
    waiting: AppColors.waiting,
    muted: AppColors.mutedDark,
    field: AppColors.fieldDark,
    tab: AppColors.tabDark,
    tint: Color(0x0DFFFFFF),
  );

  @override
  AppPalette copyWith({
    Color? answered,
    Color? missed,
    Color? waiting,
    Color? muted,
    Color? field,
    Color? tab,
    Color? tint,
  }) => AppPalette(
    answered: answered ?? this.answered,
    missed: missed ?? this.missed,
    waiting: waiting ?? this.waiting,
    muted: muted ?? this.muted,
    field: field ?? this.field,
    tab: tab ?? this.tab,
    tint: tint ?? this.tint,
  );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      answered: Color.lerp(answered, other.answered, t)!,
      missed: Color.lerp(missed, other.missed, t)!,
      waiting: Color.lerp(waiting, other.waiting, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      field: Color.lerp(field, other.field, t)!,
      tab: Color.lerp(tab, other.tab, t)!,
      tint: Color.lerp(tint, other.tint, t)!,
    );
  }
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final palette = isLight ? AppPalette._light : AppPalette._dark;

    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.brand,
          brightness: brightness,
        ).copyWith(
          primary: isLight ? AppColors.brand : AppColors.brandLight,
          onPrimary: Colors.white,
          primaryContainer: isLight
              ? AppColors.containerLight
              : AppColors.containerDark,
          onPrimaryContainer: isLight
              ? AppColors.brandDark
              : AppColors.containerLight,
          surface: isLight ? AppColors.surfaceLight : AppColors.surfaceDark,
          onSurface: isLight ? AppColors.textLight : Colors.white,
          onSurfaceVariant: palette.muted,
          outlineVariant: isLight
              ? AppColors.outlineLight
              : AppColors.outlineDark,
          error: palette.missed,
        );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: isLight ? AppColors.bgLight : AppColors.bgDark,
    );

    return base.copyWith(
      extensions: [palette],
      textTheme: GoogleFonts.interTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        color: scheme.surface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          minimumSize: const Size.fromHeight(50),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 64,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(
          GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}
