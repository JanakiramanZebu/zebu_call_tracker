import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../recording/domain/recording_matcher.dart';
import '../data/call_feed.dart';
import '../domain/call_entry.dart';

class CallDetailScreen extends ConsumerWidget {
  const CallDetailScreen({super.key, required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = directionStyle(context, entry.row.direction);
    final started = entry.startedAtUtc;

    return Scaffold(
      appBar: AppBar(title: const Text('Call detail')),
      // This screen is pushed over the shell, so there is no NavigationBar
      // reserving the gesture inset — without SafeArea the last card runs
      // under the system bar.
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Header(entry: entry, dir: dir),
            const SizedBox(height: 14),
            if (started != null) _Timeline(entry: entry, started: started),
            const SizedBox(height: 14),
            _SimRow(entry: entry),
            const SizedBox(height: 14),
            _RecordingCard(entry: entry),
            const SizedBox(height: 14),
            _UploadCard(entry: entry),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry, required this.dir});

  final CallEntry entry;
  final ({IconData icon, Color color, String label}) dir;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(18),
    child: Row(
      children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.colors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            Fmt.initials(entry.hasName ? entry.displayTitle : null),
            style: context.text.titleLarge?.copyWith(
              color: context.colors.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.displayTitle,
                style: context.text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 19,
                ),
              ),
              const SizedBox(height: 2),
              // Full number here, masked in lists: reading it is a
              // deliberate act rather than something on show in a corridor.
              Text(
                Fmt.prettyNumber(entry.row.number),
                style: context.text.bodyMedium?.copyWith(
                  color: context.palette.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  StatusPill(
                    label: dir.label,
                    color: dir.color,
                    icon: dir.icon,
                  ),
                  StatusPill(
                    label: entry.isConnected ? 'Answered' : 'Not connected',
                    color: context.palette.muted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.entry, required this.started});

  final CallEntry entry;
  final DateTime started;

  @override
  Widget build(BuildContext context) {
    // The call log gives start and duration only. Answer time is derived from
    // the matched recording where one exists, and otherwise left out rather
    // than invented — a fabricated timestamp would look identical to a real one.
    final rec = entry.recording;
    final answeredAt = rec == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            rec.dateAddedEpochSeconds * 1000,
            isUtc: false,
          ).toUtc();
    final endedAt = started.add(
      Duration(
        seconds:
            entry.durationSeconds +
            (answeredAt?.difference(started).inSeconds ?? 0),
      ),
    );

    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Timeline'),
          const SizedBox(height: 16),
          _Step(
            label: 'Started',
            time: Fmt.fullTimestamp(started),
            note: entry.isConnected ? 'Ringing' : 'No answer',
            color: context.palette.muted,
          ),
          if (answeredAt != null)
            _Step(
              label: 'Answered',
              time: Fmt.fullTimestamp(answeredAt),
              note: 'After ${answeredAt.difference(started).inSeconds} seconds',
              color: context.palette.answered,
            ),
          _Step(
            label: 'Ended',
            time: Fmt.fullTimestamp(endedAt),
            note: entry.isConnected ? 'Call complete' : 'Never connected',
            color: context.palette.muted,
            last: true,
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: context.colors.outlineVariant),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Duration',
                style: context.text.bodyMedium?.copyWith(
                  color: context.palette.muted,
                ),
              ),
              Text(
                Fmt.duration(entry.durationSeconds),
                style: context.text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
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

class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.time,
    required this.note,
    required this.color,
    this.last = false,
  });

  final String label;
  final String time;
  final String note;
  final Color color;
  final bool last;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 12,
          child: Column(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: context.colors.outlineVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: context.text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      time,
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  note,
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _SimRow extends ConsumerWidget {
  const _SimRow({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sim = ref.watch(simInfoProvider).value;
    final accountId = entry.row.phoneAccountId;

    // Dual-SIM data is device dependent by design; when it is absent the row
    // says so instead of guessing a slot.
    final match = sim?.subscriptions.where(
      (s) => s.subscriptionId?.toString() == accountId,
    );
    final sub = (match != null && match.isNotEmpty) ? match.first : null;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          IconChip(icon: Icons.sim_card_outlined, color: context.palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub == null
                      ? 'SIM not identified'
                      : 'SIM ${(sub.simSlotIndex ?? 0) + 1} · ${sub.carrierName ?? "Unknown carrier"}',
                  style: context.text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  accountId == null
                      ? 'The call log carried no SIM reference'
                      : 'Subscription $accountId',
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
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

/// The recording block. This app records nothing — anything shown here was
/// written by the phone's own dialer and matched to this call on evidence.
class _RecordingCard extends StatelessWidget {
  const _RecordingCard({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context) {
    final style = recordingStyle(context, entry.match.status);
    final rec = entry.match.candidate;

    if (rec == null) {
      return AppCard(
        child: Row(
          children: [
            IconChip(icon: style.icon, color: style.color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    style.label,
                    style: context.text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.isConnected
                        ? entry.match.reason
                        : 'This call never connected, so there is nothing to record.',
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.muted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final ambiguous = entry.match.status == RecordingMatchStatus.ambiguous;

    return AppCard(
      padding: EdgeInsets.zero,
      borderColor: ambiguous ? context.palette.waiting : null,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                IconChip(
                  icon: ambiguous
                      ? Icons.help_outline_rounded
                      : Icons.play_arrow_rounded,
                  color: style.color,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recording',
                        style: context.text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${Fmt.duration(rec.durationSeconds.round())} · '
                        '${Fmt.fileSize(rec.sizeBytes)} · '
                        '${rec.mimeType?.split("/").last ?? "audio"}',
                        style: context.text.bodySmall?.copyWith(
                          color: context.palette.muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                StatusPill(label: style.label, color: style.color),
              ],
            ),
          ),
          Divider(height: 1, color: context.colors.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: context.palette.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ambiguous
                        ? 'More than one recording fits this call, so it has not '
                              'been associated automatically. A reviewer decides.'
                        : "Captured by the phone's own call recorder, then matched "
                              'on duration and timing · '
                              '${(entry.match.confidence * 100).toStringAsFixed(1)}% confidence.',
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.muted,
                      height: 1.5,
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

class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context) {
    final up = uploadStyle(context, entry.uploadState);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          IconChip(icon: up.icon, color: up.color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  up.label,
                  style: context.text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  // Honest about the current state of the system: there is no
                  // server yet, so nothing has actually been uploaded.
                  'Held on this device · no backend configured',
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
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
