import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
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
    final feed = ref.watch(callFeedProvider);
    final entries = feed.asData?.value.entries ?? const <CallEntry>[];

    final (title, subtitle, icon, color) = _getCategoryMetadata(context);
    final filteredCalls = _filterCalls(entries);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Column(
          children: [
            // Handle Bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.colors.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header Section
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
              child: Row(
                children: [
                  IconChip(icon: icon, color: color, size: 44, iconSize: 24),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: context.text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
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
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

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
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: InputDecoration(
                        hintText: 'Search number or contact...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        filled: true,
                        fillColor: context.colors.surfaceContainerLowest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: context.colors.outlineVariant),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: context.colors.outlineVariant),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    SectionLabel(
                      'Matched Records (${filteredCalls.length})',
                    ),
                    const SizedBox(height: 8),

                    if (filteredCalls.isEmpty)
                      AppCard(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.find_in_page_outlined,
                                size: 36,
                                color: context.palette.muted,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'No calls found matching filter',
                                style: context.text.bodyMedium?.copyWith(
                                  color: context.palette.muted,
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
                                Padding(
                                  padding: const EdgeInsets.only(left: 64),
                                  child: Divider(
                                    height: 1,
                                    color: context.colors.outlineVariant,
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
    final p = context.palette;
    return switch (widget.category) {
      PopupFilterCategory.talkTime => (
          'Talk Time Analytics',
          'Total calling duration & volume insights',
          Icons.access_time_filled_rounded,
          context.colors.primary,
        ),
      PopupFilterCategory.totalCalls => (
          'Total Phone Calls',
          'All tracked incoming, outgoing and missed calls',
          Icons.phone_in_talk_rounded,
          context.colors.primary,
        ),
      PopupFilterCategory.incoming => (
          'Incoming Calls',
          'Detailed breakdown of incoming communications',
          Icons.call_received_rounded,
          p.answered,
        ),
      PopupFilterCategory.outgoing => (
          'Outgoing Calls',
          'Overview of initiated call activity',
          Icons.call_made_rounded,
          context.colors.primary,
        ),
      PopupFilterCategory.missed => (
          'Missed Calls',
          'Unanswered incoming calls requiring attention',
          Icons.call_missed_rounded,
          p.missed,
        ),
      PopupFilterCategory.rejected => (
          'Rejected Calls',
          'Calls declined or rejected by recipient/user',
          Icons.phone_disabled_rounded,
          p.missed,
        ),
      PopupFilterCategory.neverAttended => (
          'Never Attended',
          'Calls that disconnected before connection',
          Icons.phone_paused_rounded,
          context.colors.primary,
        ),
      PopupFilterCategory.notPickup => (
          'Not Pickup by Client',
          'Outgoing calls where the client did not answer',
          Icons.call_end_rounded,
          p.muted,
        ),
      PopupFilterCategory.uniqueCalls => (
          'Unique Calls',
          'Distinct phone numbers contacted in this period',
          Icons.contact_phone_rounded,
          context.colors.primary,
        ),
      PopupFilterCategory.avgDuration => (
          'Call Duration Analysis',
          'Average length and duration trends',
          Icons.schedule_rounded,
          p.muted,
        ),
      PopupFilterCategory.recordings => (
          'Recording Management',
          'Matched audio recordings and server uploads',
          Icons.graphic_eq_rounded,
          p.answered,
        ),
      PopupFilterCategory.syncStatus => (
          'Cloud Sync Status',
          'Realtime outbox sync and server status',
          Icons.cloud_sync_rounded,
          p.waiting,
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
          borderColor: context.colors.primary.withValues(alpha: 0.3),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MetricStat(
                    label: 'Total Duration',
                    value: '${h}h ${m}m',
                    color: context.colors.primary,
                  ),
                  _MetricStat(
                    label: 'Total Calls',
                    value: '${stats.total}',
                    color: context.palette.answered,
                  ),
                  _MetricStat(
                    label: 'Answered Ratio',
                    value: stats.total > 0
                        ? '${((stats.answered / stats.total) * 100).round()}%'
                        : '0%',
                    color: context.palette.waiting,
                  ),
                ],
              ),
            ],
          ),
        );

      case PopupFilterCategory.rejected:
        return AppCard(
          borderColor: context.palette.missed.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Rejected Calls',
                value: '${stats.rejected}',
                color: context.palette.missed,
              ),
              _MetricStat(
                label: 'Share of Total',
                value: stats.total > 0
                    ? '${((stats.rejected / stats.total) * 100).round()}%'
                    : '0%',
                color: context.palette.muted,
              ),
            ],
          ),
        );

      case PopupFilterCategory.neverAttended:
        return AppCard(
          borderColor: context.colors.primary.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Never Attended',
                value: '${stats.neverAttended}',
                color: context.colors.primary,
              ),
              _MetricStat(
                label: 'Attention Needed',
                value: stats.neverAttended > 0 ? 'High' : 'None',
                color: stats.neverAttended > 0 ? context.palette.waiting : context.palette.answered,
              ),
            ],
          ),
        );

      case PopupFilterCategory.notPickup:
        return AppCard(
          borderColor: context.palette.muted.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Not Picked Up',
                value: '${stats.notPickupByClient}',
                color: context.palette.muted,
              ),
              _MetricStat(
                label: 'Outgoing Ratio',
                value: stats.outgoing > 0
                    ? '${((stats.notPickupByClient / stats.outgoing) * 100).round()}%'
                    : '0%',
                color: context.palette.waiting,
              ),
            ],
          ),
        );

      case PopupFilterCategory.uniqueCalls:
        return AppCard(
          borderColor: context.colors.primary.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Unique Contacts',
                value: '${stats.uniqueCalls}',
                color: context.colors.primary,
              ),
              _MetricStat(
                label: 'Avg Calls/Contact',
                value: stats.uniqueCalls > 0
                    ? (stats.total / stats.uniqueCalls).toStringAsFixed(1)
                    : '0',
                color: context.palette.answered,
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
          borderColor: context.palette.answered.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Incoming Volume',
                value: '${stats.incoming}',
                color: context.palette.answered,
              ),
              _MetricStat(
                label: 'Incoming Time',
                value: '${h}h ${m}m',
                color: context.palette.answered,
              ),
              _MetricStat(
                label: 'Share of Total',
                value: stats.total > 0
                    ? '${((stats.incoming / stats.total) * 100).round()}%'
                    : '0%',
                color: context.palette.muted,
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
          borderColor: context.colors.primary.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Outgoing Volume',
                value: '${stats.outgoing}',
                color: context.colors.primary,
              ),
              _MetricStat(
                label: 'Outgoing Time',
                value: '${h}h ${m}m',
                color: context.colors.primary,
              ),
              _MetricStat(
                label: 'Share of Total',
                value: stats.total > 0
                    ? '${((stats.outgoing / stats.total) * 100).round()}%'
                    : '0%',
                color: context.palette.muted,
              ),
            ],
          ),
        );

      case PopupFilterCategory.missed:
        return AppCard(
          borderColor: context.palette.missed.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Missed Calls',
                value: '${stats.missed}',
                color: context.palette.missed,
              ),
              _MetricStat(
                label: 'Missed Ratio',
                value: stats.total > 0
                    ? '${((stats.missed / stats.total) * 100).round()}%'
                    : '0%',
                color: context.palette.missed,
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
                color: context.palette.answered,
              ),
              _MetricStat(
                label: 'Connected Calls',
                value: '${stats.answered}',
                color: context.colors.primary,
              ),
            ],
          ),
        );

      case PopupFilterCategory.recordings:
        return AppCard(
          borderColor: context.palette.answered.withValues(alpha: 0.3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricStat(
                label: 'Matched Audio',
                value: '${stats.recordingsMatched}',
                color: context.palette.answered,
              ),
              _MetricStat(
                label: 'Needs Review',
                value: '${stats.recordingsNeedReview}',
                color: stats.recordingsNeedReview > 0
                    ? context.palette.waiting
                    : context.palette.muted,
              ),
              _MetricStat(
                label: 'No Audio',
                value: '${stats.recordingsAbsent}',
                color: context.palette.muted,
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
                            color: context.palette.answered,
                          ),
                          _MetricStat(
                            label: 'Pending',
                            value: '$waiting',
                            color: context.palette.waiting,
                          ),
                          _MetricStat(
                            label: 'Failed',
                            value: '$failed',
                            color: context.palette.missed,
                          ),
                          _MetricStat(
                            label: 'Total Local',
                            value: '$total',
                            color: context.colors.primary,
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
                            backgroundColor: context.colors.primary,
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
                  SectionLabel('Last Sync Result'),
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
                                  ? context.palette.answered
                                  : context.palette.missed,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              syncState.asData!.value!.isSuccess
                                  ? 'Sync completed successfully'
                                  : 'Sync failed',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Synced calls: ${syncState.asData!.value!.syncedCalls}\n'
                          'Uploaded recordings: ${syncState.asData!.value!.uploadedRecordings}\n'
                          'Failed calls: ${syncState.asData!.value!.failedCalls}',
                          style: context.text.bodySmall,
                        ),
                        if (syncState.asData!.value!.errorMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Error: ${syncState.asData!.value!.errorMessage}',
                            style: context.text.bodySmall?.copyWith(
                              color: context.palette.missed,
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
            style: context.text.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: context.text.labelSmall?.copyWith(
              color: context.palette.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
}
