import 'package:sembast/sembast.dart';

import 'adapter.dart';
import 'sembast_factory_web.dart'
    if (dart.library.io) 'sembast_factory_io.dart';

/// Sembast: a NoSQL document store in pure Dart (a file on native,
/// IndexedDB on the web).
class SembastAdapter extends StorageAdapter {
  late Database _db;
  final _store = StoreRef<String, Object>.main();

  @override
  String get name => 'Sembast';
  @override
  String get label => 'Sem';
  @override
  String get package => 'sembast 3.8.11';
  @override
  String get encryption => 'none';

  @override
  Future<void> open() async => _db = await openSembast('storage_benchmark.db');

  // Cold read: close the database and open it again (reloads the file).
  @override
  Future<void> openCold() async {
    await _db.close();
    await open();
  }

  @override
  Future<void> clear() => _store.drop(_db);
  @override
  Future<void> write(String key, Object value) =>
      _store.record(key).put(_db, value);
  @override
  Future<Object?> read(String key) => _store.record(key).get(_db);
  @override
  Future<void> delete(String key) => _store.record(key).delete(_db);
}
