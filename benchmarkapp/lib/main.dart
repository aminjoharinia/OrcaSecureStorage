import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'bench/adapter.dart';
import 'bench/adapters.dart';
import 'bench/memory.dart';
import 'bench/memory_web.dart' if (dart.library.io) 'bench/memory_io.dart';
import 'bench/runner.dart';
import 'platform/platform_web.dart'
    if (dart.library.io) 'platform/platform_io.dart';
import 'ui/bar_chart.dart';
import 'ui/memory_chart.dart';
import 'ui/results_table.dart';
import 'ui/theme.dart';

// flutter run --release --dart-define=AUTORUN=true --dart-define=ENTRIES=100
// runs once, prints the results, saves a screenshot and exits (not on web).
const _autorun = bool.fromEnvironment('AUTORUN');
const _autorunEntries = int.fromEnvironment('ENTRIES', defaultValue: 50);
// e.g. --dart-define=KINDS=integers,json (default: all value types).
const _autorunKinds = String.fromEnvironment('KINDS');
// --dart-define=MEMORY=true: the autorun measures memory instead (desktop);
// MEMORY=after: the timing benchmark first, then memory, as from the UI.
const _autorunMemory = String.fromEnvironment('MEMORY');
// light, dark or system (default).
const _theme = String.fromEnvironment('THEME', defaultValue: 'system');

void main() {
  // Started by the memory benchmark to measure one storage: no UI.
  if (isMemoryChild) {
    runMemoryChild();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  themeMode.value = ThemeMode.values.firstWhere(
    (m) => m.name == _theme,
    orElse: () => ThemeMode.system,
  );
  runApp(const BenchmarkApp());
}

class BenchmarkApp extends StatelessWidget {
  const BenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Storage Benchmark',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: const BenchmarkPage(),
      ),
    );
  }
}

String _capitalized(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

String _opDescription(Op op) => switch (op) {
  Op.write => 'Write every entry, then wait until it is saved',
  Op.update => 'One write into the full storage, saved · median of 20',
  Op.read => 'Read every entry',
  Op.coldRead => 'Open the data from disk again and read every entry',
  Op.delete => 'Delete every entry, then wait until it is saved',
};

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  static const _entryOptions = [
    10, 50, 100, 500, 1000, 5000, 10000, 15000, 20000, 50000, 100000,
  ];

  final _adapters = allAdapters();
  late final Set<StorageAdapter> _selected = {..._adapters};
  final _screenshotKey = GlobalKey();

  /// Progress lives outside [setState], so only the progress bar rebuilds
  /// while the benchmark runs.
  final _progress = ValueNotifier<(String, double)>(('', 0));

  int _entriesIndex = _entryOptions.indexOf(500);
  bool _logScale = false;
  Op _op = Op.write;
  final Set<Kind> _kinds = {...Kind.values};
  List<Kind> _resultKinds = Kind.values;
  Kind _summaryKind = Kind.strings;
  bool _running = false;
  List<AdapterResult>? _results;

  /// Entries of the last run (the chips may have changed since).
  int _resultEntries = 0;

  /// Last memory run, and its entries.
  List<(StorageAdapter, MemoryRow)>? _memory;
  int _memoryEntries = 0;

  int get _entries => _entryOptions[_entriesIndex];
  List<Kind> get _legendKinds => _results != null
      ? _resultKinds
      : [
          for (final k in Kind.values)
            if (_kinds.contains(k)) k,
        ];
  bool get _canRun => !_running && _selected.isNotEmpty && _kinds.isNotEmpty;

  String get _buildMode => kReleaseMode
      ? 'release'
      : kProfileMode
      ? 'profile'
      : 'debug';

  @override
  void initState() {
    super.initState();
    if (_autorun) {
      final i = _entryOptions.indexOf(_autorunEntries);
      if (i >= 0) _entriesIndex = i;
      if (_autorunKinds.isNotEmpty) {
        final names = _autorunKinds.split(',').map((k) => k.trim()).toSet();
        _kinds.retainWhere((k) => names.contains(k.name));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _autorunAndExit());
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    _progress.value = ('Starting', 0);
    setState(() {
      _running = true;
      _results = null;
    });
    final runner = BenchmarkRunner(
      [
        for (final a in _adapters)
          if (_selected.contains(a)) a,
      ],
      _entries,
      kinds: [
        for (final k in Kind.values)
          if (_kinds.contains(k)) k,
      ],
    );
    _resultKinds = runner.kinds;
    if (!_resultKinds.contains(_summaryKind)) _summaryKind = _resultKinds.first;
    final results = await runner.run((m, f) => _progress.value = (m, f));
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
      _resultEntries = runner.entries;
    });
    // Also on the console (browser dev tools, `flutter run` output).
    debugPrint(_markdown(), wrapWidth: 100000);
  }

  /// Measures each selected storage in child processes of this app: clear,
  /// then write, then open, each in a fresh process.
  Future<void> _runMemory() async {
    final adapters = [
      for (final a in _adapters)
        if (_selected.contains(a)) a,
    ];
    final entries = _entries;
    final rows = [for (final a in adapters) (a, MemoryRow())];
    _progress.value = ('Starting', 0);
    setState(() {
      _running = true;
      _memory = rows;
      _memoryEntries = entries;
    });
    const phases = ['clear', 'write', 'open'];
    for (final (i, (a, row)) in rows.indexed) {
      for (final (j, phase) in phases.indexed) {
        _progress.value = (
          '${a.name}: $phase ${_short(entries)} records',
          (i * phases.length + j) / (rows.length * phases.length),
        );
        try {
          final r = await runMemoryPhase(a.name, phase, entries);
          if (phase == 'write') row.write = r;
          if (phase == 'open') row.open = r;
        } on TimeoutException {
          row.problem = '$phase took over 90 s (stopped)';
        } catch (e) {
          row.problem = '$phase failed: $e';
        }
        if (!mounted) return;
        setState(() {});
        if (row.problem != null) break;
      }
    }
    _progress.value = ('Done', 1);
    if (!mounted) return;
    setState(() => _running = false);
    debugPrint(_memoryMarkdown(), wrapWidth: 100000);
  }

  static String _short(int n) => n >= 1000 ? '${n ~/ 1000}k' : '$n';

  static const _memoryHeaders = [
    'Write held MB',
    'Write peak MB',
    'Open held MB',
    'Open peak MB',
    'Write ms',
    'Open + read ms',
    'Max UI stall ms',
  ];

  List<ResultCell> _memoryCells(MemoryRow row) {
    ResultCell c(double? v) => v == null
        ? const ResultCell('–')
        : ResultCell(formatNum(v), value: v);
    final w = row.write, o = row.open;
    final stall = [?w?.maxStallMs, ?o?.maxStallMs];
    return [
      c(w?.steadyMB),
      c(w?.peakMB),
      c(o?.steadyMB),
      c(o?.peakMB),
      c(w?.ms),
      c(o?.ms),
      c(stall.isEmpty ? null : stall.reduce((a, b) => a > b ? a : b)),
    ];
  }

  String _memoryMarkdown() {
    final rows = _memory;
    if (rows == null) return '';
    final b = StringBuffer()
      ..writeln(
        'Memory — ${platformName()}, $_buildMode, $_memoryEntries records '
        '(${memoryJsonMB(_memoryEntries).toStringAsFixed(1)} MB of JSON)',
      )
      ..writeln()
      ..writeln('| Storage | Encryption | ${_memoryHeaders.join(' | ')} |')
      ..writeln('|---|---|${'---:|' * _memoryHeaders.length}');
    for (final (a, row) in rows) {
      final cells = row.problem != null
          ? [row.problem!, ...List.filled(_memoryHeaders.length - 1, '')]
          : [for (final c in _memoryCells(row)) c.text];
      b.writeln('| ${a.name} | ${a.encryption} | ${cells.join(' | ')} |');
    }
    return b.toString();
  }

  String _markdown() {
    final results = _results ?? [];
    String cell(AdapterResult r, Op op, Kind k) =>
        r.timeouts[(op, k)] ?? r.results[(op, k)]?.ms.toStringAsFixed(1) ?? '–';
    final b = StringBuffer()
      ..writeln(
        'Storage benchmark — ${platformName()}, $_buildMode, $_resultEntries entries',
      )
      ..writeln()
      ..writeln('Summary (${_summaryKind.title}):')
      ..writeln()
      ..writeln(
        '| Storage | Encryption | ${[for (final op in Op.values) '${_capitalized(op.title)} ms'].join(' | ')} |',
      )
      ..writeln('|---|---|${'---:|' * Op.values.length}');
    for (final r in results) {
      final cells = r.error != null
          ? [...List.filled(Op.values.length - 1, 'n/a'), r.error!]
          : [for (final op in Op.values) cell(r, op, _summaryKind)];
      b.writeln(
        '| ${r.adapter.name} | ${r.adapter.encryption} | ${cells.join(' | ')} |',
      );
    }
    b
      ..writeln()
      ..writeln('All operations:')
      ..writeln()
      ..writeln(
        '| Storage | Op | ${[for (final k in _resultKinds) '${k.title} ms'].join(' | ')} |',
      )
      ..writeln('|---|---|${'---:|' * _resultKinds.length}');
    for (final r in results) {
      if (r.error != null) {
        b.writeln(
          '| ${r.adapter.name} | – | ${[for (final _ in _resultKinds) 'n/a'].join(' | ')} | ${r.error} |',
        );
        continue;
      }
      for (final op in Op.values) {
        b.writeln(
          '| ${r.adapter.name} | ${op.title} | ${[for (final k in _resultKinds) cell(r, op, k)].join(' | ')} |',
        );
      }
    }
    return b.toString();
  }

  Future<void> _autorunAndExit() async {
    if (_autorunMemory == 'after') {
      await _run();
      // ignore: avoid_print
      print('BENCHMARK_MARKDOWN_BEGIN\n${_markdown()}BENCHMARK_MARKDOWN_END');
    }
    if (_autorunMemory.isNotEmpty) {
      await _runMemory();
      await WidgetsBinding.instance.endOfFrame;
      await _saveScreenshot('storage_benchmark_memory.png');
      // ignore: avoid_print
      print('BENCHMARK_MEMORY_BEGIN\n${_memoryMarkdown()}BENCHMARK_MEMORY_END');
      exitApp(0);
      return;
    }
    await _run();
    for (final op in Op.values) {
      setState(() => _op = op);
      // Let the bars finish growing.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await WidgetsBinding.instance.endOfFrame;
      await _saveScreenshot('storage_benchmark_${op.name}.png');
    }
    // ignore: avoid_print
    print('BENCHMARK_MARKDOWN_BEGIN\n${_markdown()}BENCHMARK_MARKDOWN_END');
    // ignore: avoid_print
    print(
      'BENCHMARK_JSON ${jsonEncode([
        for (final r in _results!) {
            'storage': r.adapter.name,
            'encryption': r.adapter.encryption,
            'error': r.error,
            for (final e in r.results.entries) '${e.key.$1.name}_${e.key.$2.name}': {'ms': e.value.ms},
            'timeouts': {for (final t in r.timeouts.entries) '${t.key.$1.name}_${t.key.$2.name}': t.value},
          },
      ])}',
    );
    exitApp(0);
  }

  Future<void> _saveScreenshot(String name) async {
    final boundary =
        _screenshotKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final path = await saveFile(name, png!.buffer.asUint8List());
    // ignore: avoid_print
    if (path != null) print('SCREENSHOT $path');
  }

  Future<void> _copyResults() async {
    await Clipboard.setData(
      ClipboardData(
        text: [
          if (_results != null) _markdown(),
          if (_memory != null) _memoryMarkdown(),
        ].join('\n'),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Results copied as Markdown'),
        behavior: SnackBarBehavior.floating,
        width: 320,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: RepaintBoundary(
        key: _screenshotKey,
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 1000;
                final gutter = constraints.maxWidth < 600 ? 16.0 : 28.0;
                final header = [
                  _header(theme),
                  if (!kReleaseMode && !kProfileMode) ...[
                    const SizedBox(height: 16),
                    _debugWarning(theme),
                  ],
                  const SizedBox(height: 24),
                ];
                if (!wide) {
                  return ListView(
                    padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 32),
                    children: [
                      ...header,
                      _settings(theme),
                      const SizedBox(height: 16),
                      ..._resultsSection(theme),
                    ],
                  );
                }
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1440),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 360,
                          child: ListView(
                            padding: EdgeInsets.fromLTRB(gutter, 28, 8, 32),
                            children: [_settings(theme)],
                          ),
                        ),
                        Expanded(
                          child: ListView(
                            padding: EdgeInsets.fromLTRB(16, 28, gutter, 32),
                            children: [...header, ..._resultsSection(theme)],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6366F1), Color(0xFFA855F7)],
            ),
          ),
          child: const Icon(Icons.speed_rounded, color: Colors.white),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Storage Benchmark', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(
                '${platformName()} · $_buildMode build · '
                '${_adapters.length} storages',
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ValueListenableBuilder(
          valueListenable: themeMode,
          builder: (context, mode, _) => SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_rounded, size: 18),
                tooltip: 'System theme',
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_rounded, size: 18),
                tooltip: 'Light theme',
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_rounded, size: 18),
                tooltip: 'Dark theme',
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => themeMode.value = s.first,
          ),
        ),
      ],
    );
  }

  Widget _debugWarning(ThemeData theme) {
    final c = warningColors(theme.brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: c.foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Debug build: Dart runs unoptimized and every new isolate is '
              'registered with the debugger, so timings are not representative '
              '(storages that use a background isolate look slowest). '
              'Run with --release or --profile.',
              style: theme.textTheme.bodySmall!.copyWith(
                color: c.foreground,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectAll<T>(Set<T> set, List<T> all) {
    final full = set.length == all.length;
    return TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      onPressed: _running
          ? null
          : () => setState(() => full ? set.clear() : set.addAll(all)),
      child: Text(full ? 'None' : 'All'),
    );
  }

  Widget _settings(ThemeData theme) {
    final scheme = theme.colorScheme;
    String short(int n) => n >= 1000 ? '${n ~/ 1000}k' : '$n';
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Entries'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, n) in _entryOptions.indexed)
                ChoiceChip(
                  label: Text(short(n)),
                  selected: i == _entriesIndex,
                  onSelected: _running
                      ? null
                      : (_) => setState(() => _entriesIndex = i),
                ),
            ],
          ),
          const SizedBox(height: 24),
          SectionLabel('Storages', trailing: _selectAll(_selected, _adapters)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in _adapters)
                FilterChip(
                  showCheckmark: true,
                  tooltip: '${a.name}\n${a.package} · ${a.encryption}',
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(a.label),
                      if (a.encrypted) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.lock_rounded,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                  selected: _selected.contains(a),
                  onSelected: _running
                      ? null
                      : (v) => setState(
                          () => v ? _selected.add(a) : _selected.remove(a),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          SectionLabel(
            'Value types',
            trailing: _selectAll(_kinds, Kind.values),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in Kind.values)
                FilterChip(
                  label: Text(k.title),
                  avatar: _Dot(kindColor(k), dim: !_kinds.contains(k)),
                  selected: _kinds.contains(k),
                  onSelected: _running
                      ? null
                      : (v) => setState(
                          () => v ? _kinds.add(k) : _kinds.remove(k),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _canRun ? _run : null,
            icon: _running
                ? SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(
              _running ? 'Running…' : 'Run benchmark · ${short(_entries)}',
            ),
          ),
          const SizedBox(height: 10),
          Tooltip(
            message: memorySupported
                ? 'Each storage is written and opened in its own background '
                      'process with ${short(_entries)} JSON records of ~330 bytes'
                : 'Needs a desktop OS: each storage runs in its own process',
            child: FilledButton.tonalIcon(
              onPressed: memorySupported && !_running && _selected.isNotEmpty
                  ? _runMemory
                  : null,
              icon: const Icon(Icons.memory_rounded, size: 18),
              label: Text('Measure memory · ${short(_entries)}'),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _running ? _progressBar(theme) : const SizedBox.shrink(),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: (_results == null && _memory == null) || _running
                ? null
                : _copyResults,
            icon: const Icon(Icons.content_copy_rounded, size: 16),
            label: const Text('Copy results as Markdown'),
          ),
        ],
      ),
    );
  }

  Widget _progressBar(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: RepaintBoundary(
      child: ValueListenableBuilder(
        valueListenable: _progress,
        builder: (context, p, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: p.$2),
              duration: const Duration(milliseconds: 300),
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  '${(p.$2 * 100).round()}%',
                  style: theme.textTheme.labelSmall!.copyWith(
                    fontFeatures: tabular,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _resultsSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final results = _results;
    final memory = _memory;
    return [
      if (memory != null) ...[
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Memory · $_memoryEntries records · '
                '${memoryJsonMB(_memoryEntries).toStringAsFixed(1)} MB of JSON',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                'Peak memory each storage added to its own process · lower is better',
                style: muted,
              ),
              const SizedBox(height: 16),
              MemoryChart(rows: memory),
              const SizedBox(height: 8),
              Wrap(
                spacing: 18,
                children: [
                  for (final (color, text) in [
                    (memoryWriteColor, 'writing every record'),
                    (memoryOpenColor, 'opening and reading every record'),
                  ])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Dot(color),
                        const SizedBox(width: 6),
                        Text(text, style: muted),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 16),
              ResultsTable(
                headers: _memoryHeaders,
                results: [
                  for (final (a, row) in memory)
                    AdapterResult(a)..error = row.problem,
                ],
                cells: (r) => _memoryCells(
                  memory.firstWhere((m) => m.$1 == r.adapter).$2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Each storage is cleared, written and opened in fresh '
                'processes of this app. Held: two seconds after the phase; '
                'memory freed after a peak usually stays with the process. '
                'Below about 10k records the differences are within a few MB '
                'of noise. Lowest in each column highlighted.',
                style: muted.copyWith(height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PillTabs<Op>(
              values: Op.values,
              selected: _op,
              label: (op) => _capitalized(op.title),
              onChanged: (op) => setState(() => _op = op),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_capitalized(_op.title)} · '
                        '${results == null ? _entries : _resultEntries} entries',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(_opDescription(_op), style: muted),
                    ],
                  ),
                ),
                Text('Log scale', style: muted),
                const SizedBox(width: 6),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: _logScale,
                    onChanged: (v) => setState(() => _logScale = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: results != null
                  ? BarChart(
                      key: const ValueKey('chart'),
                      results: results,
                      op: _op,
                      kinds: _resultKinds,
                      logScale: _logScale,
                    )
                  : _chartPlaceholder(theme),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final k in _legendKinds)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Dot(kindColor(k)),
                      const SizedBox(width: 6),
                      Text(k.title, style: muted),
                    ],
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text('encrypted', style: muted),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      if (results != null) ...[
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Summary', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Every operation for one value type · ms',
                        style: muted,
                      ),
                    ],
                  ),
                  PillTabs<Kind>(
                    values: _resultKinds,
                    selected: _summaryKind,
                    label: (k) => k.title,
                    leading: (k) => _Dot(kindColor(k)),
                    onChanged: (k) => setState(() => _summaryKind = k),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ResultsTable(
                headers: [for (final op in Op.values) _capitalized(op.title)],
                results: results,
                cells: (r) => [
                  for (final op in Op.values)
                    ResultCell.of(r, op, _summaryKind),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_capitalized(_op.title)} by value type',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text('ms · fastest in each column highlighted', style: muted),
              const SizedBox(height: 12),
              ResultsTable(
                headers: [for (final k in _resultKinds) k.title],
                results: results,
                cells: (r) => [
                  for (final k in _resultKinds) ResultCell.of(r, _op, k),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Times include waiting until the data is on disk. "Update 1" is one '
            'write into the full storage (median of 20). "Cold read" opens the '
            'data from disk again and reads every key. Operations over 20 s are '
            'stopped.',
            style: muted.copyWith(height: 1.5),
          ),
        ),
      ],
    ];
  }

  Widget _chartPlaceholder(ThemeData theme) {
    final scheme = theme.colorScheme;
    return SizedBox(
      key: ValueKey(_running),
      height: 302,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: _running
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: scheme.primary,
                      ),
                    )
                  : Icon(Icons.bar_chart_rounded, color: scheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              _running ? 'Benchmark running' : 'No results yet',
              style: theme.textTheme.titleSmall!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            if (_running)
              ValueListenableBuilder(
                valueListenable: _progress,
                builder: (context, p, _) => Text(
                  p.$1,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Text(
                'Pick storages and value types, then run the benchmark.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, {this.dim = false});
  final Color color;
  final bool dim;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: dim ? color.withValues(alpha: 0.35) : color,
      shape: BoxShape.circle,
    ),
  );
}
