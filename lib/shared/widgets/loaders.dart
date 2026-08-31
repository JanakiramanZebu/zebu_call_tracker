import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import 'ui_kit.dart';

/// Shimmering placeholder block for dark UI surfaces.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = AppTokens.r8,
  });

  const Skeleton.line({Key? key, double width = double.infinity})
      : this(key: key, width: width, height: 12, radius: 4);

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
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const base = Color(0xFF131C2C);
    const highlight = Color(0xFF1F2E45);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final x = _c.value * 3 - 1;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment(x - 1, 0),
                end: Alignment(x + 1, 0),
                colors: const [base, highlight, base],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Placeholder rows for the call list timeline.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 7, this.padding});

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
                    const Padding(
                      padding: EdgeInsets.only(left: 64),
                      child: Divider(
                        height: 1,
                        color: AppTokens.borderSubtle,
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
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Skeleton.circle(size: 36),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Skeleton(width: 140, height: 13),
                  SizedBox(height: 8),
                  Skeleton(width: 100, height: 11),
                ],
              ),
            ),
            SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Skeleton(width: 36, height: 11),
                SizedBox(height: 8),
                Skeleton(width: 22, height: 11),
              ],
            ),
          ],
        ),
      );
}

/// Dashboard-shaped placeholder: Hero metric + 6 compact tiles + Chart.
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          // Filter pills skeleton
          Row(
            children: [
              Skeleton(width: 76, height: 36, radius: 20),
              SizedBox(width: 8),
              Skeleton(width: 96, height: 36, radius: 20),
              SizedBox(width: 8),
              Skeleton(width: 90, height: 36, radius: 20),
            ],
          ),
          SizedBox(height: 16),

          // Date range skeleton
          Skeleton(width: 220, height: 18),
          SizedBox(height: 20),

          // Hero Metric Card skeleton
          AppCard(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(width: 90, height: 12),
                SizedBox(height: 12),
                Row(
                  children: [
                    Skeleton(width: 130, height: 34),
                    SizedBox(width: 12),
                    Skeleton(width: 70, height: 22, radius: 6),
                  ],
                ),
                SizedBox(height: 16),
                Skeleton(width: double.infinity, height: 42, radius: 6),
              ],
            ),
          ),
          SizedBox(height: 14),

          // 2x3 Metric Grid skeleton
          Row(
            children: [
              Expanded(child: _SkeletonTile()),
              SizedBox(width: 10),
              Expanded(child: _SkeletonTile()),
            ],
          ),
          SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _SkeletonTile()),
              SizedBox(width: 10),
              Expanded(child: _SkeletonTile()),
            ],
          ),
          SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _SkeletonTile()),
              SizedBox(width: 10),
              Expanded(child: _SkeletonTile()),
            ],
          ),
          SizedBox(height: 16),

          // Activity Chart placeholder
          AppCard(
            padding: EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(width: 110, height: 14),
                SizedBox(height: 16),
                Skeleton(width: double.infinity, height: 140, radius: 8),
              ],
            ),
          ),
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
            Row(
              children: [
                Skeleton.circle(size: 28),
                SizedBox(width: 8),
                Expanded(child: Skeleton(width: 60, height: 12)),
              ],
            ),
            SizedBox(height: 12),
            Skeleton(width: 48, height: 20, radius: 5),
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
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTokens.brandElectric,
            ),
          ),
          if (label case final text?) ...[
            const SizedBox(width: 10),
            Text(
              text,
              style: const TextStyle(
                color: AppTokens.textMuted,
                fontSize: 12.5,
              ),
            ),
          ],
        ],
      );
}

/// Dark scrim + centered loader for async blocking operations.
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
                duration: const Duration(milliseconds: 160),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.65),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: AppTokens.surface2,
                        borderRadius: BorderRadius.circular(AppTokens.r16),
                        border: Border.all(color: AppTokens.borderDefault),
                        boxShadow: AppTokens.cardShadow,
                      ),
                      child: InlineLoader(label: message, size: 20),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
}

/// Primary button with animated busy indicator.
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
          backgroundColor: AppTokens.brandElectric,
          disabledBackgroundColor:
              AppTokens.brandElectric.withValues(alpha: loading ? 0.8 : 0.35),
          disabledForegroundColor: Colors.white,
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Text(label),
                ],
              ),
      );
}
