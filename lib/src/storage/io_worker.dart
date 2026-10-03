import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../codec.dart';

// One long-lived isolate per container. It owns the files and a cache of each
// top-level value's JSON, so a write only sends the changed keys' JSON from
// the UI isolate.
//
// Files:
//   <c>.oss      snapshot of the whole container
//   <c>.ossbak   the same bytes, as a backup
//   <c>.osslog   changes made since the snapshot
//
// An update appends one record to the log and fsyncs it before replying, so
// it is as durable as a full rewrite but costs a small write. When writes go
// quiet ([_idleDelay]), the log outgrows the snapshot, the container is
// erased, or the app goes to the background, the worker writes a new
// snapshot and backup (temp file, fsync, rename) and starts an empty log.
//
// Crash safety:
// - A record cut short by a crash fails its length or integrity check; it
//   and anything after it are not applied (the log is kept aside first).
// - The log names the snapshot it belongs to (its fingerprint). A crash
//   after a new snapshot but before the log was reset leaves a log for the
//   previous snapshot; its changes are already in the new one, so it is not
//   applied again.
// - If the snapshot is unreadable, the backup is used with the log that
//   belongs to it.
// - Nothing is deleted on a failure: unreadable snapshots and logs are copied
//   to `.rejected` files (up to five each) before the container starts over.

/// Where an unreadable file at [path] is kept: `<path>.rejected`, then
/// `<path>.rejected.2` up to `.rejected.5`.
List<String> rejectedPaths(String path) =>
    ['$path.rejected', for (var i = 2; i <= 5; i++) '$path.rejected.$i'];

/// Writes go to the log until there has been no write for this long.
const _idleDelay = Duration(milliseconds: 300);

/// The log is folded into a new snapshot once it is larger than the
/// snapshot (and at least this big), which bounds disk use and replay time.
const _minLogBytesBeforeCompaction = 64 * 1024;

class WorkerInit {
  WorkerInit(this.replyTo, this.mainPath, this.backupPath, this.logPath, this.legacyPaths,
      this.config);
  final SendPort replyTo;
  final String mainPath;
  final String backupPath;
  final String logPath;

  /// 1.x main/backup file pairs (`.gs`, `.bak`), tried in order when there
  /// is no current file yet.
  final List<String> legacyPaths;
  final StorageCodecConfig config;
}

/// First message from the worker.
class WorkerReady {
  WorkerReady(this.port, this.hasData, this.warnings);
  final SendPort port;

  /// Whether a stored container was found. Its contents follow as a
  /// [LoadedData] message; false when there is no file yet.
  final bool hasData;
  final List<String> warnings;
}

/// The stored container, decoded. Sent with `Isolate.exit` by a short-lived
/// helper isolate, so the UI isolate receives the objects without copying
/// them and without decoding on its own thread.
class LoadedData {
  LoadedData(this.data);
  final Map<String, dynamic> data;
}

class _DecodeJob {
  _DecodeJob(this.replyTo, this.text);
  final SendPort replyTo;
  final String text;
}

void _decodeForUi(_DecodeJob job) =>
    Isolate.exit(job.replyTo, LoadedData(json.decode(job.text) as Map<String, dynamic>));

class FlushRequest {
  FlushRequest(this.id, this.reset, this.changes);
  final int id;

  /// Drop every cached key before applying [changes] (erase / full resync).
  final bool reset;

  /// Key -> encoded JSON value, or null for a removed key.
  final Map<String, String?> changes;
}

/// Write a new snapshot now if the log has changes (app going to the
/// background). Answered with a [FlushReply].
class CompactRequest {
  CompactRequest(this.id);
  final int id;
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
  String? text;
  try {
    text = await worker.load(warnings);
  } catch (e) {
    warnings.add('Could not load ${init.mainPath}: $e');
    text = '{}';
  }
  init.replyTo.send(WorkerReady(port.sendPort, text != null, warnings));
  if (text != null) {
    // The worker itself only keeps each key's JSON text; a helper decodes
    // the document and hands the objects to the UI isolate.
    await Isolate.spawn(_decodeForUi, _DecodeJob(init.replyTo, text),
        onError: init.replyTo, debugName: 'OrcaSecureStorage:decode');
    text = null;
  }
  // Fold a replayed log into a new snapshot after replying, so opening the
  // container does not wait for it. Requests run after it (serialised).
  await worker.serial(worker.afterLoad);

  port.listen((msg) {
    final int id;
    final Future<void> Function() job;
    if (msg is FlushRequest) {
      id = msg.id;
      job = () => worker.flush(msg);
    } else if (msg is CompactRequest) {
      id = msg.id;
      job = worker.compactIfNeeded;
    } else {
      return;
    }
    worker.serial(job).then(
          (_) => init.replyTo.send(FlushReply(id, null)),
          onError: (Object e) => init.replyTo.send(FlushReply(id, '$e')),
        );
  });
}

class _Worker {
  _Worker(this.init)
      : _codec = StorageCodec(
          init.config,
          // Level 1: ~7x smaller for typical JSON at a fraction of the cost
          // of higher levels.
          compress: GZipCodec(level: 1).encoder,
          decompress: gzip.decode,
        );
  final WorkerInit init;
  final StorageCodec _codec;
  final Map<String, String> _cache = <String, String>{};

  // The open log and the snapshot it belongs to.
  RandomAccessFile? _log;
  Uint8List? _fingerprint;
  int _seq = 0;
  int _logBytes = 0;
  int _snapshotBytes = 0;
  Timer? _idle;
  bool _compactAfterLoad = false;

  // Every file operation runs through here, one at a time: appends, idle
  // compaction and background compaction never interleave.
  Future<void> _chain = Future<void>.value();

  Future<T> serial<T>(Future<T> Function() job) {
    final result = _chain.then((_) => job());
    _chain = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  // ---- Loading ------------------------------------------------------------

  /// Reads the container into the per-key cache and returns its JSON text
  /// for the UI isolate, or null when there is no file yet.
  Future<String?> load(List<String> warnings) async {
    final main = File(init.mainPath);
    final backup = File(init.backupPath);
    final hasMain = _hasData(main);
    final hasBackup = _hasData(backup);
    if (!hasMain && !hasBackup) {
      _keepLogAside(warnings, 'no snapshot was found');
      return _convertLegacy(warnings);
    }

    if (hasMain) {
      try {
        final snapshot = await _readSnapshot(main);
        final replay = await _replayLog(snapshot, warnings, fromBackup: false);
        _cache
          ..clear()
          ..addAll(snapshot.values);
        if (snapshot.needsRewrite) {
          // Old format or different encryption (e.g. password -> key):
          // convert before init() returns, so the next start can rely on it.
          await _compact();
        } else if (replay) {
          // Snapshot + log on disk are complete and durable; fold the log
          // into a new snapshot right after replying (afterLoad).
          _compactAfterLoad = true;
        } else {
          await _resetLog(snapshot.fingerprint, snapshot.length);
        }
        return replay ? assembleDocument(_cache) : snapshot.text;
      } catch (e) {
        warnings.add('Corrupted box, recovering backup file ($e)');
      }
    }

    _cache.clear();
    try {
      final snapshot = await _readSnapshot(backup);
      await _replayLog(snapshot, warnings, fromBackup: true);
      _cache.addAll(snapshot.values);
    } catch (e) {
      // Nothing usable. Keep the files aside instead of destroying them, then
      // start empty like get_storage does.
      warnings.add('Can not recover Corrupted box ($e)');
      if (hasMain) {
        final kept = _keepAside(main, warnings);
        warnings.add('Previous file kept as $kept');
      }
      _keepLogAside(warnings, 'the snapshot could not be read');
    }
    await _compact();
    return assembleDocument(_cache);
  }

  static bool _hasData(File file) => file.existsSync() && file.lengthSync() > 0;

  /// Reads the first readable 1.x file pair and writes it in the current
  /// format. The 1.x files are left as they are. Returns null when there is
  /// nothing to convert.
  Future<String?> _convertLegacy(List<String> warnings) async {
    final paths = init.legacyPaths;
    for (var i = 0; i + 1 < paths.length; i += 2) {
      for (final file in [File(paths[i]), File(paths[i + 1])]) {
        if (!_hasData(file)) continue;
        try {
          final snapshot = await _readSnapshot(file);
          _cache
            ..clear()
            ..addAll(snapshot.values);
          await _compact();
          warnings.add('Converted ${file.path} to ${init.mainPath}');
          return snapshot.text;
        } catch (e) {
          warnings.add('Could not read ${file.path}, left untouched ($e)');
        }
      }
    }
    return null;
  }

  Future<_Snapshot> _readSnapshot(File file) async {
    final bytes = await file.readAsBytes();
    final doc = await _codec.decode(bytes);
    final text = doc.plaintext;
    final Map<String, String> values;
    if (doc.needsRewrite) {
      // 1.x or get_storage files are not integrity-checked like the current
      // format: parse them fully, once, so malformed JSON is refused here.
      final decoded = json.decode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('container is not a JSON object');
      }
      values = {for (final e in decoded.entries) e.key: json.encode(e.value)};
    } else {
      values = splitDocument(text);
    }
    return _Snapshot(text, values, doc.needsRewrite, await StorageCodec.fingerprintOf(bytes),
        bytes.length);
  }

  /// Applies the log's changes to [snapshot].data. Returns whether the files
  /// should be rewritten now (changes were applied, or the log is stale or
  /// damaged and must be replaced).
  Future<bool> _replayLog(_Snapshot snapshot, List<String> warnings,
      {required bool fromBackup}) async {
    final file = File(init.logPath);
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    final logFingerprint = _codec.readLogHeader(bytes);
    if (logFingerprint == null) {
      _keepLogAside(warnings, 'its header is not valid');
      return true;
    }
    if (!_sameBytes(logFingerprint, snapshot.fingerprint)) {
      if (fromBackup) {
        // Belongs to a newer snapshot that could not be read: its changes
        // cannot be applied to the backup safely.
        _keepLogAside(warnings, 'it belongs to a snapshot that could not be read');
      }
      // Otherwise it is from before the snapshot, which already contains it.
      return true;
    }

    var offset = StorageCodec.logHeaderLength;
    var seq = 0;
    while (offset + 4 <= bytes.length) {
      final length = (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      if (offset + 4 + length > bytes.length) break; // torn last record
      final body = Uint8List.sublistView(bytes, offset + 4, offset + 4 + length);
      final payload = await _codec.decodeLogRecord(body, snapshot.fingerprint, seq);
      if (payload == null || !_apply(snapshot.values, payload)) break;
      offset += 4 + length;
      seq++;
    }
    if (offset < bytes.length) {
      _keepLogAside(warnings,
          '${bytes.length - offset} bytes at its end are incomplete or damaged; $seq changes were applied');
      return true;
    }
    return seq > 0;
  }

  /// Applies one record's payload; false if it is not a valid change.
  static bool _apply(Map<String, String> values, String payload) {
    try {
      final change = json.decode(payload);
      if (change is! Map) return false;
      if (change['r'] == true) values.clear();
      final set = change['s'];
      if (set is Map) {
        set.forEach((k, v) => values[k as String] = json.encode(v));
      }
      final del = change['d'];
      if (del is List) {
        for (final k in del) {
          values.remove(k);
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Copies the log to `.osslog.rejected` before it is replaced.
  void _keepLogAside(List<String> warnings, String reason) {
    final file = File(init.logPath);
    if (!file.existsSync() || file.lengthSync() == 0) return;
    final kept = _keepAside(file, warnings);
    warnings.add('Change log not fully used ($reason); kept as $kept');
  }

  /// Copies [file] to the first free name of [rejectedPaths], so earlier
  /// copies are not overwritten; when all are taken, replaces the oldest.
  String _keepAside(File file, List<String> warnings) {
    final paths = rejectedPaths(file.path);
    var target = paths.firstWhere(
      (p) => !File(p).existsSync(),
      orElse: () => '',
    );
    if (target.isEmpty) {
      target = paths.reduce((a, b) =>
          File(a).lastModifiedSync().isBefore(File(b).lastModifiedSync())
              ? a
              : b);
      warnings.add('$target replaced: at most ${paths.length} rejected '
          'copies are kept');
    }
    file.copySync(target);
    // Copies may keep the source's time; the oldest copy is found by it.
    File(target).setLastModifiedSync(DateTime.now());
    return target;
  }

  /// Finishes what [load] deferred. Runs right after the data was handed to
  /// the UI isolate, before any other request.
  Future<void> afterLoad() async {
    if (_compactAfterLoad) {
      _compactAfterLoad = false;
      await _compact();
    }
  }

  // ---- Writing ------------------------------------------------------------

  Future<void> flush(FlushRequest req) async {
    if (req.reset) _cache.clear();
    final set = <String, String>{};
    final del = <String>[];
    req.changes.forEach((key, value) {
      if (value == null) {
        _cache.remove(key);
        del.add(key);
      } else {
        _cache[key] = value;
        set[key] = value;
      }
    });

    final log = _log;
    final fingerprint = _fingerprint;
    if (req.reset || log == null || fingerprint == null) {
      await _compact();
      return;
    }
    // A record this large would be folded into a snapshot right after it is
    // written (it is at least as many bytes as its text has characters), so
    // write the snapshot straight away: just as durable, and the record is
    // never built.
    var size = _logBytes;
    set.forEach((k, v) => size += k.length + v.length);
    for (final k in del) {
      size += k.length;
    }
    if (size > max(_minLogBytesBeforeCompaction, _snapshotBytes)) {
      await _compact();
      return;
    }

    final record = await _codec.encodeLogRecord(_payload(set, del), fingerprint, _seq);
    try {
      await log.writeFrom(record);
      await log.flush(); // fsync: durable before the write is acknowledged
    } catch (_) {
      // The log may now end in a partial record. Don't append after it:
      // write everything as a new snapshot instead.
      _closeLog();
      await _compact();
      return;
    }
    _seq++;
    _logBytes += record.length;

    if (_logBytes > max(_minLogBytesBeforeCompaction, _snapshotBytes)) {
      await _compact();
    } else {
      _idle?.cancel();
      _idle = Timer(_idleDelay, () => serial(compactIfNeeded).ignore());
    }
  }

  /// `{"r":false,"s":{"key":<json>},"d":["key"]}`, with values embedded as the
  /// JSON text the UI isolate already encoded.
  static String _payload(Map<String, String> set, List<String> del) {
    final sb = StringBuffer('{"r":false,"s":{');
    var first = true;
    set.forEach((k, v) {
      if (!first) sb.write(',');
      first = false;
      sb
        ..write(json.encode(k))
        ..write(':')
        ..write(v);
    });
    sb
      ..write('},"d":')
      ..write(json.encode(del))
      ..write('}');
    return sb.toString();
  }

  Future<void> compactIfNeeded() async {
    if (_seq > 0 || _log == null) await _compact();
  }

  /// Writes the whole container as a new snapshot and backup, then starts an
  /// empty log for it. Each file is replaced atomically.
  Future<void> _compact() async {
    _idle?.cancel();
    final bytes = await _codec.encodeDocument(_cache);
    await _atomicWrite(init.mainPath, bytes);
    await _atomicWrite(init.backupPath, bytes);
    await _resetLog(await StorageCodec.fingerprintOf(bytes), bytes.length);
  }

  Future<void> _resetLog(Uint8List fingerprint, int snapshotBytes) async {
    _closeLog();
    await _atomicWrite(init.logPath, _codec.logHeader(fingerprint));
    _log = await File(init.logPath).open(mode: FileMode.append);
    _fingerprint = fingerprint;
    _seq = 0;
    _logBytes = 0;
    _snapshotBytes = snapshotBytes;
  }

  void _closeLog() {
    final log = _log;
    _log = null;
    _fingerprint = null;
    log?.closeSync();
  }

  /// Write to a temp file, fsync, then rename over the target, so a crash
  /// leaves either the old or the new file, never a torn one.
  static Future<void> _atomicWrite(String path, List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Snapshot {
  _Snapshot(this.text, this.values, this.needsRewrite, this.fingerprint, this.length);

  /// The document as stored, and each top-level key's JSON text.
  final String text;
  final Map<String, String> values;
  final bool needsRewrite;
  final Uint8List fingerprint;
  final int length;
}
