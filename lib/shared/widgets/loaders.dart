import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import 'ui_kit.dart';

/// One pulse clock for every [Skeleton] beneath it.
///
/// Each skeleton used to own an `AnimationController.repeat()` — some twenty
/// tickers for one placeholder screen, all running the same sweep. The scope
/// runs one and the skeletons read it.
class ShimmerScope extends StatefulWidget {
  const ShimmerScope({super.key, required this.child});

  final Widget child;

  @override
  State<ShimmerScope> createState() => _ShimmerScopeState();
}

class _ShimmerScopeState extends State<ShimmerScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = _pulseController(this);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _Shimmer(animation: _c, child: widget.child);
}

class _Shimmer extends InheritedWidget {
  const _Shimmer({required this.animation, required super.child});

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_Shimmer old) => old.animation != animation;
}

AnimationController _pulseController(TickerProvider vsync) {
  final c = AnimationController(
    vsync: vsync,
    duration: const Duration(milliseconds: 1100),
  );
  final reduce = WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;
  if (!reduce) c.repeat(reverse: true);
  return c;
}

/// A placeholder block the shape of the content it stands in for.
///
/// A flat block whose fill breathes between two neighbouring surface shades.
/// Solid fills only: a sweeping gradient banded on low-precision GPUs.
/// Follows the nearest [ShimmerScope]; outside one it runs a clock of its own.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = AppTokens.r4,
  });

  const Skeleton.circle({Key? key, double size = 38})
    : this(key: key, width: size, height: size, radius: size / 2);

  final double width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  AnimationController? _own;
  late Animation<double> _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shared = context
        .dependOnInheritedWidgetOfExactType<_Shimmer>()
        ?.animation;
    _animation = shared ?? (_own ??= _pulseController(this));
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final base = z.sunken;
    final highlight = z.line;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) => Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(base, highlight, _animation.value),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        ),
      ),
    );
  }
}

/// Placeholder ledger rows for the call list.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 8});

  final int rows;

  @override
  Widget build(BuildContext context) => ShimmerScope(
    child: ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < rows; i++) ...[
          if (i > 0) const Divider(height: 1),
          const SkeletonCallRow(),
        ],
      ],
    ),
  );
}

/// One placeholder row in the shape of a [CallRowTile].
class SkeletonCallRow extends StatelessWidget {
  const SkeletonCallRow({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: AppTokens.gutter, vertical: 15),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Skeleton(width: 52, height: 12),
        SizedBox(width: 22),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 140, height: 14),
              SizedBox(height: 8),
              Skeleton(width: 110, height: 11),
            ],
          ),
        ),
        SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Skeleton(width: 34, height: 13),
            SizedBox(height: 8),
            Skeleton(width: 28, height: 10),
          ],
        ),
      ],
    ),
  );
}

/// Home-shaped placeholder: the brand summary panel, the outcome list and a
/// few ledger rows.
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ShimmerScope(
    child: ListView(
      padding: const EdgeInsets.only(bottom: 24),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter,
            20,
            AppTokens.gutter,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Skeleton(width: 54, height: 14),
                  SizedBox(width: 22),
                  Skeleton(width: 70, height: 14),
                  SizedBox(width: 22),
                  Skeleton(width: 50, height: 14),
                ],
              ),
              const SizedBox(height: 24),
              const Skeleton(width: 120, height: 52),
              const SizedBox(height: 12),
              const Skeleton(width: 200, height: 13),
              const SizedBox(height: 22),
              const Skeleton(width: double.infinity, height: 60),
              const SizedBox(height: 32),
              const Skeleton(width: 90, height: 16),
              const SizedBox(height: 14),
              const Skeleton(width: double.infinity, height: 8),
              const SizedBox(height: 12),
              for (var i = 0; i < 4; i++) ...[
                const SizedBox(height: 14),
                const Row(
                  children: [
                    Skeleton(width: 10, height: 10, radius: 3),
                    SizedBox(width: 12),
                    Skeleton(width: 110, height: 13),
                    Spacer(),
                    Skeleton(width: 30, height: 13),
                  ],
                ),
                const SizedBox(height: 14),
                if (i < 3) const Divider(height: 1),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SkeletonCallRow(),
        const Divider(height: 1),
        const SkeletonCallRow(),
      ],
    ),
  );
}

/// Small inline loader for footers and button refreshes.
class InlineLoader extends StatelessWidget {
  const InlineLoader({super.key, this.label, this.size = 16});

  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(strokeWidth: 2, color: z.accent),
        ),
        if (label case final text?) ...[
          const SizedBox(width: 10),
          Text(text, style: AppType.label.copyWith(color: z.ink3)),
        ],
      ],
    );
  }
}

/// Scrim + centred loader for async blocking operations.
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
  Widget build(BuildContext context) {
    final z = context.z;
    return Stack(
      children: [
        AbsorbPointer(absorbing: busy, child: child),
        if (busy)
          Positioned.fill(
            child: ColoredBox(
              color: z.overlay,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color: z.raised,
                    borderRadius: BorderRadius.circular(AppTokens.r14),
                  ),
                  child: InlineLoader(label: message, size: 20),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Primary footer button with a busy state.
///
/// A thin adapter over [ZButton], kept so call sites read the same.
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
  Widget build(BuildContext context) => ZButton(
    label: label,
    onPressed: onPressed,
    loading: loading,
    icon: icon,
    size: ZButtonSize.large,
  );
}
