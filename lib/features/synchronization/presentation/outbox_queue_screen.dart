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
    final z = context.z;
    final filter = ref.watch(outboxFilterProvider);
    final outboxAsync = ref.watch(outboxItemsProvider);
    final syncState = ref.watch(syncServiceProvider);
    final isSyncing = syncState.isLoading;

    return Scaffold(
      backgroundColor: z.canvas,
      appBar: AppBar(
        title: const Text('Calls not sent yet'),
        actions: [
          if (isSyncing)
            Semantics(
              label: 'Sending',
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: z.accent,
                    ),
                  ),
                ),
              ),
            )
          else
            TapIcon(
              icon: Icons.refresh_rounded,
              tooltip: 'Send now',
              color: z.ink2,
              onTap: () {
                ref.invalidate(outboxItemsProvider);
                ref.read(syncServiceProvider.notifier).triggerSync();
              },
            ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: Icon(Icons.more_vert_rounded, color: z.ink2),
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
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'retry_all',
                child: _MenuRow(
                  icon: Icons.restart_alt_rounded,
                  label: 'Try again',
                ),
              ),
              PopupMenuItem(
                value: 'rescan',
                child: _MenuRow(
                  icon: Icons.sync_rounded,
                  label: 'Check for new calls',
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Filter tabs
          UnderlineTabs<OutboxFilter>(
            semanticLabel: 'Show calls',
            segments: const {
              OutboxFilter.pending: 'Waiting',
              OutboxFilter.failed: 'Problems',
              OutboxFilter.synced: 'Sent',
              OutboxFilter.all: 'All',
            },
            selected: filter,
            onSelected: (f) =>
                ref.read(outboxFilterProvider.notifier).select(f),
          ),
          Expanded(
            child: outboxAsync.when(
              loading: () => const SkeletonList(),
              error: (e, _) => ErrorStateView(
                error: e,
                logContext: 'OUTBOX',
                fallbackTitle: 'Could not load the queue',
                onRetry: () => ref.invalidate(outboxItemsProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return EmptyState(
                    icon: Icons.done_all_rounded,
                    title: filter == OutboxFilter.failed
                        ? 'Nothing has failed'
                        : 'Everything has been sent',
                    message: filter == OutboxFilter.failed
                        ? 'Every call on this phone reached the server.'
                        : (filter == OutboxFilter.pending
                              ? 'There are no calls waiting. New ones appear here '
                                    'until they reach the server.'
                              : 'No calls match this filter.'),
                  );
                }

                return RefreshIndicator(
                  color: z.accent,
                  backgroundColor: z.raised,
                  onRefresh: () async {
                    ref.invalidate(outboxItemsProvider);
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                  },
                  // A pushed screen with no bottom bar: the padding carries
                  // the system navigation bar's height so the last row is
                  // never hidden behind the nav buttons. Rows run edge to
                  // edge, so there is no side padding.
                  child: ListView.builder(
                    padding: context.scrollPadding(top: 0, horizontal: 0),
                    itemCount: items.length,
                    itemBuilder: (context, index) => CardListSlice(
                      first: index == 0,
                      last: index == items.length - 1,
                      dividerIndent: AppTokens.gutter,
                      child: _OutboxItemRow(item: items[index]),
                    ),
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

/// Icon + label for a popup menu entry, in the theme's text colour.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: context.z.ink2),
      const SizedBox(width: 12),
      Text(label, style: AppType.body.copyWith(color: context.z.ink)),
    ],
  );
}

/// One queued call as a ledger row: when it was made, who, how it went and
/// how long, then its delivery state and, in plain words, why it has not gone
/// yet.
class _OutboxItemRow extends ConsumerWidget {
  const _OutboxItemRow({required this.item});

  final LocalCall item;

  static final _date = DateFormat('d MMM');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final state = CallSyncState.normalize(item.syncState);
    final isSynced = state == CallSyncState.uploaded;
    final isFailed = CallSyncState.isFailed(state);

    // A synced call whose audio never made it is not a clean success — the
    // recording is the point of the product, so say so rather than showing a
    // plain "Sent" and leaving the gap invisible.
    final recordingMissing =
        isSynced &&
        item.hasRecording &&
        item.recordingUploadStatus != RecordingUploadStatus.uploaded;

    final Color statusColor = switch (state) {
      _ when isFailed => z.danger,
      _ when recordingMissing => z.warn,
      _ when isSynced => z.ok,
      CallSyncState.uploading => z.accent,
      _ => z.warn,
    };

    final String statusLabel = switch (state) {
      CallSyncState.failed => "Couldn't send",
      CallSyncState.retryPending => 'Will retry',
      CallSyncState.uploading => 'Sending',
      CallSyncState.uploaded when recordingMissing => 'Sent (no recording)',
      CallSyncState.uploaded => 'Sent',
      _ => 'Waiting',
    };

    final (CallGlyphKind glyph, Color directionColor) =
        switch (item.direction.toLowerCase()) {
          'incoming' => (CallGlyphKind.incoming, z.incoming),
          'outgoing' => (CallGlyphKind.outgoing, z.outgoing),
          _ => (CallGlyphKind.missed, z.missed),
        };

    final recordingSent =
        item.recordingUploadStatus == RecordingUploadStatus.uploaded;

    final dateLocal = item.startedAt.toLocal();
    final durationStr = Fmt.duration(item.durationSeconds);
    final contactTitle =
        (item.contactName != null && item.contactName!.isNotEmpty)
        ? item.contactName!
        : (item.phoneNumber.isNotEmpty ? item.phoneNumber : 'Unknown number');
    final showReason = isFailed || item.lastErrorCode != null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.gutter,
        vertical: 13,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time first, then the day, in a fixed column so rows line up.
          SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Fmt.clock(item.startedAt),
                    maxLines: 1,
                    style: AppType.tabular(
                      AppType.label,
                    ).copyWith(color: z.ink2),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _date.format(dateLocal),
                    maxLines: 1,
                    style: AppType.tabular(
                      AppType.caption,
                    ).copyWith(color: z.ink3),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        contactTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.tabular(AppType.bodyStrong),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusPill(label: statusLabel, color: statusColor),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    CallGlyph(glyph, size: 12, color: directionColor),
                    const SizedBox(width: 4),
                    Text(
                      item.direction.capitalize(),
                      style: AppType.label.copyWith(color: directionColor),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      durationStr,
                      style: AppType.tabular(AppType.label).copyWith(
                        color: z.ink3,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
                if (item.hasRecording) ...[
                  const SizedBox(height: 4),
                  Text(
                    recordingSent ? 'Recording sent' : 'Recording waiting',
                    style: AppType.caption.copyWith(color: z.ink3),
                  ),
                ],
                if (showReason) ...[
                  const SizedBox(height: 8),
                  Text(
                    _humanErrorMessage(
                      item.lastErrorCode,
                      permanent: state == CallSyncState.failed,
                    ),
                    style: AppType.label.copyWith(
                      color: z.ink2,
                      fontWeight: FontWeight.w400,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ZButton(
                    label: 'Try again',
                    icon: Icons.restart_alt_rounded,
                    variant: ZButtonVariant.secondary,
                    size: ZButtonSize.compact,
                    expand: false,
                    onPressed: () {
                      ref
                          .read(syncServiceProvider.notifier)
                          .retryCall(item.idempotencyKey);
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Plain words only. Attempt counters and raw codes meant nothing to the
  /// person reading this; the code itself is on Technical details.
  static String _humanErrorMessage(
    String? errorCode, {
    required bool permanent,
  }) {
    final code = errorCode ?? '';
    // The server's own codes first (Mobile API Guide §9). Every one of these
    // used to read "Tap Try again", which for most of them can never work.
    if (code.contains('SYNC_POLICY_VIOLATION')) {
      return 'The server no longer accepts this call: it is too old, or the '
          "phone's clock was wrong when it was made.";
    }
    if (code.contains('VALIDATION_ERROR') ||
        code.contains('INVALID_CALL_STATE_TRANSITION')) {
      return 'The server rejected the details of this call. Your admin can '
          'see why.';
    }
    if (code.contains('DEVICE_REVOKED') ||
        code.contains('ACCOUNT_INACTIVE') ||
        code.contains('ACCOUNT_LOCKED') ||
        code.contains('OWNED_BY_ANOTHER_USER')) {
      return "This phone's access was removed. Contact your admin.";
    }
    if (code.contains('DEVICE_NOT_REGISTERED') ||
        code.contains('DEVICE_INACTIVE')) {
      return 'Reconnecting this phone to the server, will retry';
    }
    if (code.contains('PAYLOAD_TOO_LARGE')) {
      return 'The recording is too large to send. The call itself was sent.';
    }
    if (code.contains('UNSUPPORTED_MEDIA_TYPE') ||
        code.contains('CORRUPT_UPLOAD')) {
      return "The recording file can't be read. The call itself was sent.";
    }
    if (code.contains('RATE_LIMIT') ||
        code.contains('UNAVAILABLE') ||
        code.contains('INSUFFICIENT_STORAGE')) {
      return 'The server is busy, will retry';
    }
    if (code.contains('401') ||
        code.contains('UNAUTHORIZED') ||
        code.contains('AUTH_') ||
        code.contains('INVALID_TOKEN')) {
      return 'Sign in again to send';
    }
    if (code.contains('NETWORK') ||
        code.contains('SocketException') ||
        code.contains('500') ||
        code.contains('502') ||
        code.contains('503')) {
      return "Couldn't reach the server, will retry";
    }
    return permanent
        ? "Couldn't send this call. Tap Try again."
        : 'Will try again automatically';
  }
}

extension on String {
  String capitalize() {
    if (isEmpty) return this;
    return this[0].toUpperCase() + substring(1);
  }
}
