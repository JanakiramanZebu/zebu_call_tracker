/// Loading vocabulary for the app.
///
/// Three distinct states, deliberately kept apart because they answer different
/// questions for the user:
///
///  * [Skeleton] / [SkeletonList] - "the shape you are about to see". Used when
///    the layout is known in advance (the call list, the dashboard cards), so
///    the screen does not jump when data lands.
///  * [InlineLoader] - "this small thing is still working". Pagination footers,
///    row-level refreshes.
///  * [BusyOverlay] - "your action is in flight, do not press again". Only for
///    user-initiated writes such as sign-in.
///
/// A bare centred [CircularProgressIndicator] is not part of the vocabulary: on
/// a first paint it tells the user nothing about what is coming.
library;

import 'package:flutter/material.dart';

import 'ui_kit.dart';

/// One shimmering placeholder block.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = 6,
  });

  const Skeleton.line({Key? key, double width = double.infinity})
    : this(key: key, width: width, height: 12, radius: 4);

  const Skeleton.circle({Key? key, double size = 38})
    : this(key: key, width: size, height: size, radius: size / 3.4);

  final double width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = context.palette.tint;
    // The highlight is a second wash of the same tint rather than a fixed
    // grey, so the shimmer stays subtle on #181818 and on #F8F9FA alike.
    final highlight = context.colors.onSurface.withValues(alpha: 0.04);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // Sweep the gradient across three widths so the band spends part of
          // the cycle off-screen; a continuous pulse reads as a flicker.
          final x = _c.value * 3 - 1;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment(x - 1, 0),
                end: Alignment(x + 1, 0),
                colors: [base, highlight, base],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Placeholder rows shaped like [CallRowTile], so the call list settles in
/// place instead of reflowing when the first page arrives.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6, this.padding});

  final int rows;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => ListView(
    padding: padding ?? const EdgeInsets.fromLTRB(16, 12, 16, 24),
    physics: const NeverScrollableScrollPhysics(),
    children: [
      AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < rows; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 64),
                  child: Divider(
                    height: 1,
                    color: context.colors.outlineVariant,
                  ),
                ),
              const _SkeletonRow(),
            ],
          ],
        ),
      ),
    ],
  );
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(14, 14, 14, 14),
    child: Row(
      children: [
        Skeleton.circle(),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 148, height: 13),
              SizedBox(height: 8),
              Skeleton(width: 104, height: 11),
            ],
          ),
        ),
        SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Skeleton(width: 38, height: 11),
            SizedBox(height: 8),
            Skeleton(width: 24, height: 11),
          ],
        ),
      ],
    ),
  );
}

/// Dashboard-shaped placeholder: hero card, stat grid, summary row.
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    physics: const NeverScrollableScrollPhysics(),
    children: const [
      AppCard(
        padding: EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 108, height: 12),
            SizedBox(height: 14),
            Skeleton(width: 168, height: 38, radius: 8),
            SizedBox(height: 18),
            Skeleton(width: double.infinity, height: 6, radius: 3),
          ],
        ),
      ),
      SizedBox(height: 12),
      _SkeletonTileRow(),
      SizedBox(height: 12),
      _SkeletonTileRow(),
      SizedBox(height: 16),
      AppCard(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Skeleton.circle(),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Skeleton(width: 96, height: 12),
                  SizedBox(height: 8),
                  Skeleton(width: 148, height: 11),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _SkeletonTileRow extends StatelessWidget {
  const _SkeletonTileRow();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Expanded(child: _SkeletonTile()),
      SizedBox(width: 12),
      Expanded(child: _SkeletonTile()),
    ],
  );
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile();

  @override
  Widget build(BuildContext context) => const AppCard(
    padding: EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Skeleton.circle(),
        SizedBox(height: 12),
        Skeleton(width: 46, height: 20, radius: 5),
        SizedBox(height: 8),
        Skeleton(width: 68, height: 11),
      ],
    ),
  );
}

/// Small spinner with an optional label, for footers and inline refreshes.
class InlineLoader extends StatelessWidget {
  const InlineLoader({super.key, this.label, this.size = 16});

  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: context.colors.primary,
        ),
      ),
      if (label != null) ...[
        const SizedBox(width: 10),
        Text(
          label!,
          style: context.text.bodySmall?.copyWith(color: context.palette.muted),
        ),
      ],
    ],
  );
}

/// Scrim + spinner over the current screen while a user-initiated action runs.
///
/// [AbsorbPointer] rather than merely disabling the button: sign-in has other
/// tappable affordances on screen, and none of them should fire mid-request.
class BusyOverlay extends StatelessWidget {
  const BusyOverlay({
    super.key,
    required this.busy,
    required this.child,
    this.message,
  });

  final bool busy;
  final Widget child;
  final String? message;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      AbsorbPointer(absorbing: busy, child: child),
      if (busy)
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: busy ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: ColoredBox(
              color: context.colors.surface.withValues(alpha: 0.72),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.colors.outlineVariant),
                  ),
                  child: InlineLoader(label: message, size: 18),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Primary button that swaps its label for a spinner while [loading].
///
/// The button keeps its full height and width during the swap so the form does
/// not shift under the user's thumb the instant they tap it.
class LoadingFilledButton extends StatelessWidget {
  const LoadingFilledButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: loading ? null : onPressed,
    style: FilledButton.styleFrom(
      // Material dims a disabled button; while loading it is busy, not
      // unavailable, so it keeps full-strength brand colour.
      disabledBackgroundColor: loading
          ? context.colors.primary
          : context.colors.primary.withValues(alpha: 0.38),
      disabledForegroundColor: Colors.white,
    ),
    child: loading
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
              Text(label),
            ],
          ),
  );
}
