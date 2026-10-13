import 'package:flutter/material.dart';

import '../../core/errors/user_facing_error.dart';
import '../../core/platform/native_call_bridge.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../features/call_tracking/domain/call_entry.dart';
import '../../features/recording/domain/recording_matcher.dart';

// The app's shared components.
//
// The visual language is a ledger, not a card kit: rows run edge to edge
// separated by hairlines, numbers sit in tabular columns, times come first,
// and colour marks a call's outcome alongside a glyph that differs too. There
// are no gradients and no glows anywhere. One element per screen at most gets
// the Zebu brand blue.

/// Convenience accessors on BuildContext.
extension ThemeX on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;

  /// The colours for the current brightness. Read this, never a literal.
  ZColors get z => Theme.of(this).extension<ZColors>() ?? ZColors.dark;
}

/// Safe-area helpers.
///
/// The app draws edge to edge (Android 15 enforces it), so the system
/// navigation bar — gesture pill or the three buttons — sits ON TOP of the
/// app's last pixels. A scroll view given an explicit `padding` no longer adds
/// that inset by itself, and its last row ends up under the nav buttons. Every
/// scrollable screen builds its padding through [scrollPadding] instead.
extension SafeAreaX on BuildContext {
  /// Height of the system navigation bar / gesture area at the bottom.
  double get safeBottom => MediaQuery.viewPaddingOf(this).bottom;

  /// Height of the status bar / cutout at the top.
  double get safeTop => MediaQuery.viewPaddingOf(this).top;

  /// Page padding for a scroll view: [horizontal] at the sides and [bottom] of
  /// breathing room *above* the system navigation bar.
  ///
  /// Uses the padding still present in this context's MediaQuery, so inside a
  /// Scaffold with a bottom bar (which already consumed the inset) it adds
  /// only [bottom]. Ledger screens pass `horizontal: 0` and indent each row.
  EdgeInsets scrollPadding({
    double top = 8,
    double bottom = 24,
    double horizontal = AppTokens.gutter,
  }) => EdgeInsets.fromLTRB(
    horizontal,
    top,
    horizontal,
    bottom + MediaQuery.paddingOf(this).bottom,
  );
}

/// Pads [child] up from the system navigation bar.
///
/// For bottom-pinned content — action bars, sheet footers — that is not inside
/// a scroll view. Wraps [SafeArea] with only the bottom edge, plus [minimum]
/// breathing room so a phone with no nav bar still gets a margin.
class BottomSafe extends StatelessWidget {
  const BottomSafe({super.key, required this.child, this.minimum = 16});

  final Widget child;
  final double minimum;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    left: false,
    right: false,
    minimum: EdgeInsets.only(bottom: minimum),
    child: child,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Glyphs and outcome styles
// ─────────────────────────────────────────────────────────────────────────────

/// The shape drawn for a call's outcome. Each is distinct, so the outcome
/// never rests on colour alone.
enum CallGlyphKind {
  incoming,
  outgoing,
  missed,
  rejected,
  blocked,
  voicemail,
  unknown,
}

/// A thin-stroke call-outcome glyph drawn on a 16-unit grid.
///
/// Custom rather than a Material icon: the filled handset icons were too heavy
/// for a ledger row, and the arrow alone reads faster at 12px.
class CallGlyph extends StatelessWidget {
  const CallGlyph(
    this.kind, {
    super.key,
    this.size = 14,
    this.color,
    this.semanticLabel,
  });

  final CallGlyphKind kind;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      size: Size.square(size),
      painter: _CallGlyphPainter(
        kind,
        color ?? IconTheme.of(context).color ?? context.z.ink,
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: paint);
    return Semantics(label: semanticLabel, image: true, child: paint);
  }
}

class _CallGlyphPainter extends CustomPainter {
  const _CallGlyphPainter(this.kind, this.color);

  final CallGlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 16;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    Offset o(double x, double y) => Offset(x * k, y * k);
    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(o(x1, y1), o(x2, y2), p);
    void poly(List<Offset> pts) => canvas.drawPath(
      Path()..addPolygon(pts.map((e) => o(e.dx, e.dy)).toList(), false),
      p,
    );

    switch (kind) {
      case CallGlyphKind.incoming:
        line(12, 4, 4, 12);
        poly(const [Offset(4, 6.5), Offset(4, 12), Offset(9.5, 12)]);
      case CallGlyphKind.outgoing:
        line(4, 12, 12, 4);
        poly(const [Offset(6.5, 4), Offset(12, 4), Offset(12, 9.5)]);
      case CallGlyphKind.missed:
        line(4.5, 4.5, 11.5, 11.5);
        line(11.5, 4.5, 4.5, 11.5);
      case CallGlyphKind.rejected:
      case CallGlyphKind.blocked:
        canvas.drawCircle(o(8, 8), 5.25 * k, p);
        line(4.3, 4.3, 11.7, 11.7);
      case CallGlyphKind.voicemail:
        canvas.drawCircle(o(4.5, 8.5), 2.5 * k, p);
        canvas.drawCircle(o(11.5, 8.5), 2.5 * k, p);
        line(4.5, 11, 11.5, 11);
      case CallGlyphKind.unknown:
        canvas.drawCircle(o(8, 8), 2.5 * k, p);
    }
  }

  @override
  bool shouldRepaint(_CallGlyphPainter old) =>
      old.kind != kind || old.color != color;
}

/// Visual style for a call direction: its glyph, its colour and its label.
///
/// [icon] is kept for the few places that still need a Material [IconData]
/// (a list tile leading slot, a notification); rows draw [glyph].
({IconData icon, Color color, String label, CallGlyphKind glyph}) directionStyle(
  BuildContext context,
  CallDirection direction,
) {
  final z = context.z;
  return switch (direction) {
    CallDirection.incoming => (
      icon: Icons.call_received_rounded,
      color: z.incoming,
      label: 'Incoming',
      glyph: CallGlyphKind.incoming,
    ),
    CallDirection.outgoing => (
      icon: Icons.call_made_rounded,
      color: z.outgoing,
      label: 'Outgoing',
      glyph: CallGlyphKind.outgoing,
    ),
    CallDirection.missed => (
      icon: Icons.call_missed_rounded,
      color: z.missed,
      label: 'Missed',
      glyph: CallGlyphKind.missed,
    ),
    CallDirection.rejected => (
      icon: Icons.phone_disabled_rounded,
      color: z.rejected,
      label: 'Rejected',
      glyph: CallGlyphKind.rejected,
    ),
    CallDirection.blocked => (
      icon: Icons.block_rounded,
      color: z.missed,
      label: 'Blocked',
      glyph: CallGlyphKind.blocked,
    ),
    CallDirection.voicemail => (
      icon: Icons.voicemail_rounded,
      color: z.ink3,
      label: 'Voicemail',
      glyph: CallGlyphKind.voicemail,
    ),
    CallDirection.unknown => (
      icon: Icons.call_rounded,
      color: z.ink3,
      label: 'Unknown',
      glyph: CallGlyphKind.unknown,
    ),
  };
}

/// Visual style for sync/upload state.
({IconData icon, Color color, String label}) uploadStyle(
  BuildContext context,
  UploadState state,
) {
  final z = context.z;
  return switch (state) {
    UploadState.uploaded => (
      icon: Icons.check_rounded,
      color: z.ink3,
      label: 'Sent',
    ),
    UploadState.uploading => (
      icon: Icons.arrow_upward_rounded,
      color: z.accent,
      label: 'Sending',
    ),
    UploadState.pending => (
      icon: Icons.schedule_rounded,
      color: z.warn,
      label: 'Waiting',
    ),
    UploadState.failed => (
      icon: Icons.error_outline_rounded,
      color: z.danger,
      label: 'Not sent',
    ),
  };
}

/// Recording match status helper.
({IconData icon, Color color, String label}) recordingStyle(
  BuildContext context,
  RecordingMatchStatus status,
) {
  final z = context.z;
  return switch (status) {
    RecordingMatchStatus.matched => (
      icon: Icons.graphic_eq_rounded,
      color: z.ok,
      label: 'Recording attached',
    ),
    RecordingMatchStatus.ambiguous => (
      icon: Icons.help_outline_rounded,
      color: z.warn,
      label: 'Pick a recording',
    ),
    RecordingMatchStatus.unmatched => (
      icon: Icons.mic_off_outlined,
      color: z.ink3,
      label: 'No recording',
    ),
    RecordingMatchStatus.notFound => (
      icon: Icons.mic_off_outlined,
      color: z.ink3,
      label: 'No recording',
    ),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Small parts
// ─────────────────────────────────────────────────────────────────────────────

/// A tappable icon with a circular ripple and no highlight overlay.
///
/// [IconButton] in Material 3 paints a filled state layer on press; this keeps
/// only the splash. The hit area is at least 44×44 even when [size] is
/// smaller, so a small glyph is still easy to hit. Always pass [tooltip]: it is
/// the accessible name for screen readers too.
class TapIcon extends StatelessWidget {
  const TapIcon({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.color,
    this.size = 22,
    this.hitSize = AppTokens.minTap,
    this.background,
    this.splashColor,
    this.selected,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final Color? color;
  final double size;
  final double hitSize;

  /// Optional filled circle behind the glyph.
  final Color? background;
  final Color? splashColor;

  /// For toggles: exposed to accessibility services as the selected state.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = color ?? context.z.ink;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkResponse(
            onTap: onTap,
            containedInkWell: true,
            customBorder: const CircleBorder(),
            highlightColor: Colors.transparent,
            splashColor: splashColor ?? fg.withValues(alpha: 0.16),
            child: Ink(
              width: hitSize,
              height: hitSize,
              decoration: background == null
                  ? null
                  : BoxDecoration(color: background, shape: BoxShape.circle),
              child: Icon(
                icon,
                size: size,
                color: enabled ? fg : fg.withValues(alpha: 0.38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small filled status dot. Pass [pulse] while something is in progress.
class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.size = 8,
    this.pulse = false,
  });

  final Color color;
  final double size;
  final bool pulse;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final reduce =
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    if (widget.pulse && !reduce) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: widget.pulse
            ? [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.5 * (1 - _c.value)),
                  spreadRadius: 6 * _c.value,
                ),
              ]
            : null,
      ),
    ),
  );
}

/// A compact status label: a dot and a word on a soft tint. Square-cornered,
/// not a pill.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppTokens.r4 + 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            maxLines: 1,
            style: AppType.captionStrong.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "WhatsApp" marker for calls captured from WhatsApp.
class WhatsAppTag extends StatelessWidget {
  const WhatsAppTag({super.key});

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: z.whatsappSoft,
        borderRadius: BorderRadius.circular(AppTokens.r4),
      ),
      child: Text('WhatsApp', style: AppType.micro.copyWith(color: z.whatsapp)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Headings
// ─────────────────────────────────────────────────────────────────────────────

/// Heading above a group of list rows, in sentence case: "Tracking",
/// "Health checks". Optional [trailing] (a count, a link).
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.text, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      AppTokens.gutter,
      20,
      AppTokens.gutter,
      8,
    ),
  });

  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              text,
              style: AppType.labelStrong.copyWith(color: context.z.ink3),
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Heading for a content section: "Outcome", "Latest calls", "Recording".
/// [trailing] sits on the baseline at the right — a note or a text button.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: AppTokens.gutter),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: AppType.heading),
          ),
        ),
        if (trailing != null)
          DefaultTextStyle.merge(
            style: AppType.label.copyWith(color: context.z.ink3),
            child: trailing!,
          ),
      ],
    ),
  );
}

/// Large screen title used at the top of each tab: title, optional subtitle
/// and trailing actions. Not an AppBar, so it scrolls with the content.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 20, 10, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.title,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.small.copyWith(color: context.z.ink3),
                ),
              ],
            ],
          ),
        ),
        ...actions,
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Surfaces and lists
// ─────────────────────────────────────────────────────────────────────────────

/// A bordered, raised box. Use sparingly — lists are [ListGroup]s, not cards.
/// For a self-contained block that has to read as one unit: a dialog body, a
/// recording picker option, an inline form.
///
/// When [onTap] is set the whole box ripples on press.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
    this.onTap,
    this.accent,
    this.radius = AppTokens.r12,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final VoidCallback? onTap;

  /// Tints the box towards a semantic colour — for a status block.
  final Color? accent;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final shape = BorderRadius.circular(radius);
    final bg = accent != null
        ? Color.alphaBlend(accent!.withValues(alpha: 0.10), z.raised)
        : z.raised;
    final border =
        borderColor ??
        (accent != null ? accent!.withValues(alpha: 0.28) : z.line);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: shape,
        border: Border.all(color: border),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: shape,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// An edge-to-edge band of rows on the raised surface, ruled top and bottom
/// with a hairline between rows (inset by the gutter).
///
/// The settings-style grouped list. For long lazily built lists, build each
/// row in a [CardListSlice] instead.
class ListGroup extends StatelessWidget {
  const ListGroup({
    super.key,
    required this.children,
    this.dividerIndent = AppTokens.gutter,
    this.background,
  });

  final List<Widget> children;
  final double dividerIndent;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background ?? z.raised,
        border: Border.symmetric(horizontal: BorderSide(color: z.line)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: dividerIndent),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One row of a [ListGroup]: title, optional subtitle, a right-aligned value
/// and/or trailing widget, and a chevron when it navigates.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.valueColor,
    this.leading,
    this.trailing,
    this.onTap,
    this.chevron,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final Color? valueColor;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Defaults to showing a chevron whenever [onTap] is set and there is no
  /// [trailing] widget.
  final bool? chevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final showChevron = chevron ?? (onTap != null && trailing == null);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: subtitle == null ? 54 : 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.gutter,
            vertical: 10,
          ),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 14)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: destructive
                          ? AppType.bodyStrong.copyWith(color: z.danger)
                          : AppType.bodyMedium,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: AppType.label.copyWith(
                          color: z.ink3,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                Text(
                  value!,
                  style: AppType.tabular(
                    AppType.small,
                  ).copyWith(color: valueColor ?? z.ink3),
                ),
              ],
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              if (showChevron) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, size: 20, color: z.ink3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One row's slice of a ruled list: a hairline above every row but the first,
/// and the band's top/bottom rule on the ends.
///
/// Lets a long list keep its band look while being built lazily. A band
/// wrapping a Column of every row built and laid out all of them up front,
/// however few were on screen.
class CardListSlice extends StatelessWidget {
  const CardListSlice({
    super.key,
    required this.first,
    required this.last,
    required this.child,
    this.dividerIndent = 0,
    this.background,
  });

  final bool first;
  final bool last;
  final double dividerIndent;

  /// Defaults to the page canvas; pass `context.z.raised` for a raised band.
  final Color? background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final side = BorderSide(color: z.line);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background ?? z.canvas,
        border: Border(
          top: first ? side : BorderSide.none,
          bottom: last ? side : BorderSide.none,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!first) Divider(height: 1, indent: dividerIndent),
            child,
          ],
        ),
      ),
    );
  }
}

/// A key/value fact for [FactGrid].
class Fact {
  const Fact(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;
}

/// Two-column fact sheet: each cell a small key over its value, ruled like a
/// confirmation slip. Used for a call's details.
class FactGrid extends StatelessWidget {
  const FactGrid({super.key, required this.facts});

  final List<Fact> facts;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final rows = <List<Fact>>[];
    for (var i = 0; i < facts.length; i += 2) {
      rows.add(facts.sublist(i, i + 2 > facts.length ? facts.length : i + 2));
    }
    final side = BorderSide(color: z.line);

    Widget cell(Fact? f, {required bool left, required bool lastRow}) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.gutter,
              vertical: 13,
            ),
            decoration: BoxDecoration(
              border: Border(
                right: left ? side : BorderSide.none,
                bottom: lastRow ? BorderSide.none : side,
              ),
            ),
            child: f == null
                ? const SizedBox.shrink()
                : MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          f.label,
                          style: AppType.captionStrong.copyWith(color: z.ink3),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          f.value,
                          style: AppType.tabular(
                            AppType.bodyMedium,
                          ).copyWith(color: f.color ?? z.ink),
                        ),
                      ],
                    ),
                  ),
          ),
        );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: z.raised,
        border: Border.symmetric(horizontal: side),
      ),
      child: Column(
        children: [
          for (var r = 0; r < rows.length; r++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cell(rows[r][0], left: true, lastRow: r == rows.length - 1),
                  cell(
                    rows[r].length > 1 ? rows[r][1] : null,
                    left: false,
                    lastRow: r == rows.length - 1,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Selection controls
// ─────────────────────────────────────────────────────────────────────────────

/// A row of text tabs with an underline under the selected one.
///
/// Replaces pill chips and the old gradient segmented control. Scrolls
/// sideways when the labels do not fit. [counts] adds a muted figure after a
/// label ("Missed 6"). [onBrand] styles it for the Zebu-blue panel.
class UnderlineTabs<T> extends StatelessWidget {
  const UnderlineTabs({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.counts,
    this.onBrand = false,
    this.padding = const EdgeInsets.symmetric(horizontal: AppTokens.gutter),
    this.gap = 22,
    this.ruled = true,
    this.semanticLabel,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onSelected;
  final Map<T, String>? counts;
  final bool onBrand;
  final EdgeInsets padding;
  final double gap;

  /// Draws the hairline the tabs sit on.
  final bool ruled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final active = onBrand ? AppTokens.onBrand : z.ink;
    final idle = onBrand ? AppTokens.onBrand.withValues(alpha: 0.72) : z.ink3;
    final bar = onBrand ? AppTokens.onBrand : z.accent;
    final rule = onBrand ? AppTokens.onBrandLine : z.line;

    final tabs = <Widget>[];
    for (final entry in segments.entries) {
      final sel = entry.key == selected;
      final count = counts?[entry.key];
      if (tabs.isNotEmpty) tabs.add(SizedBox(width: gap));
      tabs.add(
        Semantics(
          button: true,
          selected: sel,
          label: count == null ? entry.value : '${entry.value}, $count',
          excludeSemantics: true,
          child: InkWell(
            onTap: () => onSelected(entry.key),
            borderRadius: BorderRadius.circular(AppTokens.r4),
            child: AnimatedContainer(
              duration: AppTokens.fast,
              curve: AppTokens.ease,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: sel ? bar : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: entry.value),
                    if (count != null)
                      TextSpan(
                        text: ' $count',
                        style: TextStyle(
                          color: onBrand ? idle : z.ink3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                style: AppType.tabular(AppType.small).copyWith(
                  color: sel ? active : idle,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: ruled
              ? Border(bottom: BorderSide(color: rule))
              : null,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: Row(children: tabs),
        ),
      ),
    );
  }
}

/// A compact segmented picker on a sunken track — for a setting with two to
/// four mutually exclusive values (Appearance: Dark / Light / System).
class SegmentedPicker<T> extends StatelessWidget {
  const SegmentedPicker({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: z.sunken,
        borderRadius: BorderRadius.circular(AppTokens.r10),
      ),
      child: Row(
        children: [
          for (final entry in segments.entries)
            Expanded(
              child: Semantics(
                inMutuallyExclusiveGroup: true,
                checked: entry.key == selected,
                button: true,
                label: entry.value,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(entry.key),
                  child: AnimatedContainer(
                    duration: AppTokens.fast,
                    curve: AppTokens.ease,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: entry.key == selected
                          ? z.segmentActive
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppTokens.r8),
                      boxShadow: entry.key == selected && !z.isDark
                          ? [
                              BoxShadow(
                                color: z.shadow.withValues(alpha: 0.18),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      entry.value,
                      style: AppType.small.copyWith(
                        color: entry.key == selected ? z.ink : z.ink3,
                        fontWeight: entry.key == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buttons
// ─────────────────────────────────────────────────────────────────────────────

enum ZButtonVariant {
  /// The one main action on a screen. Solid brand fill.
  primary,

  /// Supporting actions. Quiet fill.
  secondary,

  /// Hairline outline, transparent fill.
  outline,

  /// Confirms something that cannot be undone, such as signing out.
  destructive,

  /// Text only, in the accent colour.
  text,
}

enum ZButtonSize {
  /// 52 tall: a screen's footer action.
  large(52, AppType.bodyStrong, 18),

  /// 48 tall: the default.
  regular(48, AppType.bodyStrong, 17),

  /// 40 tall: actions inside a row.
  compact(40, AppType.smallStrong, 16),

  /// 36 tall: player and inline controls.
  small(36, AppType.labelStrong, 15);

  const ZButtonSize(this.height, this.style, this.iconSize);

  final double height;
  final TextStyle style;
  final double iconSize;
}

/// The app's button. Solid fills only — no gradient, no glow.
///
/// [expand] stretches it to the available width (the default for footer
/// actions); pass false for a button that sizes to its label.
class ZButton extends StatelessWidget {
  const ZButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = ZButtonVariant.primary,
    this.size = ZButtonSize.regular,
    this.loading = false,
    this.expand = true,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final ZButtonVariant variant;
  final ZButtonSize size;
  final bool loading;
  final bool expand;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final enabled = onPressed != null && !loading;
    final shape = BorderRadius.circular(
      size.height >= 48 ? AppTokens.r12 : AppTokens.r10,
    );

    final (Color bg, Color fg, Color? border) = switch (variant) {
      ZButtonVariant.primary => (z.primary, z.onPrimary, null),
      ZButtonVariant.secondary => (z.secondary, z.onSecondary, null),
      ZButtonVariant.outline => (Colors.transparent, z.ink, z.lineStrong),
      ZButtonVariant.destructive => (
        AppTokens.destructiveFill,
        Colors.white,
        null,
      ),
      ZButtonVariant.text => (Colors.transparent, z.accent, null),
    };

    // A disabled primary keeps its shape but drops to the quiet fill, so it
    // never looks pressable.
    final fill = !enabled && !loading && variant == ZButtonVariant.primary
        ? z.secondary
        : bg;
    final ink = !enabled && !loading ? z.ink3 : fg;

    final content = loading
        ? SizedBox(
            key: const ValueKey('busy'),
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
          )
        : Row(
            key: const ValueKey('idle'),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: size.iconSize, color: ink),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: size.style.copyWith(color: ink),
                ),
              ),
            ],
          );

    final button = AnimatedContainer(
      duration: AppTokens.fast,
      curve: AppTokens.ease,
      height: size.height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: shape,
        border: border == null ? null : Border.all(color: border),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: shape,
          splashColor: fg.withValues(alpha: 0.16),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: variant == ZButtonVariant.text ? 8 : 16,
            ),
            child: Center(
              widthFactor: expand ? null : 1,
              child: AnimatedSwitcher(
                duration: AppTokens.fast,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: expand
          ? SizedBox(width: double.infinity, child: button)
          : button,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

/// Tone for [InfoBanner].
enum BannerTone { info, success, warning, danger }

/// An inline notice: a tinted block with an icon, optional title, body and an
/// optional action (usually a text-variant [ZButton]). No border.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.message,
    this.title,
    this.tone = BannerTone.info,
    this.icon,
    this.action,
  });

  final String message;
  final String? title;
  final BannerTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final (Color c, Color soft) = switch (tone) {
      BannerTone.info => (z.accent, z.accentSoft),
      BannerTone.success => (z.ok, z.okSoft),
      BannerTone.warning => (z.warn, z.warnSoft),
      BannerTone.danger => (z.danger, z.dangerSoft),
    };
    final glyph =
        icon ??
        switch (tone) {
          BannerTone.info => Icons.info_outline_rounded,
          BannerTone.success => Icons.check_circle_outline_rounded,
          BannerTone.warning => Icons.warning_amber_rounded,
          BannerTone.danger => Icons.error_outline_rounded,
        };

    return Semantics(
      liveRegion: tone == BannerTone.danger,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: BoxDecoration(
          color: soft,
          borderRadius: BorderRadius.circular(AppTokens.r12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(glyph, size: 19, color: c),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(title!, style: AppType.bodyStrong),
                    const SizedBox(height: 3),
                  ],
                  Text(message, style: AppType.label.copyWith(
                    color: z.ink2,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                  )),
                  if (action != null) ...[
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerLeft, child: action!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a short confirmation at the bottom of the screen. Replaces any toast
/// already showing so they never queue up.
void showToast(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        // A toast that carries an action stays until it is used or replaced.
        duration: action == null
            ? const Duration(seconds: 3)
            : const Duration(days: 1),
        showCloseIcon: action != null,
      ),
    );
}

/// A two-button confirmation dialog. Resolves true only on [confirmLabel].
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      actions: [
        Row(
          children: [
            Expanded(
              child: ZButton(
                label: cancelLabel,
                variant: ZButtonVariant.secondary,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ZButton(
                label: confirmLabel,
                variant: destructive
                    ? ZButtonVariant.destructive
                    : ZButtonVariant.primary,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result ?? false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Call rows
// ─────────────────────────────────────────────────────────────────────────────

/// A call as one ledger row: time first, then who, with the outcome glyph and
/// masked number beneath, and the length and delivery state on the right.
///
/// Edge to edge with the gutter as padding; draws no divider of its own (wrap
/// rows in a [CardListSlice] or [ListGroup]).
class CallRowTile extends StatelessWidget {
  const CallRowTile({
    super.key,
    required this.entry,
    this.onTap,
    this.expanded,
  });

  final CallEntry entry;
  final VoidCallback? onTap;

  /// When non-null the row is an expander and announces this state.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final dir = directionStyle(context, entry.row.direction);
    final up = uploadStyle(context, entry.uploadState);
    final noAnswer =
        entry.row.direction == CallDirection.outgoing && !entry.isConnected;
    final dirColor = noAnswer ? z.noAnswer : dir.color;
    final dirLabel = noAnswer ? 'No answer' : dir.label;
    final time = entry.startedAtUtc != null
        ? Fmt.clock(entry.startedAtUtc!)
        : '--:--';

    return Semantics(
      button: onTap != null,
      expanded: expanded,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.gutter,
            vertical: 13,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    time,
                    maxLines: 1,
                    style: AppType.tabular(
                      AppType.label,
                    ).copyWith(color: z.ink2),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.bodyStrong.copyWith(
                              color: entry.hasName ? z.ink : z.ink2,
                            ),
                          ),
                        ),
                        if (entry.isWhatsApp) ...[
                          const SizedBox(width: 8),
                          const WhatsAppTag(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        CallGlyph(dir.glyph, size: 12, color: dirColor),
                        const SizedBox(width: 4),
                        Text(
                          dirLabel,
                          style: AppType.label.copyWith(color: dirColor),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            Fmt.maskNumber(entry.row.number),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.tabular(AppType.label).copyWith(
                              color: z.ink3,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    entry.isConnected
                        ? Fmt.stopwatch(entry.durationSeconds)
                        : '—',
                    style: AppType.tabular(AppType.bodyMedium).copyWith(
                      color: entry.isConnected ? z.ink : z.ink3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.needsReview) ...[
                        Icon(
                          Icons.help_outline_rounded,
                          size: 12,
                          color: z.warn,
                          semanticLabel: 'Needs review',
                        ),
                        const SizedBox(width: 4),
                      ],
                      Icon(up.icon, size: 12, color: up.color),
                      const SizedBox(width: 3),
                      Text(
                        up.label,
                        style: AppType.caption.copyWith(color: up.color),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty and error states
// ─────────────────────────────────────────────────────────────────────────────

/// Empty / zero-data state: a quiet icon, a direct title, what to do next and
/// an optional action. Left-aligned in a readable column.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(32, 32, 32, 32 + context.safeBottom),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: z.sunken,
                  borderRadius: BorderRadius.circular(AppTokens.r12),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 22, color: z.ink3),
              ),
              const SizedBox(height: 16),
              Text(title, style: AppType.heading),
              const SizedBox(height: 6),
              Text(message, style: AppType.small.copyWith(color: z.ink2)),
              if (actionLabel case final labelText?) ...[
                const SizedBox(height: 20),
                ZButton(
                  label: labelText,
                  onPressed: onAction,
                  variant: ZButtonVariant.outline,
                  size: ZButtonSize.compact,
                  expand: false,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An [EmptyState] built from a thrown object, with the exception text kept out
/// of it.
///
/// Four screens each rendered `message: '$e'`, so a storage fault reached the
/// user as `SqliteException(11): database disk image is malformed` and a lost
/// connection as a `DioException` dump. Those name no cause a reader can act on.
/// [UserFacingError] does the classification; this puts the result on screen and
/// sends the original to the log.
///
/// "Try again" is omitted when retrying provably cannot help, so the button
/// never offers something that will not work.
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    required this.error,
    required this.logContext,
    required this.onRetry,
    this.fallbackTitle,
    this.icon = Icons.error_outline_rounded,
  });

  final Object error;

  /// Tag for the log line, e.g. `DASHBOARD`.
  final String logContext;

  final VoidCallback onRetry;

  /// Used only when the classifier produces no title of its own.
  final String? fallbackTitle;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final friendly = UserFacingError.from(error);
    friendly.log(logContext);

    return EmptyState(
      icon: icon,
      title: friendly.title.isNotEmpty
          ? friendly.title
          : (fallbackTitle ?? 'Something went wrong'),
      message: friendly.message,
      actionLabel: friendly.isRetryable ? 'Try again' : null,
      onAction: friendly.isRetryable ? onRetry : null,
    );
  }
}
