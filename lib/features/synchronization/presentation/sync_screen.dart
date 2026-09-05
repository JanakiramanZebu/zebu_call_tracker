import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/charts.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/sync_service.dart';
import 'outbox_queue_screen.dart';
import 'sync_alert_banner.dart';

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
    final session = ref.watch(authControllerProvider).value;
    final feed = ref.watch(callFeedProvider).value;
    final entries = feed?.entries ?? const <CallEntry>[];
    final stats = CallStats.from(entries);

    final syncCountersAsync = ref.watch(syncCountersProvider);
    final syncState = ref.watch(syncServiceProvider);
    final isConnected = ref.watch(connectivityProvider).asData?.value ?? true;
    // The native coordinator's own record of its last run — the only source
    // that knows what happened while the Flutter engine was not running.
    final nativeSync = ref.watch(nativeSyncStatusProvider).value;

    final counters = syncCountersAsync.asData?.value ??
        {
          'uploaded': 0,
          'waiting': entries.length,
          'failed': 0,
          'total': entries.length,
        };
    final uploaded = counters['uploaded'] ?? 0;
    final waiting = counters['waiting'] ?? 0;
    final failed = counters['failed'] ?? 0;
    final totalLocal = counters['total'] ?? entries.length;

    final isSyncing = syncState.isLoading;

    final displayName = session?.displayName ?? 'Agent';
    final initials = displayName
        .trim()
        .split(' ')
        .map((s) => s.isNotEmpty ? s[0] : '')
        .take(2)
        .join()
        .toUpperCase();

    final syncProgress = totalLocal > 0
        ? (uploaded / totalLocal).clamp(0.0, 1.0)
        : (waiting == 0 ? 1.0 : 0.0);

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: const Text(
          'Sync Dashboard',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 24,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppTokens.textSecondary),
            color: AppTokens.surface2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.r12),
              side: const BorderSide(color: AppTokens.borderDefault),
            ),
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                );
              } else if (value == 'outbox') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const OutboxQueueScreen()),
                );
              } else if (value == 'help') {
                _showSyncHelp(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'outbox',
                child: Row(
                  children: [
                    Icon(Icons.inventory_2_outlined, size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Text('Calls waiting to send', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Text('Settings', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'help',
                child: Row(
                  children: [
                    Icon(Icons.help_outline_rounded, size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Text('How syncing works', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTokens.brandElectric,
        backgroundColor: AppTokens.surface2,
        onRefresh: () async {
          ref.invalidate(syncCountersProvider);
          ref.invalidate(nativeSyncStatusProvider);
          await ref.read(callFeedProvider.notifier).refresh();
          await ref.read(syncServiceProvider.notifier).triggerSync();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            // Anything stopping or degrading sync, worst first. Nothing below
            // is meaningful if one of these is live.
            const SyncAlertBanner(maxAlerts: 3),

            // ── Top User Profile Element ─────────────────────────────────────
            if (session != null) ...[
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppTokens.surface2,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppTokens.brandElectric.withValues(alpha: 0.5),
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initials.isNotEmpty ? initials : 'ZB',
                        style: const TextStyle(
                          color: AppTokens.brandElectric,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.displayName,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Employee ${session.employeeId}${session.department != null ? ' · ${session.department}' : ''}',
                            style: const TextStyle(
                              color: AppTokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    StatusPill(
                      label: isConnected ? 'Online' : 'Offline',
                      color: isConnected ? AppTokens.success : AppTokens.danger,
                      icon: isConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],

            // ── SYNC HERO: Circular Progress Radial Dashboard ────────────────
            AppCard(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                children: [
                  SyncProgressRing(
                    progress: syncProgress,
                    centerText: waiting > 0 ? '$waiting' : (uploaded > 0 ? '$uploaded' : '0'),
                    subtitle: waiting > 0 ? 'Calls in queue' : 'All synced',
                    ringColor: failed > 0
                        ? AppTokens.danger
                        : (waiting > 0 ? AppTokens.brandElectric : AppTokens.success),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    isSyncing
                        ? 'Uploading metadata & audio recordings…'
                        : (failed > 0
                            ? '$failed calls encountered errors'
                            : (waiting > 0
                                ? '$waiting records ready for cloud sync'
                                : 'All call records are synchronized with backend')),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: failed > 0 ? AppTokens.danger : Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    // The coordinator's own record, which is the only thing
                    // that knows what happened while the Flutter engine was
                    // not running. This line used to read "Just now" whenever
                    // `uploaded > 0` — a LIFETIME counter — so a handset that
                    // had not reached the server in days still claimed a sync
                    // seconds ago, while the correct value sat further down
                    // this same screen.
                    isSyncing
                        ? 'Syncing now…'
                        : 'Last sync: ${nativeSync?.lastSyncLabel ?? "—"}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── THE THREE COUNTS THAT MATTER ─────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _SyncStatTile(
                    title: 'Sent',
                    count: '$uploaded',
                    icon: Icons.check_circle_rounded,
                    color: AppTokens.success,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SyncStatTile(
                    title: 'Waiting',
                    count: '$waiting',
                    icon: Icons.schedule_rounded,
                    color: waiting > 0 ? AppTokens.warning : AppTokens.textMuted,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SyncStatTile(
                    title: 'Failed',
                    count: '$failed',
                    icon: Icons.error_rounded,
                    color: failed > 0 ? AppTokens.danger : AppTokens.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── THE ONE ACTION ───────────────────────────────────────────────
            SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isSyncing
                    ? null
                    : () async {
                        await ref.read(syncServiceProvider.notifier).triggerSync();
                        ref.invalidate(syncCountersProvider);
                        ref.invalidate(nativeSyncStatusProvider);
                      },
                style: FilledButton.styleFrom(
                  backgroundColor:
                      failed > 0 ? AppTokens.danger : AppTokens.brandElectric,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTokens.r12),
                  ),
                ),
                icon: isSyncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        failed > 0
                            ? Icons.restart_alt_rounded
                            : Icons.sync_rounded,
                        size: 20,
                      ),
                label: Text(
                  isSyncing
                      ? 'Syncing…'
                      : (failed > 0 ? 'Retry Failed Calls' : 'Sync Now'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── CALL RECORDINGS ──────────────────────────────────────────────
            const SectionLabel('Call recordings'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _BreakdownItem(
                    icon: Icons.graphic_eq_rounded,
                    iconColor: AppTokens.success,
                    title: 'Recordings found',
                    subtitle: 'Matched to a call on this phone',
                    count: '${stats.recordingsMatched}',
                    countColor: AppTokens.success,
                  ),
                  const _RowDivider(),
                  _BreakdownItem(
                    icon: Icons.mic_off_outlined,
                    iconColor: stats.recordingsAbsent > 0
                        ? AppTokens.warning
                        : AppTokens.textMuted,
                    title: 'Missing audio',
                    // Answered calls only. A missed or rejected call is never
                    // recorded, so counting those as missing audio -- the row
                    // that used to sit here -- reported a gap that cannot exist.
                    subtitle: 'Answered calls with no recording',
                    count: '${stats.recordingsAbsent}',
                    countColor: stats.recordingsAbsent > 0
                        ? AppTokens.warning
                        : AppTokens.textMuted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── WHAT IS STOPPING A SEND ──────────────────────────────────────
            const SectionLabel('Status'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _HealthRow(
                    icon: Icons.wifi_rounded,
                    label: 'Internet',
                    value: isConnected ? 'Connected' : 'Offline',
                    valueColor: isConnected ? AppTokens.success : AppTokens.danger,
                  ),
                  const _RowDivider(leftPadding: 44),
                  _HealthRow(
                    icon: Icons.dns_rounded,
                    label: 'Server',
                    // The outcome of the last real upload attempt, not whether
                    // a base URL happens to be compiled in. `hasServer` is a
                    // build constant, so this row previously read "Reachable"
                    // on a handset that had never once reached the server.
                    // A misconfigured build is not a warning, it is a dead
                    // app: no request it makes can succeed. Saying which of the
                    // three ways it is wrong is the difference between a
                    // diagnosable report and "it doesn't work".
                    value: !AppConfig.hasServer
                        ? switch (AppConfig.problem) {
                            ConfigProblem.missingServerUrl => 'No address set',
                            ConfigProblem.malformedServerUrl =>
                              'Invalid address',
                            ConfigProblem.insecureServerUrl =>
                              'Insecure address',
                            null => 'Not configured',
                          }
                        : (nativeSync?.statusLabel ?? 'Checking…'),
                    valueColor: !AppConfig.hasServer
                        ? AppTokens.danger
                        : (nativeSync == null
                            ? AppTokens.textMuted
                            : (nativeSync.isHealthy
                                ? AppTokens.success
                                : AppTokens.warning)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Informational footer
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Calls and recordings are saved on this phone as soon as they finish, and sent automatically once you have an internet connection. You do not need to keep the app open.',
                style: TextStyle(
                  color: AppTokens.textMuted,
                  height: 1.45,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSyncHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTokens.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r16),
          side: const BorderSide(color: AppTokens.borderDefault),
        ),
        title: const Text('How syncing works', style: TextStyle(color: Colors.white)),
        content: const Text(
          '• Every call is saved on this phone first, so nothing is lost if you are offline.\n'
          '• Calls and recordings are sent in the background — you do not need to keep the app open.\n'
          '• A call is never sent twice, even if syncing is interrupted.\n'
          '• Outbox Queue: Inspect individual pending items, error details, and perform manual retries from the Outbox.',
          style: TextStyle(color: AppTokens.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it', style: TextStyle(color: AppTokens.brandElectric)),
          ),
        ],
      ),
    );
  }
}

// ── Compact stat tile ───────────────────────────────────────────────────────
/// One number, large, with the word for what it counts.
///
/// Three of these fit across a phone only because the subtitle each used to
/// carry ("Confirmed by the server", "Queued in outbox") repeated its own
/// label. A fourth tile, "Uploading", showed a hard-coded 1 or 0 derived from
/// the button's own spinner, so it told the user nothing the button did not.
class _SyncStatTile extends StatelessWidget {
  const _SyncStatTile({
    required this.title,
    required this.count,
    required this.icon,
    required this.color,
  });

  final String title;
  final String count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      child: Column(
        children: [
          IconChip(icon: icon, color: color, size: 30, iconSize: 16),
          const SizedBox(height: 8),
          Text(
            count,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: -0.4,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTokens.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _BreakdownItem extends StatelessWidget {
  const _BreakdownItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.countColor,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String count;
  final Color countColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconChip(icon: icon, color: iconColor, size: 34, iconSize: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTokens.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            count,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 17,
              color: countColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTokens.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13.5, color: Colors.white),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider({this.leftPadding = 56});

  final double leftPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: leftPadding),
      child: const Divider(height: 1, color: AppTokens.borderSubtle),
    );
  }
}