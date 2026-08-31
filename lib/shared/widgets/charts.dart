import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A sleek mini area sparkline chart for hero metrics and KPI cards.
class MiniSparkline extends StatelessWidget {
  const MiniSparkline({
    super.key,
    required this.data,
    this.lineColor = const Color(0xFF4F6BFF),
    this.height = 42,
    this.showGlowDot = true,
  });

  final List<double> data;
  final Color lineColor;
  final double height;
  final bool showGlowDot;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return SizedBox(height: height);
    }

    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          data: data,
          lineColor: lineColor,
          showGlowDot: showGlowDot,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.data,
    required this.lineColor,
    required this.showGlowDot,
  });

  final List<double> data;
  final Color lineColor;
  final bool showGlowDot;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final minVal = data.reduce(math.min);
    final maxVal = data.reduce(math.max);
    final range = (maxVal - minVal) == 0 ? 1.0 : (maxVal - minVal);

    final points = <Offset>[];
    final dx = size.width / (data.length - 1);

    for (int i = 0; i < data.length; i++) {
      final normalized = (data[i] - minVal) / range;
      // Invert Y and add padding so line doesn't clip
      final y = size.height - (normalized * (size.height - 10)) - 5;
      points.add(Offset(i * dx, y));
    }

    // Build smooth cubic bezier path
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final controlPoint1 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p0.dy);
      final controlPoint2 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p1.dy);
      linePath.cubicTo(
        controlPoint1.dx,
        controlPoint1.dy,
        controlPoint2.dx,
        controlPoint2.dy,
        p1.dx,
        p1.dy,
      );
    }

    // Area fill path
    final fillPath = Path.from(linePath)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.32),
          lineColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // Stroke line
    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(linePath, linePaint);

    // Glowing dot at the end
    if (showGlowDot && points.isNotEmpty) {
      final lastPoint = points.last;
      final glowPaint = Paint()
        ..color = lineColor.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(lastPoint, 6, glowPaint);

      final dotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(lastPoint, 3.5, dotPaint);

      final dotBorderPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(lastPoint, 3.5, dotBorderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.data != data || oldDelegate.lineColor != lineColor;
}

/// Rich Call Activity Area & Line Chart with multi-series toggles.
class CallActivityChart extends StatefulWidget {
  const CallActivityChart({
    super.key,
    required this.incomingPoints,
    required this.outgoingPoints,
    required this.missedPoints,
    required this.labels,
    this.height = 180,
  });

  final List<double> incomingPoints;
  final List<double> outgoingPoints;
  final List<double> missedPoints;
  final List<String> labels;
  final double height;

  @override
  State<CallActivityChart> createState() => _CallActivityChartState();
}

class _CallActivityChartState extends State<CallActivityChart> {
  bool _showIncoming = true;
  bool _showOutgoing = true;
  bool _showMissed = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Legend toggles
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _LegendChip(
              label: 'Incoming',
              color: const Color(0xFF22C55E),
              active: _showIncoming,
              onTap: () => setState(() => _showIncoming = !_showIncoming),
            ),
            const SizedBox(width: 8),
            _LegendChip(
              label: 'Outgoing',
              color: const Color(0xFF6366F1),
              active: _showOutgoing,
              onTap: () => setState(() => _showOutgoing = !_showOutgoing),
            ),
            const SizedBox(width: 8),
            _LegendChip(
              label: 'Missed',
              color: const Color(0xFFEF4444),
              active: _showMissed,
              onTap: () => setState(() => _showMissed = !_showMissed),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Chart canvas
        SizedBox(
          height: widget.height,
          child: CustomPaint(
            size: Size.infinite,
            painter: _CallActivityPainter(
              incoming: _showIncoming ? widget.incomingPoints : const [],
              outgoing: _showOutgoing ? widget.outgoingPoints : const [],
              missed: _showMissed ? widget.missedPoints : const [],
              labels: widget.labels,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.4) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: active ? color : const Color(0xFF64748B),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? Colors.white : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallActivityPainter extends CustomPainter {
  _CallActivityPainter({
    required this.incoming,
    required this.outgoing,
    required this.missed,
    required this.labels,
  });

  final List<double> incoming;
  final List<double> outgoing;
  final List<double> missed;
  final List<String> labels;

  @override
  void paint(Canvas canvas, Size size) {
    const bottomPadding = 24.0;
    final chartHeight = size.height - bottomPadding;

    // Draw subtle horizontal grid lines
    final gridPaint = Paint()
      ..color = const Color(0xFF1E293B).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (int i = 0; i <= 3; i++) {
      final y = chartHeight * (i / 3);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Determine global max across series
    final allValues = [...incoming, ...outgoing, ...missed];
    final maxVal = allValues.isEmpty
        ? 10.0
        : math.max(10.0, allValues.reduce(math.max));

    // Draw series
    if (incoming.isNotEmpty) {
      _drawSeries(
        canvas,
        size,
        incoming,
        maxVal,
        chartHeight,
        const Color(0xFF22C55E),
      );
    }
    if (outgoing.isNotEmpty) {
      _drawSeries(
        canvas,
        size,
        outgoing,
        maxVal,
        chartHeight,
        const Color(0xFF6366F1),
      );
    }
    if (missed.isNotEmpty) {
      _drawSeries(
        canvas,
        size,
        missed,
        maxVal,
        chartHeight,
        const Color(0xFFEF4444),
      );
    }

    // Draw X-axis labels
    if (labels.isNotEmpty) {
      final labelCount = labels.length;
      final dx = size.width / math.max(1, labelCount - 1);
      final textStyle = const TextStyle(
        color: Color(0xFF64748B),
        fontSize: 10.5,
        fontWeight: FontWeight.w500,
      );

      for (int i = 0; i < labelCount; i++) {
        final tp = TextPainter(
          text: TextSpan(text: labels[i], style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout();

        final x = (i * dx) - (tp.width / 2);
        final clampedX = x.clamp(0.0, size.width - tp.width);
        tp.paint(canvas, Offset(clampedX, size.height - bottomPadding + 8));
      }
    }
  }

  void _drawSeries(
    Canvas canvas,
    Size size,
    List<double> data,
    double maxVal,
    double chartHeight,
    Color color,
  ) {
    if (data.length < 2) return;

    final points = <Offset>[];
    final dx = size.width / (data.length - 1);

    for (int i = 0; i < data.length; i++) {
      final normalized = data[i] / maxVal;
      final y = chartHeight - (normalized * (chartHeight - 16)) - 8;
      points.add(Offset(i * dx, y));
    }

    // Build smooth curve
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final cp1 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p0.dy);
      final cp2 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p1.dy);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
    }

    // Area fill
    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, chartHeight)
      ..lineTo(points.first.dx, chartHeight)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.22),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, chartHeight))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // Line stroke
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _CallActivityPainter oldDelegate) => true;
}

/// Circular Sync Progress Ring for the Sync Dashboard.
class SyncProgressRing extends StatelessWidget {
  const SyncProgressRing({
    super.key,
    required this.progress, // 0.0 to 1.0
    required this.centerText,
    required this.subtitle,
    this.size = 170,
    this.strokeWidth = 11,
    this.ringColor = const Color(0xFF4F6BFF),
  });

  final double progress;
  final String centerText;
  final String subtitle;
  final double size;
  final double strokeWidth;
  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background Glow
          Container(
            width: size * 0.72,
            height: size * 0.72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: ringColor.withValues(alpha: 0.18),
                  blurRadius: 36,
                  spreadRadius: 4,
                ),
              ],
            ),
          ),

          // Custom Arc Painter
          CustomPaint(
            size: Size(size, size),
            painter: _RingPainter(
              progress: progress.clamp(0.0, 1.0),
              strokeWidth: strokeWidth,
              ringColor: ringColor,
              trackColor: const Color(0xFF182235),
            ),
          ),

          // Center Text Readout
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                centerText,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.ringColor,
    required this.trackColor,
  });

  final double progress;
  final double strokeWidth;
  final Color ringColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Background track
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, trackPaint);

    // Active progress arc
    if (progress > 0) {
      final sweepAngle = 2 * math.pi * progress;
      final startAngle = -math.pi / 2;

      final gradient = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          ringColor.withValues(alpha: 0.6),
          ringColor,
        ],
      );

      final progressPaint = Paint()
        ..shader = gradient.createShader(
          Rect.fromCircle(center: center, radius: radius),
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.ringColor != ringColor;
}

/// Horizontal segmented distribution bar.
class MiniBarDistribution extends StatelessWidget {
  const MiniBarDistribution({
    super.key,
    required this.segments,
    this.height = 7,
  });

  final List<DistributionSegment> segments;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
    if (total == 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(
          children: segments.map((seg) {
            final flex = (seg.value / total * 1000).round();
            if (flex <= 0) return const SizedBox.shrink();
            return Expanded(
              flex: flex,
              child: ColoredBox(color: seg.color),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class DistributionSegment {
  const DistributionSegment({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;
}
