import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/sync_state.dart';
import '../../../core/theme/design_tokens.dart';
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
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Call Metadata Outbox',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 20,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTokens.brandElectric,
                    ),
                  )
                : const Icon(Icons.refresh_rounded, color: AppTokens.textSecondary),
            onPressed: isSyncing
                ? null
                : () {
                    ref.invalidate(outboxItemsProvider);
                    ref.read(syncServiceProvider.notifier).triggerSync();
                  },
            tooltip: 'Sync Queue',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppTokens.textSecondary),
            color: AppTokens.surface2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.r12),
              side: const BorderSide(color: AppTokens.borderDefault),
            ),
            onSelected: (value) async {
              if (value == 'retry_all') {
                await ref.read(syncServiceProvider.notifier).retryAllFailed();
              } else if (value == 'rescan') {
                await ref
                    .read(syncServiceProvider.notifier)
                    .ingestNativeCallLogs();
                ref.invalidate(outboxItemsProvider);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'retry_all',
                child: Row(
                  children: [
                    Icon(Icons.restart_alt_rounded, size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Text('Retry All Failed', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'rescan',
                child: Row(
                  children: [
                    Icon(Icons.sync_rounded, size: 18, color: Colors.white),
                    SizedBox(width: 10),
                    Text('Rescan Call Logs', style: TextStyle(color: Colors.white)),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: ModernSegmentedControl<OutboxFilter>(
              segments: const {
                OutboxFilter.pending: 'Pending',
                OutboxFilter.failed: 'Failed',
                OutboxFilter.synced: 'Synced',
                OutboxFilter.all: 'All',
              },
              selected: filter,
              onSelected: (f) =>
                  ref.read(outboxFilterProvider.notifier).select(f),
            ),
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
                        ? 'Zero failed uploads'
                        : (filter == OutboxFilter.pending
                            ? 'All calls synced'
                            : 'Outbox is clear'),
                    message: filter == OutboxFilter.pending
                        ? 'All local call records and audio matches have been uploaded to the intelligence server.'
                        : 'No records matching the selected queue filter.',
                  );
                }

                return RefreshIndicator(
                  color: AppTokens.brandElectric,
                  backgroundColor: AppTokens.surface2,
                  onRefresh: () async {
                    ref.invalidate(outboxItemsProvider);
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
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

class _OutboxItemCard extends ConsumerWidget {
  const _OutboxItemCard({required this.item});

  final LocalCall item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = CallSyncState.normalize(item.syncState);
    final isSynced = state == CallSyncState.uploaded;
    final isFailed = CallSyncState.isFailed(state);

    // A synced call whose audio never made it is not a clean success — the
    // recording is the point of the product, so say so rather than showing a
    // green SYNCED and leaving the gap invisible.
    final recordingMissing = isSynced &&
        item.hasRecording &&
        item.recordingUploadStatus != RecordingUploadStatus.uploaded;

    final Color statusColor = switch (state) {
      _ when isFailed => AppTokens.danger,
      _ when recordingMissing => AppTokens.warning,
      _ when isSynced => AppTokens.success,
      _ => AppTokens.warning,
    };

    final String statusLabel = switch (state) {
      CallSyncState.failed => 'PERMANENT FAILURE',
      CallSyncState.retryPending => 'RETRYING',
      CallSyncState.uploading => 'UPLOADING',
      CallSyncState.uploaded when recordingMissing => 'NO RECORDING',
      CallSyncState.uploaded => 'SYNCED',
      _ => 'PENDING',
    };

    final iconData = switch (item.direction.toLowerCase()) {
      'incoming' => Icons.call_received_rounded,
      'outgoing' => Icons.call_made_rounded,
      _ => Icons.call_missed_rounded,
    };

    final directionColor = switch (item.direction.toLowerCase()) {
      'incoming' => AppTokens.callIncoming,
      'outgoing' => AppTokens.callOutgoing,
      _ => AppTokens.callMissed,
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
              IconChip(icon: iconData, color: directionColor, size: 34, iconSize: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contactTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.direction.capitalize()} · $durationStr',
                      style: const TextStyle(
                        color: AppTokens.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: statusLabel,
                color: statusColor,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppTokens.borderSubtle),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.access_time_rounded,
                    size: 14,
                    color: AppTokens.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    timeStr,
                    style: const TextStyle(
                      color: AppTokens.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (item.hasRecording)
                Row(
                  children: [
                    const Icon(
                      Icons.graphic_eq_rounded,
                      size: 14,
                      color: AppTokens.success,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.recordingUploadStatus == 'uploaded'
                          ? 'Audio synced'
                          : 'Audio queued',
                      style: const TextStyle(
                        color: AppTokens.success,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (isFailed || item.lastErrorCode != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTokens.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppTokens.r8),
                border: Border.all(
                  color: AppTokens.danger.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: AppTokens.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _humanErrorMessage(item.lastErrorCode, item.attemptCount),
                      style: const TextStyle(
                        color: AppTokens.danger,
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
                        foregroundColor: AppTokens.danger,
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
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
      return attempts > 0
          ? 'Retry scheduled (attempt $attempts)'
          : 'Pending sync';
    }
    if (errorCode.contains('NETWORK') ||
        errorCode.contains('SocketException')) {
      return 'Waiting for network connection';
    }
    if (errorCode.contains('401') || errorCode.contains('UNAUTHORIZED')) {
      return 'Authentication required';
    }
    if (errorCode.contains('500') ||
        errorCode.contains('502') ||
        errorCode.contains('503')) {
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
