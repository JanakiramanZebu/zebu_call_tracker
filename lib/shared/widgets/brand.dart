import 'package:flutter/material.dart';

import 'ui_kit.dart';

/// The official Call Tracker app icon glyph drawn natively in Flutter.
///
/// Transcribed directly from `res/drawable/ic_launcher_foreground.xml` so the app icon
/// in Android launcher, the splash screen, and the in-app headers remain 100% identical.
class ZebuMark extends StatelessWidget {
  const ZebuMark({super.key, this.size = 40, this.color});

  /// Size of the glyph in logical pixels. Aspect ratio is 1.0 (square).
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _ZebuMarkPainter(color ?? context.colors.primary),
      );
}

class _ZebuMarkPainter extends CustomPainter {
  const _ZebuMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Target size scale factor from design viewBox (36x36)
    final scale = size.height / 36.0;

    canvas.save();
    canvas.scale(scale, scale);
    canvas.translate(-7.8, -9.5);

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // 1. Phone Receiver path from ic_launcher_foreground.xml
    final phonePath = Path()
      ..moveTo(13.25, 24.19)
      ..cubicTo(15.65, 28.9, 19.5, 32.74, 24.21, 35.15)
      ..lineTo(27.88, 31.48)
      ..cubicTo(28.34, 31.02, 29.01, 30.87, 29.62, 31.08)
      ..cubicTo(31.57, 31.72, 33.68, 32.07, 35.83, 32.07)
      ..cubicTo(36.83, 32.07, 37.66, 32.9, 37.66, 33.9)
      ..lineTo(37.66, 39.69)
      ..cubicTo(37.66, 40.69, 36.83, 41.52, 35.83, 41.52)
      ..cubicTo(20.55, 41.52, 8.18, 29.15, 8.18, 13.87)
      ..cubicTo(8.18, 12.87, 9.01, 12.04, 10.01, 12.04)
      ..lineTo(15.8, 12.04)
      ..cubicTo(16.8, 12.04, 17.63, 12.87, 17.63, 13.87)
      ..cubicTo(17.63, 16.03, 17.97, 18.13, 18.62, 20.08)
      ..cubicTo(18.82, 20.69, 18.68, 21.36, 18.22, 21.82)
      ..close();

    canvas.drawPath(phonePath, fillPaint);

    // 2. Signal Waves arc paths from ic_launcher_foreground.xml
    final wavesPath = Path()
      ..moveTo(27.5, 12.04)
      ..cubicTo(30.8, 13.8, 33.5, 16.5, 35.26, 19.8)
      ..moveTo(24.5, 16.04)
      ..cubicTo(26.2, 17.0, 27.5, 18.3, 28.46, 20.0);

    canvas.drawPath(wavesPath, strokePaint);

    // 3. Tracking Chart Arrow polyline paths from ic_launcher_foreground.xml
    final chartPath = Path()
      ..moveTo(22.0, 28.0)
      ..lineTo(28.0, 22.0)
      ..lineTo(33.0, 26.0)
      ..lineTo(42.0, 16.0)
      ..moveTo(36.0, 16.0)
      ..lineTo(42.0, 16.0)
      ..lineTo(42.0, 22.0);

    canvas.drawPath(chartPath, strokePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ZebuMarkPainter old) => old.color != color;
}

/// Mark on a brand-blue rounded tile — the official App Icon reproduced in-app.
class ZebuAppMark extends StatelessWidget {
  const ZebuAppMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.colors.primary,
          borderRadius: BorderRadius.circular(size * 0.24),
        ),
        child: ZebuMark(size: size * 0.52, color: Colors.white),
      );
}

/// Mark + product name, used as the login lockup header.
class ZebuLockup extends StatelessWidget {
  const ZebuLockup({super.key, this.markSize = 34});

  final double markSize;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ZebuMark(size: markSize),
          SizedBox(width: markSize * 0.4),
          Text(
            'Call Tracker',
            style: context.text.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              fontSize: markSize * 0.62,
            ),
          ),
        ],
      );
}
