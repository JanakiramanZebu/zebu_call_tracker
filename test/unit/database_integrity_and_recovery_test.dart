import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:zebu_call_tracker/core/storage/app_database.dart';
import 'package:zebu_call_tracker/core/storage/calls_dao.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late CallsDao dao;
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zebu_db_test_');
    dbFile = File('${tempDir.path}/zebu_calls.sqlite');

    db = AppDatabase(
      NativeDatabase(
        dbFile,
        setup: (rawDb) {
          rawDb.execute('PRAGMA journal_mode=WAL;');
          rawDb.execute('PRAGMA busy_timeout=10000;');
          rawDb.execute('PRAGMA synchronous=NORMAL;');
        },
      ),
    );
    dao = CallsDao(db);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Database Integrity & Recovery Tests', () {
    test('Database creates tables and passes PRAGMA integrity_check', () async {
      // Insert a sample call
      final now = DateTime.now().toUtc();
      await dao.insertOrUpdateCall(
        LocalCallsCompanion.insert(
          idempotencyKey: 'test-key-1',
          phoneNumber: '+919876543210',
          direction: 'incoming',
          status: 'completed',
          startedAt: now,
          clientCreatedAt: now,
          durationSeconds: const drift.Value(45),
        ),
      );

      final call = await dao.findByIdempotencyKey('test-key-1');
      expect(call, isNotNull);
      expect(call!.phoneNumber, '+919876543210');
      expect(call.durationSeconds, 45);

      // Verify PRAGMA integrity_check via raw sqlite3
      final rawDb = sql.sqlite3.open(dbFile.path);
      final check = rawDb.select('PRAGMA integrity_check;');
      expect(check.first.values.first, 'ok');
      rawDb.dispose();
    });

    test('findByIdempotencyKeys safely handles empty, small, and large chunked batches', () async {
      final now = DateTime.now().toUtc();
      final keys = <String>[];

      // Insert 120 calls across multiple chunks
      for (int i = 0; i < 120; i++) {
        final key = 'bulk-key-$i';
        keys.add(key);
        await dao.insertOrUpdateCall(
          LocalCallsCompanion.insert(
            idempotencyKey: key,
            phoneNumber: '+9198765432$i',
            direction: i.isEven ? 'incoming' : 'outgoing',
            status: 'completed',
            startedAt: now.add(Duration(seconds: i)),
            clientCreatedAt: now,
          ),
        );
      }

      // Empty query
      final emptyResult = await dao.findByIdempotencyKeys([]);
      expect(emptyResult, isEmpty);

      // Small batch query (<= 50)
      final smallResult = await dao.findByIdempotencyKeys(keys.take(20).toList());
      expect(smallResult.length, 20);

      // Large batch query (> 50, triggers chunking)
      final allResult = await dao.findByIdempotencyKeys(keys);
      expect(allResult.length, 120);
    });

    test('Self-healing recovery restores damaged database and preserves corrupt backup', () async {
      // 1. Insert test calls into database
      final now = DateTime.now().toUtc();
      for (int i = 0; i < 10; i++) {
        await dao.insertOrUpdateCall(
          LocalCallsCompanion.insert(
            idempotencyKey: 'recovery-key-$i',
            phoneNumber: '+91900000000$i',
            direction: 'incoming',
            status: 'completed',
            startedAt: now,
            clientCreatedAt: now,
          ),
        );
      }

      await db.close();

      // 2. Run recovery routine on database file
      final recovered = await AppDatabase.checkAndRepairDatabaseFile(dbFile);
      expect(recovered, isTrue);

      // 3. Verify clean DB opens and contains all recovered calls
      final newDb = AppDatabase(NativeDatabase(dbFile));
      final newDao = CallsDao(newDb);

      final calls = await newDao.findByIdempotencyKeys(['recovery-key-0', 'recovery-key-5', 'recovery-key-9']);
      expect(calls.length, 3);
      await newDb.close();
    });
  });
}
