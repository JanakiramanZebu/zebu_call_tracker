import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/server_snapshot.dart';
import '../data/sync_service.dart';
import 'outbox_queue_screen.dart';
import 'sync_alert_banner.dart';

/// "1 call" / "3 calls".
String _calls(int n) => '$n ${n == 1 ? 'call' : 'calls'}';

/// "1,285": stage counts in the delivery pipeline.
final _count = NumberFormat('#,##0');

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
      ref.invalidate(syncCountersProvider);
      ref.invalidate(backgroundStatusProvider);
      // A run that completed while this screen was backgrounded leaves no
      // trace in Dart; resume is the only reliable moment to re-read it.
      ref.invalidate(nativeSyncStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;

    // Only the two recording counts, as a record so this screen rebuilds when
    // they change rather than on every page the call feed loads.
    final recordings = ref.watch(
      callFeedProvider.select((feed) {
        var found = 0, missing = 0;
        for (final e in feed.value?.entries ?? const <CallEntry>[]) {
          if (e.recording != null) {
            found++;
          } else if (e.isConnected && !e.needsReview) {
            // Answered calls only. A missed or rejected call is never recorded,
            // so counting those reported a gap that cannot exist.
            missing++;
          }
        }
        return (found: found, missing: missing);
      }),
    );

    final counters = ref.watch(syncCountersProvider).value ?? const {};
    final isSyncing = ref.watch(syncServiceProvider).isLoading;
    final isConnected = ref.watch(connectivityProvider).value ?? true;
    // The native coordinator's own record of its last run — the only source
    // that knows what happened while the Flutter engine was not running.
    final nativeSync = ref.watch(nativeSyncStatusProvider).value;

    final received = _receivedSummary(
      context,
      ref.watch(serverSnapshotProvider).value,
    );

    final uploaded = counters['uploaded'] ?? 0;
    final waiting = counters['waiting'] ?? 0;
    final failed = counters['failed'] ?? 0;
    final totalLocal = counters['total'] ?? 0;

    // The coordinator's own record, which is the only thing that knows what
    // happened while the Flutter engine was not running. This line used to
    // read "Just now" whenever `uploaded > 0` — a LIFETIME counter — so a
    // handset that had not reached the server in days still claimed a sync
    // seconds ago, while the correct value sat further down this same screen.
    final lastSent = 'Last sent: ${nativeSync?.lastSyncLabel ?? '—'}.';

    // One tone for the whole statement: the icon tile and the explanation
    // agree on whether this phone needs attention.
    final ({Color color, Color soft, IconData icon, String sub}) tone =
        isSyncing
        ? (
            color: z.accent,
            soft: z.accentSoft,
            icon: Icons.cloud_upload_outlined,
            sub: 'Delivering to Zebu CRM now.',
          )
        : failed > 0
        ? (
            color: z.danger,
            soft: z.dangerSoft,
            icon: Icons.error_outline_rounded,
            sub:
                'They will not be sent again on their own. Tap Try again, '
                'or open the call queue to see why. $lastSent',
          )
        : (waiting > 0 && !isConnected)
        ? (
            color: z.warn,
            soft: z.warnSoft,
            icon: Icons.wifi_off_rounded,
            sub:
                'This phone is offline. They go out automatically once it is '
                'back online. $lastSent',
          )
        : waiting > 0
        ? (
            color: z.warn,
            soft: z.warnSoft,
            icon: Icons.schedule_rounded,
            sub:
                'They go out automatically when the connection allows. '
                '$lastSent',
          )
        : (
            color: z.ok,
            soft: z.okSoft,
            icon: Icons.check_rounded,
            sub: lastSent,
          );

    final headline = isSyncing
        ? 'Sending your calls…'
        : (failed > 0
              ? "${_calls(failed)} couldn't be sent"
              : (waiting > 0
                    ? '${_calls(waiting)} waiting to send'
                    : 'All calls delivered'));

    final hasQueued = waiting > 0 || failed > 0;

    Future<void> openQueue() async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const OutboxQueueScreen()),
      );
      ref.invalidate(syncCountersProvider);
      ref.invalidate(nativeSyncStatusProvider);
    }

    return Scaffold(
      backgroundColor: z.canvas,
      // No AppBar: the same large scrolling-free header as Home and Calls,
      // kept clear of the status bar by the SafeArea.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            PageHeader(
              title: 'Sync',
              subtitle: 'Calls go to Zebu CRM on their own.',
              actions: [
                TapIcon(
                  icon: Icons.help_outline_rounded,
                  tooltip: 'How sending works',
                  color: z.ink2,
                  onTap: () => _showSyncHelp(context),
                ),
                TapIcon(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  color: z.ink2,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                ),
              ],
            ),
            Expanded(
              child: RefreshIndicator(
                color: z.accent,
                backgroundColor: z.raised,
                onRefresh: () async {
                  ref.invalidate(syncCountersProvider);
                  ref.invalidate(nativeSyncStatusProvider);
                  await ref.read(callFeedProvider.notifier).refresh();
                  await ref.read(syncServiceProvider.notifier).triggerSync();
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Ledger layout: rows run edge to edge and indent their own
                  // content by the gutter.
                  padding: context.scrollPadding(
                    top: 4,
                    bottom: 32,
                    horizontal: 0,
                  ),
                  children: [
                    // ── ONE STATUS, WHEN IT LAST SENT, AND THE ONE ACTION ────────────
                    // First on the screen because "have my calls gone?" is the only
                    // question this tab exists to answer.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTokens.gutter,
                        12,
                        AppTokens.gutter,
                        20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AnimatedContainer(
                                duration: AppTokens.medium,
                                curve: AppTokens.ease,
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: tone.soft,
                                  borderRadius: BorderRadius.circular(
                                    AppTokens.r14,
                                  ),
                                ),
                                child: isSyncing
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: z.accent,
                                          backgroundColor: z.accentSoft,
                                        ),
                                      )
                                    : Icon(
                                        tone.icon,
                                        size: 22,
                                        color: tone.color,
                                      ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Semantics(
                                  liveRegion: true,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        headline,
                                        style: AppType.tabular(
                                          AppType.statement,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        tone.sub,
                                        style: AppType.tabular(
                                          AppType.small,
                                        ).copyWith(color: z.ink2),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          _DeliveryPipeline(
                            saved: totalLocal,
                            waiting: waiting,
                            failed: failed,
                            delivered: uploaded,
                            sending: isSyncing,
                          ),
                          const SizedBox(height: 22),
                          ZButton(
                            loading: isSyncing,
                            semanticLabel: isSyncing ? 'Sending…' : null,
                            // Nothing queued: still a way to send, but not the
                            // screen's call to action.
                            variant: hasQueued
                                ? ZButtonVariant.primary
                                : ZButtonVariant.secondary,
                            onPressed: isSyncing
                                ? null
                                : () async {
                                    await ref
                                        .read(syncServiceProvider.notifier)
                                        .triggerSync(reviveFailed: true);
                                    ref.invalidate(syncCountersProvider);
                                    ref.invalidate(nativeSyncStatusProvider);
                                  },
                            label: isSyncing
                                ? 'Sending…'
                                : (failed > 0 ? 'Try again' : 'Send now'),
                          ),
                        ],
                      ),
                    ),

                    // Anything stopping or degrading sync, worst first —
                    // battery restrictions included.
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppTokens.gutter,
                      ),
                      child: SyncAlertBanner(maxAlerts: 3),
                    ),

                    // ── WHAT IS STOPPING A SEND ──────────────────────────────────────
                    const SectionLabel('Health checks'),
                    ListGroup(
                      children: [
                        _HealthRow(
                          title: 'Internet',
                          value: isConnected ? 'Connected' : 'Offline',
                          color: isConnected ? z.ok : z.danger,
                        ),
                        _HealthRow(
                          title: 'Server',
                          // The outcome of the last real upload attempt, not whether
                          // a base URL happens to be compiled in. `hasServer` is a
                          // build constant, so this row previously read "Reachable"
                          // on a handset that had never once reached the server.
                          // A misconfigured build is not a warning, it is a dead
                          // app: no request it makes can succeed, and nothing the
                          // user can change fixes it. Which way it is wrong is on
                          // the support-only Technical details screen.
                          value: !AppConfig.hasServer
                              ? "Can't connect – contact IT"
                              : (nativeSync?.statusLabel ?? 'Checking…'),
                          color: !AppConfig.hasServer
                              ? z.danger
                              : (nativeSync == null
                                    ? null
                                    : (nativeSync.isHealthy ? z.ok : z.warn)),
                        ),
                        // The server's own count, from its last check-in.
                        // "In Zebu CRM" above is the phone's belief; this is
                        // what actually arrived.
                        _HealthRow(
                          title: 'Received by CRM',
                          value: received.label,
                          color: received.color,
                        ),
                        _HealthRow(
                          title: 'Call queue',
                          value: failed > 0
                              ? '$failed need attention'
                              : (waiting > 0 ? '$waiting waiting' : 'View'),
                          color: failed > 0
                              ? z.danger
                              : (waiting > 0 ? z.warn : null),
                          // Each call, its state, and in plain words why it
                          // has not gone. This screen used to be reachable
                          // only by long-pressing the version in Settings.
                          onTap: openQueue,
                        ),
                      ],
                    ),

                    // ── CALL RECORDINGS ──────────────────────────────────────────────
                    const SectionLabel('Call recordings'),
                    ListGroup(
                      children: [
                        _HealthRow(
                          title: 'Recordings found',
                          subtitle: 'Matched to a call on this phone',
                          value: _count.format(recordings.found),
                          color: recordings.found > 0 ? z.ok : null,
                        ),
                        _HealthRow(
                          title: 'Missing recordings',
                          subtitle: 'Answered calls with no recording',
                          value: _count.format(recordings.missing),
                          color: recordings.missing > 0 ? z.warn : null,
                        ),
                      ],
                    ),

                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTokens.gutter,
                        16,
                        AppTokens.gutter,
                        0,
                      ),
                      child: Text(
                        'Calls and recordings are saved on this phone as soon '
                        'as they finish, and sent automatically once you have '
                        'an internet connection. You do not need to keep the '
                        'app open.',
                        style: AppType.label.copyWith(
                          color: z.ink3,
                          fontWeight: FontWeight.w400,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSyncHelp(BuildContext context) {
    final z = context.z;
    final steps = [
      'Every call is saved on this phone first, so nothing is lost if you '
          'are offline.',
      'Calls and recordings are sent in the background. You do not need to '
          'keep the app open.',
      'A call is never sent twice, even if sending is interrupted.',
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How sending works'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    child: Text(
                      '${i + 1}.',
                      style: AppType.tabular(
                        AppType.small,
                      ).copyWith(color: z.ink3),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: AppType.small.copyWith(color: z.ink2),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        actions: [
          ZButton(
            label: 'Got it',
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }
}

// ── Delivery pipeline ───────────────────────────────────────────────────────
/// Where this phone's calls are: saved on the phone, waiting to send, and in
/// Zebu CRM — three nodes on a track that fills as calls are delivered.
///
/// Replaces the progress ring, which showed one number and hid the other two.
/// The "Couldn't send" count that used to have its own tile is carried under
/// the middle stage, so a failure is never folded into "waiting".
class _DeliveryPipeline extends StatelessWidget {
  const _DeliveryPipeline({
    required this.saved,
    required this.waiting,
    required this.failed,
    required this.delivered,
    required this.sending,
  });

  final int saved;
  final int waiting;
  final int failed;
  final int delivered;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final outstanding = waiting > 0 || failed > 0;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // How far along the track has filled: all the way when nothing is
    // outstanding, to the middle node while calls wait, and past it while a
    // send is running.
    final fill = !outstanding ? 1.0 : (sending ? 0.78 : 0.5);

    final middleColor = failed > 0
        ? z.danger
        : (waiting > 0 ? (sending ? z.accent : z.warn) : z.accent);

    final semantics = [
      '${_count.format(saved)} saved on phone',
      '${_count.format(waiting)} waiting to send',
      if (failed > 0) "${_count.format(failed)} couldn't send",
      '${_count.format(delivered)} in Zebu CRM',
    ].join(', ');

    return Semantics(
      image: true,
      label: semantics,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The track runs between the centres of the outer nodes.
          final column = constraints.maxWidth / 3;
          final track = constraints.maxWidth - column;
          return Stack(
            children: [
              Positioned(
                top: 9,
                left: column / 2,
                width: track,
                height: 2,
                child: ColoredBox(
                  color: z.lineStrong,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: reduceMotion ? Duration.zero : AppTokens.slow,
                      curve: AppTokens.ease,
                      width: track * fill,
                      height: 2,
                      color: z.accent,
                    ),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Stage(
                    node: _Node(fill: z.accent, border: z.accent),
                    value: _count.format(saved),
                    label: 'Saved on phone',
                  ),
                  _Stage(
                    node: _Node(
                      fill: middleColor,
                      border: middleColor,
                      pulse: sending && waiting > 0,
                    ),
                    value: _count.format(waiting),
                    valueColor: waiting > 0 && !sending ? z.warn : null,
                    label: 'Waiting to send',
                    note: failed > 0
                        ? "${_count.format(failed)} couldn't send"
                        : null,
                    noteColor: z.danger,
                  ),
                  _Stage(
                    node: _Node(
                      fill: outstanding ? z.canvas : z.accent,
                      border: z.accent,
                    ),
                    value: _count.format(delivered),
                    label: 'In Zebu CRM',
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.node,
    required this.value,
    required this.label,
    this.valueColor,
    this.note,
    this.noteColor,
  });

  final Widget node;
  final String value;
  final String label;
  final Color? valueColor;
  final String? note;
  final Color? noteColor;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Expanded(
      child: Column(
        children: [
          node,
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            style: AppType.tabular(
              AppType.statement,
            ).copyWith(fontSize: 20, color: valueColor ?? z.ink),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(color: z.ink3),
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note!,
              textAlign: TextAlign.center,
              style: AppType.tabular(
                AppType.captionStrong,
              ).copyWith(color: noteColor),
            ),
          ],
        ],
      ),
    );
  }
}

/// One 20px pipeline node. Pulses while a send is moving calls through it.
class _Node extends StatelessWidget {
  const _Node({required this.fill, required this.border, this.pulse = false});

  final Color fill;
  final Color border;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    // StatusDot already honours the system's reduce-motion setting.
    if (pulse) return StatusDot(color: fill, size: 20, pulse: true);
    return AnimatedContainer(
      duration: AppTokens.medium,
      curve: AppTokens.ease,
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 2),
      ),
    );
  }
}

// ── Health row ──────────────────────────────────────────────────────────────
/// One ledger row: what is being checked on the left, its state on the right
/// with a status dot when it has one.
///
/// Not a [ListRow]: server outcomes such as "Access removed – contact your
/// admin" are longer than the room beside a row label on a narrow phone, so
/// the value here shrinks with an ellipsis instead of overflowing.
class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.title,
    required this.value,
    this.subtitle,
    this.color,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String value;

  /// Status colour for the value and its dot; null for a neutral value.
  final Color? color;

  /// When set the row opens something, and shows a chevron to say so.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final label = subtitle == null
        ? Text(title, style: AppType.body)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: AppType.body),
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: AppType.label.copyWith(
                  color: z.ink3,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          );
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: subtitle == null ? 52 : 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.gutter,
          vertical: 10,
        ),
        child: Row(
          children: [
            // A one-word label keeps its natural width and the value takes
            // the rest; a label with an explanation under it shares the row.
            if (subtitle == null) label else Expanded(flex: 5, child: label),
            const SizedBox(width: 12),
            Expanded(
              flex: 4,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (color != null) ...[
                    StatusDot(color: color!),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: AppType.tabular(
                        AppType.small,
                      ).copyWith(color: color ?? z.ink3),
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: z.ink3),
            ],
          ],
        ),
      ),
    );
    final labelled = MergeSemantics(child: row);
    if (onTap == null) return labelled;
    return Semantics(
      button: true,
      child: InkWell(onTap: onTap, child: labelled),
    );
  }
}

/// The "Received by CRM" row, from the server's last `/sync/status`.
({String label, Color? color}) _receivedSummary(
  BuildContext context,
  ServerSnapshot? s,
) {
  final z = context.z;
  if (s == null) return (label: 'Not checked yet', color: null);
  if (!s.isDeviceActive) {
    return (label: 'Not accepting this phone', color: z.danger);
  }
  final today = s.callsTodayIsCurrent ? s.callsToday : null;
  final last = s.lastCallAt;
  final parts = <String>[
    if (today != null) '${_calls(today)} today',
    if (last != null) 'last ${_clock(last)}',
  ];
  if (parts.isEmpty) {
    return (label: 'Connected', color: z.ok);
  }
  return (label: parts.join(', '), color: z.ok);
}

/// "09:16" today, otherwise "3 Oct".
String _clock(DateTime at) {
  final local = at.toLocal();
  final now = DateTime.now();
  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${local.day} ${months[local.month - 1]}';
}
