import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../../call_tracking/presentation/call_detail_screen.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../recording/data/recording_player.dart';
import '../../recording/domain/recording_matcher.dart';
import '../../settings/presentation/settings_screen.dart';
import 'dial_pad_sheet.dart';

enum CallFilter { all, incoming, outgoing, missed }

class CallFilterController extends Notifier<CallFilter> {
  @override
  CallFilter build() => CallFilter.all;

  void select(CallFilter filter) => state = filter;
}

final callFilterProvider = NotifierProvider<CallFilterController, CallFilter>(
  CallFilterController.new,
);

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

/// One day of the list: its heading and the calls of that day still shown
/// after the filter and search.
typedef _Day = ({String heading, List<CallEntry> calls});

const _filterLabels = {
  CallFilter.all: 'All',
  CallFilter.incoming: 'Incoming',
  CallFilter.outgoing: 'Outgoing',
  CallFilter.missed: 'Missed',
};

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;

  /// The one expanded row, by [_rowKey]. A notifier rather than screen state
  /// so opening a row rebuilds the two rows involved, not the whole list.
  final _expanded = ValueNotifier<String?>(null);

  // The day groups and tab counts, rebuilt only when what they are derived
  // from changes.
  List<CallEntry>? _daysEntries;
  CallFilter? _daysFilter;
  String? _daysQuery;
  List<_Day> _days = const [];
  Map<CallFilter, String> _counts = const {};

  // No resume handler here: HomeShell's catch-up refreshes the feed on resume
  // and reconnect. This screen refreshing as well doubled every resume's
  // call-log read and recording scan.

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    _searchController.dispose();
    _expanded.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      ref.read(callFeedProvider.notifier).loadMore();
    }
  }

  /// Filtering waits for a pause in typing: re-filtering hundreds of rows on
  /// every keystroke made the field itself lag behind the keyboard.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _searchQuery = value);
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searchQuery = '';
      _searchController.clear();
    });
  }

  /// From "No calls match …": back to every call, no search, no filter.
  void _showAll() {
    _clearSearch();
    ref.read(callFilterProvider.notifier).select(CallFilter.all);
  }

  static String _rowKey(CallEntry e) =>
      '${e.row.dateMillis}|${e.row.number}|${e.row.direction.name}';

  static bool _filterMatches(CallEntry e, CallFilter filter) =>
      switch (filter) {
        CallFilter.all => true,
        CallFilter.incoming => e.row.direction == CallDirection.incoming,
        CallFilter.outgoing => e.row.direction == CallDirection.outgoing,
        CallFilter.missed => const {
          CallDirection.missed,
          CallDirection.rejected,
          CallDirection.blocked,
        }.contains(e.row.direction),
      };

  static bool _queryMatches(CallEntry e, String q) {
    if (q.isEmpty) return true;
    final name = (e.contactName ?? e.row.cachedName ?? '').toLowerCase();
    final phone = (e.row.number ?? '').toLowerCase();
    return name.contains(q) || phone.contains(q);
  }

  /// Day groups for the list, built as one sliver group per day so each day's
  /// heading can stick while its calls scroll under it, and each day's rows
  /// are still built lazily. Each day used to be a single item holding a
  /// Column of every call that day, all built and laid out at once.
  ///
  /// The tab counts come out of the same pass: they count the loaded calls
  /// that match the search, per filter, so they cost no extra walk.
  List<_Day> _daysFor(CallFeedState state, CallFilter filter) {
    if (identical(state.entries, _daysEntries) &&
        filter == _daysFilter &&
        _searchQuery == _daysQuery) {
      return _days;
    }

    final q = _searchQuery.trim().toLowerCase();
    final counts = {for (final f in CallFilter.values) f: 0};
    final days = <_Day>[];
    for (final (heading, calls) in state.grouped) {
      final shown = <CallEntry>[];
      for (final e in calls) {
        if (!_queryMatches(e, q)) continue;
        for (final f in CallFilter.values) {
          if (_filterMatches(e, f)) counts[f] = counts[f]! + 1;
        }
        if (_filterMatches(e, filter)) shown.add(e);
      }
      if (shown.isEmpty) continue;
      days.add((heading: heading, calls: shown));
    }

    _daysEntries = state.entries;
    _daysFilter = filter;
    _daysQuery = _searchQuery;
    _counts = {for (final e in counts.entries) e.key: '${e.value}'};
    return _days = days;
  }

  Widget _header() {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 14, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text('Calls', style: AppType.title),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Call log on this phone',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: AppType.label.copyWith(
                    color: z.ink3,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              TapIcon(
                icon: Icons.refresh_rounded,
                tooltip: 'Refresh calls',
                color: z.ink2,
                onTap: () => ref.read(callFeedProvider.notifier).refresh(),
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
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: AppTokens.gutter - 8),
            child: _SearchField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onClear: _clearSearch,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final feed = ref.watch(callFeedProvider);
    final filter = ref.watch(callFilterProvider);

    return Scaffold(
      backgroundColor: z.canvas,
      // Sits above the shell's bottom nav: the shell's Scaffold already took
      // the system inset out of this one's MediaQuery.
      floatingActionButton: _DialFab(onTap: () => DialPadSheet.show(context)),
      // No AppBar: the large header scrolls with nothing, so the top is kept
      // clear of the status bar by hand.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(),
            Expanded(
              child: feed.when(
                loading: () => const SkeletonList(),
                error: (e, _) => ErrorStateView(
                  error: e,
                  logContext: 'CALLS',
                  fallbackTitle: "Couldn't load your calls",
                  onRetry: () => ref.read(callFeedProvider.notifier).refresh(),
                ),
                data: (state) {
                  if (state.blocked) {
                    return EmptyState(
                      icon: Icons.lock_outline_rounded,
                      title: 'Call log access needed',
                      message:
                          'Allow access to your call log so the app can '
                          'show your calls and send them to the CRM.',
                      actionLabel: 'Review permissions',
                      onAction: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PermissionScreen(),
                        ),
                      ),
                    );
                  }

                  final days = _daysFor(state, filter);
                  final query = _searchQuery.trim();

                  return Column(
                    children: [
                      UnderlineTabs<CallFilter>(
                        segments: _filterLabels,
                        selected: filter,
                        counts: _counts,
                        semanticLabel: 'Call type',
                        onSelected: (f) =>
                            ref.read(callFilterProvider.notifier).select(f),
                      ),
                      Expanded(
                        child: days.isEmpty
                            ? (query.isNotEmpty
                                  ? EmptyState(
                                      icon: Icons.search_off_rounded,
                                      title: 'No calls match "$query"',
                                      message:
                                          'Check the spelling, search by the '
                                          'last digits of the number, or '
                                          'switch to All.',
                                      actionLabel: 'Show all calls',
                                      onAction: _showAll,
                                    )
                                  : filter == CallFilter.all
                                  ? const EmptyState(
                                      icon: Icons.call_outlined,
                                      title: 'No calls yet',
                                      message:
                                          'Calls you make and receive on this '
                                          'phone will show up here.',
                                    )
                                  : EmptyState(
                                      icon: Icons.filter_list_off_rounded,
                                      title: 'No calls of this type',
                                      message:
                                          'Switch to All to see every call.',
                                      actionLabel: 'Show all calls',
                                      onAction: () => ref
                                          .read(callFilterProvider.notifier)
                                          .select(CallFilter.all),
                                    ))
                            : RefreshIndicator(
                                color: z.accent,
                                backgroundColor: z.raised,
                                onRefresh: () => ref
                                    .read(callFeedProvider.notifier)
                                    .refresh(),
                                child: CustomScrollView(
                                  controller: _scroll,
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  slivers: [
                                    for (final day in days)
                                      SliverMainAxisGroup(
                                        key: ValueKey(day.heading),
                                        slivers: [
                                          PinnedHeaderSliver(
                                            child: _DayHeader(
                                              heading: day.heading,
                                              count: day.calls.length,
                                            ),
                                          ),
                                          SliverList.builder(
                                            itemCount: day.calls.length,
                                            itemBuilder: (context, i) =>
                                                _row(day.calls[i]),
                                          ),
                                        ],
                                      ),
                                    SliverToBoxAdapter(
                                      child: _Footer(
                                        loading: state.loadingMore,
                                        hasMore: state.hasMore,
                                      ),
                                    ),
                                    // Bottom room keeps the last row clear of
                                    // the dial-pad button.
                                    SliverPadding(
                                      padding: context.scrollPadding(
                                        top: 0,
                                        bottom: 88,
                                        horizontal: 0,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(CallEntry entry) {
    final key = _rowKey(entry);
    return KeyedSubtree(
      key: ValueKey(key),
      child: ValueListenableBuilder<String?>(
        valueListenable: _expanded,
        builder: (context, expanded, _) => _ExpandableCallRow(
          entry: entry,
          isExpanded: expanded == key,
          onToggle: () => _expanded.value = expanded == key ? null : key,
        ),
      ),
    );
  }
}

/// The always-visible search box under the title: a sunken, hairline-ruled
/// field with a clear button once something is typed.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final shape = BorderRadius.circular(AppTokens.r10);
    final border = OutlineInputBorder(
      borderRadius: shape,
      borderSide: BorderSide(color: z.line),
    );
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      style: AppType.body.copyWith(color: z.ink),
      cursorColor: z.accent,
      decoration: InputDecoration(
        hintText: 'Search name or number',
        hintStyle: AppType.body.copyWith(color: z.ink3),
        filled: true,
        fillColor: z.sunken,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        prefixIcon: Icon(Icons.search_rounded, size: 19, color: z.ink3),
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : TapIcon(
                  icon: Icons.close_rounded,
                  tooltip: 'Clear search',
                  size: 18,
                  hitSize: 40,
                  color: z.ink2,
                  onTap: onClear,
                ),
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 0),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: z.lineStrong),
        ),
      ),
      onChanged: onChanged,
    );
  }
}

/// A day's sticky heading: "Today" on the left, "48 calls" on the right, on
/// the sunken band with a hairline under it.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.heading, required this.count});

  final String heading;
  final int count;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.gutter,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: z.sunken,
        border: Border(bottom: BorderSide(color: z.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                heading,
                style: AppType.labelStrong.copyWith(color: z.ink2),
              ),
            ),
          ),
          Text(
            count == 1 ? '1 call' : '$count calls',
            style: AppType.tabular(
              AppType.label,
            ).copyWith(color: z.ink3, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    );
  }
}

/// A call row that opens in place to show the full number and its actions.
class _ExpandableCallRow extends ConsumerWidget {
  const _ExpandableCallRow({
    required this.entry,
    required this.isExpanded,
    required this.onToggle,
  });

  final CallEntry entry;
  final bool isExpanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final number = entry.row.number ?? '';
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final reveal = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200);

    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : AppTokens.fast,
      curve: AppTokens.ease,
      decoration: BoxDecoration(
        color: isExpanded ? z.rowActive : Colors.transparent,
        border: Border(bottom: BorderSide(color: z.line)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CallRowTile(entry: entry, onTap: onToggle, expanded: isExpanded),
            AnimatedSwitcher(
              duration: reveal,
              switchInCurve: AppTokens.ease,
              switchOutCurve: AppTokens.ease,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axisAlignment: -1,
                  child: child,
                ),
              ),
              child: isExpanded
                  ? Padding(
                      key: const ValueKey('open'),
                      // Indented to sit under the name column of the row.
                      padding: const EdgeInsets.fromLTRB(
                        94,
                        0,
                        AppTokens.gutter,
                        16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            number.isNotEmpty
                                ? Fmt.prettyNumber(number)
                                : 'Private number',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.tabular(
                              AppType.small,
                            ).copyWith(color: z.ink2),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ZButton(
                                label: 'Call',
                                icon: Icons.call_outlined,
                                size: ZButtonSize.compact,
                                expand: false,
                                onPressed: number.isNotEmpty
                                    ? () async {
                                        final bridge = ref.read(
                                          nativeBridgeProvider,
                                        );
                                        await bridge.dialNumber(number);
                                      }
                                    : null,
                              ),
                              if (entry.recording case final rec?)
                                _ListenButton(candidate: rec),
                              ZButton(
                                label: 'Details',
                                variant: ZButtonVariant.secondary,
                                size: ZButtonSize.compact,
                                expand: false,
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          CallDetailScreen(entry: entry),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(
                      key: ValueKey('closed'),
                      width: double.infinity,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plays the call's recording in place, from the row. The same toggle the
/// row's inline play disc used: tap to play, tap again to pause.
///
/// Watches only this recording's playing/loading flags, so a position tick
/// of the player does not rebuild every open row.
class _ListenButton extends ConsumerWidget {
  const _ListenButton({required this.candidate});

  final RecordingCandidate candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = candidate.mediaStoreId;
    final (playing, loading) = ref.watch(
      recordingPlayerProvider.select((s) => (s.isPlaying(id), s.isLoading(id))),
    );
    return ZButton(
      label: playing ? 'Pause' : 'Listen',
      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      variant: ZButtonVariant.secondary,
      size: ZButtonSize.compact,
      expand: false,
      loading: loading,
      semanticLabel: playing ? 'Pause recording' : 'Listen to recording',
      onPressed: () =>
          ref.read(recordingPlayerProvider.notifier).toggle(candidate),
    );
  }
}

/// The extended "Dial" button: solid primary, a neutral shadow, ripple only.
class _DialFab extends StatelessWidget {
  const _DialFab({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final shape = BorderRadius.circular(AppTokens.r16);
    return Semantics(
      button: true,
      label: 'Open dial pad',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: z.primary,
          borderRadius: shape,
          boxShadow: [
            BoxShadow(
              color: z.shadow,
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: shape,
            splashColor: z.onPrimary.withValues(alpha: 0.16),
            highlightColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
              child: SizedBox(
                height: 52,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.dialpad_rounded, size: 20, color: z.onPrimary),
                    const SizedBox(width: 10),
                    Text(
                      'Dial',
                      style: AppType.bodyStrong.copyWith(color: z.onPrimary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.loading, required this.hasMore});

  final bool loading;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: InlineLoader(label: 'Loading more calls…'),
      );
    }
    if (hasMore) return const SizedBox(height: 24);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        "That's all your calls",
        textAlign: TextAlign.center,
        style: AppType.caption.copyWith(color: context.z.ink3),
      ),
    );
  }
}
