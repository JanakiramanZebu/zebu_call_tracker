import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
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
  int _subTabIndex = 0; // 0: Summary, 1: Analysis
  bool _excludeNumbers = true;

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(callFeedProvider);
    final period = ref.watch(dashboardPeriodProvider);
    final rangeInfo = ref.watch(periodRangeInfoProvider);
    final stats = ref.watch(periodStatsProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? const Color(0xFFF8FAFC)
          : const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: const Text(
          'Analytics',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 26,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.read(callFeedProvider.notifier).refresh(),
            tooltip: 'Refresh analytics',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
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
                    Icon(Icons.settings_outlined, size: 20),
                    SizedBox(width: 10),
                    Text('Settings'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(callFeedProvider.notifier).refresh(),
        child: feed.when(
          loading: () => const DashboardSkeleton(),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not read calls',
            message: '$e',
            actionLabel: 'Try again',
            onAction: () => ref.read(callFeedProvider.notifier).refresh(),
          ),
          data: (state) {
            if (state.blocked) {
              return EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Call log access needed',
                message:
                    'Grant call log access so calls made on this device can be '
                    'tracked against your employee record.',
                actionLabel: 'Review permissions',
                onAction: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              );
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                // ── Filter Buttons Row ──────────────────────────────────────────
                Row(
                  children: [
                    // 1. Filter button with badge 2
                    _FilterPill(
                      icon: Icons.filter_alt_rounded,
                      badgeCount: 2,
                      label: 'Filter',
                      onTap: () => _showFilterOptions(context),
                    ),
                    const SizedBox(width: 8),

                    // 2. Period dropdown pill
                    _DropdownPill(
                      label: _periodLabel(period),
                      onTap: () => _showPeriodSelector(context),
                    ),
                    const SizedBox(width: 8),

                    // 3. Exclude Number pill
                    _DropdownPill(
                      label: 'Ex. No.:${_excludeNumbers ? "Yes" : "No"}',
                      onTap: () {
                        setState(() {
                          _excludeNumbers = !_excludeNumbers;
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Date Range Indicator ────────────────────────────────────────
                Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFF3B82F6),
                          width: 1.5,
                        ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.calendar_today_rounded,
                        size: 14,
                        color: Color(0xFF3B82F6),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        rangeInfo.formattedRange,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).brightness == Brightness.light
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFE2E8F0),
                          letterSpacing: -0.2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ── Summary vs Analysis Sub-tabs ────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _subTabIndex = 0),
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          children: [
                            Text(
                              'Summary',
                              style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: _subTabIndex == 0
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: _subTabIndex == 0
                                    ? (Theme.of(context).brightness == Brightness.light
                                        ? const Color(0xFF0F172A)
                                        : Colors.white)
                                    : const Color(0xFF94A3B8),
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (_subTabIndex == 0)
                              Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).brightness == Brightness.light
                                      ? const Color(0xFF0F172A)
                                      : Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              )
                            else
                              const SizedBox(height: 5),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _subTabIndex = 1),
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          children: [
                            Text(
                              'Analysis',
                              style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: _subTabIndex == 1
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: _subTabIndex == 1
                                    ? (Theme.of(context).brightness == Brightness.light
                                        ? const Color(0xFF0F172A)
                                        : Colors.white)
                                    : const Color(0xFF94A3B8),
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (_subTabIndex == 1)
                              Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).brightness == Brightness.light
                                      ? const Color(0xFF0F172A)
                                      : Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              )
                            else
                              const SizedBox(height: 5),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // ── Analytics 2-Column Grid ─────────────────────────────────────
                _buildAnalyticsGrid(context, stats),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAnalyticsGrid(BuildContext context, CallStats stats) {
    return Column(
      children: [
        // Row 1: Total Phone Calls & Incoming Calls
        Row(
          children: [
            Expanded(
              child: _AnalyticsCard(
                title: 'Total Phone Calls',
                count: stats.total,
                duration: Fmt.exactDuration(stats.talkTimeSeconds),
                icon: const _DualCallIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.totalCalls,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AnalyticsCard(
                title: 'Incoming Calls',
                count: stats.incoming,
                duration: Fmt.exactDuration(stats.incomingDurationSeconds),
                icon: const _IncomingCallIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.incoming,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Row 2: Outgoing Calls & Missed Calls
        Row(
          children: [
            Expanded(
              child: _AnalyticsCard(
                title: 'Outgoing Calls',
                count: stats.outgoing,
                duration: Fmt.exactDuration(stats.outgoingDurationSeconds),
                icon: const _OutgoingCallIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.outgoing,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AnalyticsCard(
                title: 'Missed Calls',
                count: stats.missed,
                duration: '0h  0m 0s',
                icon: const _MissedCallIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.missed,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Row 3: Rejected Calls & Never Attended
        Row(
          children: [
            Expanded(
              child: _AnalyticsCard(
                title: 'Rejected Calls',
                count: stats.rejected,
                duration: '0h  0m 0s',
                icon: const _RejectedCallIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.rejected,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AnalyticsCard(
                title: 'Never Attended',
                count: stats.neverAttended,
                duration: null,
                showPhoneIcon: false,
                icon: const _NeverAttendedIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.neverAttended,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Row 4: Not Pickup by Client & Unique Calls
        Row(
          children: [
            Expanded(
              child: _AnalyticsCard(
                title: 'Not Pickup by Client',
                count: stats.notPickupByClient,
                duration: '0h  0m 0s',
                icon: const _NotPickupIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.notPickup,
                  stats: stats,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AnalyticsCard(
                title: 'Unique Calls',
                count: stats.uniqueCalls,
                duration: null,
                showPhoneIcon: false,
                icon: const _UniqueCallsIcon(),
                onTap: () => CardAnalyticalPopup.show(
                  context,
                  category: PopupFilterCategory.uniqueCalls,
                  stats: stats,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _periodLabel(DashboardPeriod p) => switch (p) {
        DashboardPeriod.today => 'Today',
        DashboardPeriod.yesterday => 'Yesterday',
        DashboardPeriod.week => 'This Week',
        DashboardPeriod.month => 'This Month',
      };

  void _showPeriodSelector(BuildContext context) {
    final current = ref.read(dashboardPeriodProvider);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Select Time Period',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
              ),
              const SizedBox(height: 8),
              for (final p in DashboardPeriod.values)
                ListTile(
                  title: Text(
                    _periodLabel(p),
                    style: TextStyle(
                      fontWeight: p == current ? FontWeight.w700 : FontWeight.w500,
                      color: p == current
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  trailing: p == current
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Analytics Filters',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Exclude Internal Employee Numbers'),
                subtitle: const Text('Filters out calls between staff'),
                value: _excludeNumbers,
                onChanged: (val) {
                  setState(() => _excludeNumbers = val);
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Apply Filters'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Analytics Card Component ──────────────────────────────────────────────────
class _AnalyticsCard extends StatelessWidget {
  const _AnalyticsCard({
    required this.title,
    required this.count,
    this.duration,
    required this.icon,
    this.showPhoneIcon = true,
    this.onTap,
  });

  final String title;
  final int count;
  final String? duration;
  final Widget icon;
  final bool showPhoneIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Material(
      color: isLight ? Colors.white : const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isLight
                  ? const Color(0xFFE2E8F0)
                  : const Color(0xFF334155),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isLight ? 0.03 : 0.2),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Title + Icon Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isLight
                            ? const Color(0xFF334155)
                            : const Color(0xFFCBD5E1),
                        letterSpacing: -0.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Calls Count Row
              Row(
                children: [
                  if (showPhoneIcon) ...[
                    const Icon(
                      Icons.call,
                      size: 15,
                      color: Color(0xFF0F172A),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: showPhoneIcon ? 18 : 22,
                      fontWeight: FontWeight.w800,
                      color: isLight
                          ? const Color(0xFF0F172A)
                          : Colors.white,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),

              // Duration Row (if available)
              if (duration != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(
                      Icons.timer_outlined,
                      size: 15,
                      color: Color(0xFF64748B),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        duration!,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isLight
                              ? const Color(0xFF0F172A)
                              : Colors.white,
                          letterSpacing: -0.3,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Filter Pill Component ─────────────────────────────────────────────────────
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
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFCBD5E1), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: const Color(0xFF334155)),
              const SizedBox(width: 4),
              Container(
                width: 17,
                height: 17,
                decoration: const BoxDecoration(
                  color: Color(0xFF3B82F6),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Dropdown Pill Component ───────────────────────────────────────────────────
class _DropdownPill extends StatelessWidget {
  const _DropdownPill({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFCBD5E1), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: Color(0xFF3B82F6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Custom Visual Icons Matching Reference Design ─────────────────────────────

class _DualCallIcon extends StatelessWidget {
  const _DualCallIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.phone_forwarded_rounded,
        size: 18,
        color: Color(0xFF64748B),
      ),
    );
  }
}

class _IncomingCallIcon extends StatelessWidget {
  const _IncomingCallIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.phone_callback_rounded,
        size: 18,
        color: Color(0xFF84CC16),
      ),
    );
  }
}

class _OutgoingCallIcon extends StatelessWidget {
  const _OutgoingCallIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.phone_forwarded_rounded,
        size: 18,
        color: Color(0xFFF59E0B),
      ),
    );
  }
}

class _MissedCallIcon extends StatelessWidget {
  const _MissedCallIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.phone_missed_rounded,
        size: 18,
        color: Color(0xFFEF4444),
      ),
    );
  }
}

class _RejectedCallIcon extends StatelessWidget {
  const _RejectedCallIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.phone_disabled_rounded,
        size: 18,
        color: Color(0xFFDC2626),
      ),
    );
  }
}

class _NeverAttendedIcon extends StatelessWidget {
  const _NeverAttendedIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.phone_paused_rounded,
        size: 18,
        color: Color(0xFF3B82F6),
      ),
    );
  }
}

class _NotPickupIcon extends StatelessWidget {
  const _NotPickupIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.call_end_rounded,
        size: 18,
        color: Color(0xFF475569),
      ),
    );
  }
}

class _UniqueCallsIcon extends StatelessWidget {
  const _UniqueCallsIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F3FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.star_rounded,
        size: 20,
        color: Color(0xFF6366F1),
      ),
    );
  }
}
