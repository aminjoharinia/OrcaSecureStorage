import 'adapter.dart';
import 'sqflite_factory_web.dart'
    if (dart.library.io) 'sqflite_factory_io.dart';

/// One row per key in a `kv(key TEXT PRIMARY KEY, value)` table, one SQL
/// statement per call.
class SqfliteAdapter extends StorageAdapter {
  late BenchDatabase _db;

  @override
  String get name => 'sqflite';
  @override
  String get label => 'sqfl';
  @override
  String get package => 'sqflite 2.4.4';
  @override
  String get encryption => 'none';
  @override
  String? get unsupportedReason => sqfliteUnsupportedReason;

  @override
  Future<void> open() async => _db = await openBenchDatabase();

  // Cold read: close the database and open it again.
  @override
  Future<void> openCold() async {
    await _db.close();
    await open();
  }

  @override
  Future<void> clear() => _db.execute('DELETE FROM kv');
  @override
  Future<void> write(String key, Object value) => _db.execute(
    'INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)',
    [key, encodeIfJson(value)],
  );
  @override
  Future<Object?> read(String key) async =>
      decodeIfJson(await _db.readValue(key));
  @override
  Future<void> delete(String key) =>
      _db.execute('DELETE FROM kv WHERE key = ?', [key]);
}
