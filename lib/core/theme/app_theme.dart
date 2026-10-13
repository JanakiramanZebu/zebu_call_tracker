import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Press feedback for Material buttons: a ripple and nothing else.
///
/// Material 3 draws a filled "state layer" behind a pressed button on top of
/// the ripple, which reads as a grey/blue blob over icons. Returning null for
/// the pressed state makes the ink fall back to the theme's [splashColor] for
/// the ripple and its transparent [highlightColor] for the overlay — so taps
/// splash without a tinted overlay. Focus keeps a faint layer so keyboard and
/// switch-access users still see where they are.
WidgetStateProperty<Color?> _rippleOnly(Color focus) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return null;
      if (states.contains(WidgetState.focused)) return focus;
      return Colors.transparent;
    });

/// The app's light and dark [ThemeData], both built from [ZColors].
///
/// Flat by design: solid fills, hairline rules, no gradients, no glows and no
/// elevation tint. The one strong colour is the Zebu brand blue, which screens
/// use for a single panel at most.
abstract final class AppTheme {
  /// Bundled in assets/fonts and declared in pubspec.yaml.
  static const fontFamily = AppType.family;

  static ThemeData light() => _build(ZColors.light);
  static ThemeData dark() => _build(ZColors.dark);

  static ThemeData _build(ZColors z) {
    final brightness = z.brightness;
    final focusLayer = z.accent.withValues(alpha: 0.14);

    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppTokens.zebuBlue,
          brightness: brightness,
        ).copyWith(
          primary: z.primary,
          onPrimary: z.onPrimary,
          primaryContainer: z.accentSoft,
          onPrimaryContainer: z.accent,
          secondary: z.accent,
          onSecondary: z.canvas,
          tertiary: z.accent,
          surface: z.raised,
          onSurface: z.ink,
          onSurfaceVariant: z.ink2,
          surfaceContainerLowest: z.canvas,
          surfaceContainerLow: z.raised,
          surfaceContainer: z.raised,
          surfaceContainerHigh: z.raised,
          surfaceContainerHighest: z.sunken,
          outlineVariant: z.line,
          outline: z.lineStrong,
          error: z.danger,
          onError: Colors.white,
          surfaceTint: Colors.transparent,
          shadow: z.shadow,
          scrim: z.overlay,
        );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: z.canvas,
      canvasColor: z.canvas,
      dividerColor: z.line,
      // Ripple-only touch feedback, app-wide. InkRipple is used over the M3
      // default InkSparkle because it reads clearly on dark surfaces and costs
      // no shader warm-up on low-end phones.
      splashFactory: InkRipple.splashFactory,
      splashColor: z.ink.withValues(alpha: z.isDark ? 0.10 : 0.08),
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: focusLayer,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );

    final text = base.textTheme
        .apply(
          fontFamily: fontFamily,
          bodyColor: z.ink,
          displayColor: z.ink,
        )
        .copyWith(
          headlineMedium: AppType.title.copyWith(color: z.ink),
          headlineSmall: AppType.statement.copyWith(color: z.ink),
          titleLarge: AppType.barTitle.copyWith(color: z.ink),
          titleMedium: AppType.heading.copyWith(color: z.ink),
          titleSmall: AppType.bodyStrong.copyWith(color: z.ink),
          bodyLarge: AppType.body.copyWith(color: z.ink),
          bodyMedium: AppType.small.copyWith(color: z.ink),
          bodySmall: AppType.label.copyWith(color: z.ink3),
          labelLarge: AppType.smallStrong.copyWith(color: z.ink),
          labelMedium: AppType.labelStrong.copyWith(color: z.ink2),
          labelSmall: AppType.micro.copyWith(color: z.ink3),
        );

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.r12),
    );

    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppTokens.r10),
      borderSide: BorderSide(color: z.line),
    );

    return base.copyWith(
      extensions: [z],
      textTheme: text,
      primaryTextTheme: text,
      iconTheme: IconThemeData(color: z.ink, size: 22),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: z.canvas,
        surfaceTintColor: Colors.transparent,
        foregroundColor: z.ink,
        iconTheme: IconThemeData(color: z.ink, size: 22),
        actionsIconTheme: IconThemeData(color: z.ink2, size: 22),
        titleSpacing: 4,
        titleTextStyle: AppType.barTitle.copyWith(color: z.ink),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          overlayColor: _rippleOnly(focusLayer),
          splashFactory: InkRipple.splashFactory,
          minimumSize: const WidgetStatePropertyAll(
            Size(AppTokens.minTap, AppTokens.minTap),
          ),
          shape: const WidgetStatePropertyAll(CircleBorder()),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r12),
          side: BorderSide(color: z.line),
        ),
        color: z.raised,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: z.sunken,
        hintStyle: AppType.body.copyWith(color: z.ink3),
        labelStyle: AppType.body.copyWith(color: z.ink2),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => AppType.labelStrong.copyWith(
            color: states.contains(WidgetState.error)
                ? z.danger
                : states.contains(WidgetState.focused)
                ? z.accent
                : z.ink2,
          ),
        ),
        prefixIconColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.error)
              ? z.danger
              : states.contains(WidgetState.focused)
              ? z.accent
              : z.ink3,
        ),
        suffixIconColor: z.ink3,
        errorStyle: AppType.captionStrong.copyWith(color: z.danger),
        errorMaxLines: 2,
        helperStyle: AppType.caption.copyWith(color: z.ink3),
        helperMaxLines: 2,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        disabledBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: z.line.withValues(alpha: 0.5)),
        ),
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: z.accent, width: 1.6),
        ),
        errorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: z.danger),
        ),
        focusedErrorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: z.danger, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: z.primary,
          foregroundColor: z.onPrimary,
          disabledBackgroundColor: z.secondary,
          disabledForegroundColor: z.ink3,
          minimumSize: const Size.fromHeight(48),
          elevation: 0,
          shape: buttonShape,
          textStyle: AppType.bodyStrong,
        ).copyWith(overlayColor: _rippleOnly(focusLayer)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: z.secondary,
          foregroundColor: z.onSecondary,
          elevation: 0,
          minimumSize: const Size.fromHeight(48),
          shape: buttonShape,
          textStyle: AppType.bodyStrong,
        ).copyWith(overlayColor: _rippleOnly(focusLayer)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: z.ink,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: z.lineStrong),
          shape: buttonShape,
          textStyle: AppType.bodyStrong,
        ).copyWith(overlayColor: _rippleOnly(focusLayer)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: z.accent,
          minimumSize: const Size(AppTokens.minTap, AppTokens.minTap),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: buttonShape,
          textStyle: AppType.smallStrong,
        ).copyWith(overlayColor: _rippleOnly(focusLayer)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: z.raised,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: z.raised,
        modalBarrierColor: z.overlay,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: z.lineStrong,
        dragHandleSize: const Size(36, 4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.r20),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: z.raised,
        surfaceTintColor: Colors.transparent,
        barrierColor: z.overlay,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r18),
        ),
        titleTextStyle: AppType.statement.copyWith(fontSize: 19, color: z.ink),
        contentTextStyle: AppType.small.copyWith(color: z.ink2),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: z.toastBg,
        contentTextStyle: AppType.smallStrong.copyWith(
          color: z.toastInk,
          fontWeight: FontWeight.w500,
        ),
        actionTextColor: z.isDark ? AppTokens.zebuBlue : const Color(0xFF9DBBFF),
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r10),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: z.raised,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: z.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r12),
          side: BorderSide(color: z.line),
        ),
        textStyle: AppType.body.copyWith(color: z.ink),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: z.raised,
        selectedColor: z.accentSoft,
        side: BorderSide(color: z.line),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r8),
        ),
        labelStyle: AppType.labelStrong.copyWith(color: z.ink),
        checkmarkColor: z.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? z.primary : z.switchOff,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: _rippleOnly(focusLayer),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? z.accent : z.ink3,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? z.primary : null,
        ),
        side: BorderSide(color: z.lineStrong, width: 1.5),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: z.accent,
        linearTrackColor: z.line,
        circularTrackColor: Colors.transparent,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: z.accent,
        inactiveTrackColor: z.lineStrong,
        thumbColor: z.accent,
        overlayColor: z.accent.withValues(alpha: 0.14),
        trackHeight: 3,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: z.toastBg,
          borderRadius: BorderRadius.circular(AppTokens.r8),
        ),
        textStyle: AppType.captionStrong.copyWith(color: z.toastInk),
      ),
      dividerTheme: DividerThemeData(color: z.line, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.gutter,
        ),
        iconColor: z.ink2,
        titleTextStyle: AppType.bodyMedium.copyWith(color: z.ink),
        subtitleTextStyle: AppType.label.copyWith(
          color: z.ink3,
          fontWeight: FontWeight.w400,
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: z.accent,
        selectionColor: z.accent.withValues(alpha: 0.30),
        selectionHandleColor: z.accent,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
