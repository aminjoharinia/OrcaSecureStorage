import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../codec.dart';

// One long-lived isolate per container. It owns the file and a cache of each
// top-level value's JSON, so a write only sends the changed keys' JSON from
// the UI isolate; joining, compressing, encrypting and writing happen here.

class WorkerInit {
  WorkerInit(this.replyTo, this.mainPath, this.backupPath, this.legacyPaths, this.config);
  final SendPort replyTo;
  final String mainPath;
  final String backupPath;

  /// 1.x main/backup file pairs (`.gs`, `.bak`), tried in order when there
  /// is no current file yet.
  final List<String> legacyPaths;
  final StorageCodecConfig config;
}

/// First message from the worker.
class WorkerReady {
  WorkerReady(this.port, this.data, this.warnings);
  final SendPort port;

  /// The stored container, or null when there is no file yet.
  final Map<String, dynamic>? data;
  final List<String> warnings;
}

class FlushRequest {
  FlushRequest(this.id, this.reset, this.changes);
  final int id;

  /// Drop every cached key before applying [changes] (erase / full resync).
  final bool reset;

  /// Key -> encoded JSON value, or null for a removed key.
  final Map<String, String?> changes;
}

class FlushReply {
  FlushReply(this.id, this.error);
  final int id;
  final String? error;
}

Future<void> storageWorkerMain(WorkerInit init) async {
  final port = ReceivePort();
  final worker = _Worker(init);
  final warnings = <String>[];
  Map<String, dynamic>? data;
  try {
    data = await worker.load(warnings);
  } catch (e) {
    warnings.add('Could not load ${init.mainPath}: $e');
    data = {};
  }
  init.replyTo.send(WorkerReady(port.sendPort, data, warnings));
  // Build the per-key cache after replying, so opening the container does
  // not wait for it. Flush requests queue on the port until this is done.
  worker.fillCache();

  await for (final msg in port) {
    if (msg is FlushRequest) {
      try {
        await worker.flush(msg);
        init.replyTo.send(FlushReply(msg.id, null));
      } catch (e) {
        init.replyTo.send(FlushReply(msg.id, '$e'));
      }
    }
  }
}

class _Worker {
  _Worker(this.init)
      : _codec = StorageCodec(
          init.config,
          // Level 1: ~7x smaller for typical JSON at a fraction of the cost
          // of higher levels.
          compress: GZipCodec(level: 1).encode,
          decompress: gzip.decode,
        );
  final WorkerInit init;
  final StorageCodec _codec;
  final Map<String, String> _cache = <String, String>{};
  Map<String, dynamic>? _loaded;

  Future<Map<String, dynamic>?> load(List<String> warnings) async {
    final main = File(init.mainPath);
    final backup = File(init.backupPath);
    final hasMain = _hasData(main);
    final hasBackup = _hasData(backup);
    if (!hasMain && !hasBackup) return _convertLegacy(warnings);

    if (hasMain) {
      try {
        final (data, needsRewrite) = await _readFile(main);
        _fill(data);
        if (needsRewrite) {
          // A 1.x file (or one whose encryption changed): convert it now.
          fillCache();
          await _write();
        }
        return data;
      } catch (e) {
        warnings.add('Corrupted box, recovering backup file ($e)');
      }
    }
    Map<String, dynamic> data;
    try {
      (data, _) = await _readFile(backup);
      _fill(data);
    } catch (e) {
      // Nothing usable. Keep the main file aside instead of destroying it,
      // then start empty like get_storage does.
      warnings.add('Can not recover Corrupted box ($e)');
      if (hasMain) {
        main.copySync('${init.mainPath}.rejected');
        warnings.add('Previous file kept as ${init.mainPath}.rejected');
      }
      data = _fill({});
    }
    fillCache();
    await _write();
    return data;
  }

  static bool _hasData(File file) => file.existsSync() && file.lengthSync() > 0;

  /// Reads the first readable 1.x file pair and writes it in the current
  /// format. The 1.x files are left as they are. Returns null when there is
  /// nothing to convert.
  Future<Map<String, dynamic>?> _convertLegacy(List<String> warnings) async {
    final paths = init.legacyPaths;
    for (var i = 0; i + 1 < paths.length; i += 2) {
      for (final file in [File(paths[i]), File(paths[i + 1])]) {
        if (!_hasData(file)) continue;
        try {
          final (data, _) = await _readFile(file);
          _fill(data);
          fillCache();
          await _write();
          warnings.add('Converted ${file.path} to ${init.mainPath}');
          return data;
        } catch (e) {
          warnings.add('Could not read ${file.path}, left untouched ($e)');
        }
      }
    }
    return null;
  }

  Future<(Map<String, dynamic>, bool)> _readFile(File file) async {
    final doc = await _codec.decode(await file.readAsBytes());
    final decoded = json.decode(doc.plaintext);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('container is not a JSON object');
    }
    return (decoded, doc.needsRewrite);
  }

  /// Remembers [data]; its per-key JSON is built later by [fillCache].
  Map<String, dynamic> _fill(Map<String, dynamic> data) {
    _cache.clear();
    _loaded = data;
    return data;
  }

  void fillCache() {
    final data = _loaded;
    _loaded = null;
    if (data == null) return;
    _cache.addAll({for (final e in data.entries) e.key: json.encode(e.value)});
  }

  Future<void> flush(FlushRequest req) async {
    if (req.reset) _cache.clear();
    req.changes.forEach((key, value) {
      if (value == null) {
        _cache.remove(key);
      } else {
        _cache[key] = value;
      }
    });
    await _write();
  }

  Future<void> _write() async {
    final bytes = await _codec.encode(assembleDocument(_cache));
    await _atomicWrite(init.mainPath, bytes);
    await _atomicWrite(init.backupPath, bytes);
  }

  /// Write to a temp file, fsync, then rename over the target, so a crash
  /// leaves either the old or the new file, never a torn one.
  static Future<void> _atomicWrite(String path, List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }
}
