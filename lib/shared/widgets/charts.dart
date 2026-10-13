import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/theme/design_tokens.dart';
import 'ui_kit.dart';

// Charts. Solid marks only: no gradients, no glows, no area fills. Every
// colour comes from `context.z`, or from the brand tokens on the Zebu-blue
// panel.

// ─────────────────────────────────────────────────────────────────────────────
// Day strip
// ─────────────────────────────────────────────────────────────────────────────

/// One call as the day strip needs it: when it started (local time) and how
/// long it was connected. Zero seconds means nobody talked.
@immutable
class StripCall {
  const StripCall(this.start, this.seconds);

  final DateTime start;
  final int seconds;

  bool get answered => seconds > 0;
}

/// The Home panel's signature: the period's calls drawn on the Zebu-blue
/// panel.
///
/// For a single day each call is a thin vertical mark placed at its time of
/// day, taller the longer it ran; calls nobody answered are short and in
/// [AppTokens.onBrandMissed], so they differ from answered ones in height and
/// lightness and not by hue alone. The axis covers at least the working day
/// (9 AM to 7 PM) and stretches to take in any call outside it. Today gets a
/// dashed "Now" marker.
///
/// For a longer period the strip turns into one bar per day (per week or per
/// month when the span is long), with the current one solid and the rest
/// dimmed.
///
/// The marks grow in once, left to right, the first time the strip is shown,
/// and not at all when the system asks for reduced motion.
class CallDayStrip extends StatefulWidget {
  const CallDayStrip({
    super.key,
    required this.calls,
    required this.rangeStart,
    required this.rangeEnd,
    this.now,
  });

  /// The period's calls, in any order.
  final List<StripCall> calls;

  /// The period's bounds in local time, as the period picker defines them.
  final DateTime rangeStart;
  final DateTime rangeEnd;

  /// Defaults to the wall clock; overridable so the strip is deterministic.
  final DateTime? now;

  @override
  State<CallDayStrip> createState() => _CallDayStripState();
}

class _CallDayStripState extends State<CallDayStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  bool _started = false;

  // The model is rebuilt only when its inputs change, not on every rebuild of
  // the panel around it.
  _StripModel? _model;
  List<StripCall>? _modelCalls;
  DateTime? _modelStart;
  DateTime? _modelEnd;
  int? _modelMinute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _grow.value = 1;
    } else {
      _grow.forward();
    }
  }

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  _StripModel _modelFor(DateTime now) {
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    if (_model != null &&
        identical(_modelCalls, widget.calls) &&
        _modelStart == widget.rangeStart &&
        _modelEnd == widget.rangeEnd &&
        _modelMinute == minute) {
      return _model!;
    }
    _modelCalls = widget.calls;
    _modelStart = widget.rangeStart;
    _modelEnd = widget.rangeEnd;
    _modelMinute = minute;
    return _model = _StripModel.build(
      widget.calls,
      widget.rangeStart,
      widget.rangeEnd,
      now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = _modelFor(widget.now ?? DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: model.semanticLabel,
          image: true,
          excludeSemantics: true,
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size(double.infinity, _StripPainter.totalHeight),
              painter: _StripPainter(
                model: model,
                progress: _grow,
                textScaler: MediaQuery.textScalerOf(context),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          model.caption,
          style: AppType.caption.copyWith(color: AppTokens.onBrandMuted),
        ),
      ],
    );
  }
}

/// A mark on the strip: horizontal centre as a fraction of the width, height
/// in pixels, and whether it is drawn dimmed or as a missed call.
class _Mark {
  const _Mark(this.x, this.height, this.color, {this.wide = false});

  final double x;
  final double height;
  final Color color;

  /// A per-day bar rather than a single call's line.
  final bool wide;
}

class _Label {
  const _Label(this.x, this.text);

  final double x;
  final String text;
}

class _StripModel {
  const _StripModel({
    required this.marks,
    required this.labels,
    required this.barWidthFraction,
    required this.nowX,
    required this.caption,
    required this.semanticLabel,
  });

  final List<_Mark> marks;
  final List<_Label> labels;

  /// Width of each per-day bar as a fraction of its slot; 0 for call lines.
  final double barWidthFraction;

  /// Where the "Now" marker goes, or null when the period is not today.
  final double? nowX;
  final String caption;
  final String semanticLabel;

  static const double _chart = _StripPainter.chartHeight;

  static final _dayLabel = DateFormat('d MMM');
  static final _weekdayLabel = DateFormat('EEE');
  static final _monthLabel = DateFormat('MMM yy');

  static _StripModel build(
    List<StripCall> calls,
    DateTime rangeStart,
    DateTime rangeEnd,
    DateTime now,
  ) {
    final singleDay =
        rangeEnd.difference(rangeStart) <= const Duration(days: 1);
    return singleDay
        ? _day(calls, rangeStart, rangeEnd, now)
        : _days(calls, rangeStart, rangeEnd, now);
  }

  static String _hour(int h) {
    final hh = h % 24;
    final suffix = hh < 12 ? 'AM' : 'PM';
    final display = hh % 12 == 0 ? 12 : hh % 12;
    return '$display $suffix';
  }

  /// One day: a line per call on an hour axis.
  static _StripModel _day(
    List<StripCall> calls,
    DateTime rangeStart,
    DateTime rangeEnd,
    DateTime now,
  ) {
    final isToday = !now.isBefore(rangeStart) && !now.isAfter(rangeEnd);
    final dayStart = DateTime(
      rangeStart.year,
      rangeStart.month,
      rangeStart.day,
    );
    double minuteOf(DateTime t) => t.difference(dayStart).inSeconds / 60;

    // At least the working day; wider when a call (or the clock) is outside
    // it, so no call falls off the edge.
    var startHour = 9;
    var endHour = 19;
    var longest = 120; // seconds; a day of short calls is not drawn full height
    for (final c in calls) {
      final m = minuteOf(c.start);
      final endM = m + c.seconds / 60;
      startHour = math.min(startHour, (m / 60).floor());
      endHour = math.max(endHour, (endM / 60).ceil());
      longest = math.max(longest, c.seconds);
    }
    if (isToday) endHour = math.max(endHour, now.hour + 1);
    startHour = startHour.clamp(0, 23);
    endHour = endHour.clamp(startHour + 1, 24);
    final spanMinutes = (endHour - startHour) * 60.0;
    double xOf(double minute) =>
        ((minute - startHour * 60) / spanMinutes).clamp(0.0, 1.0);

    final marks = <_Mark>[
      for (final c in calls)
        _Mark(
          xOf(minuteOf(c.start)),
          c.answered ? 10 + (_chart - 16) * (c.seconds / longest) : 6,
          c.answered ? AppTokens.onBrand : AppTokens.onBrandMissed,
        ),
    ]..sort((a, b) => a.x.compareTo(b.x));

    final step = endHour - startHour > 12 ? 4 : 3;
    final labels = <_Label>[
      for (
        var h = ((startHour + step - 1) ~/ step) * step;
        h < endHour;
        h += step
      )
        _Label(xOf(h * 60.0), _hour(h)),
    ];

    final n = calls.length;
    return _StripModel(
      marks: marks,
      labels: labels,
      barWidthFraction: 0,
      nowX: isToday ? xOf(minuteOf(now)) : null,
      caption: 'Each line is a call. Taller lines ran longer.',
      semanticLabel:
          '${n == 1 ? '1 call' : '$n calls'} between ${_hour(startHour)} '
          'and ${_hour(endHour)}',
    );
  }

  /// Several days: one bar per day, week or month.
  static _StripModel _days(
    List<StripCall> calls,
    DateTime rangeStart,
    DateTime rangeEnd,
    DateTime now,
  ) {
    DateTime dateOf(DateTime t) => DateTime(t.year, t.month, t.day);
    int daysBetween(DateTime a, DateTime b) =>
        (b.difference(a).inHours / 24).round();

    final today = dateOf(now);
    // "All time" starts at the epoch; draw from the first call instead.
    var first = dateOf(rangeStart);
    if (rangeStart.year < 2000) {
      first = today;
      for (final c in calls) {
        final d = dateOf(c.start);
        if (d.isBefore(first)) first = d;
      }
    }
    var last = dateOf(rangeEnd);
    if (last.isAfter(today)) last = today;
    if (last.isBefore(first)) last = first;
    final includesToday = !today.isBefore(first) && !today.isAfter(last);

    final days = daysBetween(first, last) + 1;
    final _Unit unit = days <= 45
        ? _Unit.day
        : days <= 26 * 7
        ? _Unit.week
        : _Unit.month;

    int bucketOf(DateTime d) => switch (unit) {
      _Unit.day => daysBetween(first, d),
      _Unit.week => daysBetween(first, d) ~/ 7,
      _Unit.month => (d.year - first.year) * 12 + d.month - first.month,
    };
    DateTime bucketStart(int i) => switch (unit) {
      _Unit.day => DateTime(first.year, first.month, first.day + i),
      _Unit.week => DateTime(first.year, first.month, first.day + i * 7),
      _Unit.month => DateTime(first.year, first.month + i),
    };

    final count = bucketOf(last) + 1;
    final values = List<int>.filled(count, 0);
    for (final c in calls) {
      final i = bucketOf(dateOf(c.start));
      if (i >= 0 && i < count) values[i]++;
    }
    final peak = values.fold<int>(0, math.max);
    final current = includesToday ? bucketOf(today) : -1;

    double xOf(int i) => (i + 0.5) / count;
    final marks = <_Mark>[
      for (var i = 0; i < count; i++)
        _Mark(
          xOf(i),
          peak == 0 || values[i] == 0
              ? 2
              : math.max(2.0, values[i] / peak * (_chart - 6)),
          i == current
              ? AppTokens.onBrand
              : AppTokens.onBrand.withValues(alpha: 0.6),
          wide: true,
        ),
    ];

    String labelFor(int i) {
      if (i == current && unit == _Unit.day) return 'Today';
      final d = bucketStart(i);
      return switch (unit) {
        _Unit.day => count <= 7 ? _weekdayLabel.format(d) : _dayLabel.format(d),
        _Unit.week => _dayLabel.format(d),
        _Unit.month => _monthLabel.format(d),
      };
    }

    final labels = <_Label>[];
    if (count <= 7) {
      for (var i = 0; i < count; i++) {
        labels.add(_Label(xOf(i), labelFor(i)));
      }
    } else {
      final picks = <int>{
        for (var k = 0; k < 5; k++) ((count - 1) * k / 4).round(),
      };
      for (final i in picks) {
        labels.add(_Label(xOf(i), labelFor(i)));
      }
    }

    final per = switch (unit) {
      _Unit.day => 'day',
      _Unit.week => 'week',
      _Unit.month => 'month',
    };
    return _StripModel(
      marks: marks,
      labels: labels,
      barWidthFraction: 0.55,
      nowX: null,
      caption: includesToday
          ? 'Calls per $per. The solid bar is this $per.'
          : 'Calls per $per.',
      semanticLabel:
          'Calls per $per over $count ${count == 1 ? per : '${per}s'}, '
          'up to $peak a $per',
    );
  }
}

enum _Unit { day, week, month }

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.model,
    required this.progress,
    required this.textScaler,
  }) : super(repaint: progress);

  final _StripModel model;
  final Animation<double> progress;
  final TextScaler textScaler;

  static const double chartHeight = 60;
  static const double labelGap = 6;
  static const double labelHeight = 16;
  static const double totalHeight = chartHeight + labelGap + labelHeight;

  static const _lineWidth = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final t = progress.value;
    final marks = model.marks;
    final slot = marks.isEmpty ? w : w / marks.length;
    final barWidth = model.barWidthFraction == 0
        ? _lineWidth
        : (slot * model.barWidthFraction).clamp(2.0, 22.0);

    final paint = Paint()..isAntiAlias = true;
    for (var i = 0; i < marks.length; i++) {
      final m = marks[i];
      // Left to right: each mark starts a little after the one before it and
      // grows over the latter part of the run.
      final delay = m.x * 0.45;
      final local = ((t - delay) / 0.55).clamp(0.0, 1.0);
      final h = m.height * AppTokens.ease.transform(local);
      if (h <= 0) continue;
      final cx = (m.x * w).clamp(barWidth / 2, w - barWidth / 2);
      final r = Radius.circular(m.wide ? 2 : _lineWidth / 2);
      paint.color = m.color;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(cx - barWidth / 2, chartHeight - h, barWidth, h),
          topLeft: r,
          topRight: r,
        ),
        paint,
      );
    }

    // The baseline the marks stand on.
    canvas.drawLine(
      const Offset(0, chartHeight - 0.5),
      Offset(w, chartHeight - 0.5),
      Paint()
        ..color = AppTokens.onBrandLine
        ..strokeWidth = 1,
    );

    // "Now": a dashed rule with its label beside it.
    if (model.nowX case final nx?) {
      final x = (nx * w).clamp(0.5, w - 0.5);
      final dash = Paint()
        ..color = AppTokens.onBrandMuted
        ..strokeWidth = 1;
      for (double y = 0; y < chartHeight; y += 6) {
        canvas.drawLine(
          Offset(x, y),
          Offset(x, math.min(y + 3, chartHeight)),
          dash,
        );
      }
      final tp = _text('Now', AppType.micro, AppTokens.onBrand);
      final lx = x + 5 + tp.width <= w ? x + 5 : x - 5 - tp.width;
      tp.paint(canvas, Offset(lx, -2));
    }

    // Axis labels, centred under their tick and kept inside the strip.
    for (final l in model.labels) {
      final tp = _text(l.text, AppType.caption, AppTokens.onBrandMuted);
      final x = (l.x * w - tp.width / 2)
          .clamp(0.0, math.max(0.0, w - tp.width))
          .toDouble();
      tp.paint(canvas, Offset(x, chartHeight + labelGap));
    }
  }

  TextPainter _text(String text, TextStyle style, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: AppType.tabular(style).copyWith(color: color),
    ),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();

  @override
  bool shouldRepaint(covariant _StripPainter old) =>
      !identical(old.model, model) ||
      old.progress != progress ||
      old.textScaler != textScaler;
}

// ─────────────────────────────────────────────────────────────────────────────
// Share bar
// ─────────────────────────────────────────────────────────────────────────────

/// A thin stacked share bar: each segment's width in proportion to its value,
/// with a small gap between segments and rounded ends. An empty bar shows only
/// the sunken track.
class MiniBarDistribution extends StatelessWidget {
  const MiniBarDistribution({
    super.key,
    required this.segments,
    this.height = 8,
    this.semanticLabel,
  });

  final List<DistributionSegment> segments;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final shown = [
      for (final s in segments)
        if (s.value > 0) s,
    ];
    final total = shown.fold<double>(0, (sum, s) => sum + s.value);

    final children = <Widget>[];
    for (final seg in shown) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 2));
      children.add(
        Expanded(
          flex: math.max(1, (seg.value / total * 1000).round()),
          child: ColoredBox(color: seg.color),
        ),
      );
    }

    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          child: ColoredBox(
            color: z.sunken,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
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
