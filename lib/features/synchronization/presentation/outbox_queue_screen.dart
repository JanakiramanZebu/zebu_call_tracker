import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../data/sync_service.dart';

class OutboxQueueScreen extends ConsumerWidget {
  const OutboxQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(outboxFilterProvider);
    final outboxAsync = ref.watch(outboxItemsProvider);
    final syncState = ref.watch(syncServiceProvider);
    final isSyncing = syncState.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Call Metadata Outbox'),
        actions: [
          IconButton(
            icon: isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: isSyncing
                ? null
                : () {
                    ref.invalidate(outboxItemsProvider);
                    ref.read(syncServiceProvider.notifier).triggerSync();
                  },
            tooltip: 'Sync Queue',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) async {
              if (value == 'retry_all') {
                await ref.read(syncServiceProvider.notifier).retryAllFailed();
              } else if (value == 'rescan') {
                await ref.read(syncServiceProvider.notifier).ingestNativeCallLogs();
                ref.invalidate(outboxItemsProvider);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'retry_all',
                child: Row(
                  children: [
                    Icon(Icons.restart_alt_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Retry All Failed'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'rescan',
                child: Row(
                  children: [
                    Icon(Icons.sync_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Rescan Call Logs'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Tabs
          _FilterTabs(
            selected: filter,
            onSelect: (f) => ref.read(outboxFilterProvider.notifier).select(f),
          ),
          Expanded(
            child: outboxAsync.when(
              loading: () => const SkeletonList(),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Could not load queue',
                message: '$e',
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(outboxItemsProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return EmptyState(
                    icon: Icons.done_all_rounded,
                    title: filter == OutboxFilter.failed
                        ? 'No failed items'
                        : (filter == OutboxFilter.pending
                            ? 'No pending items'
                            : 'Outbox is clear'),
                    message: filter == OutboxFilter.pending
                        ? 'All captured calls have been successfully synchronized to the server.'
                        : 'No calls in the outbox matching this filter.',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(outboxItemsProvider);
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return _OutboxItemCard(item: item);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterTabs extends StatelessWidget {
  const _FilterTabs({required this.selected, required this.onSelect});

  final OutboxFilter selected;
  final ValueChanged<OutboxFilter> onSelect;

  static const _labels = {
    OutboxFilter.pending: 'Pending',
    OutboxFilter.failed: 'Failed',
    OutboxFilter.synced: 'Synced',
    OutboxFilter.all: 'All',
  };

  @override
  Widget build(BuildContext context) => Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final entry in _labels.entries) ...[
              _FilterChip(
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

class _FilterChip extends StatelessWidget {
  const _FilterChip({
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
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              label,
              style: context.text.bodyMedium?.copyWith(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? Colors.white : context.palette.muted,
              ),
            ),
          ),
        ),
      );
}

class _OutboxItemCard extends ConsumerWidget {
  const _OutboxItemCard({required this.item});

  final LocalCall item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSynced = item.syncState == 'synced';
    final isFailed = item.syncState == 'failed_permanent' ||
        item.syncState == 'failed_retryable';

    final Color statusColor = isSynced
        ? context.palette.answered
        : (isFailed ? context.palette.missed : context.palette.waiting);

    final String statusLabel = isSynced
        ? 'SYNCED'
        : (item.syncState == 'failed_permanent'
            ? 'PERMANENT FAILURE'
            : (item.syncState == 'failed_retryable'
                ? 'RETRYING'
                : 'PENDING'));

    final iconData = switch (item.direction.toLowerCase()) {
      'incoming' => Icons.call_received_rounded,
      'outgoing' => Icons.call_made_rounded,
      _ => Icons.call_missed_rounded,
    };

    final directionColor = switch (item.direction.toLowerCase()) {
      'incoming' => context.palette.answered,
      'outgoing' => context.colors.primary,
      _ => context.palette.missed,
    };

    final dateLocal = item.startedAt.toLocal();
    final timeStr = DateFormat('h:mm a · MMM d').format(dateLocal);
    final durationStr = Fmt.duration(item.durationSeconds);
    final contactTitle = (item.contactName != null && item.contactName!.isNotEmpty)
        ? item.contactName!
        : (item.phoneNumber.isNotEmpty ? item.phoneNumber : 'Unknown number');

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(icon: iconData, color: directionColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contactTitle,
                      style: context.text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.direction.capitalize()} · $durationStr',
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 14,
                    color: context.palette.muted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    timeStr,
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (item.hasRecording)
                Row(
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 14,
                      color: context.palette.answered,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.recordingUploadStatus == 'uploaded'
                          ? 'Audio synced'
                          : 'Audio queued',
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.answered,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (isFailed || item.lastErrorCode != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: context.palette.missed.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: context.palette.missed.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: context.palette.missed,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _humanErrorMessage(item.lastErrorCode, item.attemptCount),
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.missed,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 28,
                    child: TextButton(
                      onPressed: () {
                        ref
                            .read(syncServiceProvider.notifier)
                            .retryCall(item.idempotencyKey);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: context.palette.missed,
                      ),
                      child: const Text('Retry', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _humanErrorMessage(String? errorCode, int attempts) {
    if (errorCode == null) {
      return attempts > 0 ? 'Retry scheduled (attempt $attempts)' : 'Pending sync';
    }
    if (errorCode.contains('NETWORK') || errorCode.contains('SocketException')) {
      return 'Waiting for network connection';
    }
    if (errorCode.contains('401') || errorCode.contains('UNAUTHORIZED')) {
      return 'Authentication required';
    }
    if (errorCode.contains('500') || errorCode.contains('502') || errorCode.contains('503')) {
      return 'Server temporarily unavailable (attempt $attempts)';
    }
    return 'Sync error: $errorCode (attempt $attempts)';
  }
}

extension on String {
  String capitalize() {
    if (isEmpty) return this;
    return this[0].toUpperCase() + substring(1);
  }
}
