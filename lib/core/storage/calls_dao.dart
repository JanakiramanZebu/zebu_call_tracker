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
          ..where((t) => t.serverCallId.isNull())
          // Not while its POST is in flight: the coordinator records the
          // verdict by the old key, finds no row, and the renamed one is then
          // sent again — two server records. The next ingest repairs it.
          ..where((t) => t.syncState.equals(CallSyncState.uploading).not())
          // Never sent. A row with an attempt behind it may be on the server
          // under its old key with the response lost (§5.4); no
          // server_call_id does not prove otherwise. Renaming that one would
          // create the second record this exists to prevent, and the key must
          // never change once it may have left the phone (§4.1).
          ..where((t) => t.attemptCount.equals(0)))
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

  /// Inserts [entry] unless a row with its idempotency key already exists, and
  /// says whether it did. Ignoring covers the unique key as well as the
  /// primary key, which matters because Kotlin inserts into this table too.
  ///
  /// Not `insertReturningOrNull`: that emits `INSERT ... RETURNING`, which
  /// needs SQLite 3.35, and drift runs on Android's own SQLite here (3.32 up to
  /// Android 13). On those phones every insert threw, the page's transaction
  /// rolled back, and the Dart ingest captured nothing at all. `changes()`
  /// reports whether the ignore fired on any SQLite version. Callers run this
  /// inside a transaction, so nothing can slip between the two statements.
  Future<bool> insertCallIfAbsent(LocalCallsCompanion entry) async {
    await into(_table).insert(entry, mode: InsertMode.insertOrIgnore);
    final changed = await customSelect('SELECT changes() AS c').getSingle();
    return changed.read<int>('c') > 0;
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

  /// True when the outbox holds no calls at all.
  ///
  /// Mirror of `NativeCallOutboxDao.isEmpty`. Used to catch an ingest cursor
  /// that is lying: the cursor lives in SharedPreferences and the rows live in
  /// SQLite, so a database wiped and rebuilt empty by [AppDatabase]'s
  /// corruption repair leaves the cursor still claiming everything is captured.
  /// Without this the call log is never re-read and the app shows an empty
  /// dashboard permanently.
  Future<bool> isEmpty() async {
    final row = await customSelect(
      'SELECT EXISTS(SELECT 1 FROM local_calls) AS has_rows;',
    ).getSingleOrNull();
    if (row == null) return false;
    return (row.data['has_rows'] as int? ?? 1) == 0;
  }

  /// Writes the server-bound `metadata` bag for one call.
  ///
  /// Raw SQL rather than a generated column — see the note on
  /// `AppDatabase._additiveColumns` for why `metadata_json` is not declared on
  /// the table. The column is created by the additive migration that runs in
  /// `beforeOpen`, so it is always present by the time this can be called.
  ///
  /// A null or empty [json] is a no-op rather than a write of NULL: the caller
  /// could not build a bag, which is not a reason to erase one another pass
  /// already stored.
  Future<void> setMetadataJson({
    required String idempotencyKey,
    required String? json,
  }) async {
    if (json == null || json.isEmpty) return;
    await customStatement(
      'UPDATE local_calls SET metadata_json = ? WHERE idempotency_key = ?;',
      [json, idempotencyKey],
    );
  }

  /// Fills `answered_at` / `ended_at` only where the row has none.
  ///
  /// Guarded rather than a plain write: a journal-derived answer time is
  /// measured from the telephony broadcast itself and beats one reconstructed
  /// from a file timestamp, so a recording matched minutes later must not
  /// overwrite the better value the ingester already stored.
  Future<void> fillMissingTimes({
    required String idempotencyKey,
    DateTime? answeredAt,
    DateTime? endedAt,
  }) async {
    if (answeredAt != null) {
      await (update(_table)
            ..where((t) =>
                t.idempotencyKey.equals(idempotencyKey) & t.answeredAt.isNull()))
          .write(LocalCallsCompanion(answeredAt: Value(answeredAt)));
    }
    if (endedAt != null) {
      await (update(_table)
            ..where((t) =>
                t.idempotencyKey.equals(idempotencyKey) & t.endedAt.isNull()))
          .write(LocalCallsCompanion(endedAt: Value(endedAt)));
    }
  }

  /// The stored `metadata` bag, or null when the row has none.
  Future<String?> metadataJsonFor(String idempotencyKey) async {
    final rows = await customSelect(
      'SELECT metadata_json FROM local_calls WHERE idempotency_key = ?;',
      variables: [Variable<String>(idempotencyKey)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.data['metadata_json'] as String?;
  }

  /// Links a recording to a call that has never had one. True when it did.
  ///
  /// Guarded at write time, not just at read time: the matcher runs between
  /// reading the row and writing it, across platform calls and an isolate, and
  /// the native ingester may link — and the coordinator upload — a recording in
  /// that gap. Unguarded, this put a second file on a call the server already
  /// had audio for. It also never revives a recording the coordinator gave up
  /// on (`has_recording = 0` with the media id kept): re-linking that file sent
  /// it to be refused again on every sync, for ever.
  Future<bool> updateRecordingInfo({
    required String idempotencyKey,
    required String recordingPath,
    required int mediaStoreId,
  }) async {
    final changed = await (update(_table)
          ..where((t) =>
              t.idempotencyKey.equals(idempotencyKey) &
              t.recordingMediaStoreId.isNull() &
              (t.recordingUploadStatus.isNull() |
                  t.recordingUploadStatus
                      .equals(RecordingUploadStatus.uploaded)
                      .not())))
        .write(
      LocalCallsCompanion(
        hasRecording: const Value(true),
        recordingPath: Value(recordingPath),
        recordingMediaStoreId: Value(mediaStoreId),
        recordingUploadStatus: const Value(RecordingUploadStatus.pending),
      ),
    );
    return changed > 0;
  }

  /// Counted in SQL: the counters stream is watched for the whole session
  /// and re-runs on every write to the table, so it must not pull every row
  /// across into Dart to tally a handful of states.
  Selectable<QueryRow> get _stateCounts => customSelect(
        'SELECT sync_state, COUNT(*) AS n FROM local_calls GROUP BY sync_state;',
        readsFrom: {_table},
      );

  Map<String, int> _countStates(List<QueryRow> rows) {
    int uploaded = 0;
    int uploading = 0;
    int waiting = 0;
    int failed = 0;

    for (final row in rows) {
      final state = row.read<String>('sync_state');
      final n = row.read<int>('n');
      if (CallSyncState.isUploaded(state)) {
        uploaded += n;
      } else if (CallSyncState.isInFlight(state)) {
        uploading += n;
      } else if (CallSyncState.isPermanentFailure(state)) {
        failed += n;
      } else {
        waiting += n;
      }
    }

    return {
      'uploaded': uploaded,
      'uploading': uploading,
      'waiting': waiting,
      'failed': failed,
      'total': uploaded + uploading + waiting + failed,
    };
  }

  Future<Map<String, int>> getSyncCounters() async =>
      _countStates(await _stateCounts.get());

  Stream<Map<String, int>> watchSyncCounters() =>
      _stateCounts.watch().map(_countStates).distinct(mapEquals);

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

  /// `external_call_id` prefix of WhatsApp calls (Kotlin's
  /// `NativeCallOutboxDao.EXTERNAL_WHATSAPP_PREFIX`).
  static const whatsAppPrefix = 'whatsapp-';

  /// Calls that connected but have not yet been linked to a recording candidate.
  ///
  /// WhatsApp calls are excluded: their audio cannot be recorded, so any match
  /// would be a cellular call's recording that merely overlapped in time.
  ///
  /// "Never linked" is `recording_media_store_id IS NULL`. This used to also
  /// take `has_recording = 0`, which is how the coordinator marks a recording
  /// it gave up on (refused by the server, rejected locally) while keeping the
  /// media id — so those files were re-matched and re-sent on every sync.
  Future<List<LocalCall>> getCallsNeedingRecordingMatch({int limit = 100}) {
    return (select(_table)
          ..where((t) =>
              t.durationSeconds.isBiggerThanValue(0) &
              (t.externalCallId.isNull() |
                  t.externalCallId.like('$whatsAppPrefix%').not()) &
              t.recordingMediaStoreId.isNull() &
              (t.recordingUploadStatus.isNull() |
                  t.recordingUploadStatus
                      .equals(RecordingUploadStatus.uploaded)
                      .not()))
          ..orderBy([
            (t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)
          ])
          ..limit(limit))
        .get();
  }

  /// WhatsApp calls started in [fromMillis, beforeMillis), newest first. A
  /// null bound is open.
  Future<List<LocalCall>> getWhatsAppCalls({int? fromMillis, int? beforeMillis}) {
    final query = select(_table)
      ..where((t) {
        Expression<bool> e = t.externalCallId.like('$whatsAppPrefix%');
        if (fromMillis != null) {
          e = e &
              t.startedAt.isBiggerOrEqualValue(
                DateTime.fromMillisecondsSinceEpoch(fromMillis),
              );
        }
        if (beforeMillis != null) {
          e = e &
              t.startedAt.isSmallerThanValue(
                DateTime.fromMillisecondsSinceEpoch(beforeMillis),
              );
        }
        return e;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc),
      ]);
    return query.get();
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
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)
      ])
      // The queue view is a support tool, not an archive: the newest few
      // hundred are what anyone looks at, and "all" or "synced" otherwise
      // loaded every call this phone has ever made.
      ..limit(500);
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
}
