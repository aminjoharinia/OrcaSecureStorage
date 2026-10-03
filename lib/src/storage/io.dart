import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:get/get.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../codec.dart';
import 'io_worker.dart';

class StorageImpl {
  StorageImpl(this.fileName, [this.path]);

  final String? path;
  final String fileName;

  final ValueStorage<Map<String, dynamic>> subject =
      ValueStorage<Map<String, dynamic>>(<String, dynamic>{});

  //^ Only keys changed since the last flush are re-encoded on this (UI)
  //^ isolate; the worker keeps every other key's JSON and does the joining,
  //^ encryption and file I/O. Encoding the whole container here cost
  //^ ~100 ms per write at 15 MB.
  final Set<String> _dirty = <String>{};
  bool _cleared = false;
  bool _fullResync = false;

  SendPort? _worker;
  // Kept for the container's lifetime; it compacts when the app is hidden.
  // ignore: unused_field
  AppLifecycleListener? _lifecycle;
  RawReceivePort? _replies;
  final Map<int, Completer<void>> _pending = {};
  int _nextId = 0;

  void clear() {
    subject
      ..value!.clear()
      ..changeValue("", null);
    _dirty.clear();
    _cleared = true;
  }

  /// Re-encode every key on the next flush, catching values that were
  /// mutated in place without a `write`.
  void markAllDirty() => _fullResync = true;

  Future<void> deleteBox() => _deleteFile();

  Future<void> flush() async {
    final reset = _fullResync || _cleared;
    if (!reset && _dirty.isEmpty) return;
    final data = subject.value!;
    final keys = _fullResync ? data.keys : _dirty;
    final changes = <String, String?>{
      for (final key in keys)
        key: data.containsKey(key) ? json.encode(data[key]) : null,
    };
    _fullResync = false;
    _cleared = false;
    _dirty.clear();

    final id = _nextId++;
    final done = Completer<void>();
    _pending[id] = done;
    _worker!.send(FlushRequest(id, reset, changes));
    try {
      await done.future;
    } catch (_) {
      // Which of these changes reached the file is unknown: send every key
      // again with the next flush.
      _fullResync = true;
      rethrow;
    }
  }

  T? read<T>(String key) {
    return subject.value![key] as T?;
  }

  T getKeys<T>() {
    return subject.value!.keys as T;
  }

  T getValues<T>() {
    return subject.value!.values as T;
  }

  Future<void> init(
      Map<String, dynamic>? initialData, StorageCodecConfig config) async {
    subject.value = initialData ?? <String, dynamic>{};
    final dir = await _dir();
    final main = _file(dir, '.oss');
    final backup = _file(dir, '.ossbak');
    final log = _file(dir, '.osslog');
    main.parent.createSync(recursive: true);

    final ready = Completer<WorkerReady>();
    _replies = RawReceivePort((dynamic msg) {
      if (msg is WorkerReady) {
        ready.complete(msg);
      } else if (msg is FlushReply) {
        final done = _pending.remove(msg.id);
        if (msg.error == null) {
          done?.complete();
        } else {
          done?.completeError(Exception(msg.error));
        }
      } else if (msg is List) {
        // Uncaught worker error: [error, stack].
        final error = Exception('OrcaSecureStorage worker failed: ${msg.first}');
        if (!ready.isCompleted) ready.completeError(error);
        for (final done in _pending.values) {
          done.completeError(error);
        }
        _pending.clear();
      }
    });
    _replies!.keepIsolateAlive = false;

    await Isolate.spawn(
      storageWorkerMain,
      WorkerInit(_replies!.sendPort, main.path, backup.path, log.path,
          [for (final f in _legacyFiles(dir)) f.path], config),
      onError: _replies!.sendPort,
      debugName: 'OrcaSecureStorage:$fileName',
    );
    final result = await ready.future;
    _worker = result.port;
    for (final warning in result.warnings) {
      Get.log(warning, isError: true);
    }

    _watchLifecycle();

    if (result.data == null) {
      _fullResync = true;
      await flush();
    } else {
      subject.value = result.data;
    }
  }

  //^ Writes go to a change log until the app is idle; when it leaves the
  //^ foreground, fold the log into the snapshot right away. The log is
  //^ already durable, this only keeps it short.
  void _watchLifecycle() {
    try {
      _lifecycle = AppLifecycleListener(
        onHide: _compactNow,
        onPause: _compactNow,
        onDetach: _compactNow,
      );
    } catch (_) {
      // No Flutter binding (e.g. plain Dart): the idle timer still compacts.
    }
  }

  void _compactNow() {
    final worker = _worker;
    if (worker == null) return;
    final id = _nextId++;
    final done = Completer<void>();
    _pending[id] = done;
    done.future.catchError((Object e) => Get.log('$e', isError: true));
    worker.send(CompactRequest(id));
  }

  void remove(String key) {
    subject
      ..value!.remove(key)
      ..changeValue(key, null);
    _dirty.add(key);
  }

  void write(String key, dynamic value) {
    subject
      ..value![key] = value
      ..changeValue(key, value);
    _dirty.add(key);
  }

  // Current files: <container>.oss, .ossbak and .osslog. Files written by
  // 1.x (and get_storage) are <container>.gs and <container>.bak; they are
  // converted once and then left alone.
  List<File> _currentFiles(String dir) =>
      [_file(dir, '.oss'), _file(dir, '.ossbak'), _file(dir, '.osslog')];

  /// Copies kept aside after a failed open (see [rejectedPaths]).
  List<File> _rejectedFiles(String dir) => [
        for (final ext in ['.oss', '.osslog'])
          for (final path in rejectedPaths(_file(dir, ext).path)) File(path),
      ];

  /// Legacy main/backup pairs, in the order they are tried.
  List<File> _legacyFiles(String dir) => [
        _file(dir, '.gs'),
        _file(dir, '.bak'),
        if (fileName == OrcaSecureStorage.defaultContainer) ...[
          _file(dir, '.gs', OrcaSecureStorage.legacyDefaultContainer),
          _file(dir, '.bak', OrcaSecureStorage.legacyDefaultContainer),
        ],
      ];

  Future<bool> _hasFile() async {
    final dir = await _dir();
    return [..._currentFiles(dir), ..._legacyFiles(dir)].any((f) => f.existsSync());
  }

  /// Deletes the container's current, legacy and rejected files, so a
  /// deleted container is not converted again from its old files.
  Future<void> _deleteFile() async {
    final dir = await _dir();
    for (final file in [
      ..._currentFiles(dir),
      ..._legacyFiles(dir),
      ..._rejectedFiles(dir),
    ]) {
      if (file.existsSync()) await file.delete();
    }
  }

  Future<String> _dir() async =>
      path ?? (await getApplicationDocumentsDirectory()).path;

  File _file(String dir, String extension, [String? name]) {
    final separator = GetPlatform.isWindows ? '\\' : '/';
    return File('$dir$separator${name ?? fileName}$extension');
  }

  static Future<void> deleteContainer(String container, [String? path]) async {
    final tmp = StorageImpl(container, path);
    await tmp._deleteFile();
  }

  static Future<bool> hasContainer(String container, [String? path]) async {
    final tmp = StorageImpl(container, path);
    return tmp._hasFile();
  }
}
