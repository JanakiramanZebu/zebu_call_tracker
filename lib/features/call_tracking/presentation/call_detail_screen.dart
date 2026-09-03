import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
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
class CallDetailScreen extends ConsumerStatefulWidget {
  const CallDetailScreen({super.key, required this.entry});

  final CallEntry entry;

  @override
  ConsumerState<CallDetailScreen> createState() => _CallDetailScreenState();
}

class _CallDetailScreenState extends ConsumerState<CallDetailScreen> {
  @override
  void dispose() {
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
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Call Detail',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 20,
            color: Colors.white,
          ),
        ),
        actions: [
          if (number.isNotEmpty)
            IconButton(
              onPressed: () => _copyNumber(context, number),
              icon: const Icon(Icons.copy_rounded, size: 19, color: AppTokens.textSecondary),
              tooltip: 'Copy number',
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // 1. Contact Hero Header
            _Header(entry: entry, dir: dir),
            const SizedBox(height: 12),

            // 2. Action Buttons (Call Back, Copy)
            _ActionRow(entry: entry),
            const SizedBox(height: 14),

            // 3. Audio Recording Section
            _RecordingCard(entry: entry),
            const SizedBox(height: 14),

            // 4. Visual Lifecycle Timeline
            if (started != null) ...[
              _Timeline(entry: entry, started: started),
              const SizedBox(height: 14),
            ],

            // 5. SIM & Device Info
            _SimRow(entry: entry),
            const SizedBox(height: 14),

            // 6. Server Sync & Outbox Status
            _UploadCard(entry: entry),

            // 7. Contact Interaction History
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
        content: Text('Phone number copied to clipboard'),
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
              width: 54,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTokens.surface2,
                shape: BoxShape.circle,
                border: Border.all(
                  color: dir.color.withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: Text(
                Fmt.initials(entry.hasName ? entry.displayTitle : null),
                style: TextStyle(
                  color: dir.color,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
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
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    Fmt.prettyNumber(entry.row.number),
                    style: const TextStyle(
                      color: AppTokens.textSecondary,
                      fontSize: 13.5,
                      fontFeatures: [FontFeature.tabularFigures()],
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
                        label: entry.isConnected
                            ? Fmt.duration(entry.durationSeconds)
                            : 'Not connected',
                        color: entry.isConnected
                            ? AppTokens.success
                            : AppTokens.textMuted,
                        icon: entry.isConnected
                            ? Icons.timer_outlined
                            : Icons.phone_disabled_rounded,
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
                            content: Text('No phone dialer app available'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  : null,
              icon: const Icon(Icons.call_rounded, size: 18),
              label: const Text('Call Back'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.brandElectric,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTokens.r12),
                ),
              ),
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
                          content: Text('Number copied to clipboard'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.copy_rounded, size: 18, color: Colors.white),
              label: const Text(
                'Copy Number',
                style: TextStyle(color: Colors.white),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTokens.borderDefault),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTokens.r12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecordingCard extends ConsumerWidget {
  const _RecordingCard({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = recordingStyle(context, entry.match.status);
    final rec = entry.match.candidate;

    if (rec == null) {
      return AppCard(
        child: Row(
          children: [
            IconChip(icon: style.icon, color: style.color, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    style.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.isConnected
                        ? entry.match.reason
                        : 'Call did not connect, no audio recorded.',
                    style: const TextStyle(
                      color: AppTokens.textMuted,
                      fontSize: 12.5,
                      height: 1.4,
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
      borderColor: ambiguous ? AppTokens.warning : null,
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
                      const Text(
                        'Call Recording',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${Fmt.fileSize(rec.sizeBytes)} · ${rec.mimeType?.split("/").last ?? "audio"}',
                        style: const TextStyle(
                          color: AppTokens.textMuted,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                StatusPill(label: style.label, color: style.color),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: RecordingPlayerBar(candidate: rec),
          ),
          const Divider(height: 1, color: AppTokens.borderSubtle),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: AppTokens.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ambiguous
                        ? 'More than one recording fits this call. Pick the right '
                            'one below — nothing is uploaded until you do.'
                        : 'Matched by native audio ingestion engine (${(entry.match.confidence * 100).toStringAsFixed(1)}% match confidence).',
                    style: const TextStyle(
                      color: AppTokens.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (ambiguous) _CandidatePicker(entry: entry),
        ],
      ),
    );
  }
}

/// The choice behind "Review required".
///
/// The matcher already ranks every candidate that survived its hard gates and
/// records why each scored as it did; all of that used to be computed and
/// dropped, leaving a warning badge with nothing behind it. This shows the
/// shortlist and lets a person settle it.
class _CandidatePicker extends ConsumerStatefulWidget {
  const _CandidatePicker({required this.entry});

  final CallEntry entry;

  @override
  ConsumerState<_CandidatePicker> createState() => _CandidatePickerState();
}

class _CandidatePickerState extends ConsumerState<_CandidatePicker> {
  bool _busy = false;

  Future<void> _choose(RecordingCandidate candidate) async {
    final startedAt = widget.entry.row.dateMillis;
    if (startedAt == null || _busy) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(callFeedProvider.notifier).confirmRecording(
            startedAtMillis: startedAt,
            rawNumber: widget.entry.row.number,
            candidate: candidate,
          );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Recording attached and queued for upload'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not attach that recording: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ranked = widget.entry.match.rankedCandidates;
    if (ranked.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: AppTokens.borderSubtle),
        for (final option in ranked.take(4))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.candidate.displayName ??
                            'Recording ${option.candidate.mediaStoreId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // The evidence, not just the verdict. Someone breaking a
                      // tie needs to see what made it close.
                      Text(
                        '${(option.confidence * 100).toStringAsFixed(0)}% · '
                        '${Fmt.duration(option.candidate.durationSeconds.round())} · '
                        '${option.signals}',
                        style: const TextStyle(
                          color: AppTokens.textMuted,
                          fontSize: 11.5,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                RecordingPlayButton(candidate: option.candidate, size: 28),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: _busy ? null : () => _choose(option.candidate),
                  child: const Text('Use'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.entry, required this.started});

  final CallEntry entry;
  final DateTime started;

  @override
  Widget build(BuildContext context) {
    final rec = entry.recording;
    final answeredAt = rec == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            rec.dateAddedEpochSeconds * 1000,
          ).toUtc();

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
          const SectionLabel('Lifecycle Timeline'),
          const SizedBox(height: 16),
          _Step(
            label: 'Call Initiated',
            time: Fmt.fullTimestamp(started),
            note: entry.isConnected ? 'Ringing / alerting' : 'No connection established',
            color: AppTokens.brandElectric,
          ),
          if (answeredAt != null)
            _Step(
              label: 'Call Connected',
              time: Fmt.fullTimestamp(answeredAt),
              note: 'Answered after $ringSeconds seconds',
              color: AppTokens.success,
            ),
          _Step(
            label: 'Call Terminated',
            time: Fmt.fullTimestamp(endedAt),
            note: entry.isConnected ? 'Call completed' : 'Disconnected',
            color: AppTokens.textMuted,
            last: true,
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppTokens.borderSubtle),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Duration',
                style: TextStyle(color: AppTokens.textMuted, fontSize: 13),
              ),
              Text(
                Fmt.duration(entry.durationSeconds),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: Colors.white,
                  letterSpacing: -0.3,
                  fontFeatures: [FontFeature.tabularFigures()],
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
              width: 14,
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
                        color: AppTokens.borderSubtle,
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
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          time,
                          style: const TextStyle(
                            color: AppTokens.textMuted,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: const TextStyle(
                        color: AppTokens.textSecondary,
                        fontSize: 12,
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

    final match = sim?.subscriptions.where(
      (s) => s.subscriptionId?.toString() == accountId,
    );
    final sub = (match != null && match.isNotEmpty) ? match.first : null;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          const IconChip(icon: Icons.sim_card_outlined, color: AppTokens.brandIndigo, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub == null
                      ? 'Default SIM Slot'
                      : 'SIM ${(sub.simSlotIndex ?? 0) + 1} · ${sub.carrierName ?? "Active Carrier"}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                Text(
                  accountId == null
                      ? 'Captured via native telephony bridge'
                      : 'Subscription Identifier: $accountId',
                  style: const TextStyle(
                    color: AppTokens.textMuted,
                    fontSize: 12,
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
          IconChip(icon: up.icon, color: up.color, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cloud Sync: ${up.label}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                Text(
                  entry.uploadState == UploadState.uploaded
                      ? 'Confirmed by backend intelligence server'
                      : 'Stored securely in local outbox queue',
                  style: const TextStyle(
                    color: AppTokens.textMuted,
                    fontSize: 12,
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
        const SectionLabel('Contact History'),
        const SizedBox(height: 8),
        history.when(
          loading: () => const AppCard(
            padding: EdgeInsets.all(16),
            child: InlineLoader(label: 'Loading interaction history...'),
          ),
          error: (e, _) => AppCard(
            child: Text(
              'Could not read history for this number.',
              style: const TextStyle(color: AppTokens.textMuted),
            ),
          ),
          data: (entries) {
            if (entries.isEmpty) {
              return const AppCard(
                child: Text(
                  'No previous interactions recorded with this number.',
                  style: TextStyle(color: AppTokens.textMuted, fontSize: 13),
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
                          const Padding(
                            padding: EdgeInsets.only(left: 58),
                            child: Divider(
                              height: 1,
                              color: AppTokens.borderSubtle,
                            ),
                          ),
                        _HistoryRow(
                          entry: entries[i],
                          isCurrent: entries[i].row.dateMillis ==
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
            _Metric(value: '${stats.total}', label: 'Total Calls'),
            _Divider(),
            _Metric(
              value: Fmt.duration(stats.talkTimeSeconds),
              label: 'Talk Time',
            ),
            _Divider(),
            _Metric(
              value: '${stats.missed}',
              label: 'Missed',
              color: stats.missed > 0 ? AppTokens.danger : null,
            ),
            _Divider(),
            _Metric(
              value: '${stats.recordingsMatched}',
              label: 'Recordings',
              color: stats.recordingsMatched > 0 ? AppTokens.success : null,
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
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: color ?? Colors.white,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: AppTokens.textMuted,
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
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppTokens.borderSubtle,
      );
}

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
      color: isCurrent ? AppTokens.brandElectric.withValues(alpha: 0.08) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          IconChip(icon: dir.icon, color: dir.color, size: 30, iconSize: 15),
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
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 6),
                      const StatusPill(
                        label: 'Active',
                        color: AppTokens.brandElectric,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.isConnected
                      ? '${dir.label} · ${Fmt.duration(entry.durationSeconds)}'
                      : dir.label,
                  style: const TextStyle(
                    color: AppTokens.textMuted,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (rec != null)
            RecordingPlayButton(candidate: rec, size: 30)
          else
            Icon(
              entry.needsReview
                  ? Icons.help_outline_rounded
                  : Icons.mic_off_outlined,
              size: 16,
              color: entry.needsReview
                  ? AppTokens.warning
                  : AppTokens.textMuted,
            ),
        ],
      ),
    );
  }
}
