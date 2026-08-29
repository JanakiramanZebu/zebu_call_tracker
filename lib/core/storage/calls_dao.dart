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

  Future<List<LocalCall>> getPendingCalls(int limit) {
    final now = DateTime.now().toUtc();
    return (select(_table)
          ..where((t) =>
              t.syncState.equals('pending') |
              (t.syncState.equals('failed_retryable') &
                  (t.nextAttemptAt.isNull() | t.nextAttemptAt.isSmallerThan(Variable(now)))))
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.asc)])
          ..limit(limit))
        .get();
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
        syncState: const Value('synced'),
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
          syncState: const Value('failed_permanent'),
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
        syncState: const Value('failed_retryable'),
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

  Future<Map<String, int>> getSyncCounters() async {
    final all = await select(_table).get();
    int uploaded = 0;
    int waiting = 0;
    int failed = 0;

    for (final c in all) {
      if (c.syncState == 'synced') {
        uploaded++;
      } else if (c.syncState == 'failed_permanent') {
        failed++;
      } else {
        waiting++;
      }
    }

    return {
      'uploaded': uploaded,
      'waiting': waiting,
      'failed': failed,
      'total': all.length,
    };
  }

  Future<List<LocalCall>> getPendingRecordingUploads() {
    return (select(_table)
          ..where((t) =>
              t.hasRecording.equals(true) &
              t.recordingUploadStatus.equals('pending') &
              t.syncState.equals('synced')))
        .get();
  }
}
