import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/database_providers.dart';
import '../../auth/data/auth_repository.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../device/data/device_repository.dart';
import '../../recording/domain/recording_matcher.dart';
import 'sync_repository.dart';



final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  const store = SecureSessionStore();
  final client = ApiClient(sessionStore: store);
  return SyncRepository(apiClient: client);
});

final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  const store = SecureSessionStore();
  final client = ApiClient(sessionStore: store);
  return DeviceRepository(apiClient: client);
});

/// Shared sync counters — stream-backed for instant UI updates.
final syncCountersProvider = StreamProvider.autoDispose<Map<String, int>>((ref) {
  final dao = ref.watch(callsDaoProvider);
  return dao.watchSyncCounters();
});

enum OutboxFilter { all, pending, failed, synced }

class OutboxFilterController extends Notifier<OutboxFilter> {
  @override
  OutboxFilter build() => OutboxFilter.pending;

  void select(OutboxFilter filter) => state = filter;
}

final outboxFilterProvider =
    NotifierProvider<OutboxFilterController, OutboxFilter>(
  OutboxFilterController.new,
);

final outboxItemsProvider = FutureProvider.autoDispose<List<LocalCall>>((ref) async {
  final dao = ref.watch(callsDaoProvider);
  final filter = ref.watch(outboxFilterProvider);
  final filterKey = switch (filter) {
    OutboxFilter.all => null,
    OutboxFilter.pending => 'pending',
    OutboxFilter.failed => 'failed',
    OutboxFilter.synced => 'synced',
  };
  return dao.getOutboxItems(filter: filterKey);
});

class SyncResultSummary {
  const SyncResultSummary({
    required this.attemptedCalls,
    required this.syncedCalls,
    required this.failedCalls,
    required this.uploadedRecordings,
    this.deviceRevoked = false,
    this.clockSkewWarning,
    this.errorMessage,
  });

  final int attemptedCalls;
  final int syncedCalls;
  final int failedCalls;
  final int uploadedRecordings;
  final bool deviceRevoked;
  final String? clockSkewWarning;
  final String? errorMessage;

  bool get isSuccess => syncedCalls > 0 || uploadedRecordings > 0;
}

class SyncServiceNotifier extends AsyncNotifier<SyncResultSummary?> {
  final _uuid = const Uuid();
  static const _dnsNamespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

  @override
  Future<SyncResultSummary?> build() async => null;

  Future<void> retryCall(String idempotencyKey) async {
    final dao = ref.read(callsDaoProvider);
    await dao.retryCall(idempotencyKey);
    ref.invalidate(outboxItemsProvider);
    await triggerSync();
  }

  Future<void> retryAllFailed() async {
    final dao = ref.read(callsDaoProvider);
    await dao.retryAllFailed();
    ref.invalidate(outboxItemsProvider);
    await triggerSync();
  }

  /// Ingests new native call logs into local database outbox.
  ///
  /// Employs sliding-window candidate scanning and offloads CPU-intensive
  /// heuristic matching to a background isolate using [RecordingMatcher.matchBatchInIsolate].
  Future<int> ingestNativeCallLogs() async {
    final bridge = ref.read(nativeBridgeProvider);
    final dao = ref.read(callsDaoProvider);
    final matcher = ref.read(recordingMatcherProvider);

    try {
      bool hasRecordingAccess = false;
      try {
        final access = await bridge.getRecordingAccess();
        if (access.granted) {
          hasRecordingAccess = true;
        }
      } catch (_) {
        // Recording access is optional; call metadata can still be ingested.
      }

      int totalIngested = 0;
      int beforeMillis = 0;
      int maxPages = 30; // up to 15,000 historical call rows
      int pageCount = 0;

      while (pageCount < maxPages) {
        pageCount++;
        final rows = await bridge.readCallLog(
          sinceMillis: 0,
          beforeMillis: beforeMillis,
          limit: 500,
        );

        if (rows.isEmpty) break;

        // Determine timestamp window for the current call batch
        int minMillis = rows.first.dateMillis ?? 0;
        int maxMillis = rows.first.dateMillis ?? 0;
        for (final r in rows) {
          final m = r.dateMillis;
          if (m != null) {
            if (m < minMillis) minMillis = m;
            if (m > maxMillis) maxMillis = m;
          }
        }

        // Bounded candidate pool for this sliding window (with ±5 minute margin)
        List<RecordingCandidate> pool = const [];
        if (hasRecordingAccess && maxMillis > 0) {
          final sinceSec = math.max(0, (minMillis ~/ 1000) - 300);
          final beforeSec = (maxMillis ~/ 1000) + 300;
          try {
            pool = await bridge.scanRecordings(
              sinceEpochSeconds: sinceSec,
              beforeEpochSeconds: beforeSec,
              limit: 500,
            );
          } catch (_) {}
        }

        // Collect calls that connected for batch matching
        final callsToMatch = <CallForMatching>[];
        if (pool.isNotEmpty) {
          for (final r in rows) {
            if (r.dateMillis != null && (r.durationSeconds ?? 0) > 0) {
              callsToMatch.add(CallForMatching(
                startedAtEpochMillis: r.dateMillis!,
                durationSeconds: r.durationSeconds ?? 0,
                normalizedNumber: r.number,
                contactName: r.cachedName,
              ));
            }
          }
        }

        // Offload matching compute to a background isolate
        final matchResults = callsToMatch.isNotEmpty
            ? await RecordingMatcher.matchBatchInIsolate(
                calls: callsToMatch,
                candidates: pool,
                matcher: matcher,
              )
            : const <int, RecordingMatch>{};

        int pageIngested = 0;
        for (final r in rows) {
          if (r.dateMillis == null) continue;
          final date = DateTime.fromMillisecondsSinceEpoch(r.dateMillis!).toUtc();

          final extId = 'android-${r.dateMillis}-${r.number}';
          final idempotencyKey = _uuid.v5(
            _dnsNamespace,
            'zebu:call:$extId:${date.millisecondsSinceEpoch}',
          );

          final existing = await dao.findByIdempotencyKey(idempotencyKey);
          if (existing != null) {
            // Check if unlinked call can now be linked to a recording candidate
            if ((!existing.hasRecording || existing.recordingMediaStoreId == null) &&
                (r.durationSeconds ?? 0) > 0) {
              final match = matchResults[r.dateMillis!];
              if (match != null &&
                  match.status == RecordingMatchStatus.matched &&
                  match.candidate != null) {
                try {
                  final recPath =
                      await bridge.getRecordingUri(match.candidate!.mediaStoreId);
                  await dao.updateRecordingInfo(
                    idempotencyKey: idempotencyKey,
                    recordingPath: recPath,
                    mediaStoreId: match.candidate!.mediaStoreId,
                  );
                } catch (_) {}
              }
            }
            continue;
          }

          final directionStr = switch (r.direction) {
            CallDirection.outgoing => 'outgoing',
            CallDirection.incoming => 'incoming',
            CallDirection.missed => 'incoming',
            CallDirection.rejected => 'incoming',
            _ => 'incoming',
          };

          final statusStr = switch (r.direction) {
            CallDirection.missed => 'missed',
            CallDirection.rejected => 'rejected',
            _ => (r.durationSeconds ?? 0) > 0 ? 'completed' : 'missed',
          };

          final durationSecs = r.durationSeconds ?? 0;
          final hasConnected = durationSecs > 0;

          // --- Recording association ---
          RecordingCandidate? matched;
          if (hasConnected) {
            final match = matchResults[r.dateMillis!];
            if (match != null && match.status == RecordingMatchStatus.matched) {
              matched = match.candidate;
            }
          }

          String? recordingPath;
          if (matched != null) {
            try {
              recordingPath = await bridge.getRecordingUri(matched.mediaStoreId);
            } catch (_) {
              matched = null;
            }
          }

          await dao.insertOrUpdateCall(
            LocalCallsCompanion.insert(
              idempotencyKey: idempotencyKey,
              externalCallId: Value(extId),
              phoneNumber: r.number ?? 'Unknown',
              normalizedPhoneNumber: Value(r.number),
              contactName: Value(r.cachedName),
              direction: directionStr,
              status: statusStr,
              startedAt: date,
              durationSeconds: Value(durationSecs),
              hasRecording: Value(matched != null),
              recordingPath: Value(recordingPath),
              recordingMediaStoreId: Value(matched?.mediaStoreId),
              simSlot: const Value(1),
              clientCreatedAt: DateTime.now().toUtc(),
            ),
          );
          pageIngested++;
        }

        totalIngested += pageIngested;

        final lastDate = rows.last.dateMillis;
        if (lastDate == null || lastDate == beforeMillis) break;
        beforeMillis = lastDate;
      }

      // Secondary retroactive pass: re-scan database calls that connected but lack recording link
      if (hasRecordingAccess) {
        final unlinked = await dao.getCallsNeedingRecordingMatch();
        if (unlinked.isNotEmpty) {
          int minEpochSec = unlinked.first.startedAt.millisecondsSinceEpoch ~/ 1000;
          int maxEpochSec = unlinked.first.startedAt.millisecondsSinceEpoch ~/ 1000;
          for (final c in unlinked) {
            final sec = c.startedAt.millisecondsSinceEpoch ~/ 1000;
            if (sec < minEpochSec) minEpochSec = sec;
            if (sec > maxEpochSec) maxEpochSec = sec;
          }

          final retroactivePool = await bridge.scanRecordings(
            sinceEpochSeconds: math.max(0, minEpochSec - 300),
            beforeEpochSeconds: maxEpochSec + 300,
            limit: 500,
          );

          if (retroactivePool.isNotEmpty) {
            final unlinkedCallsForMatch = [
              for (final call in unlinked)
                CallForMatching(
                  startedAtEpochMillis: call.startedAt.millisecondsSinceEpoch,
                  durationSeconds: call.durationSeconds,
                  normalizedNumber: call.normalizedPhoneNumber,
                  contactName: call.contactName,
                )
            ];

            final unlinkedMatches = await RecordingMatcher.matchBatchInIsolate(
              calls: unlinkedCallsForMatch,
              candidates: retroactivePool,
              matcher: matcher,
            );

            for (final call in unlinked) {
              final result =
                  unlinkedMatches[call.startedAt.millisecondsSinceEpoch];
              if (result != null &&
                  result.status == RecordingMatchStatus.matched &&
                  result.candidate != null) {
                try {
                  final recPath =
                      await bridge.getRecordingUri(result.candidate!.mediaStoreId);
                  await dao.updateRecordingInfo(
                    idempotencyKey: call.idempotencyKey,
                    recordingPath: recPath,
                    mediaStoreId: result.candidate!.mediaStoreId,
                  );
                } catch (_) {}
              }
            }
          }
        }
      }

      return totalIngested;
    } catch (_) {
      return 0;
    }
  }

  bool _isProcessing = false;

  /// Triggers full sync with strict sequential one-by-one uploads (concurrency = 1)
  /// and granular server confirmation.
  Future<SyncResultSummary> triggerSync() async {
    if (_isProcessing) {
      debugPrint('[SYNC] Sync already in progress, skipping concurrent trigger.');
      return state.value ??
          const SyncResultSummary(
            attemptedCalls: 0,
            syncedCalls: 0,
            failedCalls: 0,
            uploadedRecordings: 0,
          );
    }

    if (!AppConfig.hasServer) {
      return const SyncResultSummary(
        attemptedCalls: 0,
        syncedCalls: 0,
        failedCalls: 0,
        uploadedRecordings: 0,
        errorMessage: 'No server configured.',
      );
    }

    _isProcessing = true;
    state = const AsyncLoading();

    try {
      debugPrint('[SYNC] SYNC START - Ingesting native call logs and triggering native SyncCoordinator...');
      await ingestNativeCallLogs();
      await ref.read(nativeBridgeProvider).triggerNativeSync();

      // Check counters from SQLite
      final counters = await ref.read(callsDaoProvider).getSyncCounters();
      final summary = SyncResultSummary(
        attemptedCalls: counters['total'] ?? 0,
        syncedCalls: counters['uploaded'] ?? 0,
        failedCalls: counters['failed'] ?? 0,
        uploadedRecordings: 0,
      );

      state = AsyncData(summary);
      return summary;
    } catch (e) {
      debugPrint('[SYNC] SYNC ERROR: $e');
      final summary = SyncResultSummary(
        attemptedCalls: 0,
        syncedCalls: 0,
        failedCalls: 0,
        uploadedRecordings: 0,
        errorMessage: e.toString(),
      );
      state = AsyncData(summary);
      return summary;
    } finally {
      _isProcessing = false;
      ref.invalidate(outboxItemsProvider);
      ref.invalidate(syncCountersProvider);
    }
  }
}

final syncServiceProvider =
    AsyncNotifierProvider<SyncServiceNotifier, SyncResultSummary?>(
  SyncServiceNotifier.new,
);