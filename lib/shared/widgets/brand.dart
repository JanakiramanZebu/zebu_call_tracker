import 'package:flutter/material.dart';

import 'ui_kit.dart';

/// The Zebu mark, drawn rather than shipped as an asset.
///
/// The glyph is the same geometry as the launcher icon
/// (`res/drawable/ic_launcher_foreground.xml`), transcribed once from
/// design/zebu_logo.svg. Drawing it means the splash, the login header and the
/// launcher can never drift apart, and the app carries no image asset that has
/// to be re-exported per density.
class ZebuMark extends StatelessWidget {
  const ZebuMark({super.key, this.size = 40, this.color});

  /// Height of the glyph in logical pixels. Width follows the 18.7:23.7 ratio.
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size * _ZebuMarkPainter.aspect, size),
    painter: _ZebuMarkPainter(color ?? context.colors.primary),
  );
}

class _ZebuMarkPainter extends CustomPainter {
  const _ZebuMarkPainter(this.color);

  final Color color;

  /// Source glyph bounds in design/zebu_logo.svg viewBox units.
  static const _w = 18.7;
  static const _h = 23.7;
  static const _top = 5.1;
  static const aspect = _w / _h;

  static const _arrow = <Offset>[
    Offset(18.7, 11.1),
    Offset(0, 5.1),
    Offset(0, 10.35),
    Offset(12.95, 14.5),
    Offset(0, 18.7),
    Offset(0, 23.95),
    Offset(13.35, 19.65),
    Offset(18.7, 17.95),
  ];

  static const _bar = <Offset>[
    Offset(0, 23.95),
    Offset(18.65, 23.95),
    Offset(18.65, 28.8),
    Offset(0, 28.8),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.height / _h;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    Path shape(List<Offset> pts) {
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final p = Offset(pts[i].dx * s, (pts[i].dy - _top) * s);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      return path..close();
    }

    canvas
      ..drawPath(shape(_arrow), paint)
      ..drawPath(shape(_bar), paint);
  }

  @override
  bool shouldRepaint(_ZebuMarkPainter old) => old.color != color;
}

/// Mark on a brand-blue rounded tile — the app icon, reproduced in-app.
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
    child: ZebuMark(size: size * 0.5, color: Colors.white),
  );
}

/// Mark + product name, used as the login header.
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
