import 'dart:convert';

/// A journal entry as an accounting app might store it (~330 bytes as JSON).
/// The memory benchmark stores these, whatever value types are selected.
Map<String, Object> memoryRecord(int i) => {
  'id': i,
  'date': '2026-10-${i % 28 + 1}',
  'desc': 'Invoice $i for consulting hours and services',
  'lines': [
    for (var j = 0; j < 4; j++)
      {
        'acct': 1000 + (i * 7 + j) % 900,
        'amount': (i * 13 + j) % 99999 / 100,
        'memo': 'Invoice $i line $j',
      },
  ],
};

/// MB of JSON that [entries] memory records take.
double memoryJsonMB(int entries) =>
    entries * jsonEncode(memoryRecord(entries ~/ 2)).length / (1024 * 1024);

/// One phase of the memory benchmark, as printed by a child process on its
/// `MEMORY {...}` line.
class MemoryResult {
  MemoryResult({
    required this.ms,
    required this.steadyMB,
    required this.peakMB,
    this.maxStallMs,
    this.afterOpenMB,
    this.openStallMs,
  });

  factory MemoryResult.fromJson(Map<String, dynamic> j) => MemoryResult(
    ms: (j['ms'] as num).toDouble(),
    steadyMB: (j['steadyMB'] as num).toDouble(),
    peakMB: (j['peakMB'] as num).toDouble(),
    maxStallMs: (j['maxStallMs'] as num?)?.toDouble(),
    afterOpenMB: (j['afterOpenMB'] as num?)?.toDouble(),
    openStallMs: (j['openStallMs'] as num?)?.toDouble(),
  );

  /// Time of the phase (open + read everything, or write everything).
  final double ms;

  /// Resident memory the storage added, two seconds after the phase.
  final double steadyMB;

  /// The most it added at any point during the phase.
  final double peakMB;

  /// Longest time the UI isolate's event loop was blocked.
  final double? maxStallMs;

  /// Memory added right after opening, before reading or writing anything.
  final double? afterOpenMB;

  /// Longest UI stall while opening alone.
  final double? openStallMs;
}

/// Write and open results of one storage, or why there are none.
class MemoryRow {
  MemoryResult? write;
  MemoryResult? open;
  String? problem;
}
