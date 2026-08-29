import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';
import 'calls_dao.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final callsDaoProvider = Provider<CallsDao>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return CallsDao(db);
});
