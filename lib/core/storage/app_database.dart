import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

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
  TextColumn get recordingUploadStatus => text().withDefault(const Constant('pending'))();
  IntColumn get simSlot => integer().nullable().withDefault(const Constant(1))();
  DateTimeColumn get clientCreatedAt => dateTime()();
  TextColumn get syncState => text().withDefault(const Constant('pending'))();
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

  @override
  int get schemaVersion => 1;

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

      // Scan rowids sequentially to bypass corrupted B-tree indexes
      final rowidsResult = corruptDb.select('SELECT rowid FROM local_calls;');
      for (final r in rowidsResult) {
        final rowid = r['rowid'];
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
    final tempCleanFile = File('${file.path}.clean_$DateTime.now().millisecondsSinceEpoch');
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
          recording_upload_status TEXT NOT NULL DEFAULT 'pending',
          sim_slot INTEGER DEFAULT 1,
          client_created_at INTEGER NOT NULL,
          sync_state TEXT NOT NULL DEFAULT 'pending',
          attempt_count INTEGER NOT NULL DEFAULT 0,
          next_attempt_at INTEGER,
          last_error_code TEXT
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
          attempt_count, next_attempt_at, last_error_code
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
          row['recording_upload_status'] ?? 'pending',
          row['sim_slot'] ?? 1,
          row['client_created_at'] ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          row['sync_state'] ?? 'pending',
          row['attempt_count'] ?? 0,
          row['next_attempt_at'],
          row['last_error_code'],
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
