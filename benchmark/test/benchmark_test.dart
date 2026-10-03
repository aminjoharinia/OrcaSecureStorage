// Read/write benchmark on 5, 10 and 15 MB of accounting data:
//   v2            this repo: format 2 (gzip + AES-256-GCM via BoringSSL, raw
//                 binary), background writer isolate, per-key JSON cache
//   fork_v1       the BOOFI copy: 1.x format, encryption via compute()
//   gslender      gslender/get_secure_storage 1.0.5
//   get_storage   jonataslaw/get_storage, unencrypted baseline
// Pick with --dart-define=IMPLS=get_storage,gslender,v2 (the default).
//
//   flutter test test/benchmark_test.dart
//   flutter test test/benchmark_test.dart --dart-define=SIZES=5 --dart-define=RUNS=1
//
// Both secure packages run with a password (encryption on); get_storage has
// no encryption and is the unencrypted baseline.
//
// Metrics, per implementation and size (median over RUNS):
//   write       write() every entry (one coalesced flush) until it reaches disk
//   update      write one entry into the full container until it reaches disk
//               (a typical app write: the whole container is re-serialised
//               and re-encrypted)
//   cold read   open a container from disk (read + decrypt + json decode)
//   max stall   longest time the calling (UI) isolate's event loop was blocked
//   jank        total blocked time beyond a 16.7 ms frame budget
// Stall and jank keep measuring after the call returns until the event loop
// has been quiet for 750 ms, so unawaited work (backup files) is counted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart' as v2;
import 'package:get_secure_storage_fork_v1/get_secure_storage.dart' as fork_v1;
import 'package:get_secure_storage_gslender/get_secure_storage.dart' as gslender;
import 'package:get_storage/get_storage.dart' as gs;

import 'utils/accounting_data.dart';
import 'utils/mock_path_provider.dart';

const _sizesArg = String.fromEnvironment('SIZES', defaultValue: '5,10,15');
const _runs = int.fromEnvironment('RUNS', defaultValue: 3);
const _updates = int.fromEnvironment('UPDATES', defaultValue: 5);
const _password = 'benchmark-password';
const _implsArg = String.fromEnvironment('IMPLS', defaultValue: 'get_storage,gslender,v2');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final sizesMb = _sizesArg.split(',').map((s) => int.parse(s.trim())).toList();
  final available = <StorageUnderTest>[
    GetStorageImpl(),
    GslenderImpl(),
    ForkV1Impl(),
    V2Impl(),
  ];
  final impls = [
    for (final id in _implsArg.split(','))
      available.firstWhere((i) => i.id == id.trim()),
  ];
  final results = <Map<String, Object?>>[];

  setUpAll(() => dir = mockDocumentsDirectory('benchmark'));

  test('warm-up (not recorded)', () async {
    final data = AccountingDataset.generate(256 * 1024);
    for (final impl in impls) {
      await _runOnce(impl, data, dir, 'warmup');
    }
  }, timeout: Timeout.none);

  for (final mb in sizesMb) {
    test('$mb MB', () async {
      final data = AccountingDataset.generate(mb * 1024 * 1024);
      // ignore: avoid_print
      print('\n$mb MB: ${data.journalEntryCount} journal entries, '
          '${_mb(data.jsonBytes)} MB JSON');
      for (final impl in impls) {
        final runs = <RunResult>[];
        for (var r = 0; r < _runs; r++) {
          runs.add(await _runOnce(impl, data, dir, '${mb}mb_r$r'));
        }
        final row = _summarise(impl, mb, data, runs);
        results.add(row);
        // ignore: avoid_print
        print('  ${impl.name.padRight(22)} write ${row['writeMs']} ms, '
            'update ${row['updateMs']} ms, cold read ${row['coldReadMs']} ms, '
            'max stall ${row['writeMaxStallMs']}/${row['updateMaxStallMs']} ms');
      }
    }, timeout: Timeout.none);
  }

  tearDownAll(() => _report(results, sizesMb));
}

// ---------------------------------------------------------------------------

Future<RunResult> _runOnce(
    StorageUnderTest impl, AccountingDataset data, Directory dir, String tag) async {
  final container = '${impl.id}_$tag';
  final res = RunResult();

  // Bulk write.
  await impl.open(container);
  var m = StallMonitor()..start();
  var sw = Stopwatch()..start();
  data.entries.forEach(impl.write);
  await impl.flushed();
  res.writeMs = sw.elapsedMicroseconds / 1000;
  await m.settle();
  res.writeMaxStallMs = m.maxStallMs;
  res.writeJankMs = m.jankMs;

  final file = File('${dir.path}/$container${impl.ext}');
  res.fileBytes = file.lengthSync();
  if (impl.encrypted) {
    expect(latin1.decode(file.readAsBytesSync()).contains('Cash at Bank'), isFalse,
        reason: '${impl.name} wrote plaintext');
  }

  // Single-entry updates on the full container.
  final rnd = Random(7);
  final keys = data.entries.keys.where((k) => k.startsWith('je_')).toList();
  final expected = Map<String, dynamic>.of(data.entries);
  m = StallMonitor()..start();
  for (var i = 0; i < _updates; i++) {
    final key = keys[rnd.nextInt(keys.length)];
    final entry = Map<String, dynamic>.from(data.entries[key] as Map)
      ..['status'] = 'posted'
      ..['approvedBy'] = 'benchmark';
    expected[key] = entry;
    sw = Stopwatch()..start();
    await impl.write(key, entry);
    await impl.flushed();
    res.updateMs.add(sw.elapsedMicroseconds / 1000);
  }
  await m.settle();
  res.updateMaxStallMs = m.maxStallMs;
  res.updateJankMs = m.jankMs;

  // Cold read: a fresh container opened from a copy of the file on disk.
  final coldName = '${container}_cold';
  file.copySync('${dir.path}/$coldName${impl.ext}');
  m = StallMonitor()..start();
  sw = Stopwatch()..start();
  await impl.open(coldName);
  res.coldReadMs = sw.elapsedMicroseconds / 1000;
  await m.settle();
  res.readMaxStallMs = m.maxStallMs;

  // Integrity, outside the timings: every key reads back intact.
  expect(impl.keys().length, expected.length);
  for (final e in expected.entries) {
    expect(json.encode(impl.read(e.key)), json.encode(e.value));
  }

  // Free the in-memory containers (every package keeps instances forever).
  for (final c in [container, coldName]) {
    await impl.open(c);
    impl.erase();
    await impl.flushed();
  }
  for (final f in dir.listSync()) {
    if (f.path.contains(container)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
  return res;
}

class RunResult {
  late double writeMs, writeMaxStallMs, writeJankMs;
  final updateMs = <double>[];
  late double updateMaxStallMs, updateJankMs;
  late double coldReadMs, readMaxStallMs;
  late int fileBytes;
}

/// Measures how long the current isolate's event loop is blocked by ticking a
/// 1 ms periodic timer and recording the gaps between ticks.
class StallMonitor {
  final _sw = Stopwatch();
  Timer? _timer;
  int _last = 0;
  int _lastBigGapAt = 0;
  int _maxGap = 0;
  int _jank = 0;
  static const _frameUs = 16667;

  void start() {
    _sw.start();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = _sw.elapsedMicroseconds;
      final gap = now - _last;
      _last = now;
      if (gap > _maxGap) _maxGap = gap;
      if (gap > _frameUs) {
        _jank += gap - _frameUs;
        _lastBigGapAt = now;
      }
    });
  }

  /// Waits until no frame-sized stall was seen for 750 ms (max 120 s).
  Future<void> settle() async {
    final deadline = _sw.elapsedMicroseconds + 120000000;
    while (_sw.elapsedMicroseconds < deadline) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_sw.elapsedMicroseconds - _lastBigGapAt > 750000) break;
    }
    _timer?.cancel();
  }

  double get maxStallMs => _maxGap / 1000;
  double get jankMs => _jank / 1000;
}

// ---------------------------------------------------------------------------

abstract class StorageUnderTest {
  String get id;

  /// Main file extension.
  String get ext => '.gs';
  String get name;
  bool get encrypted;
  Future<void> open(String container);
  Future<void> write(String key, dynamic value);
  void erase();

  /// Completes once every flush queued so far has hit the disk. `write()` and
  /// `save()` return before that in every package here.
  Future<void> flushed();
  dynamic read(String key);
  Iterable keys();
}

class GetStorageImpl extends StorageUnderTest {
  late gs.GetStorage _box;
  @override
  String get id => 'get_storage';
  @override
  String get name => 'get_storage (no enc.)';
  @override
  bool get encrypted => false;
  @override
  Future<void> open(String c) async {
    await gs.GetStorage.init(c);
    _box = gs.GetStorage(c);
  }

  @override
  void erase() => _box.erase();
  @override
  Future<void> write(String k, v) => _box.write(k, v);
  @override
  Future<void> flushed() => _flushed(_box.queue);
  @override
  dynamic read(String k) => _box.read(k);
  @override
  Iterable keys() => _box.getKeys<Iterable>();
}

class GslenderImpl extends StorageUnderTest {
  late gslender.GetSecureStorage _box;
  @override
  String get id => 'gslender';
  @override
  String get name => 'gslender 1.0.5';
  @override
  bool get encrypted => true;
  @override
  Future<void> open(String c) async {
    await gslender.GetSecureStorage.init(container: c, password: _password);
    _box = gslender.GetSecureStorage(container: c, password: _password);
  }

  @override
  void erase() => _box.erase();
  @override
  Future<void> write(String k, v) => _box.write(k, v);
  @override
  Future<void> flushed() => _flushed(_box.queue);
  @override
  dynamic read(String k) => _box.read(k);
  @override
  Iterable keys() => _box.getKeys<Iterable>();
}

class ForkV1Impl extends StorageUnderTest {
  late fork_v1.GetSecureStorage _box;
  @override
  String get id => 'fork_v1';
  @override
  String get name => 'fork v1';
  @override
  bool get encrypted => true;
  @override
  Future<void> open(String c) async {
    await fork_v1.GetSecureStorage.init(container: c, password: _password);
    _box = fork_v1.GetSecureStorage(container: c, password: _password);
  }

  @override
  void erase() => _box.erase();
  @override
  Future<void> write(String k, v) => _box.write(k, v);
  @override
  Future<void> flushed() => _flushed(_box.queue);
  @override
  dynamic read(String k) => _box.read(k);
  @override
  Iterable keys() => _box.getKeys<Iterable>();
}

class V2Impl extends StorageUnderTest {
  late v2.OrcaSecureStorage _box;
  @override
  String get id => 'v2';
  @override
  String get ext => '.oss';
  @override
  String get name => 'v2 OrcaSecureStorage';
  @override
  bool get encrypted => true;
  @override
  Future<void> open(String c) async {
    await v2.OrcaSecureStorage.init(container: c, password: _password);
    _box = v2.OrcaSecureStorage(container: c, password: _password);
  }

  @override
  void erase() => _box.erase();
  @override
  Future<void> write(String k, v) => _box.write(k, v);
  @override
  Future<void> flushed() => _flushed(_box.queue);
  @override
  dynamic read(String k) => _box.read(k);
  @override
  Iterable keys() => _box.getKeys<Iterable>();
}

/// Completes once every flush queued so far has hit the disk. `write()` queues
/// its flush in a microtask, so let that run first.
Future<void> _flushed(dynamic queue) async {
  await Future<void>.delayed(Duration.zero);
  await queue.add<void>(() async {});
}

// ---------------------------------------------------------------------------

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(2);
double _r(double v) => double.parse(v.toStringAsFixed(1));

Map<String, Object?> _summarise(
    StorageUnderTest impl, int mb, AccountingDataset data, List<RunResult> runs) {
  double med(double Function(RunResult) f) => _r(_median(runs.map(f).toList()));
  return {
    'implementation': impl.name,
    'sizeMb': mb,
    'entries': data.journalEntryCount,
    'jsonMb': _mb(data.jsonBytes),
    'fileMb': _mb(runs.first.fileBytes),
    'writeMs': med((r) => r.writeMs),
    'writeMaxStallMs': med((r) => r.writeMaxStallMs),
    'writeJankMs': med((r) => r.writeJankMs),
    'updateMs': med((r) => _median(r.updateMs)),
    'updateMaxStallMs': med((r) => r.updateMaxStallMs),
    'updateJankMs': med((r) => r.updateJankMs / _updates),
    'coldReadMs': med((r) => r.coldReadMs),
    'readMaxStallMs': med((r) => r.readMaxStallMs),
    'runs': runs.length,
  };
}

void _report(List<Map<String, Object?>> rows, List<int> sizesMb) {
  if (rows.isEmpty) return;
  final now = DateTime.now();
  final b = StringBuffer()
    ..writeln('# Storage benchmark — ${now.toIso8601String().substring(0, 16)}')
    ..writeln()
    ..writeln('Flutter test VM (JIT, debug) on ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}, ${Platform.numberOfProcessors} cores. '
        'Median of $_runs runs; update = median of $_updates single-entry writes. '
        'Secure packages use a password; get_storage is unencrypted.')
    ..writeln()
    ..writeln('| Size | Implementation | File MB | Write ms | Write stall ms | '
        'Write jank ms | Update ms | Update stall ms | Jank/update ms | '
        'Cold read ms | Read stall ms |')
    ..writeln('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
  for (final r in rows) {
    b.writeln('| ${r['sizeMb']} MB | ${r['implementation']} | ${r['fileMb']} | '
        '${r['writeMs']} | ${r['writeMaxStallMs']} | ${r['writeJankMs']} | '
        '${r['updateMs']} | ${r['updateMaxStallMs']} | ${r['updateJankMs']} | '
        '${r['coldReadMs']} | ${r['readMaxStallMs']} |');
  }
  final out = Directory('results')..createSync();
  final stamp = now.toIso8601String().substring(0, 19).replaceAll(':', '-');
  File('${out.path}/benchmark_$stamp.md').writeAsStringSync(b.toString());
  File('${out.path}/benchmark_$stamp.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rows));
  // ignore: avoid_print
  print('\n$b\nSaved to ${out.path}/benchmark_$stamp.{md,json}');
}
