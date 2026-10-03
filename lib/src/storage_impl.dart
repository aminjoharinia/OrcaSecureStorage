import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:get/utils.dart';

import 'codec.dart';
import 'sdk/flutter.dart' if (dart.library.ui) 'sdk/dart.dart';
import 'storage/html.dart' if (dart.library.io) 'storage/io.dart';
import 'value.dart';

typedef VoidCallback = void Function();
typedef ValueSetter<T> = void Function(T value);

/// Instantiate OrcaSecureStorage to access storage driver apis
class OrcaSecureStorage {
  static String kNonce = 'nonce';
  static String kMac = 'mac';
  static String kCipherText = 'cipherText';

  /// The container used when none is given.
  static const String defaultContainer = 'OrcaSecureStorage';

  /// The default container's name before the rename. Its files
  /// (`GetSecureStorage.gs`) are converted when [defaultContainer] has none.
  static const String legacyDefaultContainer = 'GetSecureStorage';

  factory OrcaSecureStorage(
      {String container = defaultContainer,
      String? password,
      String? path,
      Map<String, dynamic>? initialData,
      bool migrateUnencrypted = false}) {
    if (_sync.containsKey(container)) {
      return _sync[container]!;
    } else {
      final instance = OrcaSecureStorage._internal(
          container, path, initialData, password, migrateUnencrypted);
      _sync[container] = instance;
      return instance;
    }
  }

  OrcaSecureStorage._internal(String key,
      [String? path,
      Map<String, dynamic>? initialData,
      String? password,
      bool migrateUnencrypted = false]) {
    _concrete = StorageImpl(key, path);
    _initialData = initialData;

    // _privatekey = privatekey;
    initStorage = Future<bool>(() async {
      if (password != null) {
        // The 1.x key, kept so 1.x files can be read and converted. Current
        // files use AES-256-GCM with a key derived in the background isolate.
        algorithm = AesCtr.with128bits(macAlgorithm: Hmac.sha256());
        final pbkdf2 = Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: 1000, // 1000 iterations
          bits: 128, // 256 bits = 32 bytes output
        );
        secretKey = await pbkdf2.deriveKeyFromPassword(
          password: password,
          nonce: password.runes.toList().reversed.toList(),
        );
      }
      await _init(StorageCodecConfig(
        password: password,
        legacyKeyBytes: await secretKey?.extractBytes(),
        migrateUnencrypted: migrateUnencrypted,
        nonceField: kNonce,
        macField: kMac,
        cipherTextField: kCipherText,
      ));
      return true;
    });
  }

  static final Map<String, OrcaSecureStorage> _sync = {};

  final microtask = Microtask();

  /// Start the storage drive. It's important to use await before calling this API, or side effects will occur.
  ///
  /// Files from 1.x are detected and rewritten in the current format when
  /// opened. With a [password], a file that is not encrypted is rejected
  /// (kept aside as `<container>.gs.rejected`) unless [migrateUnencrypted] is
  /// true, in which case it is loaded and encrypted.
  static Future<bool> init(
      {String container = defaultContainer,
      String? password,
      bool migrateUnencrypted = false}) {
    initImpl();
    return OrcaSecureStorage(
            container: container,
            password: password,
            migrateUnencrypted: migrateUnencrypted)
        .initStorage;
  }

  static Future<bool> hasContainer(String container, [String? path]) =>
      StorageImpl.hasContainer(container, path);

  static deleteContainer(String container, [String? path]) =>
      StorageImpl.deleteContainer(container, path);

  Future<void> _init(StorageCodecConfig config) async {
    await _concrete.init(_initialData, config);
  }

  /// Reads a value in your container with the given key.
  T? read<T>(String key) {
    return _concrete.read(key);
  }

  T getKeys<T>() {
    return _concrete.getKeys();
  }

  T getValues<T>() {
    return _concrete.getValues();
  }

  /// return data true if value is different of null;
  bool hasData(String key) {
    return (read(key) == null ? false : true);
  }

  Map<String, dynamic> get changes => _concrete.subject.changes;

  /// Listen changes in your container
  VoidCallback listen(VoidCallback value) {
    return _concrete.subject.addListener(value);
  }

  final Map<Function, Function> _keyListeners = <Function, Function>{};

  VoidCallback listenKey(String key, ValueSetter callback) {
    listen() {
      if (changes.keys.first == key) {
        callback(changes[key]);
      }
    }

    _keyListeners[callback] = listen;
    return _concrete.subject.addListener(listen);
  }

  /// Write data on your container
  Future<void> write(String key, dynamic value) async {
    writeInMemory(key, value);
    return _tryFlush();
  }

  void writeInMemory(String key, dynamic value) {
    _concrete.write(key, value);
  }

  /// Write data on your only if data is null
  Future<void> writeIfNull(String key, dynamic value) async {
    if (read(key) != null) return;
    return write(key, value);
  }

  /// remove data from container by key
  Future<void> remove(String key) async {
    _concrete.remove(key);
    return _tryFlush();
  }

  /// clear all data on your container
  Future<void> erase() async {
    _concrete.clear();
    return _tryFlush();
  }

  /// Persists the container. Unlike [write], this re-encodes every key, so
  /// values changed in place (without a `write`) are saved too.
  Future<void> save() async {
    _concrete.markAllDirty();
    return _tryFlush();
  }

  Future<void> _tryFlush() async {
    return microtask.exec(_addToQueue);
  }

  Future _addToQueue() {
    return queue.add(_flush);
  }

  Future<void> _flush() async {
    try {
      await _concrete.flush();
    } catch (e) {
      rethrow;
    }
    return;
  }

  late StorageImpl _concrete;

  GetQueue queue = GetQueue();

  /// listenable of container
  ValueStorage<Map<String, dynamic>> get listenable => _concrete.subject;

  /// Start the storage drive. Important: use await before calling this api, or side effects will happen.
  late Future<bool> initStorage;
  Map<String, dynamic>? _initialData;
  /// The 1.x cipher and key, only used to read 1.x files.
  @Deprecated('Only used to read 1.x files; storage now uses AES-256-GCM.')
  AesCtr? algorithm;
  @Deprecated('Only used to read 1.x files; storage now uses AES-256-GCM.')
  SecretKey? secretKey;
}

class Microtask {
  int _version = 0;
  int _microtask = 0;

  void exec(Function callback) {
    if (_microtask == _version) {
      _microtask++;
      scheduleMicrotask(() {
        _version++;
        _microtask = _version;
        callback();
      });
    }
  }
}

typedef KeyCallback = Function(String);
typedef StringCallback = Future<String> Function(String input);
