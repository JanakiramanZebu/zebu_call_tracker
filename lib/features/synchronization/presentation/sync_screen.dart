import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../background/data/background_service.dart';
import '../../background/presentation/background_card.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../data/sync_service.dart';

/// Sync screen — shows upload queue state, lets the user trigger a manual sync,
/// and keeps its counters fresh after the app is resumed from the background.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      // Re-read the DB counters and background status whenever the user
      // returns to the app — permissions or a background sweep may have
      // changed both while it was closed.
      ref.invalidate(syncCountersProvider);
      ref.invalidate(backgroundStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(callFeedProvider).value;
    final entries = feed?.entries ?? const <CallEntry>[];
    final stats = CallStats.from(entries);

    final syncCountersAsync = ref.watch(syncCountersProvider);
    final syncState = ref.watch(syncServiceProvider);
    final bgStatusAsync = ref.watch(backgroundStatusProvider);

    final counters = syncCountersAsync.asData?.value ??
        {
          'uploaded': 0,
          'waiting': entries.length,
          'failed': 0,
          'total': entries.length,
        };
    final uploaded = counters['uploaded'] ?? 0;
    final waiting = counters['waiting'] ?? entries.length;
    final failed = counters['failed'] ?? 0;
    final totalLocal = counters['total'] ?? entries.length;

    final isSyncing = syncState.isLoading;
    final lastSummary = syncState.asData?.value;
    final syncError = syncState.error ?? syncCountersAsync.error;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(syncCountersProvider);
          await ref.read(callFeedProvider.notifier).refresh();
          await ref.read(syncServiceProvider.notifier).triggerSync();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ── Status banner ──────────────────────────────────────────────
            AppCard(
              padding: const EdgeInsets.all(18),
              borderColor: AppConfig.hasServer
                  ? (uploaded > 0
                      ? context.palette.answered
                      : context.palette.waiting)
                  : context.palette.waiting,
              child: Row(
                children: [
                  IconChip(
                    icon: AppConfig.hasServer
                        ? (isSyncing
                            ? Icons.sync_rounded
                            : Icons.cloud_done_rounded)
                        : Icons.cloud_off_rounded,
                    color: AppConfig.hasServer
                        ? (uploaded > 0
                            ? context.palette.answered
                            : context.palette.tint)
                        : context.palette.waiting,
                    size: 44,
                    iconSize: 22,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isSyncing
                              ? 'Synchronizing now…'
                              : (uploaded > 0
                                  ? '$uploaded calls synchronized'
                                  : 'Backend Connected'),
                          style: context.text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          AppConfig.hasServer
                              ? 'Server: ${AppConfig.apiBaseUrl}'
                              : 'No server is configured. Calls stay on device.',
                          style: context.text.bodySmall?.copyWith(
                            color: context.palette.muted,
                            height: 1.4,
                          ),
                        ),
                        if (lastSummary?.clockSkewWarning case final warning?) ...[
                          const SizedBox(height: 4),
                          Text(
                            warning,
                            style: context.text.bodySmall?.copyWith(
                              color: context.palette.missed,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        if (syncError != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '$syncError',
                            style: context.text.bodySmall?.copyWith(
                              color: context.palette.missed,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Action buttons ─────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isSyncing
                        ? null
                        : () async {
                            await ref
                                .read(syncServiceProvider.notifier)
                                .triggerSync();
                            ref.invalidate(syncCountersProvider);
                          },
                    icon: isSyncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: Text(isSyncing ? 'Syncing…' : 'Sync Now'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    await ref.read(callFeedProvider.notifier).refresh();
                    ref.invalidate(syncCountersProvider);
                  },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 50),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Rescan'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Background capture ─────────────────────────────────────────
            const SectionLabel('Capture'),
            const SizedBox(height: 8),
            BackgroundStatusCard(statusAsync: bgStatusAsync),
            const SizedBox(height: 16),

            // ── Call metadata queue ────────────────────────────────────────
            const SectionLabel('Call metadata'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _QueueRow(
                    icon: Icons.check_rounded,
                    color: context.palette.answered,
                    label: 'Uploaded',
                    note: 'Confirmed by the server',
                    count: uploaded,
                  ),
                  _divider(context),
                  _QueueRow(
                    icon: Icons.schedule_rounded,
                    color: context.palette.waiting,
                    label: 'Waiting',
                    note: 'Queued on this device',
                    count: waiting,
                  ),
                  _divider(context),
                  _QueueRow(
                    icon: Icons.error_outline_rounded,
                    color: context.palette.missed,
                    label: 'Failed',
                    note: 'Will be retried automatically',
                    count: failed,
                    last: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Recordings queue ───────────────────────────────────────────
            const SectionLabel('Recordings'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _QueueRow(
                    icon: Icons.graphic_eq_rounded,
                    color: context.palette.answered,
                    label: 'Matched',
                    note: 'Associated with a call',
                    count: stats.recordingsMatched,
                  ),
                  _divider(context),
                  _QueueRow(
                    icon: Icons.help_outline_rounded,
                    color: context.palette.waiting,
                    label: 'Needs review',
                    note: 'Match was not clear enough',
                    count: stats.recordingsNeedReview,
                  ),
                  _divider(context),
                  _QueueRow(
                    icon: Icons.mic_off_outlined,
                    color: context.palette.muted,
                    label: 'No recording',
                    note: 'Missed and unrecorded calls',
                    count: stats.recordingsAbsent,
                    last: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Status meta ────────────────────────────────────────────────
            const SectionLabel('Status'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _MetaRow(
                    icon: Icons.storage_rounded,
                    label: 'Records held locally',
                    value: '$totalLocal',
                  ),
                  _divider(context),
                  _MetaRow(
                    icon: Icons.graphic_eq_rounded,
                    label: 'Recordings discovered',
                    value: '${feed?.recordingPoolSize ?? 0}',
                  ),
                  _divider(context),
                  _MetaRow(
                    icon: Icons.dns_rounded,
                    label: 'Server',
                    value: AppConfig.hasServer
                        ? (Uri.tryParse(AppConfig.apiBaseUrl)?.host.isNotEmpty ==
                                true
                            ? Uri.parse(AppConfig.apiBaseUrl).host
                            : AppConfig.apiBaseUrl)
                        : 'Not configured',
                    valueColor: AppConfig.hasServer
                        ? context.palette.answered
                        : context.palette.waiting,
                    last: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                'Calls are saved the moment they end. Nothing is lost while '
                'offline — the queue drains once a connection and a server are '
                'available.',
                style: context.text.bodySmall?.copyWith(
                  color: context.palette.muted,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 56),
        child: Divider(height: 1, color: context.colors.outlineVariant),
      );
}

// ── Private row widgets ───────────────────────────────────────────────────────

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.note,
    required this.count,
    this.last = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String note;
  final int count;
  final bool last;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Row(
          children: [
            IconChip(icon: icon, color: color, size: 32, iconSize: 17),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: context.text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    note,
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.muted,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '$count',
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: count == 0 ? context.palette.muted : color,
                letterSpacing: -0.4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool last;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: context.palette.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: context.text.bodyMedium)),
            Text(
              value,
              style: context.text.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: valueColor ?? context.palette.muted,
              ),
            ),
          ],
        ),
      );
}