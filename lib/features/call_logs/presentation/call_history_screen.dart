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
import '../../recording/presentation/recording_player_widget.dart';
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

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  bool _isSearching = false;
  String _searchQuery = '';

  /// Currently expanded call unique key (e.g. dateMillis-number-direction)
  String? _expandedCallKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      ref.read(callFeedProvider.notifier).refresh();
    }
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      ref.read(callFeedProvider.notifier).loadMore();
    }
  }

  bool _matches(CallEntry e, CallFilter filter, String query) {
    final filterMatch = switch (filter) {
      CallFilter.all => true,
      CallFilter.incoming => e.row.direction == CallDirection.incoming,
      CallFilter.outgoing => e.row.direction == CallDirection.outgoing,
      CallFilter.missed => const {
          CallDirection.missed,
          CallDirection.rejected,
          CallDirection.blocked,
        }.contains(e.row.direction),
    };
    if (!filterMatch) return false;

    if (query.trim().isEmpty) return true;
    final q = query.toLowerCase().trim();
    final name = (e.contactName ?? e.row.cachedName ?? '').toLowerCase();
    final phone = (e.row.number ?? '').toLowerCase();
    return name.contains(q) || phone.contains(q);
  }

  void _toggleExpand(String key) {
    setState(() {
      _expandedCallKey = (_expandedCallKey == key) ? null : key;
    });
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(callFeedProvider);
    final filter = ref.watch(callFilterProvider);

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      floatingActionButton: FloatingActionButton(
        onPressed: () => DialPadSheet.show(context),
        backgroundColor: AppTokens.brandElectric,
        foregroundColor: Colors.white,
        elevation: 6,
        shape: const CircleBorder(),
        tooltip: 'Open dialer',
        child: const Icon(Icons.dialpad_rounded, size: 24),
      ),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(fontSize: 16, color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search by name or number…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintStyle: TextStyle(color: AppTokens.textMuted),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              )
            : const Text(
                'Calls',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 24,
                  letterSpacing: -0.5,
                  color: Colors.white,
                ),
              ),
        actions: [
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close_rounded : Icons.search_rounded,
              color: AppTokens.textSecondary,
            ),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                } else {
                  _isSearching = true;
                }
              });
            },
            tooltip: _isSearching ? 'Close search' : 'Search calls',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppTokens.textSecondary),
            onPressed: () => ref.read(callFeedProvider.notifier).refresh(),
            tooltip: 'Refresh calls',
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
      body: feed.when(
        loading: () => const SkeletonList(),
        error: (e, _) => EmptyState(
          icon: Icons.storage_rounded,
          title: 'Could not load call history',
          message: 'A temporary storage issue was detected. Tap below to reload or repair local data.',
          actionLabel: 'Try again',
          onAction: () => ref.read(callFeedProvider.notifier).refresh(),
        ),
        data: (state) {
          if (state.blocked) {
            return const EmptyState(
              icon: Icons.lock_outline_rounded,
              title: 'Call log access needed',
              message:
                  'Grant call log permission in Settings to view your call history.',
            );
          }

          final groups = state.grouped
              .map(
                (g) => (
                  g.$1,
                  g.$2.where((e) => _matches(e, filter, _searchQuery)).toList(),
                ),
              )
              .where((g) => g.$2.isNotEmpty)
              .toList();

          return Column(
            children: [
              // Modern Segmented Filter Control
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: ModernSegmentedControl<CallFilter>(
                  segments: const {
                    CallFilter.all: 'All',
                    CallFilter.incoming: 'Incoming',
                    CallFilter.outgoing: 'Outgoing',
                    CallFilter.missed: 'Missed',
                  },
                  selected: filter,
                  onSelected: (f) =>
                      ref.read(callFilterProvider.notifier).select(f),
                ),
              ),

              // Compact Timeline List with Samsung-style Expandable Rows
              Expanded(
                child: groups.isEmpty
                    ? EmptyState(
                        icon: Icons.filter_list_off_rounded,
                        title: _searchQuery.isNotEmpty
                            ? 'No calls match your search'
                            : 'No calls found for this filter',
                        message: _searchQuery.isNotEmpty
                            ? 'Try searching with a different contact name or phone number.'
                            : 'Try switching to "All" to see your full call history.',
                        actionLabel: filter != CallFilter.all
                            ? 'Show All Calls'
                            : null,
                        onAction: filter != CallFilter.all
                            ? () => ref
                                .read(callFilterProvider.notifier)
                                .select(CallFilter.all)
                            : null,
                      )
                    : RefreshIndicator(
                        color: AppTokens.brandElectric,
                        backgroundColor: AppTokens.surface2,
                        onRefresh: () =>
                            ref.read(callFeedProvider.notifier).refresh(),
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) {
                            if (index == groups.length) {
                              return _Footer(
                                loading: state.loadingMore,
                                hasMore: state.hasMore,
                                shown: state.entries.length,
                              );
                            }
                            final (heading, calls) = groups[index];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 14,
                                    bottom: 6,
                                    left: 4,
                                  ),
                                  child: SectionLabel(heading),
                                ),
                                Container(
                                  decoration: BoxDecoration(
                                    color: AppTokens.surface1,
                                    borderRadius:
                                        BorderRadius.circular(AppTokens.r12),
                                    border: Border.all(
                                      color: AppTokens.borderSubtle,
                                      width: 1,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(AppTokens.r12),
                                    child: Column(
                                      children: [
                                        for (var i = 0; i < calls.length; i++) ...[
                                          if (i > 0)
                                            const Divider(
                                              height: 1,
                                              indent: 56,
                                              color: AppTokens.borderSubtle,
                                            ),
                                          _ExpandableCallRow(
                                            entry: calls[i],
                                            isExpanded: _expandedCallKey ==
                                                calls[i].idempotencySeed('local'),
                                            onToggle: () => _toggleExpand(
                                              calls[i].idempotencySeed('local'),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Samsung-style Expandable Call Row item.
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
    final dir = directionStyle(context, entry.row.direction);
    final up = uploadStyle(context, entry.uploadState);
    final number = entry.row.number ?? '';

    final subtitle = entry.isConnected
        ? '${Fmt.maskNumber(number)} · ${Fmt.duration(entry.durationSeconds)}'
        : '${Fmt.maskNumber(number)} · ${dir.label}';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      color: isExpanded
          ? AppTokens.surface2
          : Colors.transparent,
      child: Column(
        children: [
          // ── Main Collapsed Row ──
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  // Direction Icon Chip
                  IconChip(
                    icon: dir.icon,
                    color: dir.color,
                    size: 34,
                    iconSize: 17,
                  ),
                  const SizedBox(width: 12),

                  // Contact & Subtitle
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5,
                            letterSpacing: -0.2,
                            color: entry.hasName
                                ? Colors.white
                                : AppTokens.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTokens.textMuted,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Inline Recording Play Button (always accessible)
                  if (entry.recording case final rec?) ...[
                    RecordingPlayButton(candidate: rec, size: 32),
                    const SizedBox(width: 8),
                  ],

                  // Time & Sync Status
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        entry.startedAtUtc != null
                            ? Fmt.clock(entry.startedAtUtc!)
                            : '--:--',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: AppTokens.textMuted,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (entry.needsReview) ...[
                            const Icon(
                              Icons.help_outline_rounded,
                              size: 13,
                              color: AppTokens.warning,
                            ),
                            const SizedBox(width: 3),
                          ],
                          Icon(up.icon, size: 12.5, color: up.color),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── Expanded Action Drawer (Samsung Phone style) ──
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.fastOutSlowIn,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? Container(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                    decoration: const BoxDecoration(
                      color: AppTokens.surface2,
                      border: Border(
                        top: BorderSide(
                          color: AppTokens.borderSubtle,
                          width: 0.8,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Metadata detail strip
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  number.isNotEmpty
                                      ? Fmt.prettyNumber(number)
                                      : 'Private number',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                    letterSpacing: 0.2,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              StatusPill(
                                label: dir.label,
                                color: dir.color,
                              ),
                              const SizedBox(width: 6),
                              StatusPill(
                                label: up.label,
                                color: up.color,
                                icon: up.icon,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Action Buttons Bar
                        Row(
                          children: [
                            // Call Action Button
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: number.isNotEmpty
                                    ? () async {
                                        final bridge =
                                            ref.read(nativeBridgeProvider);
                                        await bridge.dialNumber(number);
                                      }
                                    : null,
                                icon: const Icon(Icons.phone_rounded, size: 17),
                                label: const Text('Call'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppTokens.callIncoming,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(0, 38),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(AppTokens.r8),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),

                            // Details Action Button
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          CallDetailScreen(entry: entry),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.info_outline_rounded,
                                    size: 17),
                                label: const Text('Details'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(
                                    color: AppTokens.borderDefault,
                                  ),
                                  minimumSize: const Size(0, 38),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(AppTokens.r8),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.loading,
    required this.hasMore,
    required this.shown,
  });

  final bool loading;
  final bool hasMore;
  final int shown;

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
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          '$shown calls loaded · End of list',
          style: const TextStyle(
            color: AppTokens.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
