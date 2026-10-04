import 'dart:convert';

/// Prefix of every container, box, database and key name the benchmark
/// uses. The memory benchmark's child processes use their own, so they never
/// open files (or file locks, like Hive's) that the app itself still has
/// open from a timing run.
String storagePrefix = 'bench';

/// A database file name under [storagePrefix]; the timing run keeps its
/// original name.
String benchFileName(String name) =>
    storagePrefix == 'bench' ? name : '${storagePrefix}_$name';

/// One storage under test. Values are ints, doubles, strings or JSON maps;
/// every call is awaited one by one, the way app code usually uses these APIs.
abstract class StorageAdapter {
  /// Full name, e.g. `OrcaSecureStorage`.
  String get name;

  /// Short label under the chart bars.
  String get label;

  /// Package, e.g. `orca_secure_storage 2.2.1`.
  String get package;

  /// `none`, or the cipher / mechanism used.
  String get encryption;

  bool get encrypted => encryption != 'none';

  /// Why the storage cannot run on this platform, or null when it can.
  String? get unsupportedReason => null;

  /// Opens the storage. Not timed.
  Future<void> open();

  /// Removes everything this benchmark wrote. Not timed.
  Future<void> clear();

  Future<void> write(String key, Object value);
  Future<Object?> read(String key);
  Future<void> delete(String key);

  /// Completes when every change so far is on disk. Storages whose futures
  /// already mean "persisted" do nothing here.
  Future<void> flush() async {}

  /// Stops pending background writes after a timeout, so they do not slow
  /// down the storages measured next.
  Future<void> abort() async {}

  /// Opens the stored data again from disk, as on an app start: a new
  /// instance on a copy of the file, or close and reopen. Timed, together
  /// with reading every key through [readCold].
  Future<void> openCold();

  Future<Object?> readCold(String key) => read(key);

  /// Releases what [openCold] created. Not timed.
  Future<void> closeCold() async {}
}

/// For get_storage-style boxes: `write()` returns before the file is written;
/// the box's queue runs flushes in order, so a job queued behind them
/// completes once they are done.
Future<void> waitForQueue(dynamic queue) async {
  await Future<void>.delayed(Duration.zero);
  await queue.add<void>(() async {});
}

/// For storages that keep maps as JSON text: decodes them on read, as an app
/// would. (Benchmark strings never start with `{`.)
Object? decodeIfJson(Object? value) =>
    value is String && value.startsWith('{') ? jsonDecode(value) : value;

/// The matching encode: maps and lists become JSON text.
Object encodeIfJson(Object value) =>
    value is Map || value is List ? jsonEncode(value) : value;
