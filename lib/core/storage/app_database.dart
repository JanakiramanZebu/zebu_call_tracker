import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

@DriftDatabase(tables: [LocalCalls])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  @override
  int get schemaVersion => 1;

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'zebu_calls.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
  }
}
