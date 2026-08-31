import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../../call_tracking/presentation/call_detail_screen.dart';
import '../../settings/presentation/settings_screen.dart';

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
    // Check direction filter
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

    // Check search query
    if (query.trim().isEmpty) return true;
    final q = query.toLowerCase().trim();
    final name = (e.contactName ?? e.row.cachedName ?? '').toLowerCase();
    final phone = (e.row.number ?? '').toLowerCase();
    return name.contains(q) || phone.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(callFeedProvider);
    final filter = ref.watch(callFilterProvider);

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
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
          icon: Icons.error_outline_rounded,
          title: 'Could not load call history',
          message: '$e',
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
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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

              // Timeline List
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
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
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
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SectionLabel(heading),
                                  const SizedBox(height: 8),
                                  AppCard(
                                    padding: EdgeInsets.zero,
                                    child: Column(
                                      children: [
                                        for (
                                          var i = 0;
                                          i < calls.length;
                                          i++
                                        ) ...[
                                          if (i > 0)
                                            const Padding(
                                              padding: EdgeInsets.only(
                                                left: 64,
                                              ),
                                              child: Divider(
                                                height: 1,
                                                color: AppTokens.borderSubtle,
                                              ),
                                            ),
                                          _TimelineItemDismissible(
                                            entry: calls[i],
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
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

class _TimelineItemDismissible extends StatelessWidget {
  const _TimelineItemDismissible({required this.entry});

  final CallEntry entry;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(
        'call-${entry.row.dateMillis}-${entry.row.number}-${entry.row.direction.name}',
      ),
      direction: DismissDirection.startToEnd,
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: AppTokens.success.withValues(alpha: 0.2),
        child: const Row(
          children: [
            Icon(Icons.phone_rounded, color: AppTokens.success, size: 20),
            SizedBox(width: 8),
            Text(
              'Call',
              style: TextStyle(
                color: AppTokens.success,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd && entry.row.number != null) {
          // Open system dialer or copy number
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CallDetailScreen(entry: entry),
            ),
          );
        }
        return false; // Do not dismiss row from list
      },
      child: CallRowTile(
        entry: entry,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CallDetailScreen(entry: entry),
          ),
        ),
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
