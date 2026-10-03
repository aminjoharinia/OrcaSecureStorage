import 'package:flutter/material.dart';

import '../bench/runner.dart';
import 'bar_chart.dart';
import 'theme.dart';

/// One number in a [ResultsTable], or why there is none.
class ResultCell {
  const ResultCell(this.text, {this.value, this.problem = false});

  /// The time of [op] for [kind], `timeout` or `–`.
  factory ResultCell.of(AdapterResult r, Op op, Kind kind) {
    if (r.timeouts[(op, kind)] case final t?) {
      return ResultCell('timeout $t', problem: true);
    }
    final ms = r.results[(op, kind)]?.ms;
    return ms == null
        ? const ResultCell('–')
        : ResultCell(formatNum(ms), value: ms);
  }

  final String text;

  /// Milliseconds; the smallest in a column is highlighted.
  final double? value;
  final bool problem;
}

/// One storage per row, times in ms; the fastest in each column is marked.
class ResultsTable extends StatelessWidget {
  const ResultsTable({
    super.key,
    required this.headers,
    required this.results,
    required this.cells,
  });

  /// Titles of the number columns (the storage column comes first).
  final List<String> headers;
  final List<AdapterResult> results;

  /// The number cells of a row, one per header.
  final List<ResultCell> Function(AdapterResult) cells;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final best = dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
    final rows = [
      for (final r in results) (r, r.error == null ? cells(r) : null),
    ];
    final fastest = [
      for (var c = 0; c < headers.length; c++)
        () {
          final vs = [for (final (_, cs) in rows) ?cs?[c].value];
          return vs.length < 2 ? null : vs.reduce((a, b) => a < b ? a : b);
        }(),
    ];

    final headStyle = theme.textTheme.labelMedium!.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final numStyle = theme.textTheme.bodyMedium!.copyWith(
      fontFeatures: tabular,
    );
    const pad = EdgeInsets.symmetric(horizontal: 12, vertical: 11);
    BoxDecoration line(bool show) => BoxDecoration(
      border: show
          ? Border(bottom: BorderSide(color: scheme.outlineVariant))
          : null,
    );

    Widget number(ResultCell cell, double? min) {
      if (cell.problem) {
        return Tooltip(
          message: cell.text,
          child: Text('timeout', style: numStyle.copyWith(color: scheme.error)),
        );
      }
      // Compared as shown, so equal-looking times are all marked.
      if (cell.value == null || min == null || cell.text != formatNum(min)) {
        return Text(cell.text, style: numStyle);
      }
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: best.withValues(alpha: dark ? 0.16 : 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          cell.text,
          style: numStyle.copyWith(color: best, fontWeight: FontWeight.w700),
        ),
      );
    }

    return _HorizontalScroll(
      builder: (minWidth) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          // Only the name column flexes: it takes the slack, so the table
          // is exactly as wide as the card unless the numbers need more.
          columnWidths: const {0: IntrinsicColumnWidth(flex: 1)},
          defaultColumnWidth: const MaxColumnWidth(
            IntrinsicColumnWidth(),
            FixedColumnWidth(104),
          ),
          children: [
            TableRow(
              decoration: line(true),
              children: [
                Padding(
                  padding: pad.copyWith(left: 4),
                  child: Text('Storage', style: headStyle),
                ),
                for (final h in headers)
                  Padding(
                    padding: pad,
                    child: Text(h, style: headStyle, textAlign: TextAlign.end),
                  ),
              ],
            ),
            for (final (i, (r, cs)) in rows.indexed)
              TableRow(
                decoration: line(i < rows.length - 1),
                children: [
                  Padding(
                    padding: pad.copyWith(left: 4),
                    child: _StorageName(result: r),
                  ),
                  for (var c = 0; c < headers.length; c++)
                    Padding(
                      padding: pad,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: cs == null
                            ? Text(
                                'n/a',
                                style: numStyle.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            : number(cs[c], fastest[c]),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StorageName extends StatelessWidget {
  const _StorageName({required this.result});
  final AdapterResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = result.adapter;
    final error = result.error;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  a.name,
                  style: theme.textTheme.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (a.encrypted) ...[
                const SizedBox(width: 6),
                Icon(Icons.lock_rounded, size: 13, color: scheme.primary),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Tooltip(
            message: error ?? a.encryption,
            child: Text(
              error ?? a.encryption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall!.copyWith(
                color: error != null ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal scrolling with a visible scrollbar, so wide tables show that
/// more columns are off-screen. [builder] gets the visible width.
class _HorizontalScroll extends StatefulWidget {
  const _HorizontalScroll({required this.builder});
  final Widget Function(double minWidth) builder;

  @override
  State<_HorizontalScroll> createState() => _HorizontalScrollState();
}

class _HorizontalScrollState extends State<_HorizontalScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 10),
        child: widget.builder(constraints.maxWidth),
      ),
    ),
  );
}
