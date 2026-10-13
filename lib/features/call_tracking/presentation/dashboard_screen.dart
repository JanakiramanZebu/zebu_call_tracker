import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/charts.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../synchronization/data/sync_health_provider.dart';
import '../../synchronization/data/sync_service.dart';
import '../../synchronization/presentation/sync_alert_banner.dart';
import '../data/call_feed.dart';
import 'call_detail_screen.dart';
import 'card_analytical_popup.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  // The day strip's input, rebuilt only when the period's rows change. Mapping
  // them on every rebuild would also hand the strip a new list each time and
  // make it re-derive its marks.
  Object? _stripFrom;
  List<StripCall> _stripCalls = const [];

  /// Picks up calls made since the last catch-up.
  ///
  /// The numbers here come from the database, and new calls reach it through
  /// ingest, which a sync runs first; the analytics streams then update the
  /// screen on their own. Invalidating them as well only re-ran the queries.
  Future<void> _refresh() async {
    await ref.read(syncServiceProvider.notifier).triggerSync();
    await ref.read(callFeedProvider.notifier).refresh();
  }

  void _openSettings() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

  static String _greeting(DateTime now) => now.hour < 12
      ? 'Good morning'
      : now.hour < 17
      ? 'Good afternoon'
      : 'Good evening';

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    // Only whether the feed can be shown at all — not its rows. Watching the
    // whole feed rebuilt this screen on every page the Calls tab loaded.
    final feed = ref.watch(
      callFeedProvider.select(
        (f) => (
          ready: f.hasValue,
          blocked: f.value?.blocked ?? false,
          error: f.hasValue ? null : f.error,
        ),
      ),
    );
    final analytics = ref.watch(analyticsPeriodProvider);

    return Scaffold(
      backgroundColor: z.canvas,
      // No AppBar and no SafeArea: the blue panel runs up under the status
      // bar and pads its own content below it; the shell's bottom nav already
      // handles the navigation bar.
      body: RefreshIndicator(
        color: z.accent,
        backgroundColor: z.raised,
        edgeOffset: context.safeTop,
        onRefresh: _refresh,
        child: _content(context, feed, analytics),
      ),
    );
  }

  /// The panel's top row: the mark, the greeting and the screen's actions.
  Widget _panelHeader() {
    final hideInternal = ref.watch(analyticsExcludeInternalProvider);
    return _PanelHeader(
      greeting: _greeting(DateTime.now()),
      // Period has its own tabs; the sheet holds the rest, and "hide
      // internal calls" is the only one there.
      activeFilters: hideInternal ? 1 : 0,
      onFilter: () => _showFilterOptions(context),
      onRefresh: _refresh,
      onSettings: _openSettings,
    );
  }

  Widget _content(
    BuildContext context,
    ({bool ready, bool blocked, Object? error}) feed,
    AsyncValue<PeriodAnalytics> analytics,
  ) {
    // Every state keeps the panel's top row, so settings and refresh are
    // always one tap away; only a loaded period gets the full summary.
    Widget framed(Widget body) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BrandPanel(children: [_panelHeader()]),
        Expanded(child: body),
      ],
    );

    if (feed.error case final error?) {
      return framed(
        ErrorStateView(
          error: error,
          logContext: 'DASHBOARD',
          fallbackTitle: "Couldn't load your calls",
          onRetry: _refresh,
        ),
      );
    }
    if (feed.ready && feed.blocked) {
      return framed(
        EmptyState(
          icon: Icons.lock_outline_rounded,
          title: 'Call log access needed',
          message:
              'Allow access to your call log so the app can track your '
              'calls and send them to the CRM.',
          actionLabel: 'Review permissions',
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PermissionScreen()),
          ),
        ),
      );
    }
    if (!analytics.hasValue && analytics.error != null) {
      return framed(
        ErrorStateView(
          error: analytics.error!,
          logContext: 'DASHBOARD',
          fallbackTitle: "Couldn't load your numbers",
          onRetry: () => ref.invalidate(analyticsPeriodProvider),
        ),
      );
    }
    // A skeleton only before the first numbers arrive. Changing the period
    // keeps the previous figures up until the new ones land.
    final data = analytics.value;
    if (!feed.ready || data == null) return framed(const DashboardSkeleton());
    return _buildBody(context, data);
  }

  List<StripCall> _stripCallsFor(PeriodAnalytics data) {
    if (identical(_stripFrom, data.calls)) return _stripCalls;
    _stripFrom = data.calls;
    return _stripCalls = [
      for (final c in data.calls)
        StripCall(c.startedAt.toLocal(), c.durationSeconds),
    ];
  }

  Widget _buildBody(BuildContext context, PeriodAnalytics data) {
    final z = context.z;
    final stats = data.stats;
    final period = ref.watch(dashboardPeriodProvider);
    final rangeInfo = ref.watch(periodRangeInfoProvider);
    // The equivalent window immediately before this one. The trend is derived
    // from it; null (All time, or no prior data) hides it rather than
    // inventing a number.
    final previous = ref.watch(analyticsPreviousStatsProvider).value;

    void open(PopupFilterCategory category) =>
        CardAnalyticalPopup.show(context, category: category, stats: stats);
    String pct(int part) =>
        stats.total == 0 ? '0%' : '${(part / stats.total * 100).round()}%';

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      // Inside the shell, whose bottom nav already took the system inset;
      // scrollPadding adds whatever inset is still left, so the last row is
      // never under the phone's navigation buttons. Ledger layout: rows run
      // edge to edge and indent their own content.
      padding: context.scrollPadding(top: 0, bottom: 32, horizontal: 0),
      children: [
        _BrandPanel(
          children: [
            _panelHeader(),
            const SizedBox(height: 12),
            UnderlineTabs<DashboardPeriod>(
              onBrand: true,
              padding: EdgeInsets.zero,
              semanticLabel: 'Period',
              segments: {
                for (final p in DashboardPeriod.values) p: _periodLabel(p),
              },
              selected: period,
              onSelected: (p) =>
                  ref.read(dashboardPeriodProvider.notifier).select(p),
            ),
            const SizedBox(height: 18),
            _Headline(
              total: stats.total,
              trend: trendLabel(stats.total, previous?.total),
              previousName: _previousName(period),
              onTap: () => open(PopupFilterCategory.totalCalls),
            ),
            const SizedBox(height: 8),
            Text(
              stats.total == 0
                  ? 'No calls in this period'
                  : stats.answered == 0
                  ? 'No talk time yet'
                  : '${Fmt.duration(stats.talkTimeSeconds)} on calls, '
                        '${Fmt.duration(stats.averageDurationSeconds)} average',
              style: AppType.tabular(
                AppType.small,
              ).copyWith(color: AppTokens.onBrandMuted),
            ),
            const SizedBox(height: 22),
            Text(
              rangeInfo.formattedRange,
              style: AppType.labelStrong.copyWith(color: AppTokens.onBrand),
            ),
            const SizedBox(height: 10),
            // Replaces the old call-activity chart and the hero sparkline:
            // the same calls, placed where they happened.
            CallDayStrip(
              calls: _stripCallsFor(data),
              rangeStart: rangeInfo.start,
              rangeEnd: rangeInfo.end,
            ),
          ],
        ),

        const _SendStatusLine(),
        // Anything stopping sync, above the numbers. Analytics that look
        // healthy sitting on top of a revoked device is exactly the
        // reassurance nobody should be given.
        const _AlertsSlot(),

        if (stats.total == 0)
          _EmptyPeriod(
            onShowAll: period == DashboardPeriod.all
                ? null
                : () => ref
                      .read(dashboardPeriodProvider.notifier)
                      .select(DashboardPeriod.all),
          )
        else ...[
          // ── Outcome ──────────────────────────────────────────────────────
          // Every call lands in exactly one of these four. They were the
          // Analysis tab's "Answered vs missed" card and three of the old
          // metric tiles.
          _Section(
            top: 24,
            header: SectionHeader(
              'Outcome',
              padding: EdgeInsets.zero,
              trailing: Text(
                '${stats.answeredRate.round()}% answered',
                style: AppType.tabular(AppType.label),
              ),
            ),
            lead: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: MiniBarDistribution(
                semanticLabel:
                    '${stats.answered} answered, '
                    '${stats.neverAttended} missed, '
                    '${stats.notPickupByClient} not picked up, '
                    '${stats.rejected} rejected',
                segments: [
                  DistributionSegment(
                    label: 'Answered',
                    value: stats.answered.toDouble(),
                    color: z.accent,
                  ),
                  DistributionSegment(
                    label: 'Missed',
                    value: stats.neverAttended.toDouble(),
                    color: z.missed,
                  ),
                  DistributionSegment(
                    label: 'Not picked up',
                    value: stats.notPickupByClient.toDouble(),
                    color: z.noAnswer,
                  ),
                  DistributionSegment(
                    label: 'Rejected',
                    value: stats.rejected.toDouble(),
                    color: z.rejected,
                  ),
                ],
              ),
            ),
            rows: [
              _LedgerRow(
                leading: _Swatch(z.accent),
                label: 'Answered',
                note: pct(stats.answered),
                value: '${stats.answered}',
                onTap: () => open(PopupFilterCategory.answered),
              ),
              // One row for every incoming call nobody answered. "Missed"
              // and "Incoming Not Answered" used to sit side by side and
              // almost always showed the same number.
              _LedgerRow(
                leading: _Swatch(z.missed),
                label: 'Missed',
                note: pct(stats.neverAttended),
                value: '${stats.neverAttended}',
                onTap: () => open(PopupFilterCategory.missed),
              ),
              _LedgerRow(
                leading: _Swatch(z.noAnswer),
                label: 'Not picked up',
                note: pct(stats.notPickupByClient),
                value: '${stats.notPickupByClient}',
                onTap: () => open(PopupFilterCategory.notPickup),
              ),
              _LedgerRow(
                leading: _Swatch(z.rejected),
                label: 'Rejected',
                note: pct(stats.rejected),
                value: '${stats.rejected}',
                onTap: () => open(PopupFilterCategory.rejected),
              ),
            ],
          ),

          // ── Direction ────────────────────────────────────────────────────
          _Section(
            top: 20,
            header: const SectionHeader('Direction', padding: EdgeInsets.zero),
            rows: [
              _LedgerRow(
                leading: CallGlyph(
                  CallGlyphKind.incoming,
                  size: 14,
                  color: z.incoming,
                ),
                label: 'Incoming',
                note: Fmt.duration(stats.incomingDurationSeconds),
                value: '${stats.incoming}',
                onTap: () => open(PopupFilterCategory.incoming),
              ),
              _LedgerRow(
                leading: CallGlyph(
                  CallGlyphKind.outgoing,
                  size: 14,
                  color: z.outgoing,
                ),
                label: 'Outgoing',
                note: Fmt.duration(stats.outgoingDurationSeconds),
                value: '${stats.outgoing}',
                onTap: () => open(PopupFilterCategory.outgoing),
              ),
              _LedgerRow(
                leading: Icon(
                  Icons.person_outline_rounded,
                  size: 16,
                  color: z.ink3,
                ),
                label: 'People reached',
                note: 'unique numbers',
                value: '${stats.uniqueCalls}',
                onTap: () => open(PopupFilterCategory.uniqueCalls),
              ),
            ],
          ),

          // ── Timing ───────────────────────────────────────────────────────
          // What the old "Call insights" tiles said, as two plain rows.
          _Section(
            top: 20,
            header: const SectionHeader('Timing', padding: EdgeInsets.zero),
            rows: [
              _LedgerRow(
                label: 'Busiest time',
                // Computed from the period's connected calls. This used to
                // print a fixed "10 AM – 12 PM" whatever the data said.
                value: _peakWindowLabel(stats.peakHourStart),
              ),
              _LedgerRow(
                label: 'Average call',
                value: Fmt.duration(stats.averageDurationSeconds),
              ),
            ],
          ),
        ],

        // ── Latest calls ───────────────────────────────────────────────────
        const _RecentCalls(),
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

  static String _periodLabel(DashboardPeriod p) => switch (p) {
    DashboardPeriod.today => 'Today',
    DashboardPeriod.yesterday => 'Yesterday',
    DashboardPeriod.week => 'This week',
    DashboardPeriod.month => 'This month',
    DashboardPeriod.all => 'All time',
  };

  /// What the trend is measured against: the same-length window just before.
  static String _previousName(DashboardPeriod p) => switch (p) {
    DashboardPeriod.today => 'yesterday',
    DashboardPeriod.yesterday => 'the day before',
    _ => 'the period before',
  };

  /// The sheet takes its surface, top corners and drag handle from the
  /// theme, and pads its content up from the system navigation bar.
  void _showFilterOptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      // Its own Consumer: the sheet's switch follows the setting without the
      // dashboard watching from inside a builder it does not own.
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final z = context.z;
          return BottomSafe(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.gutter,
                      0,
                      AppTokens.gutter,
                      12,
                    ),
                    child: Semantics(
                      header: true,
                      child: Text('Filters', style: AppType.heading),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.symmetric(
                        horizontal: BorderSide(color: z.line),
                      ),
                    ),
                    child: SwitchListTile(
                      contentPadding: const EdgeInsets.fromLTRB(
                        AppTokens.gutter,
                        6,
                        12,
                        6,
                      ),
                      title: Text(
                        'Hide internal calls',
                        style: AppType.bodyMedium.copyWith(color: z.ink),
                      ),
                      subtitle: Text(
                        'Leaves out calls to office extensions (numbers of 4 '
                        'digits or fewer).',
                        style: AppType.label.copyWith(
                          color: z.ink3,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      value: ref.watch(analyticsExcludeInternalProvider),
                      onChanged: (val) => ref
                          .read(analyticsExcludeInternalProvider.notifier)
                          .set(val),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.gutter,
                      20,
                      AppTokens.gutter,
                      0,
                    ),
                    child: ZButton(
                      label: 'Done',
                      size: ZButtonSize.large,
                      onPressed: () => Navigator.of(context).pop(),
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

// ── Brand panel ──────────────────────────────────────────────────────────────

/// The one bold element on Home: a full-bleed Zebu-blue panel from the top
/// of the screen. Blue in both themes, so the status-bar icons over it are
/// always light.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
    child: ColoredBox(
      color: AppTokens.zebuBlue,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppTokens.gutter,
          context.safeTop + 12,
          AppTokens.gutter,
          20,
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: AppTokens.onBrand),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    ),
  );
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.greeting,
    required this.activeFilters,
    required this.onFilter,
    required this.onRefresh,
    required this.onSettings,
  });

  final String greeting;

  /// Filters switched on in the sheet. The badge shows only when one is.
  final int activeFilters;
  final VoidCallback onFilter;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final filtered = activeFilters > 0;
    return Row(
      children: [
        const ZebuAppMark(size: 32, inverse: true),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Call Tracker',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.bodyStrong.copyWith(
                    color: AppTokens.onBrand,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                greeting,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.label.copyWith(
                  color: AppTokens.onBrandMuted,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        // The icons' 44px hit areas overhang the gutter so the glyphs line up
        // with the panel's right edge.
        Transform.translate(
          offset: const Offset(10, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  TapIcon(
                    icon: Icons.tune_rounded,
                    tooltip: filtered
                        ? 'Filters, $activeFilters on'
                        : 'Filters',
                    color: AppTokens.onBrand,
                    onTap: onFilter,
                  ),
                  if (filtered)
                    Positioned(
                      top: 6,
                      right: 4,
                      child: IgnorePointer(
                        child: Container(
                          width: 16,
                          height: 16,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: AppTokens.onBrand,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '$activeFilters',
                            style: AppType.tabular(
                              AppType.micro,
                            ).copyWith(color: AppTokens.zebuBlue, height: 1),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              TapIcon(
                icon: Icons.refresh_rounded,
                tooltip: 'Refresh',
                color: AppTokens.onBrand,
                onTap: onRefresh,
              ),
              TapIcon(
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                color: AppTokens.onBrand,
                onTap: onSettings,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The period's call count, large, with the trend against the window before
/// it at the right. Tapping opens the list of every call.
class _Headline extends StatelessWidget {
  const _Headline({
    required this.total,
    required this.trend,
    required this.previousName,
    required this.onTap,
  });

  final int total;

  /// From [trendLabel]; null hides it.
  final String? trend;
  final String previousName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final trend = this.trend;
    return Semantics(
      button: true,
      label:
          '$total ${total == 1 ? 'call' : 'calls'}'
          '${trend == null ? '' : trend == 'New' ? ', none $previousName' : ', $trend vs $previousName'}'
          '. Show all calls',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.r8),
        splashColor: AppTokens.onBrand.withValues(alpha: 0.16),
        highlightColor: Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$total',
                      maxLines: 1,
                      style: AppType.display.copyWith(color: AppTokens.onBrand),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      total == 1 ? 'call' : 'calls',
                      style: AppType.barTitle.copyWith(
                        color: AppTokens.onBrandMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Measured against the previous window of the same length. This
            // used to read "+12% vs last period", in green, always.
            if (trend != null) ...[
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      trend,
                      style: AppType.tabular(
                        AppType.bodyStrong,
                      ).copyWith(color: AppTokens.onBrand, fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      trend == 'New'
                          ? 'none $previousName'
                          : 'vs $previousName',
                      style: AppType.caption.copyWith(
                        color: AppTokens.onBrandMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Status and alerts ────────────────────────────────────────────────────────

/// One line saying whether the CRM has every call, and a way to the Sync tab.
///
/// Its own widget, selecting just the numbers it shows, so queue changes
/// rebuild this line and nothing else on the dashboard.
class _SendStatusLine extends ConsumerWidget {
  const _SendStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final counts = ref.watch(
      syncCountersProvider.select((a) {
        final c = a.value;
        if (c == null) return null;
        return (
          waiting: c['waiting'] ?? 0,
          uploading: c['uploading'] ?? 0,
          failed: c['failed'] ?? 0,
        );
      }),
    );
    if (counts == null) return const SizedBox.shrink();

    String calls(int n) => n == 1 ? '1 call' : '$n calls';
    final (Color color, bool pulse, String title, String subtitle) =
        counts.failed > 0
        ? (
            z.danger,
            false,
            "${calls(counts.failed)} couldn't be sent",
            'Open Sync to see why and send again',
          )
        : counts.uploading > 0
        ? (
            z.accent,
            true,
            'Sending ${calls(counts.uploading + counts.waiting)} to Zebu CRM',
            'This takes a few seconds',
          )
        : counts.waiting > 0
        ? (
            z.warn,
            false,
            '${calls(counts.waiting)} waiting to send',
            'Goes out automatically when online',
          )
        : (
            z.ok,
            false,
            'All calls sent to Zebu CRM',
            'Nothing is waiting on this phone',
          );

    return Material(
      color: z.raised,
      child: InkWell(
        onTap: () => ref.read(homeTabProvider.notifier).show(HomeTab.sync),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.gutter,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: z.line)),
          ),
          child: Row(
            children: [
              StatusDot(color: color, size: 10, pulse: pulse),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppType.tabular(
                        AppType.bodyStrong,
                      ).copyWith(color: z.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppType.label.copyWith(
                        color: z.ink3,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: z.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// [SyncAlertBanner] in the gutter, taking no space when there is nothing
/// to say.
class _AlertsSlot extends ConsumerWidget {
  const _AlertsSlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final none = ref.watch(syncAlertsProvider.select((a) => a.isEmpty));
    if (none) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.fromLTRB(AppTokens.gutter, 16, AppTokens.gutter, 0),
      child: SyncAlertBanner(),
    );
  }
}

// ── Sections and rows ────────────────────────────────────────────────────────

/// A content section inside the gutter: a heading, an optional lead (the
/// share bar), and ruled rows.
class _Section extends StatelessWidget {
  const _Section({
    required this.top,
    required this.header,
    required this.rows,
    this.lead,
  });

  final double top;
  final Widget header;
  final Widget? lead;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(AppTokens.gutter, top, AppTokens.gutter, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (lead != null) lead! else const SizedBox(height: 4),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          rows[i],
        ],
      ],
    ),
  );
}

/// A 10px rounded colour swatch naming an outcome in the share bar.
class _Swatch extends StatelessWidget {
  const _Swatch(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// One ruled figure row: optional mark, label, a muted note (a share or a
/// duration), the figure right-aligned, and a chevron when it opens a list.
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({
    required this.label,
    required this.value,
    this.leading,
    this.note,
    this.onTap,
  });

  final Widget? leading;
  final String label;
  final String? note;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  if (leading != null) ...[
                    SizedBox(width: 16, child: Center(child: leading)),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      style: AppType.body.copyWith(color: z.ink),
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      note!,
                      style: AppType.tabular(
                        AppType.label,
                      ).copyWith(color: z.ink3, fontWeight: FontWeight.w400),
                    ),
                  ],
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 44),
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: AppType.tabular(
                        AppType.bodyStrong,
                      ).copyWith(color: z.ink),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded, size: 18, color: z.ink3),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// No calls in the selected period: say so, and offer the widest one.
class _EmptyPeriod extends StatelessWidget {
  const _EmptyPeriod({required this.onShowAll});

  /// Null when the period is already All time.
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        28,
        AppTokens.gutter,
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No calls in this period', style: AppType.heading),
          const SizedBox(height: 6),
          Text(
            'Calls you make or receive appear here a few seconds after they '
            'end. Pick another period above to look further back.',
            style: AppType.small.copyWith(color: z.ink2),
          ),
          if (onShowAll != null) ...[
            const SizedBox(height: 8),
            ZButton(
              label: 'Show all time',
              variant: ZButtonVariant.text,
              size: ZButtonSize.compact,
              expand: false,
              onPressed: onShowAll,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Latest calls ─────────────────────────────────────────────────────────────
/// The latest few calls, with a jump to the Calls tab.
///
/// Its own widget selecting only the feed's row list — which keeps its
/// identity while the Calls tab shows its load-more spinner — so the rest of
/// the dashboard still never rebuilds for feed changes.
class _RecentCalls extends ConsumerWidget {
  const _RecentCalls();

  static const _count = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(callFeedProvider.select((f) => f.value?.entries));
    if (entries == null || entries.isEmpty) return const SizedBox.shrink();
    final recent = entries.take(_count).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        SectionHeader(
          'Latest calls',
          padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 0, 8, 0),
          trailing: ZButton(
            label: 'View all',
            variant: ZButtonVariant.text,
            size: ZButtonSize.small,
            expand: false,
            onPressed: () =>
                ref.read(homeTabProvider.notifier).show(HomeTab.calls),
          ),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < recent.length; i++)
          CardListSlice(
            first: i == 0,
            last: i == recent.length - 1,
            child: CallRowTile(
              entry: recent[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CallDetailScreen(entry: recent[i]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
