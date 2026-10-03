import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

const String? sqfliteUnsupportedReason = null;

class BenchDatabase {
  BenchDatabase(this._db);
  final sqflite.Database _db;

  Future<void> execute(String sql, [List<Object?>? args]) =>
      _db.execute(sql, args);
  Future<void> close() => _db.close();

  Future<Object?> readValue(String key) async {
    final rows = await _db.rawQuery('SELECT value FROM kv WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'];
  }
}

/// The sqflite plugin on Android, iOS and macOS; the FFI implementation
/// (same API, bundled SQLite) on Linux and Windows.
Future<BenchDatabase> openBenchDatabase() async {
  final desktopFfi = Platform.isLinux || Platform.isWindows;
  final sqflite.DatabaseFactory factory;
  final String dir;
  if (desktopFfi) {
    ffi.sqfliteFfiInit();
    factory = ffi.databaseFactoryFfi;
    dir = (await getApplicationSupportDirectory()).path;
  } else {
    factory = sqflite.databaseFactory;
    dir = await sqflite.getDatabasesPath();
  }
  final db = await factory.openDatabase(
    p.join(dir, 'storage_benchmark.db'),
    options: sqflite.OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) =>
          db.execute('CREATE TABLE kv(key TEXT PRIMARY KEY, value)'),
    ),
  );
  return BenchDatabase(db);
}
