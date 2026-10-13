import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../data/call_feed.dart';
import '../domain/call_entry.dart';
import 'call_detail_screen.dart';

/// Which dashboard row opened the sheet, and so which calls it lists.
enum PopupFilterCategory {
  totalCalls,

  /// Calls somebody talked on, in either direction.
  answered,
  incoming,
  outgoing,

  /// Incoming calls nobody answered: the log's missed calls plus incoming
  /// calls that rang out without being marked missed. One row, because to
  /// the person holding the phone those are the same thing.
  missed,
  rejected,
  notPickup,
  uniqueCalls,
}

/// The calls behind one dashboard row, for the selected period.
class CardAnalyticalPopup extends ConsumerStatefulWidget {
  const CardAnalyticalPopup({
    super.key,
    required this.category,
    required this.stats,
  });

  final PopupFilterCategory category;
  final CallStats stats;

  /// A raised sheet in the theme's surface and corners. It draws its own
  /// handle: it sizes itself to 90% of the screen, and the theme's handle
  /// would sit outside that.
  static void show(
    BuildContext context, {
    required PopupFilterCategory category,
    required CallStats stats,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      builder: (context) =>
          CardAnalyticalPopup(category: category, stats: stats),
    );
  }

  @override
  ConsumerState<CardAnalyticalPopup> createState() =>
      _CardAnalyticalPopupState();
}

class _CardAnalyticalPopupState extends ConsumerState<CardAnalyticalPopup> {
  final _searchController = TextEditingController();
  String _query = '';
  Timer? _debounce;

  // The filtered list, recomputed only when its inputs change. It used to be
  // rebuilt on every build — each keystroke and each database emission — and
  // for "All time" that is thousands of rows walked per frame.
  List<CallEntry>? _filteredFrom;
  String? _filteredFor;
  List<CallEntry> _filtered = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _query = value.trim().toLowerCase());
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    setState(() => _query = '');
  }

  List<CallEntry> _filter(List<CallEntry> all) {
    if (identical(all, _filteredFrom) && _query == _filteredFor) {
      return _filtered;
    }

    bool inCategory(CallEntry e) {
      final dir = e.row.direction;
      return switch (widget.category) {
        PopupFilterCategory.totalCalls ||
        PopupFilterCategory.uniqueCalls => true,
        PopupFilterCategory.answered => e.isConnected,
        PopupFilterCategory.incoming => dir == CallDirection.incoming,
        PopupFilterCategory.outgoing => dir == CallDirection.outgoing,
        PopupFilterCategory.missed =>
          dir == CallDirection.missed ||
              (dir == CallDirection.incoming && !e.isConnected),
        PopupFilterCategory.rejected =>
          dir == CallDirection.rejected || dir == CallDirection.blocked,
        PopupFilterCategory.notPickup =>
          dir == CallDirection.outgoing && !e.isConnected,
      };
    }

    bool matchesQuery(CallEntry e) =>
        _query.isEmpty ||
        e.displayTitle.toLowerCase().contains(_query) ||
        (e.row.number ?? '').toLowerCase().contains(_query);

    // "People reached" lists each person once, at their latest call; the rows
    // arrive newest first, so the first sighting of a number is the one kept.
    final seen = <String>{};
    final out = <CallEntry>[];
    for (final e in all) {
      if (!inCategory(e) || !matchesQuery(e)) continue;
      if (widget.category == PopupFilterCategory.uniqueCalls) {
        final key = CallStats.personKey(e.row.number);
        if (key != null && !seen.add(key)) continue;
      }
      out.add(e);
    }

    _filteredFrom = all;
    _filteredFor = _query;
    return _filtered = out;
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final async = ref.watch(analyticsPeriodEntriesProvider);
    final filtered = _filter(async.value ?? const <CallEntry>[]);
    final (title, subtitle) = _metadata();

    // The route keeps the status bar clear (useSafeArea) but not the bottom:
    // the list pads itself above the navigation bar, and above the keyboard
    // while the search field has focus.
    final navBar = MediaQuery.viewPaddingOf(context).bottom;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottomInset = keyboard > navBar ? keyboard : navBar;

    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: z.lineStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 8, 10, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.barTitle.copyWith(color: z.ink),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.label.copyWith(
                          color: z.ink3,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                TapIcon(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  color: z.ink2,
                  size: 22,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            // Slivers so only the rows on screen are built. The list was a
            // Column of every matching call inside one card.
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverList.list(
                  children: [
                    _buildSummary(context),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTokens.gutter,
                        16,
                        AppTokens.gutter,
                        0,
                      ),
                      child: TextField(
                        controller: _searchController,
                        style: AppType.body.copyWith(color: z.ink),
                        onChanged: _onSearchChanged,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search name or number',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                          ),
                          suffixIcon: ListenableBuilder(
                            listenable: _searchController,
                            builder: (context, _) =>
                                _searchController.text.isEmpty
                                ? const SizedBox.shrink()
                                : TapIcon(
                                    icon: Icons.close_rounded,
                                    size: 18,
                                    color: z.ink3,
                                    tooltip: 'Clear search',
                                    onTap: _clearSearch,
                                  ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    SectionLabel(
                      widget.category == PopupFilterCategory.uniqueCalls
                          ? 'People'
                          : 'Calls',
                      trailing: Text(
                        '${filtered.length}',
                        style: AppType.tabular(
                          AppType.labelStrong,
                        ).copyWith(color: z.ink3),
                      ),
                    ),
                  ],
                ),
                if (!async.hasValue)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: InlineLoader(size: 22)),
                    ),
                  )
                else if (filtered.isEmpty)
                  SliverToBoxAdapter(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: z.line)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTokens.gutter,
                          24,
                          AppTokens.gutter,
                          24,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _query.isEmpty
                                  ? Icons.inbox_outlined
                                  : Icons.search_off_rounded,
                              size: 20,
                              color: z.ink3,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _query.isEmpty
                                    ? 'No calls here for this period.'
                                    : 'No calls match your search.',
                                style: AppType.small.copyWith(color: z.ink2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) => CardListSlice(
                      first: i == 0,
                      last: i == filtered.length - 1,
                      background: z.raised,
                      dividerIndent: AppTokens.gutter,
                      child: CallRowTile(
                        entry: filtered[i],
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                CallDetailScreen(entry: filtered[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Clear of the system navigation bar (or the keyboard), so
                // the last row never sits under the phone's buttons.
                SliverToBoxAdapter(child: SizedBox(height: bottomInset + 24)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, String) _metadata() => switch (widget.category) {
    PopupFilterCategory.totalCalls => ('All calls', 'Every call in this period'),
    PopupFilterCategory.answered => (
      'Answered calls',
      'Calls somebody talked on, either way',
    ),
    PopupFilterCategory.incoming => ('Incoming calls', 'Calls you received'),
    PopupFilterCategory.outgoing => ('Outgoing calls', 'Calls you made'),
    PopupFilterCategory.missed => (
      'Missed calls',
      'Incoming calls nobody answered',
    ),
    PopupFilterCategory.rejected => (
      'Rejected calls',
      'Incoming calls that were declined',
    ),
    PopupFilterCategory.notPickup => (
      'Not picked up',
      "Calls you made that weren't answered",
    ),
    PopupFilterCategory.uniqueCalls => (
      'People reached',
      'Each number once, at its latest call',
    ),
  };

  /// The row's numbers, restated over the list as a ruled three-column slip.
  /// Taken from the period's stats rather than the visible rows, so searching
  /// does not change them.
  Widget _buildSummary(BuildContext context) {
    final z = context.z;
    final stats = widget.stats;
    String share(int part, int whole) =>
        whole == 0 ? '0%' : '${(part / whole * 100).round()}%';
    // Everything that rang this phone: answered or not, declined or not.
    final received = stats.incoming + stats.missed + stats.rejected;

    final List<(String, String)> metrics = switch (widget.category) {
      PopupFilterCategory.totalCalls => [
        ('Calls', '${stats.total}'),
        ('Talk time', Fmt.duration(stats.talkTimeSeconds)),
        ('Answered', share(stats.answered, stats.total)),
      ],
      PopupFilterCategory.answered => [
        ('Answered', '${stats.answered}'),
        ('Talk time', Fmt.duration(stats.talkTimeSeconds)),
        ('Average call', Fmt.duration(stats.averageDurationSeconds)),
      ],
      PopupFilterCategory.incoming => [
        ('Calls', '${stats.incoming}'),
        ('Talk time', Fmt.duration(stats.incomingDurationSeconds)),
        ('Of all calls', share(stats.incoming, stats.total)),
      ],
      PopupFilterCategory.outgoing => [
        ('Calls', '${stats.outgoing}'),
        ('Talk time', Fmt.duration(stats.outgoingDurationSeconds)),
        ('Of all calls', share(stats.outgoing, stats.total)),
      ],
      PopupFilterCategory.missed => [
        ('Missed', '${stats.neverAttended}'),
        ('Of calls received', share(stats.neverAttended, received)),
        ('Of all calls', share(stats.neverAttended, stats.total)),
      ],
      PopupFilterCategory.rejected => [
        ('Rejected', '${stats.rejected}'),
        ('Of calls received', share(stats.rejected, received)),
        ('Of all calls', share(stats.rejected, stats.total)),
      ],
      PopupFilterCategory.notPickup => [
        ('Not picked up', '${stats.notPickupByClient}'),
        ('Of calls you made', share(stats.notPickupByClient, stats.outgoing)),
        ('Of all calls', share(stats.notPickupByClient, stats.total)),
      ],
      PopupFilterCategory.uniqueCalls => [
        ('People', '${stats.uniqueCalls}'),
        (
          'Calls per person',
          stats.uniqueCalls > 0
              ? (stats.total / stats.uniqueCalls).toStringAsFixed(1)
              : '0',
        ),
        ('Talk time', Fmt.duration(stats.talkTimeSeconds)),
      ],
    };

    final side = BorderSide(color: z.line);
    return DecoratedBox(
      decoration: BoxDecoration(border: Border.symmetric(horizontal: side)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < metrics.length; i++)
              Expanded(
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    i == 0 ? AppTokens.gutter : 14,
                    12,
                    8,
                    12,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      left: i == 0 ? BorderSide.none : side,
                    ),
                  ),
                  child: _MetricStat(label: metrics[i].$1, value: metrics[i].$2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One cell of the summary slip: a small key over its value.
class _MetricStat extends StatelessWidget {
  const _MetricStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.captionStrong.copyWith(color: z.ink3),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: AppType.tabular(
                AppType.bodyStrong,
              ).copyWith(color: z.ink, fontSize: 17),
            ),
          ),
        ],
      ),
    );
  }
}
