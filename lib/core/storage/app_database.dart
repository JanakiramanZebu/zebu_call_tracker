import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

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
    this.backupPath,
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
  final String? backupPath;
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
        },
      );

  static const String dbFilename = 'zebu_calls.sqlite';

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final file = await getDatabaseFile();

      // Perform pre-open integrity check & self-healing recovery if malformed
      await checkAndRepairDatabaseFile(file);

      return NativeDatabase.createInBackground(
        file,
        setup: (db) {
          db.execute('PRAGMA journal_mode=WAL;');
          db.execute('PRAGMA busy_timeout=10000;');
          db.execute('PRAGMA synchronous=NORMAL;');
        },
      );
    });
  }

  static Future<File> getDatabaseFile() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    return File(p.join(dbFolder.path, dbFilename));
  }

  /// Inspects database health and returns a comprehensive [DatabaseHealthReport].
  static Future<DatabaseHealthReport> checkHealth() async {
    final file = await getDatabaseFile();
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
    sql.Database? rawDb;
    try {
      rawDb = sql.sqlite3.open(file.path);
      rawDb.execute('PRAGMA busy_timeout=5000;');

      final integrityResult = rawDb.select('PRAGMA integrity_check;');
      final integrityStr = integrityResult.isNotEmpty ? integrityResult.first.values.first?.toString() ?? 'ok' : 'ok';

      final quickResult = rawDb.select('PRAGMA quick_check;');
      final quickStr = quickResult.isNotEmpty ? quickResult.first.values.first?.toString() ?? 'ok' : 'ok';

      final fkResult = rawDb.select('PRAGMA foreign_key_check;');
      final fkStr = fkResult.isEmpty ? 'ok' : '${fkResult.length} foreign key violations';

      final journalResult = rawDb.select('PRAGMA journal_mode;');
      final journalStr = journalResult.isNotEmpty ? journalResult.first.values.first?.toString() ?? 'unknown' : 'unknown';

      int rowCount = 0;
      try {
        final countResult = rawDb.select('SELECT COUNT(*) FROM local_calls;');
        rowCount = (countResult.first.values.first as num?)?.toInt() ?? 0;
      } catch (_) {
        rowCount = 0;
      }

      final isHealthy = integrityStr == 'ok' && quickStr == 'ok';

      return DatabaseHealthReport(
        isHealthy: isHealthy,
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
      rawDb?.dispose();
    }
  }

  /// Verifies database integrity via PRAGMA integrity_check.
  /// If malformed or corrupted, executes multi-tiered self-healing:
  ///   Tier 1: WAL Checkpoint + REINDEX
  ///   Tier 2: Row-level data salvage into clean DB with full backup preservation
  static Future<bool> checkAndRepairDatabaseFile(File file) async {
    if (!await file.exists()) return true;

    sql.Database? rawDb;
    bool needsRepair = false;
    String initialError = '';

    try {
      rawDb = sql.sqlite3.open(file.path);
      rawDb.execute('PRAGMA busy_timeout=5000;');
      final integrity = rawDb.select('PRAGMA integrity_check;');
      final statusStr = integrity.isNotEmpty ? integrity.first.values.first?.toString() ?? 'ok' : 'ok';

      if (statusStr != 'ok') {
        needsRepair = true;
        initialError = statusStr;
      }
    } catch (e) {
      needsRepair = true;
      initialError = e.toString();
    } finally {
      rawDb?.dispose();
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

    // 2. Tier 1: Try WAL checkpoint + REINDEX
    try {
      final db = sql.sqlite3.open(file.path);
      db.execute('PRAGMA busy_timeout=10000;');
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      db.execute('REINDEX;');
      final recheck = db.select('PRAGMA integrity_check;');
      final ok = recheck.isNotEmpty && recheck.first.values.first?.toString() == 'ok';
      db.dispose();

      if (ok) {
        debugPrint('[DB_HEALTH] Tier 1 repair (REINDEX + WAL checkpoint) successfully restored database health!');
        return true;
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
    final recoveredRows = <Map<String, dynamic>>[];
    sql.Database? corruptDb;

    try {
      corruptDb = sql.sqlite3.open(backupFile.path);
      corruptDb.execute('PRAGMA busy_timeout=10000;');

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
          final result = corruptDb.select(probe);
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
          final row = corruptDb.select('SELECT * FROM local_calls WHERE rowid = ?;', [rowid]);
          if (row.isNotEmpty) {
            recoveredRows.add(Map<String, dynamic>.from(row.first));
          }
        } catch (e) {
          debugPrint('[DB_HEALTH] Skipped damaged rowid $rowid: $e');
        }
      }
      debugPrint('[DB_HEALTH] Successfully salvaged ${recoveredRows.length} rows from damaged database.');
    } catch (e) {
      debugPrint('[DB_HEALTH] Row extraction error: $e');
    } finally {
      corruptDb?.dispose();
    }

    // Create a pristine reconstructed database
    final tempCleanFile =
        File('${file.path}.clean_${DateTime.now().millisecondsSinceEpoch}');
    sql.Database? cleanDb;

    try {
      if (await tempCleanFile.exists()) {
        await tempCleanFile.delete();
      }

      cleanDb = sql.sqlite3.open(tempCleanFile.path);
      cleanDb.execute('PRAGMA journal_mode=WAL;');
      cleanDb.execute('PRAGMA synchronous=NORMAL;');
      cleanDb.execute('PRAGMA busy_timeout=10000;');

      // Create pristine table & indexes
      cleanDb.execute('''
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

      // Re-insert salvaged rows
      final stmt = cleanDb.prepare('''
        INSERT OR IGNORE INTO local_calls (
          idempotency_key, external_call_id, server_call_id, revision,
          phone_number, normalized_phone_number, contact_name, direction, status,
          started_at, answered_at, ended_at, duration_seconds, has_recording,
          recording_path, recording_media_store_id, recording_checksum,
          recording_upload_status, sim_slot, client_created_at, sync_state,
          attempt_count, next_attempt_at, last_error_code, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''');

      for (final row in recoveredRows) {
        final key = row['idempotency_key']?.toString();
        if (key == null || key.isEmpty) continue;

        stmt.execute([
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
      stmt.dispose();

      // Check integrity of clean database
      final check = cleanDb.select('PRAGMA integrity_check;');
      final isCleanOk = check.isNotEmpty && check.first.values.first?.toString() == 'ok';

      cleanDb.dispose();
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
      cleanDb?.dispose();
      if (await tempCleanFile.exists()) {
        try {
          await tempCleanFile.delete();
        } catch (_) {}
      }
    }
  }
}
