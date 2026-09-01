import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../network/call_wire_format.dart';
import 'app_database.dart';
import 'sync_state.dart';

part 'calls_dao.g.dart';

@DriftAccessor(tables: [LocalCalls])
class CallsDao extends DatabaseAccessor<AppDatabase> with _$CallsDaoMixin {
  CallsDao(super.db);

  $LocalCallsTable get _table => db.localCalls;
  /// Matches an external id the Dart ingester wrote before the two sides
  /// agreed on how to name a withheld number: `android-<millis>-null`.
  static final _legacyWithheldExtId = RegExp(r'^android-(\d+)-null$');

  /// Renames rows the two ingesters disagreed about, before they reach the
  /// server.
  ///
  /// A withheld number used to produce `android-<millis>-null` from Dart and
  /// `android-<millis>-Unknown` from Kotlin. Both rows sat in this table under
  /// different keys, and both were uploaded, so one phone call became two call
  /// records on the server.
  ///
  /// Only rows the server has never accepted (`server_call_id IS NULL`) are
  /// touched. A row that has already synced keeps its historical key: the
  /// server knows that record by it, and renaming it locally would send the
  /// record a second time under the new name — creating exactly the duplicate
  /// this is here to prevent.
  ///
  /// The timestamp is read back out of the external id rather than from
  /// `started_at`, because drift stores that column in whole seconds and the
  /// key was built from milliseconds. Recomputing from the truncated value
  /// would invent a third key.
  ///
  /// Self-limiting and safe to call on every ingest: after the first pass no
  /// row matches.
  Future<int> repairDivergentWithheldKeys() async {
    final legacy = await (select(_table)
          ..where((t) => t.externalCallId.like('%-null'))
          ..where((t) => t.serverCallId.isNull()))
        .get();
    if (legacy.isEmpty) return 0;

    var repaired = 0;
    for (final row in legacy) {
      final match = _legacyWithheldExtId.firstMatch(row.externalCallId ?? '');
      if (match == null) continue;

      final startedAtMillis = int.tryParse(match.group(1)!);
      if (startedAtMillis == null) continue;

      final correctExtId =
          CallWireIdentity.externalId(startedAtMillis: startedAtMillis);
      final correctKey =
          CallWireIdentity.key(startedAtMillis: startedAtMillis);

      final existing = await findByIdempotencyKey(correctKey);
      if (existing != null) {
        // The Kotlin ingester already captured this call under the agreed
        // name. This row is the duplicate, and it has never been sent, so
        // dropping it costs nothing and saves the server a second record.
        await (delete(_table)
              ..where((t) => t.idempotencyKey.equals(row.idempotencyKey)))
            .go();
      } else {
        await (update(_table)
              ..where((t) => t.idempotencyKey.equals(row.idempotencyKey)))
            .write(
          LocalCallsCompanion(
            idempotencyKey: Value(correctKey),
            externalCallId: Value(correctExtId),
            phoneNumber: Value(CallWireIdentity.withheldNumber),
          ),
        );
      }
      repaired++;
    }

    debugPrint(
      '[OUTBOX] Repaired $repaired withheld-number call(s) that the two '
      'ingesters had named differently.',
    );
    return repaired;
  }

  Future<int> insertOrUpdateCall(LocalCallsCompanion entry) async {
    return into(_table).insertOnConflictUpdate(entry);
  }

  Future<LocalCall?> findByIdempotencyKey(String key) {
    return (select(_table)..where((t) => t.idempotencyKey.equals(key)))
        .getSingleOrNull();
  }

  Future<LocalCall?> findByServerCallId(String serverCallId) {
    return (select(_table)..where((t) => t.serverCallId.equals(serverCallId)))
        .getSingleOrNull();
  }

  /// Re-offers a recording the server says it never received.
  ///
  /// Only touches rows that still have a local file to send; a call whose audio
  /// was expired to `absent` has nothing to re-offer and is left alone for the
  /// caller to report back to the server instead.
  Future<bool> reopenRecordingUpload(String idempotencyKey) async {
    final updated = await (update(_table)
          ..where((t) =>
              t.idempotencyKey.equals(idempotencyKey) &
              t.hasRecording.equals(true) &
              t.recordingMediaStoreId.isNotNull()))
        .write(
      const LocalCallsCompanion(
        recordingUploadStatus: Value(RecordingUploadStatus.pending),
        nextAttemptAt: Value(null),
      ),
    );
    return updated > 0;
  }

  Future<List<LocalCall>> findByIdempotencyKeys(List<String> keys) async {
    if (keys.isEmpty) return const [];
    if (keys.length <= 50) {
      return (select(_table)..where((t) => t.idempotencyKey.isIn(keys))).get();
    }
    // Chunk queries to keep SQLite parameter lists small and safe
    final results = <LocalCall>[];
    for (var i = 0; i < keys.length; i += 50) {
      final chunk = keys.sublist(i, (i + 50 > keys.length) ? keys.length : i + 50);
      final batch =
          await (select(_table)..where((t) => t.idempotencyKey.isIn(chunk))).get();
      results.addAll(batch);
    }
    return results;
  }

  /// Records a successful upload.
  ///
  /// The one writer left on the Dart side, used when `BackgroundController`
  /// folds in what the native coordinator reported while the engine was
  /// down. Everything else that moves a row through the state machine now
  /// lives in `NativeCallOutboxDao`, so there is one writer per transition.
  Future<void> markSynced({
    required String idempotencyKey,
    required String serverCallId,
    required int revision,
  }) async {
    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      LocalCallsCompanion(
        serverCallId: Value(serverCallId),
        revision: Value(revision),
        syncState: const Value(CallSyncState.uploaded),
        lastErrorCode: const Value(null),
      ),
    );
  }

  Future<void> updateRecordingInfo({
    required String idempotencyKey,
    required String recordingPath,
    required int mediaStoreId,
  }) async {
    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      LocalCallsCompanion(
        hasRecording: const Value(true),
        recordingPath: Value(recordingPath),
        recordingMediaStoreId: Value(mediaStoreId),
        recordingUploadStatus: const Value(RecordingUploadStatus.pending),
      ),
    );
  }

  Map<String, int> _countStates(List<LocalCall> all) {
    int uploaded = 0;
    int uploading = 0;
    int waiting = 0;
    int failed = 0;

    for (final c in all) {
      if (CallSyncState.isUploaded(c.syncState)) {
        uploaded++;
      } else if (CallSyncState.isInFlight(c.syncState)) {
        uploading++;
      } else if (CallSyncState.isPermanentFailure(c.syncState)) {
        failed++;
      } else {
        waiting++;
      }
    }

    return {
      'uploaded': uploaded,
      'uploading': uploading,
      'waiting': waiting,
      'failed': failed,
      'total': all.length,
    };
  }

  Future<Map<String, int>> getSyncCounters() async =>
      _countStates(await select(_table).get());

  Stream<Map<String, int>> watchSyncCounters() =>
      select(_table).watch().map(_countStates);

  /// Calls the server already has, whose audio is still owed to it.
  ///
  /// Keyed on [CallSyncState.uploaded] rather than "not pending": a recording
  /// can only be posted to `/calls/{id}/recording`, so a server call id has to
  /// exist first.
  Future<List<LocalCall>> getPendingRecordingUploads() {
    return (select(_table)
          ..where((t) =>
              t.hasRecording.equals(true) &
              (t.recordingUploadStatus.equals(RecordingUploadStatus.pending) |
                  t.recordingUploadStatus
                      .equals(RecordingUploadStatus.failed)) &
              t.syncState.equals(CallSyncState.uploaded)))
        .get();
  }

  /// Calls that connected but have not yet been linked to a recording candidate.
  Future<List<LocalCall>> getCallsNeedingRecordingMatch({int limit = 100}) {
    return (select(_table)
          ..where((t) =>
              t.durationSeconds.isBiggerThanValue(0) &
              (t.hasRecording.equals(false) | t.recordingMediaStoreId.isNull()))
          ..orderBy([
            (t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)
          ])
          ..limit(limit))
        .get();
  }

  Future<List<LocalCall>> getOutboxItems({String? filter}) {
    var query = select(_table);
    if (filter == 'pending') {
      query.where((t) =>
          t.syncState.equals(CallSyncState.waiting) |
          t.syncState.equals(CallSyncState.retryPending) |
          t.syncState.equals(CallSyncState.uploading));
    } else if (filter == 'failed') {
      query.where((t) =>
          t.syncState.equals(CallSyncState.failed) |
          t.syncState.equals(CallSyncState.retryPending));
    } else if (filter == 'synced') {
      query.where((t) => t.syncState.equals(CallSyncState.uploaded));
    }
    query.orderBy(
        [(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]);
    return query.get();
  }

  /// Puts one call back at the head of the queue, clearing its backoff.
  ///
  /// A failed recording is reset to pending alongside it: a manual retry means
  /// the user wants the whole call re-attempted, audio included.
  Future<void> retryCall(String idempotencyKey) async {
    await (update(_table)
          ..where((t) =>
              t.idempotencyKey.equals(idempotencyKey) &
              t.recordingUploadStatus.equals(RecordingUploadStatus.failed)))
        .write(
      const LocalCallsCompanion(
        recordingUploadStatus: Value(RecordingUploadStatus.pending),
      ),
    );

    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      const LocalCallsCompanion(
        syncState: Value(CallSyncState.waiting),
        nextAttemptAt: Value(null),
        lastErrorCode: Value(null),
        attemptCount: Value(0),
      ),
    );
  }

  Future<int> retryAllFailed() async {
    Expression<bool> isFailed($LocalCallsTable t) =>
        t.syncState.equals(CallSyncState.failed) |
        t.syncState.equals(CallSyncState.retryPending);

    await (update(_table)
          ..where((t) =>
              isFailed(t) &
              t.recordingUploadStatus.equals(RecordingUploadStatus.failed)))
        .write(
      const LocalCallsCompanion(
        recordingUploadStatus: Value(RecordingUploadStatus.pending),
      ),
    );

    return (update(_table)..where(isFailed)).write(
      const LocalCallsCompanion(
        syncState: Value(CallSyncState.waiting),
        nextAttemptAt: Value(null),
        lastErrorCode: Value(null),
        attemptCount: Value(0),
      ),
    );
  }

  Future<List<LocalCall>> getCallsForAnalytics({
    DateTime? startUtc,
    DateTime? endUtc,
    bool excludeInternal = false,
  }) async {
    var query = select(_table);
    if (startUtc != null && endUtc != null) {
      query.where((t) =>
          t.startedAt.isBiggerOrEqualValue(startUtc) &
          t.startedAt.isSmallerOrEqualValue(endUtc));
    } else if (startUtc != null) {
      query.where((t) => t.startedAt.isBiggerOrEqualValue(startUtc));
    } else if (endUtc != null) {
      query.where((t) => t.startedAt.isSmallerOrEqualValue(endUtc));
    }

    if (excludeInternal) {
      query.where((t) => t.phoneNumber.length.isBiggerThanValue(4));
    }

    query.orderBy(
        [(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]);
    return query.get();
  }

  Stream<List<LocalCall>> watchCallsForAnalytics({
    DateTime? startUtc,
    DateTime? endUtc,
    bool excludeInternal = false,
  }) {
    var query = select(_table);
    if (startUtc != null && endUtc != null) {
      query.where((t) =>
          t.startedAt.isBiggerOrEqualValue(startUtc) &
          t.startedAt.isSmallerOrEqualValue(endUtc));
    } else if (startUtc != null) {
      query.where((t) => t.startedAt.isBiggerOrEqualValue(startUtc));
    } else if (endUtc != null) {
      query.where((t) => t.startedAt.isSmallerOrEqualValue(endUtc));
    }

    if (excludeInternal) {
      query.where((t) => t.phoneNumber.length.isBiggerThanValue(4));
    }

    query.orderBy(
        [(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]);
    return query.watch();
  }

  Stream<List<LocalCall>> watchAllCalls() {
    return (select(_table)
          ..orderBy([
            (t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)
          ]))
        .watch();
  }

  Future<int> getUnsyncedCount() async {
    final unsynced = await (select(_table)
          ..where((t) => t.syncState.isNotValue(CallSyncState.uploaded)))
        .get();
    return unsynced.length;
  }

  Future<int> deleteSyncedCalls() async {
    return (delete(_table)
          ..where((t) => t.syncState.equals(CallSyncState.uploaded)))
        .go();
  }

  /// Purges synced calls older than [cutoff] (e.g. 180 days) to prevent
  /// unbounded SQLite storage growth on low-end devices.
  ///
  /// Rows whose audio is still owed to the server survive regardless of age:
  /// deleting one is the single way to lose a recording permanently.
  Future<int> deleteSyncedCallsOlderThan(DateTime cutoff) async {
    return (delete(_table)
          ..where((t) =>
              t.syncState.equals(CallSyncState.uploaded) &
              t.startedAt.isSmallerThanValue(cutoff) &
              (t.hasRecording.equals(false) |
                  t.recordingUploadStatus
                      .equals(RecordingUploadStatus.uploaded) |
                  t.recordingUploadStatus
                      .equals(RecordingUploadStatus.absent))))
        .go();
  }

  /// Purges non-retryable permanently failed calls older than [cutoff].
  Future<int> deletePermanentFailuresOlderThan(DateTime cutoff) async {
    return (delete(_table)
          ..where((t) =>
              t.syncState.equals(CallSyncState.failed) &
              t.startedAt.isSmallerThanValue(cutoff)))
        .go();
  }
}
