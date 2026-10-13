import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import 'ui_kit.dart';

/// The Zebu Echo app icon glyph (a handset with two echo arcs) drawn in Flutter.
///
/// Transcribed from `res/drawable/ic_launcher_foreground.xml` (108-unit adaptive
/// icon canvas) so the launcher icon, the splash screen and the in-app headers
/// match. Change both together.
class ZebuMark extends StatelessWidget {
  const ZebuMark({super.key, this.size = 40, this.color});

  /// Size of the glyph in logical pixels. Aspect ratio is 1.0 (square).
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _ZebuMarkPainter(color ?? context.z.accent),
      );
}

class _ZebuMarkPainter extends CustomPainter {
  const _ZebuMarkPainter(this.color);

  final Color color;

  /// The glyph's square bounds on the 108-unit icon canvas, round caps included.
  static const _originX = 31.0;
  static const _originY = 28.0;
  static const _extent = 49.0;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / _extent;

    canvas.save();
    canvas.scale(scale, scale);
    canvas.translate(-_originX, -_originY);

    // 1. Handset: the Material "call" path, placed at (28, 32) and scaled 2x.
    final handset = Path()
      ..moveTo(6.62, 10.79)
      ..relativeCubicTo(1.44, 2.83, 3.76, 5.14, 6.59, 6.59)
      ..relativeLineTo(2.2, -2.2)
      ..relativeCubicTo(0.27, -0.27, 0.67, -0.36, 1.02, -0.24)
      ..relativeCubicTo(1.12, 0.37, 2.33, 0.57, 3.57, 0.57)
      ..relativeCubicTo(0.55, 0, 1, 0.45, 1, 1)
      ..lineTo(21, 20)
      ..relativeCubicTo(0, 0.55, -0.45, 1, -1, 1)
      ..relativeCubicTo(-9.39, 0, -17, -7.61, -17, -17)
      ..relativeCubicTo(0, -0.55, 0.45, -1, 1, -1)
      ..relativeLineTo(3.5, 0)
      ..relativeCubicTo(0.55, 0, 1, 0.45, 1, 1)
      ..relativeCubicTo(0, 1.25, 0.2, 2.45, 0.57, 3.57)
      ..relativeCubicTo(0.11, 0.35, 0.03, 0.74, -0.25, 1.02)
      ..relativeLineTo(-2.2, 2.2)
      ..close();

    canvas.save();
    canvas.translate(28, 32);
    canvas.scale(2, 2);
    canvas.drawPath(
      handset,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.restore();

    // 2. Echo arcs, both centred on (58, 50).
    final arcs = Path()
      ..moveTo(58, 33)
      ..arcToPoint(const Offset(75, 50), radius: const Radius.circular(17))
      ..moveTo(58, 41)
      ..arcToPoint(const Offset(67, 50), radius: const Radius.circular(9));

    canvas.drawPath(
      arcs,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ZebuMarkPainter old) => old.color != color;
}

/// The app icon reproduced in-app: the mark on a rounded tile.
///
/// A solid Zebu-blue tile with a white mark. On a Zebu-blue surface (the Home
/// summary panel, the post-call card strip) pass [inverse] for a white tile
/// with a blue mark, so the tile does not vanish into its background.
class ZebuAppMark extends StatelessWidget {
  const ZebuAppMark({super.key, this.size = 72, this.inverse = false});

  final double size;
  final bool inverse;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: inverse ? AppTokens.onBrand : AppTokens.zebuBlue,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: ZebuMark(
          size: size * 0.54,
          color: inverse ? AppTokens.zebuBlue : AppTokens.onBrand,
        ),
      );
}
