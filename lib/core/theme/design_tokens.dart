import 'package:flutter/material.dart';

/// Brightness-independent design tokens: the brand, spacing, radii, motion and
/// type scale.
///
/// Colours that change between the light and dark themes are NOT here. They
/// live on [ZColors], read with `context.z`, so a widget can never hard-code a
/// dark-theme colour into the light theme. The two exceptions are the Zebu
/// brand blue and the white that sits on it, which are the same in both.
abstract final class AppTokens {
  // ── Brand ──
  /// The Zebu logo blue. Brand panels, the post-call card strip, the app mark.
  static const Color zebuBlue = Color(0xFF0037B7);

  /// Text and icons on [zebuBlue].
  static const Color onBrand = Color(0xFFFFFFFF);

  /// Secondary text on [zebuBlue]. 6:1 against it.
  static const Color onBrandMuted = Color(0xD1FFFFFF);

  /// Hairlines and axis rules drawn on [zebuBlue].
  static const Color onBrandLine = Color(0x40FFFFFF);

  /// Missed-call marks on [zebuBlue]: lighter than the brand, darker than
  /// white, so it differs from answered marks in lightness and not hue alone.
  static const Color onBrandMissed = Color(0xFFFF9AA5);

  /// Fill for a destructive confirm button. 4.6:1 with white text.
  static const Color destructiveFill = Color(0xFFC4314B);

  // ── Spacing (4px base) ──
  static const double s2 = 2.0;
  static const double s4 = 4.0;
  static const double s6 = 6.0;
  static const double s8 = 8.0;
  static const double s10 = 10.0;
  static const double s12 = 12.0;
  static const double s14 = 14.0;
  static const double s16 = 16.0;
  static const double s20 = 20.0;
  static const double s24 = 24.0;
  static const double s28 = 28.0;
  static const double s32 = 32.0;

  /// Horizontal page gutter used by every screen. Rows run edge to edge and
  /// indent their content by this much.
  static const double gutter = 20.0;

  // ── Radii ── tighter on small controls, softer on containers.
  static const double r4 = 4.0;
  static const double r8 = 8.0;
  static const double r10 = 10.0;
  static const double r12 = 12.0;
  static const double r14 = 14.0;
  static const double r16 = 16.0;
  static const double r18 = 18.0;
  static const double r20 = 20.0;

  // ── Motion ──
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 320);

  /// Decelerating ease used by every transition in the app.
  static const Curve ease = Cubic(0.2, 0.8, 0.2, 1);

  // ── Touch ──
  /// Minimum tap target on every control.
  static const double minTap = 44.0;
}

/// The type scale. IBM Plex Sans throughout, one family.
///
/// Styles carry no colour so they inherit the ambient text colour ([ZColors.ink]
/// via the theme); add one with `copyWith(color: ...)` for secondary text.
/// Anything that shows a count, a time or a duration uses a `tabular` style so
/// digits line up down a column.
abstract final class AppType {
  static const String family = 'IBM Plex Sans';

  static const List<FontFeature> _tnum = [FontFeature.tabularFigures()];

  /// The day's call count on Home.
  static const TextStyle display = TextStyle(
    fontFamily: family,
    fontSize: 64,
    fontWeight: FontWeight.w600,
    letterSpacing: -2.2,
    height: 0.95,
    fontFeatures: _tnum,
  );

  /// Tab titles: "Calls", "Sync".
  static const TextStyle title = TextStyle(
    fontFamily: family,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.2,
  );

  /// A person's name at the top of Call details.
  static const TextStyle titleLarge = TextStyle(
    fontFamily: family,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.55,
    height: 1.15,
  );

  /// A status statement: "All calls delivered".
  static const TextStyle statement = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
  );

  /// Section headings: "Outcome", "Latest calls".
  static const TextStyle heading = TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.17,
    height: 1.3,
  );

  /// App-bar titles on pushed screens.
  static const TextStyle barTitle = TextStyle(
    fontFamily: family,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static const TextStyle body = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  /// Supporting copy: subtitles, explanations.
  static const TextStyle small = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  static const TextStyle smallStrong = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  /// Row metadata, group headings, keys in a fact sheet.
  static const TextStyle label = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  static const TextStyle labelStrong = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  static const TextStyle captionStrong = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  static const TextStyle micro = TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// A style with tabular figures, for counts, times and durations.
  static TextStyle tabular(TextStyle s) => s.copyWith(fontFeatures: _tnum);
}

/// Colours that change between the light and dark themes.
///
/// Read with `context.z` (see ui_kit.dart). Every text/background pairing used
/// in the app clears WCAG AA (4.5:1); [ink3] is the floor and was tuned to it
/// on [canvas], [raised] and [sunken].
@immutable
class ZColors extends ThemeExtension<ZColors> {
  const ZColors({
    required this.brightness,
    required this.canvas,
    required this.raised,
    required this.sunken,
    required this.line,
    required this.lineStrong,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentSoft,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.navBg,
    required this.overlay,
    required this.incoming,
    required this.outgoing,
    required this.missed,
    required this.rejected,
    required this.noAnswer,
    required this.ok,
    required this.okSoft,
    required this.warn,
    required this.warnSoft,
    required this.danger,
    required this.dangerSoft,
    required this.whatsapp,
    required this.whatsappSoft,
    required this.toastBg,
    required this.toastInk,
    required this.rowActive,
    required this.segmentActive,
    required this.switchOff,
    required this.callGreen,
    required this.shadow,
  });

  final Brightness brightness;

  // ── Surfaces ──
  /// The page background.
  final Color canvas;

  /// Bands and grouped lists that sit on [canvas]: status rows, settings
  /// groups, the fact sheet, sheets and dialogs.
  final Color raised;

  /// Inset areas: the search field, sticky day headers, keypad keys,
  /// segmented-control tracks.
  final Color sunken;

  /// Hairline row dividers.
  final Color line;

  /// Stronger rules: outlined buttons, the pipeline track, unplayed waveform.
  final Color lineStrong;

  // ── Text ──
  final Color ink;
  final Color ink2;

  /// Muted text. The contrast floor.
  final Color ink3;

  // ── Interaction ──
  /// Links, selected tabs, focus, progress. Readable as text on [canvas].
  final Color accent;
  final Color accentSoft;

  /// Fill for the primary button.
  final Color primary;
  final Color onPrimary;

  /// Fill for secondary buttons.
  final Color secondary;
  final Color onSecondary;

  final Color navBg;

  /// Scrim behind dialogs, sheets and the post-call card.
  final Color overlay;

  // ── Call outcomes ── each pairs with a distinct glyph, never colour alone.
  final Color incoming;
  final Color outgoing;
  final Color missed;
  final Color rejected;

  /// An outgoing call nobody picked up.
  final Color noAnswer;

  // ── Status ──
  final Color ok;
  final Color okSoft;
  final Color warn;
  final Color warnSoft;
  final Color danger;
  final Color dangerSoft;
  final Color whatsapp;
  final Color whatsappSoft;

  /// Snackbars are inverse: light on dark, dark on light.
  final Color toastBg;
  final Color toastInk;

  /// Background of an expanded call row.
  final Color rowActive;

  /// The selected segment of a segmented control.
  final Color segmentActive;
  final Color switchOff;

  /// Fill of the dial pad's call button.
  final Color callGreen;

  /// Colour of the shadow under floating surfaces (dialogs, the dial button).
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  static const dark = ZColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF0B1018),
    raised: Color(0xFF121925),
    sunken: Color(0xFF080C13),
    line: Color(0xFF1D2635),
    lineStrong: Color(0xFF2B3648),
    ink: Color(0xFFE8EDF5),
    ink2: Color(0xFFAEB8CA),
    ink3: Color(0xFF808CA2),
    accent: Color(0xFF7FA6FF),
    accentSoft: Color(0x297FA6FF),
    primary: Color(0xFF2F5FE0),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF1A2333),
    onSecondary: Color(0xFFE8EDF5),
    navBg: Color(0xFF0D131D),
    overlay: Color(0xAD04070C),
    incoming: Color(0xFF4CC795),
    outgoing: Color(0xFF7FA6FF),
    missed: Color(0xFFEE6C78),
    rejected: Color(0xFFE0995F),
    noAnswer: Color(0xFFD4AE5A),
    ok: Color(0xFF4CC795),
    okSoft: Color(0x244CC795),
    warn: Color(0xFFE3B354),
    warnSoft: Color(0x1FE3B354),
    danger: Color(0xFFEE6C78),
    dangerSoft: Color(0x1FEE6C78),
    whatsapp: Color(0xFF5BD68F),
    whatsappSoft: Color(0x215BD68F),
    toastBg: Color(0xFFE8EDF5),
    toastInk: Color(0xFF0B1018),
    rowActive: Color(0x127FA6FF),
    segmentActive: Color(0xFF222D42),
    switchOff: Color(0xFF2B3648),
    callGreen: Color(0xFF1E9E68),
    shadow: Color(0x8C000000),
  );

  static const light = ZColors(
    brightness: Brightness.light,
    canvas: Color(0xFFF4F5F7),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFECEEF2),
    line: Color(0xFFE2E5EA),
    lineStrong: Color(0xFFCDD3DC),
    ink: Color(0xFF0F1726),
    ink2: Color(0xFF3D4859),
    ink3: Color(0xFF5C6779),
    accent: Color(0xFF0037B7),
    accentSoft: Color(0x170037B7),
    primary: Color(0xFF0037B7),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFFE9ECF1),
    onSecondary: Color(0xFF0F1726),
    navBg: Color(0xFFFFFFFF),
    overlay: Color(0x750F1726),
    incoming: Color(0xFF0E7A51),
    outgoing: Color(0xFF0037B7),
    missed: Color(0xFFBF3440),
    rejected: Color(0xFFA3561A),
    noAnswer: Color(0xFF866300),
    ok: Color(0xFF0E7A51),
    okSoft: Color(0x1A0E7A51),
    warn: Color(0xFF866300),
    warnSoft: Color(0x24D6A028),
    danger: Color(0xFFBF3440),
    dangerSoft: Color(0x14BF3440),
    whatsapp: Color(0xFF0B7A3E),
    whatsappSoft: Color(0x1A0B7A3E),
    toastBg: Color(0xFF0F1726),
    toastInk: Color(0xFFFFFFFF),
    rowActive: Color(0x0D0037B7),
    segmentActive: Color(0xFFFFFFFF),
    switchOff: Color(0xFFCDD3DC),
    callGreen: Color(0xFF13895A),
    shadow: Color(0x470F1726),
  );

  @override
  ZColors copyWith() => this;

  @override
  ZColors lerp(covariant ZColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ZColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: l(canvas, other.canvas),
      raised: l(raised, other.raised),
      sunken: l(sunken, other.sunken),
      line: l(line, other.line),
      lineStrong: l(lineStrong, other.lineStrong),
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      secondary: l(secondary, other.secondary),
      onSecondary: l(onSecondary, other.onSecondary),
      navBg: l(navBg, other.navBg),
      overlay: l(overlay, other.overlay),
      incoming: l(incoming, other.incoming),
      outgoing: l(outgoing, other.outgoing),
      missed: l(missed, other.missed),
      rejected: l(rejected, other.rejected),
      noAnswer: l(noAnswer, other.noAnswer),
      ok: l(ok, other.ok),
      okSoft: l(okSoft, other.okSoft),
      warn: l(warn, other.warn),
      warnSoft: l(warnSoft, other.warnSoft),
      danger: l(danger, other.danger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      whatsapp: l(whatsapp, other.whatsapp),
      whatsappSoft: l(whatsappSoft, other.whatsappSoft),
      toastBg: l(toastBg, other.toastBg),
      toastInk: l(toastInk, other.toastInk),
      rowActive: l(rowActive, other.rowActive),
      segmentActive: l(segmentActive, other.segmentActive),
      switchOff: l(switchOff, other.switchOff),
      callGreen: l(callGreen, other.callGreen),
      shadow: l(shadow, other.shadow),
    );
  }
}
