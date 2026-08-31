import 'package:flutter/material.dart';

/// Centralized Design Tokens for the 2026 Dark Call Intelligence UI.
abstract final class AppTokens {
  // ── Background & Surfaces ──
  static const Color bgPrimary = Color(0xFF070B14);
  static const Color bgSecondary = Color(0xFF0B1020);
  static const Color surface1 = Color(0xFF101827);
  static const Color surface2 = Color(0xFF131C2C);
  static const Color surface3 = Color(0xFF182235);
  static const Color surfaceElevated = Color(0xFF1E293B);

  // ── Borders & Outlines ──
  static const Color borderSubtle = Color(0xFF1E293B);
  static const Color borderDefault = Color(0xFF26354A);
  static const Color borderHighlight = Color(0xFF3B82F6);
  static const Color glassBorder = Color(0x1AFFFFFF);

  // ── Text & Content ──
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);
  static const Color textDisabled = Color(0xFF475569);

  // ── Brand & Accent Palette ──
  static const Color brandElectric = Color(0xFF4F6BFF);
  static const Color brandIndigo = Color(0xFF6366F1);
  static const Color brandCyan = Color(0xFF06B6D4);
  static const Color brandPurple = Color(0xFF8B5CF6);

  // ── Semantic Status Colors ──
  static const Color success = Color(0xFF22C55E);
  static const Color successGlow = Color(0x3322C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningGlow = Color(0x33F59E0B);
  static const Color danger = Color(0xFFEF4444);
  static const Color dangerGlow = Color(0x33EF4444);
  static const Color info = Color(0xFF38BDF8);
  static const Color infoGlow = Color(0x3338BDF8);

  // ── Call Directions ──
  static const Color callIncoming = Color(0xFF22C55E);
  static const Color callOutgoing = Color(0xFF6366F1);
  static const Color callMissed = Color(0xFFEF4444);
  static const Color callRejected = Color(0xFFF97316);
  static const Color callNeverAttended = Color(0xFF38BDF8);

  // ── Gradients ──
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4F6BFF), Color(0xFF6366F1)],
  );

  static const LinearGradient surfaceGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF131C2C), Color(0xFF0E1524)],
  );

  static const LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
  );

  static const LinearGradient cardGlowGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x1A4F6BFF), Color(0x056366F1)],
  );

  static const LinearGradient chartAreaGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x404F6BFF), Color(0x004F6BFF)],
  );

  // ── Spacing ──
  static const double s4 = 4.0;
  static const double s8 = 8.0;
  static const double s12 = 12.0;
  static const double s16 = 16.0;
  static const double s20 = 20.0;
  static const double s24 = 24.0;
  static const double s32 = 32.0;

  // ── Radii ──
  static const double r6 = 6.0;
  static const double r8 = 8.0;
  static const double r12 = 12.0;
  static const double r16 = 16.0;
  static const double r20 = 20.0;
  static const double r24 = 24.0;
  static const double rFull = 999.0;

  // ── Shadows ──
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get glowShadow => [
        BoxShadow(
          color: brandElectric.withValues(alpha: 0.25),
          blurRadius: 20,
          offset: const Offset(0, 6),
        ),
      ];
}
