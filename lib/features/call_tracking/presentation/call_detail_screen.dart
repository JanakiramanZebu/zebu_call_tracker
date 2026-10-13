import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app.dart';
import '../../../core/platform/native_call_bridge.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../recording/data/recording_player.dart';
import '../../recording/data/server_recording.dart';
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
    final z = context.z;
    final entry = widget.entry;
    final number = entry.row.number ?? '';

    return Scaffold(
      backgroundColor: z.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Text(
          'Call details',
          style: AppType.bodyStrong.copyWith(fontSize: 16, color: z.ink2),
        ),
      ),
      // Sides only: the list scrolls behind the system navigation bar and
      // ends with a spacer the height of it, so the last row is never hidden
      // under the nav buttons yet nothing is clipped above them either.
      body: SafeArea(
        top: false,
        bottom: false,
        // Slivers so the history below — up to a hundred past calls — is
        // built as it scrolls into view, not all at once on open.
        child: CustomScrollView(
          slivers: [
            SliverList.list(
              children: [
                _Header(entry: entry),
                _CallFacts(entry: entry),
                _CrmNote(entry: entry),
                const SizedBox(height: 24),
                _RecordingSection(entry: entry),
              ],
            ),
            if (number.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.only(top: 28),
                sliver: _HistorySection(number: number, currentEntry: entry),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: context.safeBottom + 32),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who the call was with: the outcome line, the name, the full number, and
/// the two things a person does next — call back or copy the number.
class _Header extends StatelessWidget {
  const _Header({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final dir = directionStyle(context, entry.row.direction);
    final noAnswer =
        entry.row.direction == CallDirection.outgoing && !entry.isConnected;
    final color = noAnswer ? z.noAnswer : dir.color;
    final line = noAnswer
        ? 'Outgoing call, not answered'
        : switch (entry.row.direction) {
            CallDirection.incoming => 'Incoming call',
            CallDirection.outgoing => 'Outgoing call',
            CallDirection.missed => 'Missed call',
            CallDirection.rejected => 'Rejected call',
            CallDirection.blocked => 'Blocked call',
            CallDirection.voicemail => 'Voicemail',
            CallDirection.unknown => 'Call',
          };

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 6, AppTokens.gutter, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CallGlyph(dir.glyph, size: 13, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  line,
                  style: AppType.labelStrong.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Semantics(
            header: true,
            child: Text(
              entry.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppType.titleLarge.copyWith(
                color: entry.hasName ? z.ink : z.ink2,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Flexible(
                child: Text(
                  Fmt.prettyNumber(entry.row.number),
                  style: AppType.tabular(AppType.body).copyWith(color: z.ink2),
                ),
              ),
              if (entry.isWhatsApp) ...[
                const SizedBox(width: 8),
                const WhatsAppTag(),
              ],
            ],
          ),
          const SizedBox(height: 20),
          _ActionRow(entry: entry),
        ],
      ),
    );
  }
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
          child: ZButton(
            label: 'Call back',
            icon: Icons.call_outlined,
            onPressed: callable
                ? () async {
                    final ok = await ref
                        .read(nativeBridgeProvider)
                        .dialNumber(number);
                    if (!ok && context.mounted) {
                      showToast(context, 'No phone dialer app available');
                    }
                  }
                : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ZButton(
            label: 'Copy number',
            variant: ZButtonVariant.secondary,
            onPressed: callable
                ? () {
                    Clipboard.setData(ClipboardData(text: number));
                    showToast(context, 'Number copied to clipboard');
                  }
                : null,
          ),
        ),
      ],
    );
  }
}

/// When the call was answered and when it ended.
///
/// The answer time comes from the matched recording: the recorder starts when
/// the other side picks up, so the file's start is the best reading the phone
/// has. Without a recording there is none, and only the end can be estimated.
({DateTime? answeredAt, int ringSeconds, DateTime endedAt}) _timing(
  CallEntry entry,
  DateTime started,
) {
  final rec = entry.recording;
  final answeredAt = rec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          // The matcher's own reading of the stamps when it scored this
          // file; a stored match carries none, so the file is read alone.
          switch (entry.match.signals?.endStamped) {
                true => rec.endStampedStartEpochSeconds,
                false => rec.dateAddedEpochSeconds,
                null => rec.likelyStartEpochSeconds,
              } *
              1000,
        ).toUtc();

  final ringSeconds = answeredAt == null
      ? 0
      : answeredAt.difference(started).inSeconds.clamp(0, 600);
  final endedAt = started.add(
    Duration(seconds: ringSeconds + entry.durationSeconds),
  );
  return (answeredAt: answeredAt, ringSeconds: ringSeconds, endedAt: endedAt);
}

/// Opens the Sync tab, which explains what is holding a call up.
void _openSync(BuildContext context, WidgetRef ref) {
  Navigator.of(context).popUntil((route) => route.isFirst);
  ref.read(homeTabProvider.notifier).show(HomeTab.sync);
}

/// The call's details as a ruled two-column slip: when, how long, which SIM,
/// whether Zebu CRM has it, and whether a recording is attached.
///
/// A fact the phone cannot supply — no start time, no SIM it can name, no
/// answer time without a recording — is left out rather than shown blank.
class _CallFacts extends ConsumerWidget {
  const _CallFacts({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final started = entry.startedAtUtc;

    // Which SIM carried the call, shown only when the phone can say. A card
    // reading "Default SIM Slot" over a subscription ID told nobody anything.
    final accountId = entry.row.phoneAccountId;
    final sub = ref
        .watch(simInfoProvider)
        .value
        ?.subscriptions
        .where((s) => s.subscriptionId?.toString() == accountId)
        .firstOrNull;
    final carrier = sub?.carrierName;
    final sim = sub == null
        ? null
        : [
            'SIM ${(sub.simSlotIndex ?? 0) + 1}',
            if (carrier != null && carrier.isNotEmpty) carrier,
          ].join(', ');

    // A call that could not be sent opens the Sync tab, as the upload card
    // this cell replaced did; [_CrmNote] below says so in words.
    final crm = switch (entry.uploadState) {
      UploadState.uploaded => _FactData('Zebu CRM', 'Delivered'),
      UploadState.uploading => _FactData('Zebu CRM', 'Sending…', color: z.accent),
      UploadState.pending =>
        _FactData('Zebu CRM', 'Waiting to send', color: z.warn),
      UploadState.failed => _FactData(
        'Zebu CRM',
        "Couldn't send yet",
        color: z.danger,
        onTap: () => _openSync(context, ref),
      ),
    };

    final recording = switch (entry.match.status) {
      RecordingMatchStatus.matched => _FactData('Recording', 'Attached'),
      RecordingMatchStatus.ambiguous =>
        _FactData('Recording', 'Pick one', color: z.warn),
      _ => _FactData(
        'Recording',
        entry.isConnected ? 'None found' : 'Not applicable',
        color: z.ink3,
      ),
    };

    final List<_FactData> facts;
    if (entry.isConnected) {
      final t = started == null ? null : _timing(entry, started);
      facts = [
        if (started != null) _FactData('Date', Fmt.dayHeading(started)),
        _FactData('Talk time', Fmt.duration(entry.durationSeconds)),
        if (started != null) _FactData('Started', Fmt.clock(started)),
        if (t != null) _FactData('Ended', Fmt.clock(t.endedAt)),
        if (t?.answeredAt != null)
          _FactData('Answered after', '${t!.ringSeconds}s'),
        if (sim != null) _FactData('SIM', sim),
        crm,
        recording,
      ];
    } else {
      facts = [
        if (started != null) _FactData('Date', Fmt.dayHeading(started)),
        if (started != null) _FactData('Rang at', Fmt.clock(started)),
        _FactData(
          'Result',
          switch (entry.row.direction) {
            CallDirection.missed => 'Missed',
            CallDirection.rejected => 'Declined',
            CallDirection.blocked => 'Blocked',
            CallDirection.voicemail => 'Voicemail',
            _ => 'Not answered',
          },
        ),
        if (sim != null) _FactData('SIM', sim),
        crm,
        recording,
      ];
    }

    return _FactSheet(facts: facts);
  }
}

/// One cell of [_FactSheet]. [onTap] makes the cell open something.
class _FactData {
  const _FactData(this.label, this.value, {this.color, this.onTap});

  final String label;
  final String value;
  final Color? color;
  final VoidCallback? onTap;
}

/// A [FactGrid] whose cells can be tapped.
///
/// The shared grid is display-only, and the Zebu CRM cell has to lead to the
/// Sync tab when the call could not be sent — as the upload card it replaced
/// did.
class _FactSheet extends StatelessWidget {
  const _FactSheet({required this.facts});

  final List<_FactData> facts;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final side = BorderSide(color: z.line);
    final rows = <List<_FactData>>[
      for (var i = 0; i < facts.length; i += 2)
        facts.sublist(i, i + 2 > facts.length ? facts.length : i + 2),
    ];

    Widget cell(_FactData? f, {required bool left, required bool lastRow}) {
      final content = f == null
          ? const SizedBox.shrink()
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.label,
                        style: AppType.captionStrong.copyWith(color: z.ink3),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        f.value,
                        style: AppType.tabular(
                          AppType.bodyMedium,
                        ).copyWith(color: f.color ?? z.ink),
                      ),
                    ],
                  ),
                ),
                if (f.onTap != null)
                  Icon(Icons.chevron_right_rounded, size: 18, color: z.ink3),
              ],
            );

      return Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              right: left ? side : BorderSide.none,
              bottom: lastRow ? BorderSide.none : side,
            ),
          ),
          child: MergeSemantics(
            child: Semantics(
              button: f?.onTap != null,
              child: InkWell(
                onTap: f?.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.gutter,
                    vertical: 13,
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: z.raised,
        border: Border.symmetric(horizontal: side),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var r = 0; r < rows.length; r++)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    cell(rows[r][0], left: true, lastRow: r == rows.length - 1),
                    cell(
                      rows[r].length > 1 ? rows[r][1] : null,
                      left: false,
                      lastRow: r == rows.length - 1,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What a call that is not yet in Zebu CRM is waiting on, under the slip.
/// Nothing for a call that is delivered or on its way.
class _CrmNote extends ConsumerWidget {
  const _CrmNote({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final style = AppType.label.copyWith(
      color: z.ink3,
      fontWeight: FontWeight.w400,
      height: 1.5,
    );

    switch (entry.uploadState) {
      case UploadState.uploaded:
      case UploadState.uploading:
        return const SizedBox.shrink();
      case UploadState.pending:
        return Padding(
          padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 10, AppTokens.gutter, 0),
          child: Text(
            'Saved on this phone. It will be sent automatically.',
            style: style,
          ),
        );
      case UploadState.failed:
        return Semantics(
          button: true,
          child: InkWell(
            onTap: () => _openSync(context, ref),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppTokens.minTap),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.gutter,
                  10,
                  AppTokens.gutter,
                  10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Saved on this phone. Tap to see what is holding it up.',
                        style: style,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded, size: 18, color: z.ink3),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }
}

/// The recording: the player for the matched file, the shortlist when more
/// than one file fits, or why there is none — with the CRM's copy as a
/// fallback once the call is on the server.
class _RecordingSection extends ConsumerWidget {
  const _RecordingSection({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final rec = entry.match.candidate;
    final ambiguous = entry.match.status == RecordingMatchStatus.ambiguous;

    final String? note;
    if (rec == null) {
      note = null;
    } else if (ambiguous) {
      note = 'Pick a recording';
    } else {
      final length = Fmt.duration(rec.durationSeconds.round());
      note = entry.uploadState == UploadState.uploaded
          ? '$length, sent with the call'
          : length;
    }

    final header = SectionHeader(
      'Recording',
      trailing: note == null
          ? null
          : Text(
              note,
              style: ambiguous
                  ? AppType.label.copyWith(color: z.warn)
                  : null,
            ),
    );

    if (rec == null) {
      final outboxKey = entry.isConnected ? outboxKeyFor(entry) : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.gutter),
            child: Text(
              entry.isConnected
                  ? 'No recording was found on this phone for this call.'
                  : "This call didn't connect, so there is no recording.",
              style: AppType.small.copyWith(color: z.ink3),
            ),
          ),
          // The dialer may have deleted its copy after it was sent; the
          // CRM's is still there. Offered only for a call the server has.
          if (outboxKey != null) _ServerRecordingRow(outboxKey: outboxKey),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.gutter),
          child: RecordingPlayerBar(candidate: rec),
        ),
        if (ambiguous) ...[
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.gutter),
            child: InfoBanner(
              tone: BannerTone.warning,
              message:
                  'More than one recording fits this call. Pick the right '
                  'one below — nothing is sent until you do.',
            ),
          ),
          const SizedBox(height: 12),
          _CandidatePicker(entry: entry),
        ],
      ],
    );
  }
}

/// Plays the CRM's copy of a recording this phone no longer has (§7).
///
/// Nothing is shown until the call is known to be on the server, and nothing
/// is fetched until the user taps play: each play costs a call lookup and a
/// playback token, and is written to the server's audit trail.
class _ServerRecordingRow extends ConsumerWidget {
  const _ServerRecordingRow({required this.outboxKey});

  final String outboxKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverCallId = ref.watch(serverCallIdProvider(outboxKey)).value;
    if (serverCallId == null) return const SizedBox.shrink();

    final z = context.z;
    final playback = ref.watch(recordingPlayerProvider);
    final mine = playback.isForRemote(serverCallId);
    final playing = mine && playback.playing;
    final loading = mine && playback.loading;
    final error = mine ? playback.error : null;
    final total = playback.duration.inMilliseconds;
    final progress = mine && total > 0
        ? (playback.position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 16, AppTokens.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Semantics(
                button: true,
                label: playing ? 'Pause' : 'Play recording from Zebu CRM',
                excludeSemantics: true,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Material(
                    color: z.primary,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkResponse(
                      containedInkWell: true,
                      customBorder: const CircleBorder(),
                      highlightColor: Colors.transparent,
                      splashColor: z.onPrimary.withValues(alpha: 0.16),
                      onTap: loading
                          ? null
                          : () => ref
                                .read(recordingPlayerProvider.notifier)
                                .toggleRemote(
                                  serverCallId,
                                  () => ref
                                      .read(serverRecordingRepositoryProvider)
                                      .streamUrlFor(serverCallId),
                                ),
                      child: Center(
                        child: loading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: z.onPrimary,
                                ),
                              )
                            : Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: z.onPrimary,
                                size: 24,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Play from Zebu CRM', style: AppType.smallStrong),
                    const SizedBox(height: 6),
                    if (mine && total > 0) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(1),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          color: z.accent,
                          backgroundColor: z.lineStrong,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            Fmt.stopwatch(playback.position.inSeconds),
                            style: AppType.tabular(
                              AppType.caption,
                            ).copyWith(color: z.ink2),
                          ),
                          Text(
                            Fmt.stopwatch(playback.duration.inSeconds),
                            style: AppType.tabular(
                              AppType.caption,
                            ).copyWith(color: z.ink3),
                          ),
                        ],
                      ),
                    ] else
                      Text(
                        'Streams the copy that was sent from this phone.',
                        style: AppType.caption.copyWith(color: z.ink3),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: AppType.label.copyWith(
                  color: z.danger,
                  fontWeight: FontWeight.w400,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The choice behind "Pick a recording".
///
/// The matcher already ranks every candidate that survived its hard gates; all
/// of that used to be computed and dropped, leaving a warning badge with
/// nothing behind it. This shows the shortlist — as what a person can check
/// against their memory of the call, its length and when it was recorded, not
/// as scores — and lets them settle it.
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
    try {
      await ref.read(callFeedProvider.notifier).confirmRecording(
            startedAtMillis: startedAt,
            rawNumber: widget.entry.row.number,
            candidate: candidate,
          );
      if (!mounted) return;
      showToast(context, 'Recording attached. It will be sent with this call.');
      if (mounted) Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      showToast(context, "Couldn't attach that recording. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final ranked = widget.entry.match.rankedCandidates;
    if (ranked.isEmpty) return const SizedBox.shrink();
    final options = ranked.take(4).toList();

    return ListGroup(
      children: [
        for (final (i, option) in options.indexed)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.gutter,
              10,
              AppTokens.gutter - 4,
              10,
            ),
            child: Row(
              children: [
                RecordingPlayButton(candidate: option.candidate, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              option.candidate.displayName ??
                                  'Recording at ${_recordedAt(option.candidate)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.smallStrong,
                            ),
                          ),
                          if (i == 0) ...[
                            const SizedBox(width: 8),
                            StatusPill(label: 'Best match', color: z.ok),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${Fmt.duration(option.candidate.durationSeconds.round())} long, '
                        'recorded ${_recordedAt(option.candidate)}',
                        style: AppType.tabular(
                          AppType.caption,
                        ).copyWith(color: z.ink3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ZButton(
                  label: 'Use',
                  semanticLabel: 'Use this recording',
                  variant: ZButtonVariant.outline,
                  size: ZButtonSize.small,
                  expand: false,
                  onPressed: _busy ? null : () => _choose(option.candidate),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _recordedAt(RecordingCandidate c) => Fmt.clock(
      DateTime.fromMillisecondsSinceEpoch(
        c.likelyStartEpochSeconds * 1000,
        isUtc: true,
      ),
    );

/// Every other call with this number, as slivers so the rows build lazily.
class _HistorySection extends ConsumerWidget {
  const _HistorySection({required this.number, required this.currentEntry});

  final String number;
  final CallEntry currentEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final history = ref.watch(contactHistoryProvider(number));

    Widget box(Widget child) => SliverToBoxAdapter(child: child);
    Widget message(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 4, AppTokens.gutter, 0),
      child: Text(text, style: AppType.small.copyWith(color: z.ink3)),
    );

    final summary = switch (history) {
      AsyncData(:final value) when value.isNotEmpty => () {
        final stats = contactHistoryStats(value);
        final calls = '${stats.total} ${stats.total == 1 ? 'call' : 'calls'}';
        return stats.talkTimeSeconds > 0
            ? '$calls, ${Fmt.duration(stats.talkTimeSeconds)}'
            : calls;
      }(),
      _ => null,
    };

    return SliverMainAxisGroup(
      slivers: [
        box(
          SectionHeader(
            'Earlier with this number',
            trailing: summary == null ? null : Text(summary),
          ),
        ),
        box(const SizedBox(height: 10)),
        ...history.when(
          loading: () => [
            box(
              const Padding(
                padding: EdgeInsets.fromLTRB(AppTokens.gutter, 4, AppTokens.gutter, 0),
                child: InlineLoader(label: 'Loading past calls…'),
              ),
            ),
          ],
          error: (_, _) => [box(message("Couldn't load past calls."))],
          data: (entries) {
            if (entries.isEmpty) {
              return [box(message('No other calls with this number.'))];
            }

            return [
              SliverList.builder(
                itemCount: entries.length,
                itemBuilder: (context, i) => CardListSlice(
                  first: i == 0,
                  last: i == entries.length - 1,
                  child: _HistoryRow(
                    entry: entries[i],
                    isCurrent: entries[i].row.dateMillis ==
                        currentEntry.row.dateMillis,
                  ),
                ),
              ),
            ];
          },
        ),
      ],
    );
  }
}

/// One past call as a ledger row: the date, the outcome, the length on the
/// right, and its recording if there is one.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.isCurrent});

  final CallEntry entry;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final dir = directionStyle(context, entry.row.direction);
    final noAnswer =
        entry.row.direction == CallDirection.outgoing && !entry.isConnected;
    final dirColor = noAnswer ? z.noAnswer : dir.color;
    final dirLabel = noAnswer ? 'No answer' : dir.label;
    final rec = entry.recording;
    final started = entry.startedAtUtc;

    final Widget? marker = isCurrent
        ? StatusPill(label: 'This call', color: z.accent)
        : entry.needsReview
        ? StatusPill(label: 'Needs review', color: z.warn)
        : rec == null && entry.isConnected
        ? Text(
            'No recording',
            style: AppType.caption.copyWith(color: z.ink3),
          )
        : null;

    return Container(
      color: isCurrent ? z.rowActive : null,
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.gutter,
        vertical: 10,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  started == null ? 'Unknown date' : Fmt.dayHeading(started),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(color: z.ink2),
                ),
                if (started != null)
                  Text(
                    Fmt.clock(started),
                    style: AppType.tabular(
                      AppType.caption,
                    ).copyWith(color: z.ink3),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CallGlyph(dir.glyph, size: 12, color: dirColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        dirLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.small.copyWith(
                          color: dirColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                if (marker != null) ...[
                  const SizedBox(height: 4),
                  marker,
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            entry.isConnected ? Fmt.stopwatch(entry.durationSeconds) : '—',
            style: AppType.tabular(AppType.bodyMedium).copyWith(
              color: entry.isConnected ? z.ink : z.ink3,
            ),
          ),
          if (rec != null) ...[
            const SizedBox(width: 12),
            RecordingPlayButton(candidate: rec, size: 36),
          ],
        ],
      ),
    );
  }
}
