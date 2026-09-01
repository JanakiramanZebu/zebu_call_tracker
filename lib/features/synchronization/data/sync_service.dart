import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/call_wire_format.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/database_providers.dart';
import '../../../core/storage/sync_state.dart';
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

/// What the native coordinator recorded on its last run.
///
/// The coordinator does most of its work with no Flutter engine attached, so
/// this is the only honest answer to "when did this phone last sync?". Screens
/// used to invent one from whatever the current Dart session happened to have
/// done, which showed "Just now" on a handset that had not reached the server
/// in days.
///
/// Read on demand rather than watched: a background run does not notify Dart,
/// so it is invalidated at the moments it can have changed — app resume, and
/// after a manual sync.
final nativeSyncStatusProvider =
    FutureProvider.autoDispose<NativeSyncStatus>((ref) async {
  final raw = await ref.watch(nativeBridgeProvider).getNativeSyncStatus();
  return NativeSyncStatus.fromPlatform(raw);
});

/// Last-run record kept natively in `IngestStore`.
class NativeSyncStatus {
  const NativeSyncStatus({
    this.lastSyncAt,
    this.status,
    this.syncedCount = 0,
    this.error,
  });

  /// Null when the coordinator has never completed a run on this install.
  final DateTime? lastSyncAt;

  /// `OK`, `PARTIAL`, `SKIPPED_NO_AUTH`, `ALREADY_RUNNING`, or null.
  final String? status;

  final int syncedCount;
  final String? error;

  factory NativeSyncStatus.fromPlatform(Map<String, Object?> m) {
    final millis = (m['lastSyncAtMillis'] as num?)?.toInt() ?? 0;
    return NativeSyncStatus(
      lastSyncAt: millis > 0
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : null,
      status: (m['lastSyncStatus'] as String?)?.trim().isEmpty ?? true
          ? null
          : m['lastSyncStatus'] as String?,
      syncedCount: (m['lastSyncedCount'] as num?)?.toInt() ?? 0,
      error: m['lastSyncError'] as String?,
    );
  }

  bool get hasRun => lastSyncAt != null;

  /// True when the last run could not even start — no server or no session.
  bool get isUnauthenticated => status == 'SKIPPED_NO_AUTH';

  bool get isHealthy => status == 'OK';

  /// The server refused this handset outright — revoked device, deactivated
  /// account, dead session. Retrying will not help; a person must intervene.
  bool get isBlocked => status == 'BLOCKED';

  /// Human phrasing for how long ago the last run finished.
  String get lastSyncLabel {
    final at = lastSyncAt;
    if (at == null) return 'Never';

    final elapsed = DateTime.now().difference(at);
    if (elapsed.isNegative || elapsed.inSeconds < 60) return 'Just now';
    if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
    if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
    return '${elapsed.inDays}d ago';
  }

  /// Short description of the last outcome, for a status pill.
  String get statusLabel => switch (status) {
        'OK' => 'Healthy',
        'PARTIAL' => 'Partial',
        'SKIPPED_NO_AUTH' => 'Not signed in',
        'BLOCKED' => 'Blocked by server',
        'ALREADY_RUNNING' => 'In progress',
        null => 'Not run yet',
        _ => status!,
      };
}

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

  /// Subscription id → 1-based SIM slot, as reported by the platform.
  ///
  /// Empty on single-SIM handsets and whenever READ_PHONE_STATE is not held,
  /// both of which resolve to slot 1.
  Future<Map<String, int>> _simSlotLookup() async {
    try {
      final info = await ref.read(nativeBridgeProvider).getSimInfo();
      return {
        for (final sub in info.subscriptions)
          if (sub.subscriptionId != null && sub.simSlotIndex != null)
            sub.subscriptionId.toString(): sub.simSlotIndex! + 1,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Best-effort SIM attribution, matching Kotlin's `SimInfoReader`.
  ///
  /// Falls back to slot 1 for anything unresolvable — an unattributed call is
  /// still a valid record, and OEMs vary in what they write into
  /// `PHONE_ACCOUNT_ID`. Both ingest paths must agree here or the same call
  /// gets a different slot depending on which side saw it first.
  static int _slotFor(String? phoneAccountId, Map<String, int> lookup) {
    if (phoneAccountId == null || phoneAccountId.isEmpty) return 1;
    return lookup[phoneAccountId] ?? 1;
  }

  /// How far back in the call log this side has already read.
  ///
  /// Kept separately from the native ingestor's own cursor, because the two run
  /// independently and neither can assume the other has been through. Both
  /// converge on the same rows: the idempotency key is a deterministic v5 UUID
  /// over the same inputs on both sides, so whichever arrives second is a
  /// no-op rather than a duplicate.
  static const _cursorKey = 'zebu.dart_ingest.cursor_millis.v1';

  /// How far back the first ingest reaches. Mirrors Kotlin's
  /// `NativeCallIngestor.BACKFILL_DAYS` — the two must agree or one side
  /// re-queues what the other deliberately left out.
  ///
  /// The server rejects calls beyond its `max_call_age_days` policy (90), and
  /// it accepts one call per request, so an unbounded backfill queued thousands
  /// of unacceptable rows ahead of every live call and the outbox never
  /// drained. History older than this stays visible — the call-history screen
  /// reads the system call log directly, not this table.
  static const _backfillDays = 30;

  Future<int> _readCursor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_cursorKey) ?? 0;
  }

  Future<void> _writeCursor(int millis) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cursorKey, millis);
  }

  /// Ingests new native call logs into local database outbox.
  ///
  /// Employs sliding-window candidate scanning and offloads CPU-intensive
  /// heuristic matching to a background isolate using [RecordingMatcher.matchBatchInIsolate].
  ///
  /// Incremental after the first pass. The initial run backfills history in
  /// pages; every run after it reads only rows newer than [_cursorKey]. Without
  /// that cursor this walked up to 15,000 call-log rows and issued a point
  /// query per row — on every call, and it is called more than once per launch
  /// — which is seconds of jank on a handset with a long history and no new
  /// calls to find.
  Future<int> ingestNativeCallLogs({bool force = false}) async {
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

      final storedCursor = force ? 0 : await _readCursor();
      final isBackfill = storedCursor == 0;

      // First run starts at the backfill horizon, not at the beginning of time.
      final cursorMillis = isBackfill
          ? DateTime.now()
              .subtract(const Duration(days: _backfillDays))
              .millisecondsSinceEpoch
          : storedCursor;

      // Resolved once for the whole run: SubscriptionManager is a platform
      // call, and the mapping cannot change mid-ingest.
      final simSlots = await _simSlotLookup();

      int totalIngested = 0;
      int beforeMillis = 0;
      int newestSeenMillis = cursorMillis;
      // One page is enough once the cursor is established: anything older has
      // already been folded in, and a missed row is picked up by the next run.
      final int maxPages = isBackfill ? 12 : 1;
      int pageCount = 0;

      while (pageCount < maxPages) {
        pageCount++;
        final rows = await bridge.readCallLog(
          sinceMillis: cursorMillis,
          beforeMillis: beforeMillis,
          limit: isBackfill ? 500 : 200,
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

          // Same mapping the native coordinator uses when it posts. Deriving
          // it separately here is how the two sides came to disagree, and how
          // `completed` — absent from the server's enum — was written locally.
          final durationSecs = r.durationSeconds ?? 0;
          final outcome = callWireOutcome(
            rawDirection: r.direction.name,
            durationSeconds: durationSecs,
          );
          final directionStr = outcome.direction;
          final statusStr = outcome.status;

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

          if (r.dateMillis! > newestSeenMillis) newestSeenMillis = r.dateMillis!;

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
              simSlot: Value(_slotFor(r.phoneAccountId, simSlots)),
              clientCreatedAt: DateTime.now().toUtc(),
              syncState: const Value(CallSyncState.waiting),
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

      // Advance only to the newest row actually read, never to "now": a call
      // written to the log a moment after the query would otherwise fall into
      // the gap and never be picked up.
      //
      // On a first run that found nothing, the cursor still has to leave zero
      // or every subsequent run repeats the backfill scan.
      final advanceTo =
          newestSeenMillis > cursorMillis ? newestSeenMillis : cursorMillis;
      if (advanceTo > storedCursor) {
        await _writeCursor(advanceTo);
      }

      return totalIngested;
    } catch (_) {
      return 0;
    }
  }

  /// Corrects local state against what the server says it actually holds.
  ///
  /// `GET /sync/status` returns `pending_recording_uploads`: calls the server
  /// has metadata for but no audio. That list is the only way to detect a
  /// recording upload whose response was lost in flight — locally such a call
  /// looks uploaded, so nothing would ever offer the file again and the audio
  /// would be silently missing from the server for good.
  ///
  /// For each entry: re-open the upload if the file is still on the handset,
  /// or tell the server there is no recording so it stops asking.
  ///
  /// Best-effort. A failure here must not stop the upload run that follows —
  /// reconciliation is a repair pass, not a precondition.
  Future<int> reconcileWithServer() async {
    final dao = ref.read(callsDaoProvider);
    final repo = ref.read(syncRepositoryProvider);

    try {
      final status = await repo.getSyncStatus();

      // §5.1 question 1: may this handset still sync at all?
      if (status.deviceStatus == 'REVOKED') {
        debugPrint('[SYNC] Device REVOKED by an administrator; sync disabled.');
        return 0;
      }

      // §5.1 question 1 again, and §11.2: an unregistered device has EVERY
      // write rejected with 403 DEVICE_NOT_REGISTERED. Registering here is what
      // turns that from a permanent stall into a self-correcting one — the
      // sign-in path also registers, but it swallows its failures.
      if (!status.deviceRegistered) {
        debugPrint('[SYNC] Device not registered; registering before sync.');
        try {
          final info = await ref.read(deviceInfoProvider.future);
          await ref.read(deviceRepositoryProvider).registerDevice(deviceInfo: info);
        } catch (e) {
          debugPrint('[SYNC] Device registration failed: $e');
          return 0;
        }
      }

      // §5.1 question 2, and §4.6: once the handset clock drifts past the
      // policy window the server starts rejecting calls outright, and neither
      // side would otherwise know why.
      _warnOnClockSkew(status);

      int reopened = 0;
      for (final pending in status.pendingRecordingUploads) {
        if (pending.callId.isEmpty) continue;

        final local = await dao.findByServerCallId(pending.callId);
        if (local == null) continue;

        if (await dao.reopenRecordingUpload(local.idempotencyKey)) {
          reopened++;
        } else {
          // Nothing left to send. Say so, or the server keeps this call in its
          // pending list and every future pass re-examines it.
          try {
            await repo.updateCallNoRecording(pending.callId);
          } catch (_) {}
        }
      }

      if (reopened > 0) {
        debugPrint('[SYNC] Re-opened $reopened recording upload(s) the server never received.');
      }
      return reopened;
    } catch (e) {
      debugPrint('[SYNC] Reconciliation skipped: $e');
      return 0;
    }
  }

  /// Compares the handset clock against the server's, per §4.6.
  ///
  /// Beyond `policy.max_clock_skew_minutes` the server rejects calls as
  /// `SYNC_POLICY_VIOLATION` — permanently — so this is the difference between
  /// a diagnosable problem and calls vanishing for no visible reason.
  void _warnOnClockSkew(SyncStatusResponse status) {
    final serverTime = DateTime.tryParse(status.serverTime);
    if (serverTime == null) return;

    final skew = DateTime.now().toUtc().difference(serverTime.toUtc()).abs();
    if (skew.inMinutes >= status.policy.maxClockSkewMinutes) {
      debugPrint(
        '[SYNC] Device clock is ${skew.inMinutes} minutes off the server '
        '(limit ${status.policy.maxClockSkewMinutes}); calls will be rejected.',
      );
      _clockSkewMinutes = skew.inMinutes;
    } else {
      _clockSkewMinutes = null;
    }
  }

  int? _clockSkewMinutes;

  /// Reports queue depth to the server so a handset that has stopped syncing is
  /// visible centrally rather than only when someone notices missing calls.
  Future<void> _sendHeartbeat(Map<String, int> counters) async {
    try {
      await ref.read(deviceRepositoryProvider).sendHeartbeat(
            pendingCalls: (counters['waiting'] ?? 0) + (counters['failed'] ?? 0),
            pendingRecordings: (await ref
                    .read(callsDaoProvider)
                    .getPendingRecordingUploads())
                .length,
          );
    } catch (_) {
      // Telemetry, not a gate on syncing.
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
      final before = await ref.read(callsDaoProvider).getSyncCounters();

      await ingestNativeCallLogs();
      // Repair before uploading, so anything the server is missing is back in
      // the queue by the time the coordinator drains it.
      await reconcileWithServer();
      await ref.read(nativeBridgeProvider).triggerNativeSync();

      // triggerNativeSync hands off to the native coordinator and returns; the
      // upload itself outlives this call and may outlive the Flutter engine.
      // What comes back is therefore a snapshot of the queue, not a result —
      // the live figures reach the UI through [syncCountersProvider], which
      // watches the table the coordinator writes to.
      final counters = await ref.read(callsDaoProvider).getSyncCounters();
      final summary = SyncResultSummary(
        attemptedCalls: counters['total'] ?? 0,
        syncedCalls: counters['uploaded'] ?? 0,
        failedCalls: counters['failed'] ?? 0,
        uploadedRecordings:
            (counters['uploaded'] ?? 0) - (before['uploaded'] ?? 0),
        clockSkewWarning: _clockSkewMinutes == null
            ? null
            : 'This phone clock is $_clockSkewMinutes minutes off the server. '
                'Calls will be rejected until it is corrected.',
      );

      unawaited(_sendHeartbeat(counters));

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