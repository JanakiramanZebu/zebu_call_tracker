import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../data/background_service.dart';

/// Whether tracking is actually running while the app is closed.
///
/// This is the one status a user genuinely needs: the app can look perfectly
/// healthy in the foreground while the OS has been quietly deferring its
/// background work for a day. Rather than a green tick that means nothing, this
/// shows when the last capture happened and, when the OS is restricting it,
/// says so and offers the fix.
class BackgroundStatusCard extends ConsumerWidget {
  const BackgroundStatusCard({super.key, this.statusAsync, this.onOpenSettings});

  final AsyncValue<BackgroundStatus>? statusAsync;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<BackgroundStatus> status =
        statusAsync ?? ref.watch(backgroundStatusProvider);

    return status.when(
      loading: () => const AppCard(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Skeleton.circle(),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Skeleton(width: 120, height: 12),
                  SizedBox(height: 8),
                  Skeleton(width: 176, height: 11),
                ],
              ),
            ),
          ],
        ),
      ),
      error: (e, _) => AppCard(
        child: Text(
          'Background status unavailable',
          style: context.text.bodyMedium?.copyWith(
            color: context.palette.muted,
          ),
        ),
      ),
      data: (s) => _Body(status: s, onOpenSettings: onOpenSettings),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.status, this.onOpenSettings});

  final BackgroundStatus status;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restricted = !status.ignoringBatteryOptimizations;
    final blocked = status.lastRunStatus == 'blocked';

    final (color, label) = switch ((blocked, restricted)) {
      (true, _) => (context.palette.missed, 'Blocked'),
      (_, true) => (context.palette.waiting, 'Restricted'),
      _ => (context.palette.answered, 'Active'),
    };

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(
                icon: restricted || blocked
                    ? Icons.battery_alert_rounded
                    : Icons.autorenew_rounded,
                color: color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Background tracking',
                      style: context.text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(status),
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
              StatusPill(label: label, color: color),
            ],
          ),
          if (blocked) ...[
            const SizedBox(height: 12),
            _Note(
              color: context.palette.missed,
              text:
                  'The last background check could not read the call log. '
                  'Grant phone & call log access to resume tracking.',
            ),
          ] else if (restricted) ...[
            const SizedBox(height: 12),
            _Note(
              color: context.palette.waiting,
              text:
                  'Android is limiting this app in the background, so a call '
                  "may not be picked up until you next open it — by which time "
                  'your dialer may have deleted its recording.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: FilledButton(
                      onPressed: () => ref
                          .read(backgroundControllerProvider.notifier)
                          .requestBatteryExemption(),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                      ),
                      child: const Text('Allow background'),
                    ),
                  ),
                ),
                // Only offered where a vendor screen actually resolved; a
                // button that goes nowhere is worse than no button.
                if (status.hasVendorSettings) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: OutlinedButton(
                        onPressed: () => ref
                            .read(backgroundControllerProvider.notifier)
                            .openVendorSettings(),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                        child: Text('${status.manufacturer} settings'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (status.overflowed) ...[
            const SizedBox(height: 12),
            _Note(
              color: context.palette.waiting,
              text:
                  'The app went unopened long enough that some captured detail '
                  'was dropped. The calls themselves are still in the phone '
                  'log and were re-read.',
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle(BackgroundStatus s) {
    final lastRunAt = s.lastRunAtUtc;
    if (lastRunAt == null) return 'Waiting for the first check';
    final when = Fmt.relative(lastRunAt);
    return switch (s.lastRunReason) {
      'call-ended' => 'Last checked $when, after a call',
      'boot' => 'Last checked $when, after restart',
      'periodic' => 'Last checked $when, routine sweep',
      _ => 'Last checked $when',
    };
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: context.text.bodySmall?.copyWith(height: 1.5),
    ),
  );
}
