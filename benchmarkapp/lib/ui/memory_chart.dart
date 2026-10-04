import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bench/adapter.dart';
import '../bench/memory.dart';
import 'theme.dart';

const memoryWriteColor = Color(0xFF5B8DEF);
const memoryOpenColor = Color(0xFFA855F7);

/// Peak memory per storage: one bar after writing, one after opening.
class MemoryChart extends StatelessWidget {
  const MemoryChart({super.key, required this.rows});

  final List<(StorageAdapter, MemoryRow)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxMB = [
      for (final (_, r) in rows) ...[r.write?.peakMB ?? 0, r.open?.peakMB ?? 0],
    ].fold<double>(1, math.max);
    final label = theme.textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w600);
    final value = theme.textTheme.labelSmall!.copyWith(
      fontFeatures: tabular,
      color: scheme.onSurfaceVariant,
    );

    Widget bar(double? mb, Color color) => Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Align(
              alignment: Alignment.centerLeft,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: (mb ?? 0) / maxMB),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, f, _) => Container(
                  width: math.max(2, c.maxWidth * f),
                  height: 12,
                  decoration: BoxDecoration(
                    color: mb == null ? scheme.outlineVariant : color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            mb == null ? '–' : '${mb.round()} MB',
            textAlign: TextAlign.end,
            style: value,
          ),
        ),
      ],
    );

    return Column(
      children: [
        for (final (a, r) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(a.label, style: label, overflow: TextOverflow.ellipsis),
                      ),
                      if (a.encrypted) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.lock_rounded, size: 12, color: scheme.onSurfaceVariant),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: r.problem != null
                      ? Text(r.problem!, style: value.copyWith(color: scheme.error))
                      : Column(
                          children: [
                            bar(r.write?.peakMB, memoryWriteColor),
                            const SizedBox(height: 4),
                            bar(r.open?.peakMB, memoryOpenColor),
                          ],
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
