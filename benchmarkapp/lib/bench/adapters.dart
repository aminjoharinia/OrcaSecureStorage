import 'dart:convert';

import 'package:get_secure_storage/get_secure_storage.dart'
    show GetSecureStorage;
import 'package:get_storage/get_storage.dart' show GetStorage;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart'
    show OrcaSecureStorage;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform_web.dart'
    if (dart.library.io) '../platform/platform_io.dart';
import 'adapter.dart';
import 'sembast_adapter.dart';
import 'sqflite_adapter.dart';

// Fixed secrets: the benchmark reopens the same encrypted files on every run.
// Never hard-code secrets like this in an app.
const _password = 'benchmark-password';
final _hiveKey = List<int>.generate(32, (i) => (i * 37 + 11) & 0xff);
final _orcaKey = List<int>.generate(32, (i) => (i * 53 + 7) & 0xff);

List<StorageAdapter> allAdapters() => [
  OrcaAdapter(OrcaMode.password),
  OrcaAdapter(OrcaMode.key),
  OrcaAdapter(OrcaMode.none),
  GetSecureStorageAdapter(),
  GetStorageAdapter(),
  HiveAdapter(encrypted: false),
  HiveAdapter(encrypted: true),
  SharedPreferencesAdapter(),
  SqfliteAdapter(),
  SembastAdapter(),
];

/// How the Orca container is protected.
enum OrcaMode { password, key, none }

class OrcaAdapter extends StorageAdapter {
  OrcaAdapter(this.mode);
  final OrcaMode mode;
  late OrcaSecureStorage _box;

  String get _container => switch (mode) {
    OrcaMode.password => 'bench_orca_enc',
    OrcaMode.key => 'bench_orca_key',
    OrcaMode.none => 'bench_orca',
  };
  @override
  String get name => switch (mode) {
    OrcaMode.password => 'OrcaSecureStorage (password)',
    OrcaMode.key => 'OrcaSecureStorage (key)',
    OrcaMode.none => 'OrcaSecureStorage (no password)',
  };
  @override
  String get label => switch (mode) {
    OrcaMode.password => 'Orca pw',
    OrcaMode.key => 'Orca key',
    OrcaMode.none => 'Orca',
  };
  @override
  String get package => 'orca_secure_storage 2.1.0';
  @override
  String get encryption => switch (mode) {
    OrcaMode.password => 'AES-256-GCM, PBKDF2 key',
    OrcaMode.key => 'AES-256-GCM, raw key',
    OrcaMode.none => 'none',
  };

  Future<void> _init(String container) => OrcaSecureStorage.init(
    container: container,
    password: mode == OrcaMode.password ? _password : null,
    encryptionKey: mode == OrcaMode.key ? _orcaKey : null,
  );

  @override
  Future<void> open() async {
    await _init(_container);
    _box = OrcaSecureStorage(container: _container);
  }

  @override
  Future<void> clear() => _box.erase();
  @override
  Future<void> write(String key, Object value) => _box.write(key, value);
  @override
  Future<Object?> read(String key) async => _box.read(key);
  @override
  Future<void> delete(String key) => _box.remove(key);
  @override
  Future<void> flush() => _box.flush();
  @override
  Future<void> abort() async {
    _box.queue.cancelAllJobs();
    await waitForQueue(_box.queue);
  }

  // Cold read: a new container on a copy of the file, opened from disk.
  int _coldCount = 0;
  String? _coldName;
  OrcaSecureStorage? _cold;

  @override
  Future<void> openCold() async {
    final name = _coldName = '${_container}_cold${_coldCount++}';
    // Snapshot, backup and change log: what an app restart would find.
    for (final ext in ['.oss', '.ossbak', '.osslog']) {
      await copyStore(_container, name, ext);
    }
    await _init(name);
    _cold = OrcaSecureStorage(container: name);
  }

  @override
  Future<Object?> readCold(String key) async => _cold!.read(key);

  @override
  Future<void> closeCold() async {
    final cold = _cold;
    if (cold == null) return;
    _cold = null;
    await cold.erase();
    await cold.flush();
    await deleteStore(_coldName!, ['.oss', '.ossbak', '.osslog']);
  }
}

class GetSecureStorageAdapter extends StorageAdapter {
  late GetSecureStorage _box;
  @override
  String get name => 'GetSecureStorage';
  @override
  String get label => 'GSS';
  @override
  String get package => 'get_secure_storage 1.0.5';
  @override
  String get encryption => 'AES-128-CTR + HMAC';

  @override
  Future<void> open() async {
    await GetSecureStorage.init(container: 'bench_gss', password: _password);
    _box = GetSecureStorage(container: 'bench_gss');
  }

  int _coldCount = 0;
  String? _coldName;
  GetSecureStorage? _cold;

  @override
  Future<void> openCold() async {
    final name = _coldName = 'bench_gss_cold${_coldCount++}';
    await copyStore('bench_gss', name, '.gs');
    await GetSecureStorage.init(container: name, password: _password);
    _cold = GetSecureStorage(container: name);
  }

  @override
  Future<Object?> readCold(String key) async => _cold!.read(key);

  @override
  Future<void> closeCold() async {
    final cold = _cold;
    if (cold == null) return;
    _cold = null;
    await cold.erase();
    await waitForQueue(cold.queue);
    await deleteStore(_coldName!, ['.gs', '.bak']);
  }

  @override
  Future<void> clear() => _box.erase();
  @override
  Future<void> write(String key, Object value) => _box.write(key, value);
  @override
  Future<Object?> read(String key) async => _box.read(key);
  @override
  Future<void> delete(String key) => _box.remove(key);
  @override
  Future<void> flush() => waitForQueue(_box.queue);
  @override
  Future<void> abort() async {
    _box.queue.cancelAllJobs();
    await waitForQueue(_box.queue);
  }
}

class GetStorageAdapter extends StorageAdapter {
  late GetStorage _box;
  @override
  String get name => 'GetStorage';
  @override
  String get label => 'GS';
  @override
  String get package => 'get_storage 2.1.1';
  @override
  String get encryption => 'none';

  @override
  Future<void> open() async {
    await GetStorage.init('bench_gs');
    _box = GetStorage('bench_gs');
  }

  int _coldCount = 0;
  String? _coldName;
  GetStorage? _cold;

  @override
  Future<void> openCold() async {
    final name = _coldName = 'bench_gs_cold${_coldCount++}';
    await copyStore('bench_gs', name, '.gs');
    await GetStorage.init(name);
    _cold = GetStorage(name);
  }

  @override
  Future<Object?> readCold(String key) async => _cold!.read(key);

  @override
  Future<void> closeCold() async {
    final cold = _cold;
    if (cold == null) return;
    _cold = null;
    await cold.erase();
    await waitForQueue(cold.queue);
    await deleteStore(_coldName!, ['.gs', '.bak']);
  }

  @override
  Future<void> clear() => _box.erase();
  @override
  Future<void> write(String key, Object value) => _box.write(key, value);
  @override
  Future<Object?> read(String key) async => _box.read(key);
  @override
  Future<void> delete(String key) => _box.remove(key);
  @override
  Future<void> flush() => waitForQueue(_box.queue);
  @override
  Future<void> abort() async {
    _box.queue.cancelAllJobs();
    await waitForQueue(_box.queue);
  }
}

class HiveAdapter extends StorageAdapter {
  HiveAdapter({required this.encrypted});
  @override
  final bool encrypted;
  static Future<void>? _init;
  late Box<Object> _box;

  @override
  String get name => encrypted ? 'Hive CE (encrypted)' : 'Hive CE';
  @override
  String get label => 'Hive';
  @override
  String get package => 'hive_ce 2.20.1';
  @override
  String get encryption => encrypted ? 'AES-256-CBC' : 'none';

  @override
  Future<void> open() async {
    await (_init ??= Hive.initFlutter('storage_benchmark'));
    _box = await Hive.openBox<Object>(
      encrypted ? 'bench_hive_enc' : 'bench_hive',
      encryptionCipher: encrypted ? HiveAesCipher(_hiveKey) : null,
    );
  }

  // Cold read: close the box and open it again from disk.
  @override
  Future<void> openCold() async {
    await _box.close();
    await open();
  }

  @override
  Future<void> clear() => _box.clear();
  @override
  Future<void> write(String key, Object value) => _box.put(key, value);
  @override
  Future<Object?> read(String key) async => _box.get(key);
  @override
  Future<void> delete(String key) => _box.delete(key);
  @override
  Future<void> flush() => _box.flush();
}

class SharedPreferencesAdapter extends StorageAdapter {
  late SharedPreferences _prefs;
  @override
  String get name => 'SharedPreferences';
  @override
  String get label => 'SP';
  @override
  String get package => 'shared_preferences 2.5.5';
  @override
  String get encryption => 'none';

  @override
  Future<void> open() async => _prefs = await SharedPreferences.getInstance();

  // Cold read: re-read every preference from the platform. (The instance
  // itself is cached for the life of the app.)
  @override
  Future<void> openCold() => _prefs.reload();

  @override
  Future<void> clear() async {
    for (final key
        in _prefs.getKeys().where((k) => k.startsWith('bench_')).toList()) {
      await _prefs.remove(key);
    }
  }

  @override
  Future<void> write(String key, Object value) => switch (value) {
    int v => _prefs.setInt('bench_$key', v),
    double v => _prefs.setDouble('bench_$key', v),
    String v => _prefs.setString('bench_$key', v),
    // Maps are not supported: store them as JSON text, as apps do.
    _ => _prefs.setString('bench_$key', jsonEncode(value)),
  };
  @override
  Future<Object?> read(String key) async =>
      decodeIfJson(_prefs.get('bench_$key'));
  @override
  Future<void> delete(String key) => _prefs.remove('bench_$key');
}
