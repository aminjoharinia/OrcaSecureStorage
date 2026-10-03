// Memory benchmark: one storage, one phase per process, so each process's
// resident memory belongs to that storage alone. Not on the web.
//
// flutter build macos --release -t lib/memory_main.dart
// MEM_STORAGE='Hive CE' MEM_PHASE=write <app binary>   # then MEM_PHASE=open
//
// write: opens an empty store, writes MEM_MB (default 15) MB of JSON records
//        one by one, waits until saved.
// open:  opens the data written before (as on an app start) and reads every
//        record.
// Prints one `MEMORY {...}` line: memory added since the start of the phase,
// held afterwards (steady) and at its highest (peak), and exits.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'bench/adapters.dart';

/// A journal entry as an accounting app might store it (~330 bytes as JSON).
Map<String, Object> record(int i) => {
      'id': i,
      'date': '2026-10-${i % 28 + 1}',
      'desc': 'Invoice $i for consulting hours and services',
      'lines': [
        for (var j = 0; j < 4; j++)
          {'acct': 1000 + (i * 7 + j) % 900, 'amount': (i * 13 + j) % 99999 / 100, 'memo': 'Invoice $i line $j'},
      ],
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final env = Platform.environment;
  final name = env['MEM_STORAGE'];
  final phase = env['MEM_PHASE'] ?? 'write';
  final targetBytes = int.parse(env['MEM_MB'] ?? '15') * 1024 * 1024;
  final count = (targetBytes / jsonEncode(record(50000)).length).ceil();

  final adapters = allAdapters();
  final adapter = adapters.where((a) => a.name == name).firstOrNull;
  if (adapter == null) {
    stdout.writeln('MEMORY_ERROR unknown MEM_STORAGE "$name"; one of: '
        '${adapters.map((a) => a.name).join(', ')}');
    exit(2);
  }

  // Let the engine settle so its own start-up is not counted.
  await Future<void>.delayed(const Duration(seconds: 1));
  final base = ProcessInfo.currentRss;
  final basePeak = ProcessInfo.maxRss;
  final sw = Stopwatch()..start();

  await adapter.open();
  var found = 0;
  if (phase == 'write') {
    await adapter.clear();
    await adapter.flush();
    for (var i = 0; i < count; i++) {
      await adapter.write('r$i', record(i));
      if ((i + 1) % 50 == 0) await Future<void>.delayed(Duration.zero);
    }
    await adapter.flush();
    found = count;
  } else {
    for (var i = 0; i < count; i++) {
      if (await adapter.read('r$i') != null) found++;
    }
  }
  final ms = sw.elapsedMilliseconds;
  // Background work (compaction, caches built after opening) settles.
  await Future<void>.delayed(const Duration(seconds: 2));

  const mb = 1024 * 1024;
  stdout.writeln('MEMORY ${jsonEncode({
    'storage': adapter.name,
    'phase': phase,
    'records': count,
    'found': found,
    'jsonMB': (count * jsonEncode(record(count ~/ 2)).length / mb).toStringAsFixed(1),
    'ms': ms,
    'steadyMB': ((ProcessInfo.currentRss - base) / mb).round(),
    'peakMB': ((ProcessInfo.maxRss - basePeak) / mb).round(),
  })}');
  await stdout.flush();
  exit(found == count ? 0 : 1);
}
