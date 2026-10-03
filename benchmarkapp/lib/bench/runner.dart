import 'dart:async';
import 'dart:math';

import '../platform/platform_web.dart'
    if (dart.library.io) '../platform/platform_io.dart';
import 'adapter.dart';

enum Op {
  write('write'),
  update('update 1'),
  read('read'),
  coldRead('cold read'),
  delete('delete');

  const Op(this.title);
  final String title;
}

/// The value types measured. Keys are `<prefix><index>`.
enum Kind {
  integers('Integers', 'i'),
  doubles('Doubles', 'd'),
  strings('Strings', 's'),
  json('JSON', 'j');

  const Kind(this.title, this.prefix);
  final String title;
  final String prefix;

  /// The value stored under entry [i].
  Object value(int i) => switch (this) {
    integers => i,
    doubles => i * 1.01 + 0.5,
    strings => _stringValue(i),
    json => _jsonValue(i),
  };
}

class OpResult {
  OpResult(this.ms);

  /// Wall time, including the final flush to disk. For [Op.update], the
  /// median time of one update.
  final double ms;
}

class AdapterResult {
  AdapterResult(this.adapter);
  final StorageAdapter adapter;
  final Map<(Op, Kind), OpResult> results = {};

  /// Ops that ran out of time, with how far they got.
  final Map<(Op, Kind), String> timeouts = {};
  String? error;
}

/// [fraction] is how much of the whole run is done, from 0 to 1.
typedef Progress = void Function(String message, double fraction);

/// A string of realistic length (about 100 characters).
String _stringValue(int i) =>
    'Invoice #$i — 3 × consulting hours, paid by bank transfer, ref ${i * 7919}';

/// A small record, as an app would store a model object (~120 bytes as JSON).
Map<String, Object> _jsonValue(int i) => {
  'id': i,
  'invoice': 'INV-${100000 + i}',
  'amount': i * 12.5 + 0.99,
  'currency': 'AUD',
  'paid': i.isEven,
  'tags': ['consulting', 'q${i % 4 + 1}'],
};

class _Timeout implements Exception {
  _Timeout(this.message);
  final String message;
}

class BenchmarkRunner {
  BenchmarkRunner(
    this.adapters,
    this.entries, {
    this.kinds = Kind.values,
    this.updates = 20,
    this.budget = const Duration(seconds: 20),
  });
  final List<StorageAdapter> adapters;
  final int entries;

  /// Value types to measure, in this order.
  final List<Kind> kinds;

  /// Single-entry updates measured after the bulk write.
  final int updates;

  /// Time allowed per operation; slower storages are stopped.
  final Duration budget;

  Future<List<AdapterResult>> run(Progress progress) async {
    final out = <AdapterResult>[];
    for (final (a, adapter) in adapters.indexed) {
      final result = AdapterResult(adapter);
      out.add(result);
      if (adapter.unsupportedReason != null) {
        result.error = adapter.unsupportedReason;
        continue;
      }
      try {
        progress('${adapter.name}: opening', a / adapters.length);
        await adapter.open();
        await adapter.clear();
        await adapter.flush();
        for (final (k, kind) in kinds.indexed) {
          await _runKind(
            adapter,
            kind,
            result,
            (message, f) => progress(
              message,
              (a + (k + f) / kinds.length) / adapters.length,
            ),
          );
        }
      } catch (e) {
        result.error = '$e';
      }
    }
    return out;
  }

  Future<void> _runKind(
    StorageAdapter adapter,
    Kind kind,
    AdapterResult result,
    Progress progress,
  ) async {
    final prefix = kind.prefix;
    final value = kind.value;

    Future<void> step(Op op, Future<OpResult> Function() body) async {
      progress(
        '${adapter.name}: ${op.title} ${kind.name}',
        op.index / Op.values.length,
      );
      try {
        result.results[(op, kind)] = await body();
      } on _Timeout catch (t) {
        result.timeouts[(op, kind)] = t.message;
        progress(
          '${adapter.name}: stopping after timeout',
          op.index / Op.values.length,
        );
        await adapter.abort();
        rethrow;
      }
    }

    try {
      await step(
        Op.write,
        () => _measure((deadline) async {
          for (var i = 0; i < entries; i++) {
            await adapter.write('$prefix$i', value(i));
            await _check(deadline, i + 1);
          }
          await _flush(adapter, deadline);
        }),
      );

      await step(Op.update, () async {
        final rnd = Random(7);
        final times = <double>[];
        await _measure((deadline) async {
          for (var u = 0; u < updates; u++) {
            final i = rnd.nextInt(entries);
            final sw = Stopwatch()..start();
            await adapter.write('$prefix$i', value(i + entries));
            await _flush(adapter, deadline);
            times.add(sw.elapsedMicroseconds / 1000);
            await _check(deadline, u + 1, of: updates);
          }
        });
        times.sort();
        return OpResult(times[times.length ~/ 2]);
      });

      var found = 0;
      await step(
        Op.read,
        () => _measure((deadline) async {
          for (var i = 0; i < entries; i++) {
            if (await adapter.read('$prefix$i') != null) found++;
            await _check(deadline, i + 1);
          }
        }),
      );
      if (found != entries) {
        throw StateError('read back $found of $entries ${kind.name}');
      }

      found = 0;
      await step(
        Op.coldRead,
        () => _measure((deadline) async {
          await adapter.openCold();
          for (var i = 0; i < entries; i++) {
            if (await adapter.readCold('$prefix$i') != null) found++;
            await _check(deadline, i + 1);
          }
        }),
      );
      await adapter.closeCold();
      if (found != entries) {
        throw StateError('cold read back $found of $entries ${kind.name}');
      }

      await step(
        Op.delete,
        () => _measure((deadline) async {
          for (var i = 0; i < entries; i++) {
            await adapter.delete('$prefix$i');
            await _check(deadline, i + 1);
          }
          await _flush(adapter, deadline);
        }),
      );
    } on _Timeout {
      // Leave the rest of this kind out; start the next one from empty.
      await adapter.closeCold();
      await adapter.clear();
      await adapter.flush();
    }
  }

  /// Every 50 operations, gives the event loop a turn: storages that answer
  /// synchronously (most on the web) would otherwise run the whole loop as one
  /// chain of microtasks, so no frame or timeout could run until it ended.
  Future<void> _check(Stopwatch deadline, int done, {int? of}) async {
    if (done % 50 == 0) await yieldToEventLoop();
    if (deadline.elapsed > budget) {
      throw _Timeout(
        '> ${budget.inSeconds} s (stopped at $done of ${of ?? entries})',
      );
    }
  }

  Future<void> _flush(StorageAdapter adapter, Stopwatch deadline) async {
    final left = budget - deadline.elapsed;
    try {
      await adapter.flush().timeout(left.isNegative ? Duration.zero : left);
    } on TimeoutException {
      throw _Timeout('> ${budget.inSeconds} s (still saving to disk)');
    }
  }

  Future<OpResult> _measure(
    Future<void> Function(Stopwatch deadline) body,
  ) async {
    final sw = Stopwatch()..start();
    await body(sw);
    return OpResult(sw.elapsedMicroseconds / 1000);
  }
}
