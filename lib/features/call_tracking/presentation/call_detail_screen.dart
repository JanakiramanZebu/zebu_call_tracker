import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../recording/data/recording_player.dart';
import '../../recording/domain/recording_matcher.dart';
import '../../recording/presentation/recording_player_widget.dart';
import '../data/call_feed.dart';
import '../data/contact_history.dart';
import '../domain/call_entry.dart';

/// One call, in full: who it was, what happened, the recording if there is one,
/// and every other call with the same number.
///
/// Stateful only so that leaving the screen can stop playback — audio must not
/// keep running behind a screen the user has navigated away from.
class CallDetailScreen extends ConsumerStatefulWidget {
  const CallDetailScreen({super.key, required this.entry});

  final CallEntry entry;

  @override
  ConsumerState<CallDetailScreen> createState() => _CallDetailScreenState();
}

class _CallDetailScreenState extends ConsumerState<CallDetailScreen> {
  @override
  void dispose() {
    // The provider outlives this screen, so the player has to be told. Riverpod
    // forbids touching a ref during dispose, hence the post-frame hop.
    final container = ProviderScope.containerOf(context, listen: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      container.read(recordingPlayerProvider.notifier).stop();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final dir = directionStyle(context, entry.row.direction);
    final started = entry.startedAtUtc;
    final number = entry.row.number ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Call detail'),
        actions: [
          if (number.isNotEmpty)
            IconButton(
              onPressed: () => _copyNumber(context, number),
              icon: const Icon(Icons.copy_rounded, size: 20),
              tooltip: 'Copy number',
            ),
        ],
      ),
      // This screen is pushed over the shell, so there is no NavigationBar
      // reserving the gesture inset — without SafeArea the last card runs
      // under the system bar.
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Header(entry: entry, dir: dir),
            const SizedBox(height: 12),
            _ActionRow(entry: entry),
            const SizedBox(height: 14),
            _RecordingCard(entry: entry),
            const SizedBox(height: 14),
            if (started != null) ...[
              _Timeline(entry: entry, started: started),
              const SizedBox(height: 14),
            ],
            _SimRow(entry: entry),
            const SizedBox(height: 14),
            _UploadCard(entry: entry),
            if (number.isNotEmpty) ...[
              const SizedBox(height: 22),
              _HistorySection(number: number, currentEntry: entry),
            ],
          ],
        ),
      ),
    );
  }

  void _copyNumber(BuildContext context, String number) {
    Clipboard.setData(ClipboardData(text: number));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Number copied'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
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
                  StatusPill(label: dir.label, color: dir.color, icon: dir.icon),
                  StatusPill(
                    label: entry.isConnected
                        ? Fmt.duration(entry.durationSeconds)
                        : 'Not connected',
                    color: entry.isConnected
                        ? context.palette.answered
                        : context.palette.muted,
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

/// Call back and message, side by side under the header.
///
/// Dialling opens the system dialer with the number filled in rather than
/// placing the call directly: that needs no CALL_PHONE permission, and the
/// resulting call lands in the system log exactly like a manually dialled one,
/// which is what this app reconciles against.
class _ActionRow extends ConsumerWidget {
  const _ActionRow({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final number = entry.row.number;
    final callable = number != null && number.isNotEmpty;

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: callable
                  ? () async {
                      final ok = await ref
                          .read(nativeBridgeProvider)
                          .dialNumber(number);
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('No dialer available on this device'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  : null,
              icon: const Icon(Icons.call_rounded, size: 18),
              label: const Text('Call back'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: callable
                  ? () {
                      Clipboard.setData(ClipboardData(text: number));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Number copied'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
            ),
          ),
        ),
      ],
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
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
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
          // The transport is the point of the card, so it gets the width rather
          // than sharing a row with the metadata.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: RecordingPlayerBar(candidate: rec),
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

/// Every other call with this number, newest first, each with its recording.
///
/// The whole log is searched, not just the loaded page of the feed — a contact
/// history that stopped at "the last sixty calls overall" would be misleading.
class _HistorySection extends ConsumerWidget {
  const _HistorySection({required this.number, required this.currentEntry});

  final String number;
  final CallEntry currentEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(contactHistoryProvider(number));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('History with this number'),
        const SizedBox(height: 8),
        history.when(
          loading: () => const AppCard(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(
              children: [
                Row(
                  children: [
                    Skeleton.circle(size: 34),
                    SizedBox(width: 12),
                    Expanded(child: Skeleton(width: 140, height: 12)),
                    SizedBox(width: 12),
                    Skeleton(width: 44, height: 11),
                  ],
                ),
                SizedBox(height: 18),
                Row(
                  children: [
                    Skeleton.circle(size: 34),
                    SizedBox(width: 12),
                    Expanded(child: Skeleton(width: 110, height: 12)),
                    SizedBox(width: 12),
                    Skeleton(width: 44, height: 11),
                  ],
                ),
              ],
            ),
          ),
          error: (e, _) => AppCard(
            child: Text(
              'Could not read the history for this number.',
              style: context.text.bodySmall?.copyWith(
                color: context.palette.muted,
              ),
            ),
          ),
          data: (entries) {
            if (entries.isEmpty) {
              return AppCard(
                child: Text(
                  'No other calls with this number.',
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                  ),
                ),
              );
            }

            final stats = contactHistoryStats(entries);
            return Column(
              children: [
                _HistorySummary(stats: stats),
                const SizedBox(height: 10),
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 58),
                            child: Divider(
                              height: 1,
                              color: context.colors.outlineVariant,
                            ),
                          ),
                        _HistoryRow(
                          entry: entries[i],
                          // The call being viewed is marked rather than hidden,
                          // so its position in the relationship is visible.
                          isCurrent:
                              entries[i].row.dateMillis ==
                              currentEntry.row.dateMillis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HistorySummary extends StatelessWidget {
  const _HistorySummary({required this.stats});

  final CallStats stats;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        _Metric(value: '${stats.total}', label: 'Calls'),
        _Divider(),
        _Metric(
          value: Fmt.duration(stats.talkTimeSeconds),
          label: 'Talk time',
        ),
        _Divider(),
        _Metric(
          value: '${stats.missed}',
          label: 'Missed',
          color: stats.missed > 0 ? context.palette.missed : null,
        ),
        _Divider(),
        _Metric(
          value: '${stats.recordingsMatched}',
          label: 'Recorded',
          color: stats.recordingsMatched > 0
              ? context.palette.answered
              : null,
        ),
      ],
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label, this.color});

  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: context.text.bodySmall?.copyWith(
            color: context.palette.muted,
            fontSize: 11,
          ),
        ),
      ],
    ),
  );
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 28,
    margin: const EdgeInsets.symmetric(horizontal: 8),
    color: context.colors.outlineVariant,
  );
}

/// One past call. Plays inline: reviewing a relationship means skipping between
/// recordings, and bouncing out to a separate screen for each one makes that
/// tedious enough that people stop doing it.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.isCurrent});

  final CallEntry entry;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final dir = directionStyle(context, entry.row.direction);
    final rec = entry.recording;
    final started = entry.startedAtUtc;

    return Container(
      color: isCurrent ? context.palette.tint : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          IconChip(icon: dir.icon, color: dir.color, size: 32, iconSize: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        started == null
                            ? 'Unknown date'
                            : '${Fmt.dayHeading(started)}, ${Fmt.clock(started)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 8),
                      StatusPill(
                        label: 'This call',
                        color: context.colors.primary,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.isConnected
                      ? '${dir.label} · ${Fmt.duration(entry.durationSeconds)}'
                      : dir.label,
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (rec != null)
            RecordingPlayButton(candidate: rec)
          else
            Icon(
              entry.needsReview
                  ? Icons.help_outline_rounded
                  : Icons.mic_off_outlined,
              size: 18,
              color: entry.needsReview
                  ? context.palette.waiting
                  : context.palette.muted,
            ),
        ],
      ),
    );
  }
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
          ).toUtc();

    // Ended is start + ring time + talk time. The previous version added the
    // ring offset to a duration that already ran from `started`, pushing the
    // end past where the call actually finished.
    final ringSeconds = answeredAt == null
        ? 0
        : answeredAt.difference(started).inSeconds.clamp(0, 600);
    final endedAt = started.add(
      Duration(seconds: ringSeconds + entry.durationSeconds),
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
              note: 'After $ringSeconds seconds',
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
