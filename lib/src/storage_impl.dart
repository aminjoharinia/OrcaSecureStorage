import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:get/utils.dart';
import 'package:webcrypto/webcrypto.dart' show fillRandomBytes;

import 'codec.dart';
import 'durability.dart';
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

  /// A new random 256-bit key for [encryptionKey]. Generate it once and keep
  /// it in secure platform storage (Keychain, Android Keystore, ...).
  static Uint8List generateKey() {
    final key = Uint8List(32);
    fillRandomBytes(key);
    return key;
  }

  factory OrcaSecureStorage(
      {String container = defaultContainer,
      String? password,
      List<int>? encryptionKey,
      String? path,
      Map<String, dynamic>? initialData,
      bool migrateUnencrypted = false,
      Durability? durability}) {
    if (encryptionKey != null && encryptionKey.length != 32) {
      throw ArgumentError.value(
          encryptionKey.length, 'encryptionKey', 'must be 32 bytes (AES-256)');
    }
    if (_sync[container] case final open?) {
      // `OrcaSecureStorage()` without arguments returns the open container;
      // different arguments would be silently ignored, so they throw.
      final conflict = [
        if (password != null && password != open._password) 'password',
        if (encryptionKey != null && !_sameBytes(encryptionKey, open._key))
          'encryptionKey',
        if (path != null && path != open._path) 'path',
        if (migrateUnencrypted && !open._migrateUnencrypted)
          'migrateUnencrypted',
        if (durability != null && durability != open._durability) 'durability',
      ];
      if (conflict.isNotEmpty) {
        throw StateError('Container "$container" is already open with a '
            'different ${conflict.join(', ')}. Use the same arguments, or '
            'none to get the open container.');
      }
      return open;
    }
    final instance = OrcaSecureStorage._internal(container, path, initialData,
        password, migrateUnencrypted, encryptionKey, durability ?? Durability.fsync);
    _sync[container] = instance;
    return instance;
  }

  static bool _sameBytes(List<int> a, List<int>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  OrcaSecureStorage._internal(String key,
      [String? path,
      Map<String, dynamic>? initialData,
      String? password,
      bool migrateUnencrypted = false,
      List<int>? encryptionKey,
      Durability durability = Durability.fsync])
      : _password = password,
        _durability = durability,
        _key = encryptionKey == null ? null : List<int>.of(encryptionKey),
        _path = path,
        _migrateUnencrypted = migrateUnencrypted {
    _concrete = StorageImpl(key, path);
    _initialData = initialData;

    initStorage = Future<bool>(() async {
      // The 1.x key is derived from the password by the codec, in the
      // background isolate, and only when a 1.x file is actually read.
      await _init(StorageCodecConfig(
        password: password,
        keyBytes: encryptionKey == null ? null : List<int>.of(encryptionKey),
        migrateUnencrypted: migrateUnencrypted,
        nonceField: kNonce,
        macField: kMac,
        cipherTextField: kCipherText,
      ));
      return true;
    });
  }

  static final Map<String, OrcaSecureStorage> _sync = {};

  // The arguments the container was opened with.
  final String? _password;
  final List<int>? _key;
  final String? _path;
  final bool _migrateUnencrypted;
  final Durability _durability;

  /// No longer used; await [flush] to wait for saves.
  @Deprecated('Not used by OrcaSecureStorage any more.')
  final microtask = Microtask();

  /// Start the storage drive. It's important to use await before calling this API, or side effects will occur.
  ///
  /// Encryption: pass a [password] (the key is derived with PBKDF2, 600,000
  /// iterations, ~40 ms per container when opening), or an [encryptionKey]
  /// of 32 random bytes you keep in secure platform storage (no derivation,
  /// fast to open; see [generateKey]). Pass both to convert password-protected
  /// files, including 1.x files, to the key. If 1.x files may still turn up
  /// (an app released with get_secure_storage 1.x), keep passing both.
  ///
  /// Files from 1.x are detected and rewritten in the current format when
  /// opened. When encrypted, a file that is not encrypted is rejected
  /// (kept aside as `<container>.oss.rejected`) unless [migrateUnencrypted] is
  /// true, in which case it is loaded and encrypted.
  ///
  /// [durability] (files only) decides whether saves are fsynced before they
  /// count as saved: [Durability.fsync] (the default) or [Durability.os].
  static Future<bool> init(
      {String container = defaultContainer,
      String? password,
      List<int>? encryptionKey,
      bool migrateUnencrypted = false,
      Durability? durability}) {
    initImpl();
    return OrcaSecureStorage(
            container: container,
            password: password,
            encryptionKey: encryptionKey,
            migrateUnencrypted: migrateUnencrypted,
            durability: durability)
        .initStorage;
  }

  static Future<bool> hasContainer(String container, [String? path]) =>
      StorageImpl.hasContainer(container, path);

  static Future<void> deleteContainer(String container, [String? path]) =>
      StorageImpl.deleteContainer(container, path);

  Future<void> _init(StorageCodecConfig config) async {
    await _concrete.init(_initialData, config, _durability);
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

  /// Writes [value] under [key]. The value is readable at once; it is saved
  /// in the background, together with other writes made in the same
  /// event-loop turn. The returned future does not wait for the save: await
  /// [flush] for that, and to see save errors.
  ///
  /// The value is converted to JSON here (objects through their `toJson`),
  /// and saved as it is now; after changing it in place, call [save]. A value
  /// that cannot be converted throws a [JsonUnsupportedObjectError] right
  /// away and nothing is stored.
  Future<void> write(String key, dynamic value) {
    writeInMemory(key, value);
    return _tryFlush();
  }

  /// Like [write], without saving. Throws the same way for a value that
  /// cannot be converted to JSON.
  void writeInMemory(String key, dynamic value) {
    _concrete.write(key, value);
  }

  /// Write data on your only if data is null
  Future<void> writeIfNull(String key, dynamic value) {
    if (read(key) != null) return Future<void>.value();
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

  /// Completes when every change made so far is saved (for files: fsynced,
  /// unless opened with [Durability.os]; on the web: stored right away
  /// instead of after the usual short delay). Saves anything not saved yet,
  /// including changes whose save failed earlier. Throws if saving fails;
  /// the changes stay in memory and are tried again with the next write or
  /// [flush].
  Future<void> flush() async {
    // Errors from earlier saves are superseded by this attempt.
    _saveError = null;
    _concrete.saveNow();
    // Schedule a save even if one looks pending: `queue.cancelAllJobs()` can
    // drop a queued save without clearing the flag.
    _saveScheduled = false;
    _tryFlush();
    // The save scheduled above joins the queue first.
    await Future<void>.microtask(() {});
    await queue.add(() async {});
    final error = _saveError;
    if (error != null) {
      _saveError = null;
      Error.throwWithStackTrace(error.$1, error.$2);
    }
  }

  bool _saveScheduled = false;
  (Object, StackTrace)? _saveError;

  //^ At most one save waits in [queue] behind the one running: writes made
  //^ before a save starts are all picked up by it, so the flag is cleared
  //^ only when it starts. (Clearing it when the save was queued let each
  //^ awaited write queue its own save; a 10,000-write loop left thousands of
  //^ empty saves that then ran back to back, freezing the UI for ~200 ms.)
  //^ Saves run one at a time; a save never throws into the queue (GetQueue
  //^ only catches Exception, and an Error would stop it for good). Errors
  //^ are logged and kept for [flush].
  Future<void> _tryFlush() async {
    if (_saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() => queue.add(_flush));
  }

  Future<void> _flush() async {
    // Changes made from here on need another save.
    _saveScheduled = false;
    try {
      await _concrete.flush();
    } catch (e, s) {
      Get.log('OrcaSecureStorage: saving failed ($e)', isError: true);
      _saveError ??= (e, s);
    }
  }

  late StorageImpl _concrete;

  GetQueue queue = GetQueue();

  /// listenable of container. Decodes every value not read yet first (on
  /// files, values are decoded when first read), since the map is handed
  /// out as it is.
  ValueStorage<Map<String, dynamic>> get listenable {
    _concrete.decodeAll();
    return _concrete.subject;
  }

  /// Start the storage drive. Important: use await before calling this api, or side effects will happen.
  late Future<bool> initStorage;
  Map<String, dynamic>? _initialData;
  /// No longer set: the 1.x key is derived only when a 1.x file is read.
  @Deprecated('Not set any more; storage uses AES-256-GCM.')
  AesCtr? algorithm;
  @Deprecated('Not set any more; storage uses AES-256-GCM.')
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
