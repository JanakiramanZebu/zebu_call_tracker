import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../domain/permission_ask.dart';

/// One permission card with rationale and granting control.
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
  final bool blocked;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = ask.granted
        ? AppTokens.success
        : blocked
            ? AppTokens.danger
            : AppTokens.brandElectric;

    return AppCard(
      padding: const EdgeInsets.all(14),
      borderColor: ask.granted
          ? AppTokens.success.withValues(alpha: 0.3)
          : (blocked ? AppTokens.danger.withValues(alpha: 0.3) : AppTokens.borderDefault),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconChip(
            icon: ask.granted ? Icons.check_rounded : ask.icon,
            color: color,
            size: 38,
            iconSize: 20,
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
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (ask.granted)
                      const StatusPill(
                        label: 'Granted',
                        color: AppTokens.success,
                        icon: Icons.check_rounded,
                      )
                    else if (ask.essential)
                      const StatusPill(
                        label: 'Required',
                        color: AppTokens.danger,
                      )
                    else
                      const StatusPill(
                        label: 'Optional',
                        color: AppTokens.textMuted,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  ask.why,
                  style: const TextStyle(
                    color: AppTokens.textMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                // Optional is a choice, so state what it costs rather than
                // leaving the user to guess whether skipping matters.
                if (!ask.granted && ask.costIfSkipped != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.arrow_right_rounded,
                        size: 16,
                        color: AppTokens.textDisabled,
                      ),
                      Expanded(
                        child: Text(
                          'If skipped: ${ask.costIfSkipped}',
                          style: const TextStyle(
                            color: AppTokens.textDisabled,
                            fontSize: 11.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (blocked && !ask.granted) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Permission declined twice. Please enable it in Android system settings.',
                    style: TextStyle(
                      color: AppTokens.danger,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
                if (!ask.granted) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 36,
                    child: FilledButton(
                      onPressed: busy ? null : onRequest,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        backgroundColor: blocked
                            ? AppTokens.danger
                            : AppTokens.brandElectric,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTokens.r8),
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
                                  ? 'Open Settings'
                                  : 'Grant Access',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress bar shown above permissions lists.
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
                  backgroundColor: AppTokens.surface2,
                  color: granted == total
                      ? AppTokens.success
                      : AppTokens.brandElectric,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$granted of $total granted',
            style: const TextStyle(
              color: AppTokens.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
}

/// Placeholder shown while the first permission read is in flight.
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
                  Skeleton.circle(size: 38),
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
