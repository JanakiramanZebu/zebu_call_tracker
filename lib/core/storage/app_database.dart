import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_sqflite/drift_sqflite.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqf;

import '../network/call_wire_format.dart';
import 'sync_state.dart';

part 'app_database.g.dart';

class LocalCalls extends Table {
  IntColumn get localId => integer().autoIncrement()();
  TextColumn get idempotencyKey => text().unique()();
  TextColumn get externalCallId => text().nullable()();
  TextColumn get serverCallId => text().nullable()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  TextColumn get phoneNumber => text()();
  TextColumn get normalizedPhoneNumber => text().nullable()();
  TextColumn get contactName => text().nullable()();
  TextColumn get direction => text()();
  TextColumn get status => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get answeredAt => dateTime().nullable()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().withDefault(const Constant(0))();
  BoolColumn get hasRecording => boolean().withDefault(const Constant(false))();
  TextColumn get recordingPath => text().nullable()();
  IntColumn get recordingMediaStoreId => integer().nullable()();
  TextColumn get recordingChecksum => text().nullable()();
  TextColumn get recordingUploadStatus =>
      text().withDefault(const Constant(RecordingUploadStatus.pending))();
  IntColumn get simSlot => integer().nullable().withDefault(const Constant(1))();
  DateTimeColumn get clientCreatedAt => dateTime()();
  TextColumn get syncState =>
      text().withDefault(const Constant(CallSyncState.waiting))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
}

class DatabaseHealthReport {
  const DatabaseHealthReport({
    required this.isHealthy,
    required this.integrityCheckResult,
    required this.quickCheckResult,
    required this.foreignKeyCheckResult,
    required this.journalMode,
    required this.dbPath,
    required this.fileSizeBytes,
    required this.totalRows,
    this.repaired = false,
    this.salvagedRowsCount = 0,
    this.errorMessage,
  });

  final bool isHealthy;
  final String integrityCheckResult;
  final String quickCheckResult;
  final String foreignKeyCheckResult;
  final String journalMode;
  final String dbPath;
  final int fileSizeBytes;
  final int totalRows;
  final bool repaired;
  final int salvagedRowsCount;
  final String? errorMessage;
}

@DriftDatabase(tables: [LocalCalls])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  /// **Locked to Kotlin's `ZebuDatabaseHelper.DATABASE_VERSION`.**
  ///
  /// Both sides open this same file. `SQLiteOpenHelper` throws outright when it
  /// meets a database newer than its own version, so raising this number alone
  /// would not cause a migration — it would take background sync down entirely,
  /// silently, on the next call. Move both or neither.
  @override
  int get schemaVersion => 1;

  /// Columns added after the original schema, as `name: DDL`.
  ///
  /// Mirror of `ZebuDatabaseHelper.ADDITIVE_COLUMNS` in
  /// `android/.../background/NativeCallOutboxDao.kt`. Both owners open this
  /// same file, either may create the column, and both must tolerate finding
  /// it already there.
  ///
  /// **Deliberately not declared on [LocalCalls].** `metadata_json` is read and
  /// written by raw statements (`CallsDao.setMetadataJson`) rather than through
  /// a generated column, because drift codegen cannot run in this toolchain:
  /// the pinned `analyzer` (language 3.9.0) crashes with
  /// `Missing implementation of visitDotShorthandInvocation` on a Dart 3.10
  /// dot-shorthand under `integration_test/`. Declaring the column would make
  /// every build depend on regenerating `app_database.g.dart`, which currently
  /// cannot be done. Drift is unaffected by a physical column it does not know
  /// about — it names its columns explicitly and never does `SELECT *`.
  ///
  /// When the analyzer is upgraded, this can become a normal
  /// `TextColumn get metadataJson => text().nullable()();` and the raw
  /// statements can go.
  static const _additiveColumns = <String, String>{
    'metadata_json': 'metadata_json TEXT NULL',
  };

  /// True when `local_calls` already has [column].
  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table);').get();
    return rows.any((r) => r.data['name'] == column);
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        beforeOpen: (details) async {
          // Wait up to 10 s for the native uploader's write lock instead of
          // failing at once. busy_timeout returns a row, so it is run as a
          // select — Android rejects row-returning statements as plain execs.
          try {
            await customSelect('PRAGMA busy_timeout=10000;').get();
          } catch (error) {
            debugPrint('[DB] Could not set busy_timeout: $error');
          }

          // Additive columns, applied here rather than through a version bump.
          //
          // [schemaVersion] cannot move on its own — see the note on it. So a
          // new column is added the same way the normalisation below runs:
          // guarded, idempotent, and correct whichever of the two owners opens
          // the file first. Kotlin's `ZebuDatabaseHelper.ADDITIVE_COLUMNS`
          // carries the identical list and either side may win the race.
          //
          // Every column here must be nullable: SQLite cannot add a NOT NULL
          // column without a default, and rows written by an older build have
          // no value for it.
          // Caught per column: one failing must not skip the ones after it,
          // and "duplicate column name" is an expected outcome whenever Kotlin
          // won the race to add it.
          for (final entry in _additiveColumns.entries) {
            try {
              if (await _hasColumn('local_calls', entry.key)) continue;
              await customStatement(
                'ALTER TABLE local_calls ADD COLUMN ${entry.value};',
              );
            } catch (error) {
              debugPrint('[DB] Could not add ${entry.key}: $error');
            }
          }

          // Fold any rows still carrying the pre-unification lowercase state
          // names onto the shared vocabulary. Idempotent and cheap, so it runs
          // on every open rather than behind a schema version — see the note on
          // [schemaVersion] for why bumping that is not an option here.
          for (final statement in CallSyncState.normalizationStatements) {
            await customStatement(statement);
          }
          // Likewise for `status`: a row captured by a build that wrote
          // "completed" would keep being offered to the server with a value
          // absent from its enum, and rejected as a permanent 422.
          for (final statement in CallWireStatus.normalizationStatements) {
            await customStatement(statement);
          }

          // Indexes for the queries that run constantly: the analytics
          // windows and call list (started_at), the uploader's claim
          // (sync_state, next_attempt_at) and reconciliation
          // (server_call_id). Without them each of those was a full scan and
          // sort. Created here rather than in onCreate for the same reason as
          // the columns above; Kotlin's open helper creates the identical
          // names, and IF NOT EXISTS lets either side go first.
          for (final statement in _indexStatements) {
            await customStatement(statement);
          }
        },
      );

  /// Mirror of the index list in Kotlin's `ZebuDatabaseHelper.onOpen`.
  static const _indexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_local_calls_started_at '
        'ON local_calls(started_at);',
    'CREATE INDEX IF NOT EXISTS idx_local_calls_sync_next '
        'ON local_calls(sync_state, next_attempt_at);',
    'CREATE INDEX IF NOT EXISTS idx_local_calls_server_call_id '
        'ON local_calls(server_call_id);',
  ];

  static const String dbFilename = 'zebu_calls.sqlite';

  /// The app's connection, through Android's own SQLite (sqflite).
  ///
  /// **Why not drift's NativeDatabase.** That opened the file through the
  /// sqlite3 library bundled into the APK, while the Kotlin side
  /// (`ZebuDatabaseHelper`) opens the SAME file through Android's built-in
  /// SQLite — two separate copies of SQLite, in one process, on one file.
  /// SQLite documents exactly that as a way to corrupt a database ("Multiple
  /// copies of SQLite linked into the same application"): each copy tracks
  /// POSIX locks on its own, so one copy closing the file silently drops the
  /// other's locks, and concurrent writers — the native uploader and the app —
  /// then tear pages. On the reference SM-M356B it surfaced as
  /// `database disk image is malformed` on the Home screen.
  ///
  /// With every connection on the same SQLite, the locking is shared and
  /// correct. WAL is turned on for sqflite by the
  /// `com.tekartik.sqflite.wal_enabled` meta-data in AndroidManifest.xml.
  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final file = await getDatabaseFile();

      // Pre-open integrity check and self-healing recovery. sqflite runs its
      // statements on a background thread, so this no longer needs an
      // isolate to keep the first frame smooth.
      await checkAndRepairDatabaseFile(file);

      return SqfliteQueryExecutor(path: file.path);
    });
  }

  static Future<File> getDatabaseFile() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    return File(p.join(dbFolder.path, dbFilename));
  }

  /// First column of the first row, as text — the shape every PRAGMA check
  /// returns.
  static String _firstValue(List<Map<String, Object?>> rows, String empty) =>
      rows.isEmpty ? empty : rows.first.values.first?.toString() ?? empty;

  /// Opens [path] for inspection only.
  ///
  /// Always read-only: sqflite's read-only open installs an error handler
  /// that leaves a corrupt file alone, while its read-write open keeps
  /// Android's default handler, which DELETES the file on corruption. A health
  /// check must never be the thing that destroys what it is checking.
  static Future<sqf.Database> _openForInspection(String path) =>
      sqf.openDatabase(path, readOnly: true, singleInstance: false);

  /// Inspects database health and returns a comprehensive [DatabaseHealthReport].
  static Future<DatabaseHealthReport> checkHealth() async {
    final file = await getDatabaseFile();
    return _checkHealthAt(file);
  }

  static Future<DatabaseHealthReport> _checkHealthAt(File file) async {
    if (!await file.exists()) {
      return DatabaseHealthReport(
        isHealthy: true,
        integrityCheckResult: 'Database file not created yet',
        quickCheckResult: 'ok',
        foreignKeyCheckResult: 'ok',
        journalMode: 'WAL',
        dbPath: file.path,
        fileSizeBytes: 0,
        totalRows: 0,
      );
    }

    final fileSize = await file.length();
    sqf.Database? db;
    try {
      db = await _openForInspection(file.path);

      final integrityStr =
          _firstValue(await db.rawQuery('PRAGMA integrity_check;'), 'ok');
      final quickStr =
          _firstValue(await db.rawQuery('PRAGMA quick_check;'), 'ok');
      final fkRows = await db.rawQuery('PRAGMA foreign_key_check;');
      final fkStr =
          fkRows.isEmpty ? 'ok' : '${fkRows.length} foreign key violations';
      final journalStr =
          _firstValue(await db.rawQuery('PRAGMA journal_mode;'), 'unknown');

      var rowCount = 0;
      try {
        final count = await db.rawQuery('SELECT COUNT(*) AS c FROM local_calls;');
        rowCount = (count.first['c'] as num?)?.toInt() ?? 0;
      } catch (_) {
        rowCount = 0;
      }

      return DatabaseHealthReport(
        isHealthy: integrityStr == 'ok' && quickStr == 'ok',
        integrityCheckResult: integrityStr,
        quickCheckResult: quickStr,
        foreignKeyCheckResult: fkStr,
        journalMode: journalStr,
        dbPath: file.path,
        fileSizeBytes: fileSize,
        totalRows: rowCount,
      );
    } catch (e) {
      return DatabaseHealthReport(
        isHealthy: false,
        integrityCheckResult: 'Error: $e',
        quickCheckResult: 'Error: $e',
        foreignKeyCheckResult: 'unknown',
        journalMode: 'unknown',
        dbPath: file.path,
        fileSizeBytes: fileSize,
        totalRows: 0,
        errorMessage: e.toString(),
      );
    } finally {
      await db?.close();
    }
  }

  /// Verifies database integrity via PRAGMA integrity_check.
  /// If malformed or corrupted, executes multi-tiered self-healing:
  ///   Tier 1: WAL Checkpoint + REINDEX
  ///   Tier 2: Row-level data salvage into clean DB with full backup preservation
  static Future<bool> checkAndRepairDatabaseFile(File file) async {
    if (!await file.exists()) return true;

    sqf.Database? db;
    var needsRepair = false;
    var initialError = '';

    try {
      db = await _openForInspection(file.path);
      final status =
          _firstValue(await db.rawQuery('PRAGMA integrity_check;'), 'ok');
      if (status != 'ok') {
        needsRepair = true;
        initialError = status;
      }
    } catch (e) {
      needsRepair = true;
      initialError = e.toString();
    } finally {
      await db?.close();
    }

    if (!needsRepair) {
      debugPrint('[DB_HEALTH] Integrity check passed [OK].');
      return true;
    }

    debugPrint('[DB_HEALTH] Database integrity failure detected ($initialError)! Starting safe recovery...');
    return _executeSafeRecovery(file);
  }

  /// Executes data-preserving multi-tier database recovery.
  static Future<bool> _executeSafeRecovery(File file) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final backupFile = File('${file.path}.corrupt_backup_$timestamp');
    final walFile = File('${file.path}-wal');
    final shmFile = File('${file.path}-shm');

    // 1. Always create a safety backup before any recovery attempts
    try {
      await file.copy(backupFile.path);
      if (await walFile.exists()) {
        await walFile.copy('${backupFile.path}-wal');
      }
      if (await shmFile.exists()) {
        await shmFile.copy('${backupFile.path}-shm');
      }
      debugPrint('[DB_HEALTH] Timestamped backup preserved at: ${backupFile.path}');
    } catch (e) {
      debugPrint('[DB_HEALTH] Warning creating backup copy: $e');
    }

    // 2. Tier 1: Try WAL checkpoint + REINDEX.
    //
    // The one read-write open of a file known to be damaged. If Android's
    // default handler deletes it here, nothing is lost: the backup above is
    // what Tier 2 salvages from.
    try {
      final db = await sqf.openDatabase(file.path, singleInstance: false);
      try {
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
        await db.execute('REINDEX;');
        final ok = _firstValue(
              await db.rawQuery('PRAGMA integrity_check;'),
              '',
            ) ==
            'ok';
        if (ok) {
          debugPrint('[DB_HEALTH] Tier 1 repair (REINDEX + WAL checkpoint) successfully restored database health!');
          return true;
        }
      } finally {
        await db.close();
      }
    } catch (e) {
      debugPrint('[DB_HEALTH] Tier 1 repair encountered error: $e');
    }

    // 3. Tier 2: Deep row-level salvage into a clean, reconstructed database
    debugPrint('[DB_HEALTH] Proceeding to Tier 2 row-level salvage...');
    return _salvageRowsIntoCleanDatabase(file, backupFile);
  }

  /// Extracts readable records row-by-row from the corrupted DB and restores them into a clean DB.
  static Future<bool> _salvageRowsIntoCleanDatabase(File file, File backupFile) async {
    final recoveredRows = <Map<String, Object?>>[];
    sqf.Database? corruptDb;

    try {
      corruptDb = await _openForInspection(backupFile.path);

      // Probe every rowid in range individually, rather than asking the damaged
      // database to list them.
      //
      // `SELECT rowid FROM local_calls` looks like the cheaper way to do this
      // and is the reason salvage quietly lost half its data: the scan walks
      // the table b-tree and STOPS at the first damaged page, returning a short
      // list without raising anything. Measured on a real corrupted database
      // from this app, it reported 58 rowids — all of them below the damage —
      // while the table still held 106 readable rows. The per-rowid `catch`
      // below never got the chance to skip past the break, because the loop was
      // never told the later rows existed.
      //
      // The upper bound comes from `sqlite_sequence`, which is a separate
      // one-row table and survives damage to the main b-tree. Probing an id
      // that was never used, or sits on a damaged page, costs one failed lookup
      // and yields nothing — which is the point.
      var maxRowId = 0;
      for (final probe in const [
        "SELECT seq AS v FROM sqlite_sequence WHERE name = 'local_calls';",
        'SELECT MAX(rowid) AS v FROM local_calls;',
      ]) {
        try {
          final result = await corruptDb.rawQuery(probe);
          final value = (result.isEmpty ? null : result.first['v']) as int?;
          if (value != null && value > maxRowId) maxRowId = value;
        } catch (e) {
          debugPrint('[DB_HEALTH] Row-bound probe failed: $e');
        }
      }

      if (maxRowId == 0) {
        debugPrint('[DB_HEALTH] Could not establish a rowid range to salvage.');
      }

      for (var rowid = 1; rowid <= maxRowId; rowid++) {
        try {
          final row = await corruptDb.rawQuery(
            'SELECT * FROM local_calls WHERE rowid = ?;',
            [rowid],
          );
          if (row.isNotEmpty) {
            recoveredRows.add(Map<String, Object?>.from(row.first));
          }
        } catch (e) {
          debugPrint('[DB_HEALTH] Skipped damaged rowid $rowid: $e');
        }
      }
      debugPrint('[DB_HEALTH] Successfully salvaged ${recoveredRows.length} rows from damaged database.');
    } catch (e) {
      debugPrint('[DB_HEALTH] Row extraction error: $e');
    } finally {
      await corruptDb?.close();
    }

    // Create a pristine reconstructed database
    final tempCleanFile =
        File('${file.path}.clean_${DateTime.now().millisecondsSinceEpoch}');
    sqf.Database? cleanDb;

    try {
      if (await tempCleanFile.exists()) {
        await tempCleanFile.delete();
      }

      cleanDb = await sqf.openDatabase(tempCleanFile.path, singleInstance: false);

      // Create pristine table & indexes
      await cleanDb.execute('''
        CREATE TABLE local_calls (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          idempotency_key TEXT NOT NULL UNIQUE,
          external_call_id TEXT,
          server_call_id TEXT,
          revision INTEGER NOT NULL DEFAULT 0,
          phone_number TEXT NOT NULL,
          normalized_phone_number TEXT,
          contact_name TEXT,
          direction TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          answered_at INTEGER,
          ended_at INTEGER,
          duration_seconds INTEGER NOT NULL DEFAULT 0,
          has_recording INTEGER NOT NULL DEFAULT 0,
          recording_path TEXT,
          recording_media_store_id INTEGER,
          recording_checksum TEXT,
          recording_upload_status TEXT NOT NULL DEFAULT '${RecordingUploadStatus.pending}',
          sim_slot INTEGER DEFAULT 1,
          client_created_at INTEGER NOT NULL,
          sync_state TEXT NOT NULL DEFAULT '${CallSyncState.waiting}',
          attempt_count INTEGER NOT NULL DEFAULT 0,
          next_attempt_at INTEGER,
          last_error_code TEXT,
          metadata_json TEXT
        );
      ''');

      // Both owners read user_version: drift to decide whether to run
      // onCreate, Kotlin's SQLiteOpenHelper to decide onCreate/onUpgrade. A
      // rebuilt file left at 0 looked brand new to both.
      await cleanDb.execute('PRAGMA user_version = 1;');

      // Re-insert salvaged rows, in one transaction.
      final batch = cleanDb.batch();
      for (final row in recoveredRows) {
        final key = row['idempotency_key']?.toString();
        if (key == null || key.isEmpty) continue;

        batch.rawInsert('''
          INSERT OR IGNORE INTO local_calls (
            idempotency_key, external_call_id, server_call_id, revision,
            phone_number, normalized_phone_number, contact_name, direction, status,
            started_at, answered_at, ended_at, duration_seconds, has_recording,
            recording_path, recording_media_store_id, recording_checksum,
            recording_upload_status, sim_slot, client_created_at, sync_state,
            attempt_count, next_attempt_at, last_error_code, metadata_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''', [
          key,
          row['external_call_id'],
          row['server_call_id'],
          row['revision'] ?? 0,
          row['phone_number'] ?? 'Unknown',
          row['normalized_phone_number'],
          row['contact_name'],
          row['direction'] ?? 'incoming',
          row['status'] ?? 'completed',
          row['started_at'] ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          row['answered_at'],
          row['ended_at'],
          row['duration_seconds'] ?? 0,
          row['has_recording'] ?? 0,
          row['recording_path'],
          row['recording_media_store_id'],
          row['recording_checksum'],
          row['recording_upload_status'] ?? RecordingUploadStatus.pending,
          row['sim_slot'] ?? 1,
          row['client_created_at'] ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          CallSyncState.normalize(
              (row['sync_state'] as String?) ?? CallSyncState.waiting),
          row['attempt_count'] ?? 0,
          row['next_attempt_at'],
          row['last_error_code'],
          // Absent on rows written before the column existed, which is a null
          // rather than a problem.
          row['metadata_json'],
        ]);
      }
      await batch.commit(noResult: true);

      // Check integrity of clean database
      final isCleanOk = _firstValue(
            await cleanDb.rawQuery('PRAGMA integrity_check;'),
            '',
          ) ==
          'ok';

      // Closing the last connection checkpoints the WAL into the main file,
      // so the single file renamed below is complete.
      await cleanDb.close();
      cleanDb = null;

      if (isCleanOk) {
        // Safely swap files
        final wal = File('${file.path}-wal');
        final shm = File('${file.path}-shm');
        if (await wal.exists()) await wal.delete();
        if (await shm.exists()) await shm.delete();
        if (await file.exists()) await file.delete();

        await tempCleanFile.rename(file.path);
        debugPrint('[DB_HEALTH] Clean database successfully activated! Restored ${recoveredRows.length} calls.');
        return true;
      } else {
        debugPrint('[DB_HEALTH] Reconstructed database failed integrity check.');
        return false;
      }
    } catch (e) {
      debugPrint('[DB_HEALTH] Error during row salvage migration: $e');
      return false;
    } finally {
      await cleanDb?.close();
      for (final leftover in [
        tempCleanFile,
        File('${tempCleanFile.path}-wal'),
        File('${tempCleanFile.path}-shm'),
      ]) {
        if (await leftover.exists()) {
          try {
            await leftover.delete();
          } catch (_) {}
        }
      }
    }
  }
}
