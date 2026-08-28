import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(callFeedProvider).value;
    final entries = feed?.entries ?? const <CallEntry>[];
    final stats = CallStats.from(entries);

    // No backend is configured yet, so every record is genuinely queued. The
    // screen says that plainly rather than showing an invented "uploaded" count.
    final queued = entries.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          AppCard(
            padding: const EdgeInsets.all(18),
            borderColor: context.palette.waiting,
            child: Row(
              children: [
                IconChip(
                  icon: Icons.cloud_off_rounded,
                  color: context.palette.waiting,
                  size: 44,
                  iconSize: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nothing uploaded yet',
                        style: context.text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'No server is configured. Calls stay safely on this '
                        'device until one is.',
                        style: context.text.bodySmall?.copyWith(
                          color: context.palette.muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
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
                  count: 0,
                ),
                _divider(context),
                _QueueRow(
                  icon: Icons.schedule_rounded,
                  color: context.palette.waiting,
                  label: 'Waiting',
                  note: 'Queued on this device',
                  count: queued,
                ),
                _divider(context),
                _QueueRow(
                  icon: Icons.error_outline_rounded,
                  color: context.palette.missed,
                  label: 'Failed',
                  note: 'Will be retried automatically',
                  count: 0,
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
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
          OutlinedButton.icon(
            onPressed: () => ref.read(callFeedProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Rescan device'),
          ),
          const SizedBox(height: 16),
          const SectionLabel('Status'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _MetaRow(
                  icon: Icons.storage_rounded,
                  label: 'Records held locally',
                  value: '$queued',
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
                  value: 'Not configured',
                  valueColor: context.palette.waiting,
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
    );
  }

  Widget _divider(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 56),
    child: Divider(height: 1, color: context.colors.outlineVariant),
  );
}

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
