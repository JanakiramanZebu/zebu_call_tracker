import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/sync_service.dart';
import 'outbox_queue_screen.dart';

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

    // Calculate avatar initials
    final displayName = session?.displayName ?? 'Agent';
    final initials = displayName.trim().split(' ').map((s) => s.isNotEmpty ? s[0] : '').take(2).join().toUpperCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                );
              } else if (value == 'help') {
                _showSyncHelp(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 20),
                    SizedBox(width: 10),
                    Text('Settings'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'help',
                child: Row(
                  children: [
                    Icon(Icons.help_outline_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Help & Info'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
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
            // ── Top User Profile Element ─────────────────────────────────────
            if (session != null) ...[
              AppCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: context.colors.primary,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initials.isNotEmpty ? initials : 'SV',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
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
                            session.displayName,
                            style: context.text.bodyLarge?.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${session.employeeId}${session.department != null ? ' · ${session.department}' : ''}',
                            style: context.text.bodySmall?.copyWith(
                              color: context.palette.muted,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isConnected
                            ? context.palette.answered.withValues(alpha: 0.12)
                            : context.palette.missed.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        isConnected ? 'Online' : 'Offline',
                        style: TextStyle(
                          color: isConnected ? context.palette.answered : context.palette.missed,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],

            // ── Pending Sync Hero Card ───────────────────────────────────────
            _PendingSyncHeroCard(
              isSyncing: isSyncing,
              waiting: waiting,
              failed: failed,
              uploaded: uploaded,
              total: totalLocal,
              isConnected: isConnected,
            ),
            const SizedBox(height: 14),

            // ── Call Metadata Outbox Card ───────────────────────────────────
            AppCard(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconChip(
                        icon: Icons.inventory_2_outlined,
                        color: context.colors.primary,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Call Metadata Outbox',
                              style: context.text.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              waiting > 0
                                  ? '$waiting calls waiting to upload'
                                  : 'All calls synced with backend',
                              style: context.text.bodySmall?.copyWith(
                                color: context.palette.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const OutboxQueueScreen(),
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        side: BorderSide(color: context.colors.outlineVariant),
                      ),
                      icon: const Icon(Icons.list_alt_rounded, size: 18),
                      label: const Text(
                        'View Queue',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── Upload Status Breakdown Card ────────────────────────────────
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _BreakdownRow(
                    icon: Icons.check_rounded,
                    iconBg: context.palette.answered.withValues(alpha: 0.12),
                    iconColor: context.palette.answered,
                    title: 'Uploaded',
                    subtitle: 'Confirmed by the server',
                    count: '$uploaded',
                    countColor: context.palette.answered,
                  ),
                  const _RowDivider(),
                  _BreakdownRow(
                    icon: Icons.upload_rounded,
                    iconBg: context.colors.primary.withValues(alpha: 0.12),
                    iconColor: context.colors.primary,
                    title: 'Uploading',
                    subtitle: isSyncing ? 'In flight now' : 'Idle',
                    count: isSyncing ? '1' : '0',
                    countColor: context.colors.primary,
                  ),
                  const _RowDivider(),
                  _BreakdownRow(
                    icon: Icons.schedule_rounded,
                    iconBg: context.palette.waiting.withValues(alpha: 0.14),
                    iconColor: context.palette.waiting,
                    title: 'Waiting',
                    subtitle: 'Queued for the next window',
                    count: '$waiting',
                    countColor: context.palette.waiting,
                  ),
                  const _RowDivider(),
                  _BreakdownRow(
                    icon: Icons.warning_amber_rounded,
                    iconBg: context.palette.missed.withValues(alpha: 0.12),
                    iconColor: context.palette.missed,
                    title: 'Failed',
                    subtitle: failed > 0 ? '$failed calls need attention' : 'No failed items',
                    count: '$failed',
                    countColor: context.palette.missed,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── Sync Actions ────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: isSyncing
                          ? null
                          : () async {
                              await ref.read(syncServiceProvider.notifier).triggerSync();
                              ref.invalidate(syncCountersProvider);
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.colors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
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
                          : const Icon(Icons.sync_rounded, size: 20),
                      label: Text(
                        isSyncing ? 'Syncing…' : (failed > 0 ? 'Retry failed uploads' : 'Sync now'),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Recordings Section ──────────────────────────────────────────
            const SectionLabel('Recordings'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _BreakdownRow(
                    icon: Icons.graphic_eq_rounded,
                    iconBg: context.palette.answered.withValues(alpha: 0.12),
                    iconColor: context.palette.answered,
                    title: 'Matched',
                    subtitle: 'Associated with a call',
                    count: '${stats.recordingsMatched}',
                    countColor: context.palette.answered,
                  ),
                  const _RowDivider(),
                  _BreakdownRow(
                    icon: Icons.warning_amber_rounded,
                    iconBg: context.palette.waiting.withValues(alpha: 0.14),
                    iconColor: context.palette.waiting,
                    title: 'Needs review',
                    subtitle: 'Match was ambiguous',
                    count: '${stats.recordingsNeedReview}',
                    countColor: context.palette.waiting,
                  ),
                  const _RowDivider(),
                  _BreakdownRow(
                    icon: Icons.mic_off_outlined,
                    iconBg: context.palette.tint,
                    iconColor: context.palette.muted,
                    title: 'No recording',
                    subtitle: 'Missed & unrecorded calls',
                    count: '${stats.recordingsAbsent}',
                    countColor: context.palette.muted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Connection & Status Section ─────────────────────────────────
            const SectionLabel('Status'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _StatusItem(
                    icon: Icons.schedule_rounded,
                    label: 'Last successful sync',
                    value: isSyncing ? 'In progress' : (uploaded > 0 ? 'Just now' : 'Pending'),
                  ),
                  const _RowDivider(leftPadding: 44),
                  _StatusItem(
                    icon: Icons.wifi_rounded,
                    label: 'Network',
                    value: isConnected ? 'Connected' : 'Offline',
                    valueColor: isConnected ? context.palette.answered : context.palette.missed,
                  ),
                  const _RowDivider(leftPadding: 44),
                  _StatusItem(
                    icon: Icons.dns_rounded,
                    label: 'Server',
                    value: AppConfig.hasServer ? 'Reachable' : 'Local demo',
                    valueColor: AppConfig.hasServer ? context.palette.answered : context.palette.waiting,
                  ),
                  const _RowDivider(leftPadding: 44),
                  _StatusItem(
                    icon: Icons.inventory_2_outlined,
                    label: 'Queue size',
                    value: '$waiting records',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Calls are saved on the device the moment they end. Nothing is lost while offline — the queue drains automatically when a connection returns.',
                style: context.text.bodySmall?.copyWith(
                  color: context.palette.muted,
                  height: 1.5,
                  fontSize: 12.5,
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
        title: const Text('Synchronization & Outbox'),
        content: const Text(
          'Calls are captured natively the moment they end on your phone.\n\n'
          '• Offline-First: All calls are safely stored in local database before upload.\n'
          '• Background Sync: Native Android WorkManager uploads call metadata and audio files automatically in the background.\n'
          '• View Queue: Tap View Queue to inspect individual pending calls, error details, or trigger individual retries.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

class _PendingSyncHeroCard extends StatelessWidget {
  const _PendingSyncHeroCard({
    required this.isSyncing,
    required this.waiting,
    required this.failed,
    required this.uploaded,
    required this.total,
    required this.isConnected,
  });

  final bool isSyncing;
  final int waiting;
  final int failed;
  final int uploaded;
  final int total;
  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final hasPending = waiting > 0;
    final hasFailed = failed > 0;

    final Color accentColor = hasFailed
        ? context.palette.missed
        : (hasPending || isSyncing
            ? context.palette.waiting
            : context.palette.answered);

    final String title = isSyncing
        ? 'Syncing Outbox…'
        : (hasFailed
            ? '$failed calls failed to sync'
            : (hasPending
                ? '$waiting calls waiting to sync'
                : 'All caught up'));

    final String subtitle = isSyncing
        ? 'Uploading call metadata to server'
        : (!isConnected
            ? "You're offline · Will sync when connected"
            : (hasPending
                ? 'Stored locally · Ready for sync'
                : 'Your call data is synchronized'));

    final IconData icon = isSyncing
        ? Icons.sync_rounded
        : (hasFailed
            ? Icons.warning_amber_rounded
            : (hasPending
                ? Icons.cloud_upload_outlined
                : Icons.cloud_done_rounded));

    return Column(
      children: [
        AppCard(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: accentColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: context.text.bodyLarge?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Progress Track
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                if (uploaded > 0 || total == 0)
                  Expanded(
                    flex: uploaded > 0 ? uploaded : 1,
                    child: ColoredBox(color: context.palette.answered),
                  ),
                if (waiting > 0)
                  Expanded(
                    flex: waiting,
                    child: ColoredBox(color: context.palette.waiting),
                  ),
                if (failed > 0)
                  Expanded(
                    flex: failed,
                    child: ColoredBox(color: context.palette.missed),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.countColor,
  });

  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String count;
  final Color countColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                Text(
                  subtitle,
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          Text(
            count,
            style: context.text.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 19,
              color: countColor,
              letterSpacing: -0.4,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  const _StatusItem({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: context.text.bodyMedium?.copyWith(
                fontSize: 14,
              ),
            ),
          ),
          Text(
            value,
            style: context.text.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
              color: valueColor ?? context.palette.muted,
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
      child: Divider(
        height: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}