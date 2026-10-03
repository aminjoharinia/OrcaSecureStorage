import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bench/runner.dart';
import 'theme.dart';

/// Bar colour per value type; readable on light and dark backgrounds.
Color kindColor(Kind kind) => switch (kind) {
  Kind.integers => const Color(0xFF22C3A6),
  Kind.doubles => const Color(0xFF5B8DEF),
  Kind.strings => const Color(0xFFEF5F82),
  Kind.json => const Color(0xFFF2A93B),
};

/// `0.4`, `12.3`, `456`, `1,234`.
String formatNum(double ms) {
  if (ms >= 1000) {
    final s = ms.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return '$b';
  }
  return ms >= 100 ? '${ms.round()}' : ms.toStringAsFixed(1);
}

String formatMs(double ms) => '${formatNum(ms)} ms';

/// Grouped bars per storage, one bar per value type. Encrypted storages get
/// a lock under their label. Bars grow into place when results change.
class BarChart extends StatelessWidget {
  const BarChart({
    super.key,
    required this.results,
    required this.op,
    this.kinds = Kind.values,
    this.logScale = false,
  });

  final List<AdapterResult> results;
  final Op op;

  /// Value types to draw, one bar each.
  final List<Kind> kinds;
  final bool logScale;

  static const _chartHeight = 260.0;

  @override
  Widget build(BuildContext context) {
    final maxMs = [
      for (final r in results)
        for (final k in kinds) r.results[(op, k)]?.ms ?? 0.0,
    ].fold<double>(0, math.max);
    double scale(double ms) {
      if (maxMs <= 0) return 0;
      if (!logScale) return ms / maxMs;
      return math.log(1 + ms) / math.log(1 + maxMs);
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final axisStyle = theme.textTheme.labelSmall!.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: tabular,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 60,
          height: _chartHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Each label centred on its gridline.
              for (final f in [1.0, 0.75, 0.5, 0.25, 0.0])
                Positioned(
                  right: 0,
                  top: (1 - f) * _chartHeight - 8,
                  height: 16,
                  child: Text(_axisLabel(f, maxMs, logScale), style: axisStyle),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: _chartHeight,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _GridPainter(scheme.outlineVariant),
                  ),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final r in results)
                          _Group(
                            result: r,
                            op: op,
                            kinds: kinds,
                            scale: scale,
                            height: _chartHeight,
                            axisStyle: axisStyle,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _axisLabel(double f, double maxMs, bool log) =>
      formatMs(log ? (math.pow(1 + maxMs, f) - 1).toDouble() : maxMs * f);
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final dashed = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final f in [0.25, 0.5, 0.75, 1.0]) {
      final y = ((1 - f) * size.height).roundToDouble() + 0.5;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 4, size.width), y),
          dashed,
        );
      }
    }
    final y = size.height - 0.5;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = color
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

class _Group extends StatelessWidget {
  const _Group({
    required this.result,
    required this.op,
    required this.kinds,
    required this.scale,
    required this.height,
    required this.axisStyle,
  });

  final AdapterResult result;
  final Op op;
  final List<Kind> kinds;
  final double Function(double) scale;
  final double height;
  final TextStyle axisStyle;

  double get _barWidth => kinds.length > 2 ? 9.0 : 13.0;

  @override
  Widget build(BuildContext context) {
    final failed = result.error != null;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: failed
          ? '${result.adapter.name}\n${result.error}'
          : [
              result.adapter.name,
              'Encryption: ${result.adapter.encryption}',
              for (final k in kinds)
                '${k.title}: ${result.timeouts[(op, k)] ?? switch (result.results[(op, k)]) {
                      final r? => formatMs(r.ms),
                      null => '–',
                    }}',
            ].join('\n'),
      child: SizedBox(
        width: math.max(68, 20 + kinds.length * (_barWidth + 5)),
        child: Column(
          children: [
            SizedBox(
              height: height,
              child: failed
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.block_rounded,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 4),
                          Text('n/a', style: axisStyle),
                        ],
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final (i, k) in kinds.indexed) ...[
                          if (i > 0) const SizedBox(width: 5),
                          _bar(k),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              result.adapter.label,
              style: axisStyle.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            SizedBox(
              height: 20,
              child: result.adapter.encrypted
                  ? Icon(
                      Icons.lock_rounded,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(Kind k) {
    final width = _barWidth;
    final ms = result.results[(op, k)]?.ms;
    final timedOut = result.timeouts[(op, k)] != null;
    final color = kindColor(k);
    final target = timedOut
        ? height
        : ms == null
        ? width
        : math.max(width, scale(ms) * height);
    return TweenAnimationBuilder<double>(
      // Grows from 0 the first time, then from its current height.
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
      builder: (context, h, _) => Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(width / 2),
            bottom: const Radius.circular(3),
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: timedOut || ms == null
                ? [color.withValues(alpha: 0.28), color.withValues(alpha: 0.08)]
                : [color, color.withValues(alpha: 0.7)],
          ),
        ),
      ),
    );
  }
}
