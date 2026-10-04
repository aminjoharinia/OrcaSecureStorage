// Memory benchmark on desktop: each storage and phase runs in a child process
// (this same app, started in measuring mode), so each process's memory
// belongs to that storage alone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'adapter.dart' show storagePrefix;
import 'adapters.dart';
import 'memory.dart';

/// Child processes need a desktop OS.
bool get memorySupported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// Set when this process was started to measure one phase.
bool get isMemoryChild => Platform.environment['MEM_PHASE'] != null;

/// Runs one phase in a child process: `clear`, `write` or `open`. Returns
/// null for `clear`. Throws a [TimeoutException] when it takes longer than
/// [timeout] (the child is stopped).
Future<MemoryResult?> runMemoryPhase(
  String storage,
  String phase,
  int entries, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final process = await Process.start(Platform.resolvedExecutable, const [], environment: {
    'MEM_STORAGE': storage,
    'MEM_PHASE': phase,
    'MEM_ENTRIES': '$entries',
    'MEM_STALL': '1',
  });
  final out = StringBuffer();
  final done = Future.wait([
    process.stdout.transform(utf8.decoder).forEach(out.write),
    process.stderr.drain<void>(),
  ]);
  final int code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    rethrow;
  }
  await done;
  if (phase == 'clear') return null;
  for (final line in LineSplitter.split(out.toString())) {
    final at = line.indexOf('MEMORY {');
    if (at >= 0) {
      return MemoryResult.fromJson(jsonDecode(line.substring(at + 7)) as Map<String, dynamic>);
    }
  }
  throw StateError('$phase gave no result (exit code $code)');
}

/// The measuring mode. Environment:
/// - `MEM_STORAGE`: a storage's full name, as in the results tables.
/// - `MEM_PHASE`: `clear` empties the store (run it first, in its own
///   process: emptying a store loads what is in it, which would otherwise
///   count towards `write`); `write` writes the records one by one and waits
///   until they are saved; `open` opens them, as on an app start, and reads
///   every one.
/// - `MEM_ENTRIES`: how many records (~330 bytes of JSON each), or `MEM_MB`
///   (default 15) to size them by MB of JSON.
/// - `MEM_STALL=1`: also measure the longest UI stall.
///
/// Prints one `MEMORY {...}` line with the resident memory the storage
/// added since the start of the phase, held afterwards (steady) and at its
/// highest (peak), and exits.
Future<void> runMemoryChild() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final env = Platform.environment;
  final name = env['MEM_STORAGE'];
  final phase = env['MEM_PHASE'] ?? 'write';
  final count = int.tryParse(env['MEM_ENTRIES'] ?? '') ??
      (int.parse(env['MEM_MB'] ?? '15') * 1024 * 1024 / jsonEncode(memoryRecord(50000)).length)
          .ceil();

  // Own names: the parent app may still have its timing-run storages open.
  storagePrefix = 'mem';
  final adapters = allAdapters();
  final adapter = adapters.where((a) => a.name == name).firstOrNull;
  if (adapter == null) {
    stdout.writeln('MEMORY_ERROR unknown MEM_STORAGE "$name"; one of: '
        '${adapters.map((a) => a.name).join(', ')}');
    await stdout.flush();
    exit(2);
  }

  if (phase == 'clear') {
    await adapter.open();
    await adapter.clear();
    await adapter.flush();
    stdout.writeln('MEMORY_CLEARED ${adapter.name}');
    await stdout.flush();
    exit(0);
  }

  // Let the engine settle so its own start-up is not counted.
  await Future<void>.delayed(const Duration(seconds: 1));
  final base = ProcessInfo.currentRss;
  final basePeak = ProcessInfo.maxRss;
  final sw = Stopwatch()..start();
  // The process's all-time peak (maxRss) only shows this phase's peak when
  // the phase goes above the start-up peak, so also sample the current
  // memory every 10 ms.
  var sampled = base;
  void sample() {
    final now = ProcessInfo.currentRss;
    if (now > sampled) sampled = now;
  }

  final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) => sample());
  var lastTick = 0, maxStall = 0;
  // A stall still going on has no tick after it yet: count it at each
  // checkpoint too, or a phase that blocks until its end shows no stall.
  int stallSoFar() {
    final pending = sw.elapsedMilliseconds - lastTick;
    return pending > maxStall ? pending : maxStall;
  }

  final ticker = env['MEM_STALL'] == '1'
      ? Timer.periodic(const Duration(milliseconds: 1), (_) {
          final now = sw.elapsedMilliseconds;
          if (now - lastTick > maxStall) maxStall = now - lastTick;
          lastTick = now;
        })
      : null;

  await adapter.open();
  // Opening and the work after it, separately from the reads or writes.
  final openStall = ticker == null ? 0 : stallSoFar();
  final openMs = sw.elapsedMilliseconds;
  sample();
  final afterOpenMB = ((ProcessInfo.currentRss - base) / (1024 * 1024)).round();
  // The reads and writes are measured from here.
  maxStall = 0;
  lastTick = sw.elapsedMilliseconds;
  var found = 0;
  var firstReadUs = 0;
  // MEM_BATCH=1000: write through writeAll, that many records at a time.
  final batch = int.tryParse(env['MEM_BATCH'] ?? '') ?? 0;
  if (phase == 'write' && batch > 0) {
    for (var i = 0; i < count; i += batch) {
      await adapter.writeAll({
        for (var j = i; j < i + batch && j < count; j++) 'r$j': memoryRecord(j),
      });
      await Future<void>.delayed(Duration.zero);
    }
    await adapter.flush();
    found = count;
  } else if (phase == 'write') {
    for (var i = 0; i < count; i++) {
      await adapter.write('r$i', memoryRecord(i));
      if ((i + 1) % 50 == 0) await Future<void>.delayed(Duration.zero);
    }
    await adapter.flush();
    found = count;
  } else {
    final first = Stopwatch()..start();
    await adapter.read('r${count ~/ 2}');
    firstReadUs = first.elapsedMicroseconds;
    for (var i = 0; i < count; i++) {
      if (await adapter.read('r$i') != null) found++;
      if ((i + 1) % 50 == 0) await Future<void>.delayed(Duration.zero);
    }
  }
  final ms = sw.elapsedMilliseconds;
  final restStall = ticker == null ? 0 : stallSoFar();
  ticker?.cancel();
  sample();
  sampler.cancel();
  // Background work (compaction, caches built after opening) settles.
  await Future<void>.delayed(const Duration(seconds: 2));

  const mb = 1024 * 1024;
  final held = ((ProcessInfo.currentRss - base) / mb).round();
  final peak = (((ProcessInfo.maxRss > basePeak ? ProcessInfo.maxRss : sampled) - base) / mb).round();
  stdout.writeln('MEMORY ${jsonEncode({
    'storage': adapter.name,
    'phase': phase,
    'records': count,
    'found': found,
    'jsonMB': memoryJsonMB(count).toStringAsFixed(1),
    'ms': ms,
    if (ticker != null) 'maxStallMs': openStall > restStall ? openStall : restStall,
    if (ticker != null) 'openStallMs': openStall,
    if (ticker != null) 'restStallMs': restStall,
    'openMs': openMs,
    'afterOpenMB': afterOpenMB,
    if (phase == 'open') 'firstReadUs': firstReadUs,
    'steadyMB': held,
    'peakMB': peak < held ? held : peak,
  })}');
  await stdout.flush();
  exit(found == count ? 0 : 1);
}
