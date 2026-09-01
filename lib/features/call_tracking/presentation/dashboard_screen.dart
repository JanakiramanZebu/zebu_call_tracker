import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/charts.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/call_feed.dart';
import '../domain/call_entry.dart';
import 'card_analytical_popup.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    super.key,
    required this.onSeeAllCalls,
    this.pendingSyncCount = 0,
  });

  final VoidCallback onSeeAllCalls;
  final int pendingSyncCount;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _tabIndex = 0; // 0: Summary, 1: Analysis

  Future<void> _refreshAnalytics() async {
    await ref.read(callFeedProvider.notifier).refresh();
    ref.invalidate(analyticsPeriodStatsProvider);
    ref.invalidate(analyticsHourlyActivityProvider);
    ref.invalidate(analyticsSparklineProvider);
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(callFeedProvider);
    final period = ref.watch(dashboardPeriodProvider);
    final rangeInfo = ref.watch(periodRangeInfoProvider);
    final statsAsync = ref.watch(analyticsPeriodStatsProvider);
    // The equivalent window immediately before this one. Every trend badge is
    // derived from it; null (All time, or no prior data) hides the badge rather
    // than inventing a number.
    final previousStats = ref.watch(analyticsPreviousStatsProvider).value;
    final sparklineAsync = ref.watch(analyticsSparklineProvider);
    final activityAsync = ref.watch(analyticsHourlyActivityProvider);
    final excludeNumbers = ref.watch(analyticsExcludeInternalProvider);

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: const Text(
          'Analytics',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 24,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppTokens.textSecondary),
            onPressed: _refreshAnalytics,
            tooltip: 'Refresh analytics',
          ),
          IconButton(
            icon: const Icon(Icons.filter_list_rounded, color: AppTokens.textSecondary),
            onPressed: () => _showFilterOptions(context),
            tooltip: 'Filters',
          ),
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
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
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
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTokens.brandElectric,
        backgroundColor: AppTokens.surface2,
        onRefresh: _refreshAnalytics,
        child: feed.when(
          loading: () => const DashboardSkeleton(),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load analytics',
            message: '$e',
            actionLabel: 'Try again',
            onAction: _refreshAnalytics,
          ),
          data: (state) {
            if (state.blocked) {
              return EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Call log access needed',
                message:
                    'Grant call log permission to track and analyze calls made on this device.',
                actionLabel: 'Review permissions',
                onAction: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              );
            }

            final CallStats stats = statsAsync.asData?.value ?? ref.watch(periodStatsProvider);
            final sparklineData = sparklineAsync.asData?.value ?? const [0, 0, 0, 0, 0, 0, 0, 0];
            final activityData = activityAsync.asData?.value ??
                (
                  incoming: List.filled(6, 0.0),
                  outgoing: List.filled(6, 0.0),
                  missed: List.filled(6, 0.0),
                );

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                // ── Filter Controls Row ──────────────────────────────────────
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // 1. Filter badge pill
                      _FilterPill(
                        icon: Icons.tune_rounded,
                        badgeCount: 2,
                        label: 'Filter',
                        onTap: () => _showFilterOptions(context),
                      ),
                      const SizedBox(width: 8),

                      // 2. Period selector pill
                      _DropdownPill(
                        label: _periodLabel(period),
                        onTap: () => _showPeriodSelector(context),
                      ),
                      const SizedBox(width: 8),

                      // 3. Exclude Number pill
                      _DropdownPill(
                        label: 'Ex. No.: ${excludeNumbers ? "Yes" : "No"}',
                        icon: excludeNumbers
                            ? Icons.check_circle_rounded
                            : Icons.cancel_rounded,
                        activeColor: excludeNumbers ? AppTokens.brandElectric : null,
                        onTap: () => ref
                            .read(analyticsExcludeInternalProvider.notifier)
                            .toggle(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // ── Compact Date Range Indicator ─────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTokens.surface1,
                    borderRadius: BorderRadius.circular(AppTokens.r8),
                    border: Border.all(color: AppTokens.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.calendar_month_rounded,
                        size: 15,
                        color: AppTokens.brandElectric,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          rangeInfo.formattedRange,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTokens.textSecondary,
                            letterSpacing: -0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── Summary vs Analysis Segmented Control ─────────────────────
                ModernSegmentedControl<int>(
                  segments: const {
                    0: 'Summary',
                    1: 'Analysis',
                  },
                  selected: _tabIndex,
                  onSelected: (idx) => setState(() => _tabIndex = idx),
                ),
                const SizedBox(height: 16),

                // ── Empty State Banner when 0 records match filter ──────────
                if (stats.total == 0) ...[
                  AppCard(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, color: AppTokens.textMuted, size: 20),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'No calls match the selected date and filters.',
                            style: TextStyle(color: AppTokens.textMuted, fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _showPeriodSelector(context),
                          child: const Text('Change Filter', style: TextStyle(color: AppTokens.brandElectric)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // ── Active Tab View ──────────────────────────────────────────
                if (_tabIndex == 0)
                  _buildSummaryTab(
                    context,
                    stats,
                    previousStats,
                    sparklineData,
                    activityData,
                  )
                else
                  _buildAnalysisTab(context, stats),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSummaryTab(
    BuildContext context,
    CallStats stats,
    CallStats? previous,
    List<double> sparklineData,
    ({List<double> incoming, List<double> outgoing, List<double> missed}) activityData,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── HERO METRIC CARD ────────────────────────────────────────────────
        _HeroMetricCard(
          totalCalls: stats.total,
          talkTimeSeconds: stats.talkTimeSeconds,
          sparklineData: sparklineData,
          onTap: () => CardAnalyticalPopup.show(
            context,
            category: PopupFilterCategory.totalCalls,
            stats: stats,
          ),
        ),
        const SizedBox(height: 14),

        // ── COMPACT 2x4 METRIC TILES ────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: MetricTile(
                title: 'Incoming Calls',
                count: '${stats.incoming}',
                duration: Fmt.exactDuration(stats.incomingDurationSeconds),
                icon: Icons.call_received_rounded,
                color: AppTokens.callIncoming,
                trend: trendLabel(stats.incoming, previous?.incoming),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.incoming,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                title: 'Outgoing Calls',
                count: '${stats.outgoing}',
                duration: Fmt.exactDuration(stats.outgoingDurationSeconds),
                icon: Icons.call_made_rounded,
                color: AppTokens.callOutgoing,
                trend: trendLabel(stats.outgoing, previous?.outgoing),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.outgoing,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              child: MetricTile(
                title: 'Missed Calls',
                count: '${stats.missed}',
                duration: '0h  0m 0s',
                icon: Icons.call_missed_rounded,
                color: AppTokens.callMissed,
                trend: trendLabel(stats.missed, previous?.missed),
                higherIsWorse: true,
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.missed,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                title: 'Rejected Calls',
                count: '${stats.rejected}',
                duration: '0h  0m 0s',
                icon: Icons.phone_disabled_rounded,
                color: AppTokens.callRejected,
                trend: trendLabel(stats.rejected, previous?.rejected),
                higherIsWorse: true,
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.rejected,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              child: MetricTile(
                title: 'Never Attended',
                count: '${stats.neverAttended}',
                icon: Icons.phone_paused_rounded,
                color: AppTokens.callNeverAttended,
                trend: trendLabel(stats.neverAttended, previous?.neverAttended),
                higherIsWorse: true,
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.neverAttended,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                title: 'Not Pickup by Client',
                count: '${stats.notPickupByClient}',
                icon: Icons.call_end_rounded,
                color: AppTokens.textMuted,
                trend: trendLabel(stats.notPickupByClient, previous?.notPickupByClient),
                higherIsWorse: true,
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.notPickup,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              child: MetricTile(
                title: 'Unique Calls',
                count: '${stats.uniqueCalls}',
                icon: Icons.contact_phone_rounded,
                color: AppTokens.brandPurple,
                trend: trendLabel(stats.uniqueCalls, previous?.uniqueCalls),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.uniqueCalls,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                title: 'Avg Duration',
                count: Fmt.duration(stats.averageDurationSeconds),
                icon: Icons.timer_outlined,
                color: AppTokens.brandIndigo,
                trend: trendLabel(stats.averageDurationSeconds, previous?.averageDurationSeconds),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.totalCalls,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // ── CALL ACTIVITY CHART ─────────────────────────────────────────────
        AppCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Call Activity',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                  Text(
                    '${stats.total} total calls',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppTokens.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              CallActivityChart(
                incomingPoints: activityData.incoming,
                outgoingPoints: activityData.outgoing,
                missedPoints: activityData.missed,
                labels: const ['12A', '4A', '8A', '12P', '4P', '8P'],
                height: 160,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // ── INSIGHTS SECTION ────────────────────────────────────────────────
        const SectionLabel('Call Insights'),
        const SizedBox(height: 8),
        _buildInsightsGrid(stats),
      ],
    );
  }

  Widget _buildAnalysisTab(
    BuildContext context,
    CallStats stats,
  ) {
    final answeredRate = stats.answeredRate;
    final missedRate = stats.missedRate;
    // Against recordable calls, not every call — see CallStats.recordingCoverageRate.
    final recordingRate = stats.recordingCoverageRate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Answered vs Missed Breakdown Card ──
        AppCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Answered vs Missed Distribution',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              MiniBarDistribution(
                height: 10,
                segments: [
                  DistributionSegment(
                    label: 'Answered',
                    value: stats.answered.toDouble(),
                    color: AppTokens.success,
                  ),
                  DistributionSegment(
                    label: 'Missed',
                    value: stats.missed.toDouble(),
                    color: AppTokens.danger,
                  ),
                  DistributionSegment(
                    label: 'Rejected',
                    value: stats.rejected.toDouble(),
                    color: AppTokens.warning,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _AnalysisStatItem(
                    label: 'Answered Rate',
                    value: '${answeredRate.toStringAsFixed(1)}%',
                    color: AppTokens.success,
                  ),
                  _AnalysisStatItem(
                    label: 'Missed Rate',
                    value: '${missedRate.toStringAsFixed(1)}%',
                    color: AppTokens.danger,
                  ),
                  _AnalysisStatItem(
                    label: 'Talk Time',
                    value: Fmt.duration(stats.talkTimeSeconds),
                    color: AppTokens.brandElectric,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Call Directions Ratio ──
        AppCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Volume by Direction',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              MiniBarDistribution(
                height: 10,
                segments: [
                  DistributionSegment(
                    label: 'Incoming',
                    value: stats.incoming.toDouble(),
                    color: AppTokens.callIncoming,
                  ),
                  DistributionSegment(
                    label: 'Outgoing',
                    value: stats.outgoing.toDouble(),
                    color: AppTokens.callOutgoing,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _AnalysisStatItem(
                    label: 'Incoming Volume',
                    value: '${stats.incoming}',
                    color: AppTokens.callIncoming,
                  ),
                  _AnalysisStatItem(
                    label: 'Outgoing Volume',
                    value: '${stats.outgoing}',
                    color: AppTokens.callOutgoing,
                  ),
                  _AnalysisStatItem(
                    label: 'Unique Contacts',
                    value: '${stats.uniqueCalls}',
                    color: AppTokens.brandPurple,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Recording Ingestion Availability ──
        AppCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Recording Ingestion Status',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              MiniBarDistribution(
                height: 10,
                segments: [
                  DistributionSegment(
                    label: 'Matched',
                    value: stats.recordingsMatched.toDouble(),
                    color: AppTokens.success,
                  ),
                  DistributionSegment(
                    label: 'Review',
                    value: stats.recordingsNeedReview.toDouble(),
                    color: AppTokens.warning,
                  ),
                  DistributionSegment(
                    label: 'No Audio',
                    value: stats.recordingsAbsent.toDouble(),
                    color: AppTokens.textDisabled,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                stats.recordingEligible == 0
                    ? 'No connected calls in this period.'
                    : 'Of ${stats.recordingEligible} recordable '
                        '${stats.recordingEligible == 1 ? "call" : "calls"}. '
                        '${stats.recordingsNotApplicable} unanswered '
                        '${stats.recordingsNotApplicable == 1 ? "call" : "calls"} excluded.',
                style: const TextStyle(
                  color: AppTokens.textMuted,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _AnalysisStatItem(
                    label: 'Matched Audio',
                    value: '${stats.recordingsMatched}',
                    color: AppTokens.success,
                  ),
                  _AnalysisStatItem(
                    label: 'Needs Review',
                    value: '${stats.recordingsNeedReview}',
                    color: AppTokens.warning,
                  ),
                  _AnalysisStatItem(
                    label: 'Matched Rate',
                    value: '${recordingRate.toStringAsFixed(1)}%',
                    color: AppTokens.info,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInsightsGrid(CallStats stats) {
    final missedRate = '${stats.missedRate.toStringAsFixed(1)}%';

    return Row(
      children: [
        Expanded(
          child: _InsightTile(
            icon: Icons.schedule_rounded,
            label: 'Peak Time',
            // Computed from the period's connected calls. This tile used to
            // print a fixed "10 AM – 12 PM" whatever the data said.
            value: _peakWindowLabel(stats.peakHourStart),
            color: AppTokens.brandElectric,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InsightTile(
            icon: Icons.trending_down_rounded,
            label: 'Missed Call Rate',
            value: missedRate,
            color: AppTokens.danger,
          ),
        ),
      ],
    );
  }

  /// Formats the busiest two-hour band, e.g. `10 AM – 12 PM`.
  static String _peakWindowLabel(int? startHour) {
    if (startHour == null) return 'No data';
    String label(int hour) {
      final h = hour % 24;
      final suffix = h < 12 ? 'AM' : 'PM';
      final display = h % 12 == 0 ? 12 : h % 12;
      return '$display $suffix';
    }

    return '${label(startHour)} – ${label(startHour + 2)}';
  }

  String _periodLabel(DashboardPeriod p) => switch (p) {
        DashboardPeriod.today => 'Today',
        DashboardPeriod.yesterday => 'Yesterday',
        DashboardPeriod.week => 'This Week',
        DashboardPeriod.month => 'This Month',
        DashboardPeriod.all => 'All Time',
      };

  void _showPeriodSelector(BuildContext context) {
    final current = ref.read(dashboardPeriodProvider);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTokens.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: AppTokens.borderDefault),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTokens.borderDefault,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Select Time Period',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              for (final p in DashboardPeriod.values)
                ListTile(
                  title: Text(
                    _periodLabel(p),
                    style: TextStyle(
                      fontWeight:
                          p == current ? FontWeight.w700 : FontWeight.w500,
                      color: p == current ? AppTokens.brandElectric : Colors.white,
                    ),
                  ),
                  trailing: p == current
                      ? const Icon(
                          Icons.check_rounded,
                          color: AppTokens.brandElectric,
                        )
                      : null,
                  onTap: () {
                    ref.read(dashboardPeriodProvider.notifier).select(p);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFilterOptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTokens.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: AppTokens.borderDefault),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final isExcluded = ref.watch(analyticsExcludeInternalProvider);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Analytics Filters',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppTokens.brandElectric,
                    title: const Text(
                      'Exclude Internal Employee Calls',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      'Hides intra-company team calls from analytics',
                      style: TextStyle(color: AppTokens.textMuted),
                    ),
                    value: isExcluded,
                    onChanged: (val) {
                      ref.read(analyticsExcludeInternalProvider.notifier).set(val);
                      setModalState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Apply Filters'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Hero Metric Card ─────────────────────────────────────────────────────────
class _HeroMetricCard extends StatelessWidget {
  const _HeroMetricCard({
    required this.totalCalls,
    required this.talkTimeSeconds,
    required this.sparklineData,
    this.onTap,
  });

  final int totalCalls;
  final int talkTimeSeconds;
  final List<double> sparklineData;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Phone Calls',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: AppTokens.textMuted,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTokens.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppTokens.success.withValues(alpha: 0.3),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_upward_rounded,
                      size: 12,
                      color: AppTokens.success,
                    ),
                    SizedBox(width: 3),
                    Text(
                      '+12% vs last period',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTokens.success,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$totalCalls',
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: -0.6,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '· ${Fmt.exactDuration(talkTimeSeconds)} total duration',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppTokens.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Mini Area Sparkline chart
          MiniSparkline(
            data: sparklineData,
            height: 48,
            lineColor: AppTokens.brandElectric,
          ),
        ],
      ),
    );
  }
}

// ── Filter Pill Components ───────────────────────────────────────────────────
class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.icon,
    required this.badgeCount,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final int badgeCount;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.r20),
        child: Ink(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTokens.surface1,
            borderRadius: BorderRadius.circular(AppTokens.r20),
            border: Border.all(color: AppTokens.borderDefault),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 6),
              Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  color: AppTokens.brandElectric,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropdownPill extends StatelessWidget {
  const _DropdownPill({
    required this.label,
    required this.onTap,
    this.icon,
    this.activeColor,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.r20),
        child: Ink(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTokens.surface1,
            borderRadius: BorderRadius.circular(AppTokens.r20),
            border: Border.all(
              color: activeColor?.withValues(alpha: 0.5) ?? AppTokens.borderDefault,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: activeColor ?? AppTokens.textSecondary),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: activeColor ?? Colors.white,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: activeColor ?? AppTokens.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnalysisStatItem extends StatelessWidget {
  const _AnalysisStatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: AppTokens.textMuted),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: color,
            letterSpacing: -0.3,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _InsightTile extends StatelessWidget {
  const _InsightTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          IconChip(icon: icon, color: color, size: 32, iconSize: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTokens.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
