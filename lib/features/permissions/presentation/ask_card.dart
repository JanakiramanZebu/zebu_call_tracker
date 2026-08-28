import 'package:flutter/material.dart';

import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../domain/permission_ask.dart';

/// One permission, its rationale, and the control that grants it.
///
/// Shared by the first-run walkthrough and the Settings screen so the wording
/// and the affordance are identical wherever the user meets a permission.
class AskCard extends StatelessWidget {
  const AskCard({
    super.key,
    required this.ask,
    required this.onRequest,
    this.blocked = false,
    this.busy = false,
  });

  final PermissionAsk ask;
  final VoidCallback onRequest;

  /// Permanently denied: Android will not show the dialog again, so the button
  /// has to send the user to app settings instead of pretending to ask.
  final bool blocked;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = ask.granted
        ? context.palette.answered
        : blocked
        ? context.palette.missed
        : context.colors.primary;

    return AppCard(
      padding: const EdgeInsets.all(14),
      borderColor: ask.granted
          ? context.palette.answered.withValues(alpha: 0.35)
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconChip(
            icon: ask.granted ? Icons.check_rounded : ask.icon,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        ask.title,
                        style: context.text.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (ask.essential && !ask.granted)
                      StatusPill(
                        label: 'Required',
                        color: context.palette.missed,
                      )
                    else if (!ask.essential && !ask.granted)
                      StatusPill(
                        label: 'Optional',
                        color: context.palette.muted,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  ask.why,
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                    height: 1.5,
                  ),
                ),
                if (blocked && !ask.granted) ...[
                  const SizedBox(height: 8),
                  Text(
                    'You declined this twice, so Android will no longer show '
                    'the prompt. Turn it on in app settings.',
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.missed,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (ask.granted)
                  StatusPill(
                    label: 'Enabled',
                    color: context.palette.answered,
                    icon: Icons.check_rounded,
                  )
                else
                  SizedBox(
                    height: 36,
                    child: FilledButton(
                      onPressed: busy ? null : onRequest,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        backgroundColor: blocked
                            ? context.palette.missed
                            : context.colors.primary,
                        disabledBackgroundColor: busy
                            ? context.colors.primary
                            : context.colors.primary.withValues(alpha: 0.38),
                        disabledForegroundColor: Colors.white,
                        textStyle: context.text.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              blocked || ask.kind == AskKind.backgroundActivity
                                  ? 'Open settings'
                                  : 'Enable',
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The `n of 4` bar shown above both permission screens.
class AskProgress extends StatelessWidget {
  const AskProgress({super.key, required this.granted, required this.total});

  final int granted;
  final int total;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: total == 0 ? 0 : granted / total),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: context.palette.tint,
              color: granted == total
                  ? context.palette.answered
                  : context.colors.primary,
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Text(
        '$granted of $total',
        style: context.text.bodySmall?.copyWith(
          color: context.palette.muted,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

/// Placeholder shown while the first permission read is in flight. Matches the
/// card layout so the screen does not jump when the real state lands.
class AskSkeletonList extends StatelessWidget {
  const AskSkeletonList({super.key, this.count = 5});

  final int count;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
    physics: const NeverScrollableScrollPhysics(),
    children: [
      const Skeleton(width: double.infinity, height: 6, radius: 3),
      const SizedBox(height: 22),
      for (var i = 0; i < count; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        const AppCard(
          padding: EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton.circle(),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeleton(width: 132, height: 13),
                    SizedBox(height: 10),
                    Skeleton(width: double.infinity, height: 10),
                    SizedBox(height: 6),
                    Skeleton(width: 190, height: 10),
                    SizedBox(height: 14),
                    Skeleton(width: 86, height: 30, radius: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}
