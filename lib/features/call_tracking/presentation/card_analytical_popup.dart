import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../recording/presentation/recording_player_widget.dart';
import '../../synchronization/data/sync_service.dart';
import '../data/call_feed.dart';
import '../domain/call_entry.dart';
import 'call_detail_screen.dart';

enum PopupFilterCategory {
  talkTime,
  totalCalls,
  incoming,
  outgoing,
  missed,
  rejected,
  neverAttended,
  notPickup,
  uniqueCalls,
  avgDuration,
  recordings,
  syncStatus,
}

class CardAnalyticalPopup extends ConsumerStatefulWidget {
  const CardAnalyticalPopup({
    super.key,
    required this.category,
    required this.stats,
  });

  final PopupFilterCategory category;
  final CallStats stats;

  static void show(
    BuildContext context, {
    required PopupFilterCategory category,
    required CallStats stats,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CardAnalyticalPopup(
        category: category,
        stats: stats,
      ),
    );
  }

  @override
  ConsumerState<CardAnalyticalPopup> createState() =>
      _CardAnalyticalPopupState();
}

class _CardAnalyticalPopupState extends ConsumerState<CardAnalyticalPopup> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final periodEntries = ref.watch(analyticsPeriodEntriesProvider);
    final feed = ref.watch(callFeedProvider);
    final entries = periodEntries.asData?.value ?? feed.asData?.value.entries ?? const <CallEntry>[];

    final (title, subtitle, icon, color) = _getCategoryMetadata(context);
    final filteredCalls = _filterCalls(entries);

    return Container(
      decoration: const BoxDecoration(
        color: AppTokens.bgPrimary,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppTokens.borderDefault)),
      ),
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Column(
          children: [
            // Handle Bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTokens.borderDefault,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header Section
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
              child: Row(
                children: [
                  IconChip(icon: icon, color: color, size: 42, iconSize: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTokens.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: AppTokens.textSecondary),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppTokens.borderSubtle),

            // Main Body Content
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  // Specific Analytics Highlight Box
                  _buildAnalyticsHeader(context, filteredCalls),
                  const SizedBox(height: 16),

                  if (widget.category != PopupFilterCategory.syncStatus) ...[
                    // Search Field
                    TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: InputDecoration(
                        hintText: 'Search number or contact...',
                        hintStyle: const TextStyle(color: AppTokens.textMuted, fontSize: 13.5),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppTokens.textMuted),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 16, color: AppTokens.textMuted),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        filled: true,
                        fillColor: AppTokens.surface1,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppTokens.r12),
                          borderSide: const BorderSide(color: AppTokens.borderDefault),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppTokens.r12),
                          borderSide: const BorderSide(color: AppTokens.borderDefault),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    SectionLabel(
                      'Matched Records (${filteredCalls.length})',
                    ),
                    const SizedBox(height: 8),

                    if (filteredCalls.isEmpty)
                      const AppCard(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.find_in_page_outlined,
                                size: 36,
                                color: AppTokens.textMuted,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'No calls found matching filter',
                                style: TextStyle(
                                  color: AppTokens.textMuted,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      AppCard(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (var i = 0; i < filteredCalls.length; i++) ...[
                              if (i > 0)
                                const Padding(
                                  padding: EdgeInsets.only(left: 64),
                                  child: Divider(
                                    height: 1,
                                    color: AppTokens.borderSubtle,
                                  ),
                                ),
                              Column(
                                children: [
                                  CallRowTile(
                                    entry: filteredCalls[i],
                                    onTap: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => CallDetailScreen(
                                            entry: filteredCalls[i],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  if (widget.category == PopupFilterCategory.recordings &&
                                      filteredCalls[i].recording != null)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                      child: RecordingPlayerBar(
                                        candidate: filteredCalls[i].recording!,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                  ] else ...[
                    _buildSyncStatusDetails(context),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  (String, String, IconData, Color) _getCategoryMetadata(BuildContext context) {
    return switch (widget.category) {
      PopupFilterCategory.talkTime => (
          'Talk Time Analytics',
          'Total calling duration & volume insights',
          Icons.access_time_filled_rounded,
          AppTokens.brandElectric,
        ),
      PopupFilterCategory.totalCalls => (
          'Total Phone Calls',
          'All tracked incoming, outgoing and missed calls',
          Icons.phone_in_talk_rounded,
          AppTokens.brandElectric,
        ),
      PopupFilterCategory.incoming => (
          'Incoming Calls',
          'Detailed breakdown of incoming communications',
          Icons.call_received_rounded,
          AppTokens.callIncoming,
        ),
      PopupFilterCategory.outgoing => (
          'Outgoing Calls',
          'Overview of initiated call activity',
          Icons.call_made_rounded,
          AppTokens.callOutgoing,
        ),
      PopupFilterCategory.missed => (
          'Missed Calls',
          'Unanswered incoming calls requiring attention',
          Icons.call_missed_rounded,
          AppTokens.callMissed,
        ),
      PopupFilterCategory.rejected => (
          'Rejected Calls',
          'Calls declined or rejected by recipient/user',
          Icons.phone_disabled_rounded,
          AppTokens.callRejected,
        ),
      PopupFilterCategory.neverAttended => (
          'Never Attended',
          'Calls that disconnected before connection',
          Icons.phone_paused_rounded,
          AppTokens.callNeverAttended,
        ),
      PopupFilterCategory.notPickup => (
          'Not Pickup by Client',
          'Outgoing calls where the client did not answer',
          Icons.call_end_rounded,
          AppTokens.textMuted,
        ),
      PopupFilterCategory.uniqueCalls => (
          'Unique Calls',
          'Distinct phone numbers contacted in this period',
          Icons.contact_phone_rounded,
          AppTokens.brandPurple,
        ),
      PopupFilterCategory.avgDuration => (
          'Call Duration Analysis',
          'Average length and duration trends',
          Icons.schedule_rounded,
          AppTokens.brandIndigo,
        ),
      PopupFilterCategory.recordings => (
          'Recording Management',
          'Matched audio recordings and server uploads',
          Icons.graphic_eq_rounded,
          AppTokens.success,
        ),
      PopupFilterCategory.syncStatus => (
          'Cloud Sync Status',
          'Realtime outbox sync and server status',
          Icons.cloud_sync_rounded,
          AppTokens.warning,
        ),
    };
  }

  List<CallEntry> _filterCalls(List<CallEntry> all) {
    var list = switch (widget.category) {
      PopupFilterCategory.talkTime => all.where((e) => e.isConnected).toList(),
      PopupFilterCategory.totalCalls => all,
      PopupFilterCategory.incoming =>
        all.where((e) => e.row.direction == CallDirection.incoming).toList(),
      PopupFilterCategory.outgoing =>
        all.where((e) => e.row.direction == CallDirection.outgoing).toList(),
      PopupFilterCategory.missed => all
          .where((e) => e.row.direction == CallDirection.missed)
          .toList(),
      PopupFilterCategory.rejected => all
          .where((e) => const {
                CallDirection.rejected,
                CallDirection.blocked,
              }.contains(e.row.direction))
          .toList(),
      PopupFilterCategory.neverAttended => all
          .where((e) =>
              e.row.direction == CallDirection.incoming && !e.isConnected ||
              e.row.direction == CallDirection.missed)
          .toList(),
      PopupFilterCategory.notPickup => all
          .where((e) =>
              e.row.direction == CallDirection.outgoing && !e.isConnected)
          .toList(),
      PopupFilterCategory.uniqueCalls => all,
      PopupFilterCategory.avgDuration =>
        all.where((e) => e.durationSeconds > 0).toList(),
      PopupFilterCategory.recordings => all.where((e) {
        final rec = e.recording ?? e.match.candidate;
        return rec != null || e.needsReview;
      }).toList(),
      PopupFilterCategory.syncStatus => all,
    };

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      list = list.where((e) {
        final title = e.displayTitle.toLowerCase();
        final number = (e.row.number ?? '').toLowerCase();
        return title.contains(q) || number.contains(q);
      }).toList();
    }

    return list;
  }

  Widget _buildAnalyticsHeader(BuildContext context, List<CallEntry> filtered) {
    final stats = widget.stats;

    switch (widget.category) {
      case PopupFilterCategory.talkTime:
      case PopupFilterCategory.totalCalls:
        final (h, m) = Fmt.talkTime(stats.talkTimeSeconds);
        return AppCard(
          borderColor: AppTokens.brandElectric.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Total Duration',
                value: '${h}h ${m}m',
                color: AppTokens.brandElectric,
              ),
              _MetricStat(
                label: 'Total Calls',
                value: '${stats.total}',
                color: AppTokens.success,
              ),
              _MetricStat(
                label: 'Answered Ratio',
                value: stats.total > 0
                    ? '${((stats.answered / stats.total) * 100).round()}%'
                    : '0%',
                color: AppTokens.warning,
              ),
            ],
          ),
        );

      case PopupFilterCategory.rejected:
        return AppCard(
          borderColor: AppTokens.callRejected.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Rejected Calls',
                value: '${stats.rejected}',
                color: AppTokens.callRejected,
              ),
              _MetricStat(
                label: 'Share of Total',
                value: stats.total > 0
                    ? '${((stats.rejected / stats.total) * 100).round()}%'
                    : '0%',
                color: AppTokens.textMuted,
              ),
            ],
          ),
        );

      case PopupFilterCategory.neverAttended:
        return AppCard(
          borderColor: AppTokens.callNeverAttended.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Never Attended',
                value: '${stats.neverAttended}',
                color: AppTokens.callNeverAttended,
              ),
              _MetricStat(
                label: 'Attention Needed',
                value: stats.neverAttended > 0 ? 'High' : 'None',
                color: stats.neverAttended > 0 ? AppTokens.warning : AppTokens.success,
              ),
            ],
          ),
        );

      case PopupFilterCategory.notPickup:
        return AppCard(
          borderColor: AppTokens.borderDefault,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Not Picked Up',
                value: '${stats.notPickupByClient}',
                color: AppTokens.textMuted,
              ),
              _MetricStat(
                label: 'Outgoing Ratio',
                value: stats.outgoing > 0
                    ? '${((stats.notPickupByClient / stats.outgoing) * 100).round()}%'
                    : '0%',
                color: AppTokens.warning,
              ),
            ],
          ),
        );

      case PopupFilterCategory.uniqueCalls:
        return AppCard(
          borderColor: AppTokens.brandPurple.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Unique Contacts',
                value: '${stats.uniqueCalls}',
                color: AppTokens.brandPurple,
              ),
              _MetricStat(
                label: 'Avg Calls/Contact',
                value: stats.uniqueCalls > 0
                    ? (stats.total / stats.uniqueCalls).toStringAsFixed(1)
                    : '0',
                color: AppTokens.success,
              ),
            ],
          ),
        );

      case PopupFilterCategory.incoming:
        final incomingCalls = filtered;
        final totalSecs =
            incomingCalls.fold<int>(0, (sum, e) => sum + e.durationSeconds);
        final (h, m) = Fmt.talkTime(totalSecs);
        return AppCard(
          borderColor: AppTokens.callIncoming.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Incoming Volume',
                value: '${stats.incoming}',
                color: AppTokens.callIncoming,
              ),
              _MetricStat(
                label: 'Incoming Time',
                value: '${h}h ${m}m',
                color: AppTokens.callIncoming,
              ),
              _MetricStat(
                label: 'Share of Total',
                value: stats.total > 0
                    ? '${((stats.incoming / stats.total) * 100).round()}%'
                    : '0%',
                color: AppTokens.textMuted,
              ),
            ],
          ),
        );

      case PopupFilterCategory.outgoing:
        final outgoingCalls = filtered;
        final totalSecs =
            outgoingCalls.fold<int>(0, (sum, e) => sum + e.durationSeconds);
        final (h, m) = Fmt.talkTime(totalSecs);
        return AppCard(
          borderColor: AppTokens.callOutgoing.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Outgoing Volume',
                value: '${stats.outgoing}',
                color: AppTokens.callOutgoing,
              ),
              _MetricStat(
                label: 'Outgoing Time',
                value: '${h}h ${m}m',
                color: AppTokens.callOutgoing,
              ),
              _MetricStat(
                label: 'Share of Total',
                value: stats.total > 0
                    ? '${((stats.outgoing / stats.total) * 100).round()}%'
                    : '0%',
                color: AppTokens.textMuted,
              ),
            ],
          ),
        );

      case PopupFilterCategory.missed:
        return AppCard(
          borderColor: AppTokens.callMissed.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Missed Calls',
                value: '${stats.missed}',
                color: AppTokens.callMissed,
              ),
              _MetricStat(
                label: 'Missed Ratio',
                value: stats.total > 0
                    ? '${((stats.missed / stats.total) * 100).round()}%'
                    : '0%',
                color: AppTokens.callMissed,
              ),
            ],
          ),
        );

      case PopupFilterCategory.avgDuration:
        return AppCard(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Avg Call Length',
                value: Fmt.duration(stats.averageDurationSeconds),
                color: AppTokens.brandIndigo,
              ),
              _MetricStat(
                label: 'Connected Calls',
                value: '${stats.answered}',
                color: AppTokens.success,
              ),
            ],
          ),
        );

      case PopupFilterCategory.recordings:
        return AppCard(
          borderColor: AppTokens.success.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Matched Audio',
                value: '${stats.recordingsMatched}',
                color: AppTokens.success,
              ),
              _MetricStat(
                label: 'Needs Review',
                value: '${stats.recordingsNeedReview}',
                color: stats.recordingsNeedReview > 0
                    ? AppTokens.warning
                    : AppTokens.textMuted,
              ),
              _MetricStat(
                label: 'No Audio',
                value: '${stats.recordingsAbsent}',
                color: AppTokens.textMuted,
              ),
            ],
          ),
        );

      case PopupFilterCategory.syncStatus:
        return const SizedBox.shrink();
    }
  }

  Widget _buildSyncStatusDetails(BuildContext context) {
    final countersAsync = ref.watch(syncCountersProvider);
    final syncState = ref.watch(syncServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        countersAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error loading sync status: $e'),
          data: (counts) {
            final uploaded = counts['uploaded'] ?? 0;
            final waiting = counts['waiting'] ?? 0;
            final failed = counts['failed'] ?? 0;
            final total = counts['total'] ?? 0;

            return Column(
              children: [
                AppCard(
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _MetricStat(
                            label: 'Synced',
                            value: '$uploaded',
                            color: AppTokens.success,
                          ),
                          _MetricStat(
                            label: 'Pending',
                            value: '$waiting',
                            color: AppTokens.warning,
                          ),
                          _MetricStat(
                            label: 'Failed',
                            value: '$failed',
                            color: AppTokens.danger,
                          ),
                          _MetricStat(
                            label: 'Total Local',
                            value: '$total',
                            color: AppTokens.brandElectric,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          onPressed: syncState.isLoading
                              ? null
                              : () async {
                                  await ref
                                      .read(syncServiceProvider.notifier)
                                      .triggerSync();
                                  ref.invalidate(syncCountersProvider);
                                },
                          icon: syncState.isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.sync_rounded),
                          label: Text(
                            syncState.isLoading
                                ? 'Syncing with server...'
                                : 'Sync Now',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTokens.brandElectric,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (syncState.asData?.value != null) ...[
                  const SectionLabel('Last Sync Result'),
                  const SizedBox(height: 8),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              syncState.asData!.value!.isSuccess
                                  ? Icons.check_circle_rounded
                                  : Icons.error_rounded,
                              color: syncState.asData!.value!.isSuccess
                                  ? AppTokens.success
                                  : AppTokens.danger,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              syncState.asData!.value!.isSuccess
                                  ? 'Sync completed successfully'
                                  : 'Sync failed',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Synced calls: ${syncState.asData!.value!.syncedCalls}\n'
                          'Uploaded recordings: ${syncState.asData!.value!.uploadedRecordings}\n'
                          'Failed calls: ${syncState.asData!.value!.failedCalls}',
                          style: const TextStyle(
                            color: AppTokens.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                        if (syncState.asData!.value!.errorMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Error: ${syncState.asData!.value!.errorMessage}',
                            style: const TextStyle(
                              color: AppTokens.danger,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _MetricStat extends StatelessWidget {
  const _MetricStat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
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
            label,
            style: const TextStyle(
              color: AppTokens.textMuted,
              fontWeight: FontWeight.w500,
              fontSize: 11.5,
            ),
          ),
        ],
      );
}
