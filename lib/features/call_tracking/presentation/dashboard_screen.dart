import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../data/call_feed.dart';
import '../domain/call_entry.dart';
import 'call_detail_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({
    super.key,
    required this.onSeeAllCalls,
    this.pendingSyncCount = 0,
  });

  final VoidCallback onSeeAllCalls;

  /// Number of calls in the local outbox that have not yet been confirmed by
  /// the server. Passed in from [HomeShell] which watches [syncCountersProvider]
  /// so the badge stays in sync across tabs without re-reading the DB here.
  final int pendingSyncCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(callFeedProvider);
    final stats = ref.watch(todayStatsProvider);
    final session = ref.watch(authControllerProvider).value;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session?.displayName ?? 'Call Tracker'),
            Text(
              DateFormat('EEEE, d MMMM').format(DateTime.now()),
              style: context.text.bodySmall?.copyWith(
                color: context.palette.muted,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _SyncBadge(pending: pendingSyncCount),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(callFeedProvider.notifier).refresh(),
        child: feed.when(
          // Skeleton rather than a spinner: the dashboard's layout is known
          // ahead of the data, so the screen can settle in place instead of
          // jumping when the first read lands.
          loading: () => const DashboardSkeleton(),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not read calls',
            message: '$e',
            actionLabel: 'Try again',
            onAction: () => ref.read(callFeedProvider.notifier).refresh(),
          ),
          data: (state) {
            if (state.blocked) {
              return EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Call log access needed',
                message:
                    'Grant call log access so calls made on this device can be '
                    'tracked against your employee record.',
                actionLabel: 'Review permissions',
                onAction: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              );
            }

            final recent = state.entries.take(4).toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _TalkTimeCard(stats: stats),
                const SizedBox(height: 12),
                _StatsGrid(stats: stats),
                const SizedBox(height: 16),
                _RecordingSummary(stats: stats),
                const SizedBox(height: 20),
                SectionLabel(
                  'Recent calls',
                  trailing: TextButton(
                    onPressed: onSeeAllCalls,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('See all'),
                  ),
                ),
                const SizedBox(height: 8),
                if (recent.isEmpty)
                  AppCard(
                    child: Text(
                      'No calls recorded on this device yet.',
                      style: context.text.bodyMedium?.copyWith(
                        color: context.palette.muted,
                      ),
                    ),
                  )
                else
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < recent.length; i++) ...[
                          if (i > 0)
                            Padding(
                              padding: const EdgeInsets.only(left: 64),
                              child: Divider(
                                height: 1,
                                color: context.colors.outlineVariant,
                              ),
                            ),
                          CallRowTile(
                            entry: recent[i],
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    CallDetailScreen(entry: recent[i]),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.pending});

  final int pending;

  @override
  Widget build(BuildContext context) {
    final hasPending = pending > 0;
    final color = hasPending ? context.palette.waiting : context.palette.answered;
    final icon = hasPending ? Icons.cloud_upload_outlined : Icons.cloud_done_rounded;
    final label = hasPending ? '$pending pending' : 'Synced';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: context.text.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Talk time leads the dashboard: it is the number a manager actually asks
/// about, and it summarises the day in one glance.
class _TalkTimeCard extends StatelessWidget {
  const _TalkTimeCard({required this.stats});

  final CallStats stats;

  @override
  Widget build(BuildContext context) {
    final (hours, minutes) = Fmt.talkTime(stats.talkTimeSeconds);
    final total = stats.total == 0 ? 1 : stats.total;

    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total talk time',
            style: context.text.bodyMedium?.copyWith(
              color: context.palette.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              _BigNumber(hours),
              _Unit('h'),
              const SizedBox(width: 6),
              _BigNumber(minutes),
              _Unit('m'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 6,
                    child: Row(
                      children: [
                        Expanded(
                          flex: stats.incoming,
                          child: ColoredBox(color: context.palette.answered),
                        ),
                        Expanded(
                          flex: stats.outgoing,
                          child: ColoredBox(color: context.colors.primary),
                        ),
                        Expanded(
                          flex: stats.missed,
                          child: ColoredBox(color: context.palette.missed),
                        ),
                        // Keeps the track visible on a day with no calls.
                        if (stats.total == 0)
                          Expanded(
                            flex: total,
                            child: ColoredBox(color: context.palette.tint),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${stats.total} calls',
                style: context.text.bodySmall?.copyWith(
                  color: context.palette.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BigNumber extends StatelessWidget {
  const _BigNumber(this.value);
  final String value;

  @override
  Widget build(BuildContext context) => Text(
    value,
    style: context.text.displaySmall?.copyWith(
      fontSize: 40,
      height: 1.1,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.2,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

class _Unit extends StatelessWidget {
  const _Unit(this.value);
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 3),
    child: Text(
      value,
      style: context.text.titleLarge?.copyWith(
        color: context.palette.muted,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final CallStats stats;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _StatTile(
        icon: Icons.call_received_rounded,
        color: context.palette.answered,
        value: '${stats.incoming}',
        label: 'Incoming',
      ),
      _StatTile(
        icon: Icons.call_made_rounded,
        color: context.colors.primary,
        value: '${stats.outgoing}',
        label: 'Outgoing',
      ),
      _StatTile(
        icon: Icons.call_missed_rounded,
        color: context.palette.missed,
        value: '${stats.missed}',
        label: 'Missed',
      ),
      _StatTile(
        icon: Icons.schedule_rounded,
        color: context.palette.muted,
        value: Fmt.duration(stats.averageDurationSeconds),
        label: 'Avg. duration',
      ),
    ];

    // Deliberately NOT a GridView with childAspectRatio. A fixed ratio sets the
    // tile height from its width, so the content overflows the moment the
    // system font scale goes up — which it does on plenty of fleet devices.
    // IntrinsicHeight lets each row size to its tallest child instead, so the
    // tiles grow with the text rather than clipping it.
    return Column(
      children: [
        for (var i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: 12),
                Expanded(child: tiles[i + 1]),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        IconChip(icon: icon, color: color),
        const SizedBox(height: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: context.text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              label,
              style: context.text.bodySmall?.copyWith(
                color: context.palette.muted,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Recordings get their own row because "matched" and "needs review" demand
/// different human responses — one is done, the other is a task.
class _RecordingSummary extends StatelessWidget {
  const _RecordingSummary({required this.stats});

  final CallStats stats;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        IconChip(
          icon: Icons.graphic_eq_rounded,
          color: context.palette.answered,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recordings',
                style: context.text.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                stats.recordingsNeedReview > 0
                    ? '${stats.recordingsMatched} matched · '
                          '${stats.recordingsNeedReview} need review'
                    : '${stats.recordingsMatched} matched today',
                style: context.text.bodySmall?.copyWith(
                  color: context.palette.muted,
                ),
              ),
            ],
          ),
        ),
        if (stats.recordingsNeedReview > 0)
          StatusPill(
            label: '${stats.recordingsNeedReview}',
            color: context.palette.waiting,
          ),
      ],
    ),
  );
}
