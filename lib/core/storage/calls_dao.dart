import 'package:drift/drift.dart';

import 'app_database.dart';

part 'calls_dao.g.dart';

@DriftAccessor(tables: [LocalCalls])
class CallsDao extends DatabaseAccessor<AppDatabase> with _$CallsDaoMixin {
  CallsDao(super.db);

  $LocalCallsTable get _table => db.localCalls;

  Future<int> insertOrUpdateCall(LocalCallsCompanion entry) async {
    return into(_table).insertOnConflictUpdate(entry);
  }

  Future<LocalCall?> findByIdempotencyKey(String key) {
    return (select(_table)..where((t) => t.idempotencyKey.equals(key)))
        .getSingleOrNull();
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
      final batch = await (select(_table)..where((t) => t.idempotencyKey.isIn(chunk))).get();
      results.addAll(batch);
    }
    return results;
  }

  Future<List<LocalCall>> getPendingCalls(int limit) {
    final now = DateTime.now().toUtc();
    return (select(_table)
          ..where((t) =>
              t.syncState.equals('WAITING') |
              t.syncState.equals('pending') |
              ((t.syncState.equals('RETRY_PENDING') | t.syncState.equals('failed_retryable')) &
                  (t.nextAttemptAt.isNull() | t.nextAttemptAt.isSmallerThan(Variable(now)))))
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.asc)])
          ..limit(limit))
        .get();
  }

  Future<LocalCall?> claimNextPendingCall() async {
    final now = DateTime.now().toUtc();
    return transaction(() async {
      final call = await (select(_table)
            ..where((t) =>
                t.syncState.equals('WAITING') |
                t.syncState.equals('pending') |
                ((t.syncState.equals('RETRY_PENDING') | t.syncState.equals('failed_retryable')) &
                    (t.nextAttemptAt.isNull() | t.nextAttemptAt.isSmallerOrEqualValue(now))))
            ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.asc)])
            ..limit(1))
          .getSingleOrNull();

      if (call == null) return null;

      await (update(_table)..where((t) => t.idempotencyKey.equals(call.idempotencyKey)))
          .write(
        const LocalCallsCompanion(
          syncState: Value('UPLOADING'),
        ),
      );

      return call.copyWith(syncState: 'UPLOADING');
    });
  }

  Future<int> recoverStuckUploadingCalls({Duration timeout = const Duration(minutes: 5)}) async {
    return (update(_table)..where((t) => t.syncState.equals('UPLOADING') | t.syncState.equals('uploading')))
        .write(
      const LocalCallsCompanion(
        syncState: Value('WAITING'),
      ),
    );
  }

  Future<void> markUploading(String idempotencyKey) async {
    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      const LocalCallsCompanion(
        syncState: Value('UPLOADING'),
      ),
    );
  }

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
        syncState: const Value('UPLOADED'),
        lastErrorCode: const Value(null),
      ),
    );
  }

  Future<void> markFailed({
    required String idempotencyKey,
    required String errorCode,
    required bool retryable,
  }) async {
    final existing = await findByIdempotencyKey(idempotencyKey);
    final attempts = (existing?.attemptCount ?? 0) + 1;

    if (!retryable) {
      await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
          .write(
        LocalCallsCompanion(
          syncState: const Value('FAILED'),
          attemptCount: Value(attempts),
          lastErrorCode: Value(errorCode),
        ),
      );
      return;
    }

    final delaySeconds = (1 << attempts).clamp(2, 600);
    final nextAttempt = DateTime.now().toUtc().add(Duration(seconds: delaySeconds));

    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      LocalCallsCompanion(
        syncState: const Value('RETRY_PENDING'),
        attemptCount: Value(attempts),
        nextAttemptAt: Value(nextAttempt),
        lastErrorCode: Value(errorCode),
      ),
    );
  }

  Future<void> markRecordingUploaded(String idempotencyKey) async {
    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      const LocalCallsCompanion(
        recordingUploadStatus: Value('uploaded'),
      ),
    );
  }

  Future<void> setHasRecording(String idempotencyKey, bool hasRecording) async {
    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      LocalCallsCompanion(
        hasRecording: Value(hasRecording),
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
        recordingUploadStatus: const Value('pending'),
      ),
    );
  }

  Future<Map<String, int>> getSyncCounters() async {
    final all = await select(_table).get();
    int uploaded = 0;
    int uploading = 0;
    int waiting = 0;
    int failed = 0;

    for (final c in all) {
      if (c.syncState == 'UPLOADED' || c.syncState == 'synced' || c.syncState == 'skipped') {
        uploaded++;
      } else if (c.syncState == 'UPLOADING' || c.syncState == 'uploading') {
        uploading++;
      } else if (c.syncState == 'FAILED' || c.syncState == 'failed_permanent') {
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

  Stream<Map<String, int>> watchSyncCounters() {
    return select(_table).watch().map((all) {
      int uploaded = 0;
      int uploading = 0;
      int waiting = 0;
      int failed = 0;

      for (final c in all) {
        if (c.syncState == 'UPLOADED' || c.syncState == 'synced' || c.syncState == 'skipped') {
          uploaded++;
        } else if (c.syncState == 'UPLOADING' || c.syncState == 'uploading') {
          uploading++;
        } else if (c.syncState == 'FAILED' || c.syncState == 'failed_permanent') {
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
    });
  }

  Future<List<LocalCall>> getPendingRecordingUploads() {
    return (select(_table)
          ..where((t) =>
              t.hasRecording.equals(true) &
              t.recordingUploadStatus.equals('pending') &
              t.syncState.equals('synced')))
        .get();
  }

  /// Calls that connected but have not yet been linked to a recording candidate.
  Future<List<LocalCall>> getCallsNeedingRecordingMatch({int limit = 100}) {
    return (select(_table)
          ..where((t) =>
              t.durationSeconds.isBiggerThanValue(0) &
              (t.hasRecording.equals(false) | t.recordingMediaStoreId.isNull()))
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  Future<List<LocalCall>> getOutboxItems({String? filter}) {
    var query = select(_table);
    if (filter == 'pending') {
      query.where((t) =>
          t.syncState.equals('pending') |
          t.syncState.equals('failed_retryable') |
          t.syncState.equals('uploading'));
    } else if (filter == 'failed') {
      query.where((t) =>
          t.syncState.equals('failed_permanent') |
          t.syncState.equals('failed_retryable'));
    } else if (filter == 'synced') {
      query.where((t) => t.syncState.equals('synced'));
    }
    query.orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]);
    return query.get();
  }

  Future<void> retryCall(String idempotencyKey) async {
    await (update(_table)..where((t) => t.idempotencyKey.equals(idempotencyKey)))
        .write(
      const LocalCallsCompanion(
        syncState: Value('pending'),
        nextAttemptAt: Value(null),
        lastErrorCode: Value(null),
      ),
    );
  }

  Future<int> retryAllFailed() async {
    return (update(_table)
          ..where((t) =>
              t.syncState.equals('failed_permanent') |
              t.syncState.equals('failed_retryable')))
        .write(
      const LocalCallsCompanion(
        syncState: Value('pending'),
        nextAttemptAt: Value(null),
        lastErrorCode: Value(null),
      ),
    );
  }

  Future<List<LocalCall>> getCallsBetween(DateTime startUtc, DateTime endUtc) {
    return (select(_table)
          ..where((t) =>
              t.startedAt.isBiggerOrEqualValue(startUtc) &
              t.startedAt.isSmallerOrEqualValue(endUtc))
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]))
        .get();
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

    query.orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]);
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

    query.orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]);
    return query.watch();
  }

  Stream<List<LocalCall>> watchAllCalls() {
    return (select(_table)
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]))
        .watch();
  }

  Future<int> getUnsyncedCount() async {
    final unsynced = await (select(_table)..where((t) => t.syncState.isNotValue('synced'))).get();
    return unsynced.length;
  }

  Future<int> deleteSyncedCalls() async {
    return (delete(_table)..where((t) => t.syncState.equals('synced'))).go();
  }

  /// Purges synced calls older than [cutoff] (e.g. 180 days) to prevent
  /// unbounded SQLite storage growth on low-end devices.
  Future<int> deleteSyncedCallsOlderThan(DateTime cutoff) async {
    return (delete(_table)
          ..where((t) =>
              t.syncState.equals('synced') &
              t.startedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Purges non-retryable permanently failed calls older than [cutoff].
  Future<int> deletePermanentFailuresOlderThan(DateTime cutoff) async {
    return (delete(_table)
          ..where((t) =>
              t.syncState.equals('failed_permanent') &
              t.startedAt.isSmallerThanValue(cutoff)))
        .go();
  }
}

