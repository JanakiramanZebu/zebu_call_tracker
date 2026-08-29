import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../call_tracking/domain/call_entry.dart';
import '../../call_tracking/presentation/call_detail_screen.dart';

enum CallFilter { all, incoming, outgoing, missed }

/// Riverpod 3 moved StateProvider to the legacy barrel, so the filter is a
/// plain Notifier rather than an import of deprecated API.
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A permission grant in system settings will not be visible to this screen
    // until the next call to the bridge. Refreshing on resume picks it up
    // without requiring the user to manually pull-to-refresh.
    if (state == AppLifecycleState.resumed && mounted) {
      ref.read(callFeedProvider.notifier).refresh();
    }
  }

  /// Fetch the next page while the user is still 600px from the end, so the
  /// list never visibly stalls on a device holding thousands of rows.
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      ref.read(callFeedProvider.notifier).loadMore();
    }
  }

  bool _matches(CallEntry e, CallFilter filter) => switch (filter) {
    CallFilter.all => true,
    CallFilter.incoming => e.row.direction == CallDirection.incoming,
    CallFilter.outgoing => e.row.direction == CallDirection.outgoing,
    CallFilter.missed => const {
      CallDirection.missed,
      CallDirection.rejected,
      CallDirection.blocked,
    }.contains(e.row.direction),
  };

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(callFeedProvider);
    final filter = ref.watch(callFilterProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Calls')),
      body: feed.when(
        loading: () => const SkeletonList(),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Could not read calls',
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
                  'Without call log access there is nothing to show here. '
                  'Grant it from Settings › Permissions.',
            );
          }

          final groups = state.grouped
              .map(
                (g) => (g.$1, g.$2.where((e) => _matches(e, filter)).toList()),
              )
              .where((g) => g.$2.isNotEmpty)
              .toList();

          return Column(
            children: [
              _FilterBar(
                selected: filter,
                onSelect: (f) =>
                    ref.read(callFilterProvider.notifier).select(f),
              ),
              Expanded(
                child: groups.isEmpty
                    ? const EmptyState(
                        icon: Icons.filter_list_off_rounded,
                        title: 'No calls match',
                        message: 'Try a different filter.',
                      )
                    : RefreshIndicator(
                        onRefresh: () =>
                            ref.read(callFeedProvider.notifier).refresh(),
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          // +1 for the trailing loader row.
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
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                left: 64,
                                              ),
                                              child: Divider(
                                                height: 1,
                                                color: context
                                                    .colors
                                                    .outlineVariant,
                                              ),
                                            ),
                                          CallRowTile(
                                            entry: calls[i],
                                            onTap: () =>
                                                Navigator.of(context).push(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        CallDetailScreen(
                                                          entry: calls[i],
                                                        ),
                                                  ),
                                                ),
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

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelect});

  final CallFilter selected;
  final ValueChanged<CallFilter> onSelect;

  static const _labels = {
    CallFilter.all: 'All',
    CallFilter.incoming: 'Incoming',
    CallFilter.outgoing: 'Outgoing',
    CallFilter.missed: 'Missed',
  };

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        for (final entry in _labels.entries) ...[
          _Chip(
            label: entry.value,
            selected: entry.key == selected,
            onTap: () => onSelect(entry.key),
          ),
          const SizedBox(width: 8),
        ],
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? context.colors.primary : context.palette.tab,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 36,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          label,
          style: context.text.bodyMedium?.copyWith(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? Colors.white : context.palette.muted,
          ),
        ),
      ),
    ),
  );
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
          '$shown calls loaded',
          style: context.text.bodySmall?.copyWith(color: context.palette.muted),
        ),
      ),
    );
  }
}
