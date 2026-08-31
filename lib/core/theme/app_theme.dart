import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design_tokens.dart';

/// Semantic colors and palette definitions for the application.
abstract final class AppColors {
  static const brand = AppTokens.brandElectric;
  static const brandDark = AppTokens.brandIndigo;
  static const brandLight = Color(0xFF6B8AFF);

  // Semantic call and sync status colors
  static const answered = AppTokens.success;
  static const missed = AppTokens.danger;
  static const missedDark = AppTokens.danger;
  static const waiting = AppTokens.warning;
  static const info = AppTokens.info;
  static const purple = AppTokens.brandPurple;

  // Dark Theme Palette (Primary Default)
  static const bgDark = AppTokens.bgPrimary;
  static const bgSecondaryDark = AppTokens.bgSecondary;
  static const surfaceDark = AppTokens.surface1;
  static const surfaceElevatedDark = AppTokens.surface2;
  static const surfaceLayerDark = AppTokens.surface3;
  static const mutedDark = AppTokens.textSecondary;
  static const outlineDark = AppTokens.borderDefault;
  static const containerDark = AppTokens.surface2;
  static const fieldDark = AppTokens.surface2;
  static const tabDark = Color(0xFF131C2E);

  // Light Theme Palette (Fallback)
  static const bgLight = Color(0xFFF8FAFC);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const textLight = Color(0xFF0F172A);
  static const mutedLight = Color(0xFF64748B);
  static const outlineLight = Color(0xFFE2E8F0);
  static const containerLight = Color(0xFFEEF2F6);
  static const fieldLight = Color(0xFFF1F5F9);
  static const tabLight = Color(0xFFF1F5F9);
}

/// Semantic colors that vary by brightness, accessible via
/// `Theme.of(context).extension<AppPalette>()!`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.answered,
    required this.missed,
    required this.waiting,
    required this.info,
    required this.purple,
    required this.muted,
    required this.field,
    required this.tab,
    required this.tint,
    required this.surfaceLayer,
    required this.surfaceElevated,
    required this.borderSubtle,
  });

  final Color answered;
  final Color missed;
  final Color waiting;
  final Color info;
  final Color purple;
  final Color muted;
  final Color field;
  final Color tab;
  final Color tint;
  final Color surfaceLayer;
  final Color surfaceElevated;
  final Color borderSubtle;

  static const dark = AppPalette(
    answered: AppTokens.success,
    missed: AppTokens.danger,
    waiting: AppTokens.warning,
    info: AppTokens.info,
    purple: AppTokens.brandPurple,
    muted: AppTokens.textSecondary,
    field: AppTokens.surface2,
    tab: Color(0xFF131C2E),
    tint: Color(0x14FFFFFF),
    surfaceLayer: AppTokens.surface3,
    surfaceElevated: AppTokens.surfaceElevated,
    borderSubtle: AppTokens.borderSubtle,
  );

  static const light = AppPalette(
    answered: AppTokens.success,
    missed: AppTokens.danger,
    waiting: AppTokens.warning,
    info: AppTokens.info,
    purple: AppTokens.brandPurple,
    muted: AppColors.mutedLight,
    field: AppColors.fieldLight,
    tab: AppColors.tabLight,
    tint: Color(0x0A0F172A),
    surfaceLayer: Color(0xFFF1F5F9),
    surfaceElevated: Colors.white,
    borderSubtle: Color(0xFFE2E8F0),
  );

  @override
  AppPalette copyWith({
    Color? answered,
    Color? missed,
    Color? waiting,
    Color? info,
    Color? purple,
    Color? muted,
    Color? field,
    Color? tab,
    Color? tint,
    Color? surfaceLayer,
    Color? surfaceElevated,
    Color? borderSubtle,
  }) =>
      AppPalette(
        answered: answered ?? this.answered,
        missed: missed ?? this.missed,
        waiting: waiting ?? this.waiting,
        info: info ?? this.info,
        purple: purple ?? this.purple,
        muted: muted ?? this.muted,
        field: field ?? this.field,
        tab: tab ?? this.tab,
        tint: tint ?? this.tint,
        surfaceLayer: surfaceLayer ?? this.surfaceLayer,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        borderSubtle: borderSubtle ?? this.borderSubtle,
      );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      answered: Color.lerp(answered, other.answered, t)!,
      missed: Color.lerp(missed, other.missed, t)!,
      waiting: Color.lerp(waiting, other.waiting, t)!,
      info: Color.lerp(info, other.info, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      field: Color.lerp(field, other.field, t)!,
      tab: Color.lerp(tab, other.tab, t)!,
      tint: Color.lerp(tint, other.tint, t)!,
      surfaceLayer: Color.lerp(surfaceLayer, other.surfaceLayer, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
    );
  }
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final palette = isLight ? AppPalette.light : AppPalette.dark;

    final scheme = ColorScheme.fromSeed(
      seedColor: AppTokens.brandElectric,
      brightness: brightness,
    ).copyWith(
      primary: AppTokens.brandElectric,
      onPrimary: Colors.white,
      primaryContainer: isLight ? AppColors.containerLight : AppTokens.surface2,
      onPrimaryContainer: isLight ? AppTokens.brandIndigo : Colors.white,
      surface: isLight ? AppColors.surfaceLight : AppTokens.surface1,
      onSurface: isLight ? AppColors.textLight : AppTokens.textPrimary,
      onSurfaceVariant: palette.muted,
      outlineVariant: isLight ? AppColors.outlineLight : AppTokens.borderDefault,
      outline: isLight ? const Color(0xFFCBD5E1) : AppTokens.borderSubtle,
      error: palette.missed,
    );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: isLight ? AppColors.bgLight : AppTokens.bgPrimary,
    );

    return base.copyWith(
      extensions: [palette],
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: isLight ? scheme.surface : AppTokens.bgPrimary,
        foregroundColor: scheme.onSurface,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r16),
          side: BorderSide(
            color: isLight ? scheme.outlineVariant : AppTokens.borderDefault,
            width: 1,
          ),
        ),
        color: isLight ? scheme.surface : AppTokens.surface1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.r12),
          borderSide: BorderSide(
            color: isLight ? scheme.outlineVariant : AppTokens.borderDefault,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.r12),
          borderSide: BorderSide(
            color: isLight ? scheme.outlineVariant : AppTokens.borderDefault,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.r12),
          borderSide: const BorderSide(color: AppTokens.brandElectric, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppTokens.brandElectric,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.r12),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isLight ? AppTokens.brandElectric : Colors.white,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(
            color: isLight ? scheme.outlineVariant : AppTokens.borderDefault,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.r12),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: isLight ? scheme.surface : AppTokens.surface1,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppTokens.brandElectric.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final isSelected = states.contains(WidgetState.selected);
          return GoogleFonts.inter(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isSelected ? AppTokens.brandElectric : palette.muted,
          );
        }),
      ),
      dividerTheme: DividerThemeData(
        color: isLight ? scheme.outlineVariant : AppTokens.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}
