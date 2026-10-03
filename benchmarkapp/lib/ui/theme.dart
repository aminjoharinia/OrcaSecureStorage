import 'package:flutter/material.dart';

/// Light, dark or follow the system. Changed from the header.
final themeMode = ValueNotifier(ThemeMode.system);

const _seed = Color(0xFF5B5BD6);

/// Numbers line up in tables and on the chart axis.
const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xFF9D9BFF) : const Color(0xFF4F4CD0),
        surface: dark ? const Color(0xFF0E1016) : const Color(0xFFF4F5F9),
        onSurface: dark ? const Color(0xFFE8EAF2) : const Color(0xFF151823),
        onSurfaceVariant: dark
            ? const Color(0xFF9097AB)
            : const Color(0xFF616A80),
        surfaceContainerLowest: dark
            ? const Color(0xFF0A0B10)
            : const Color(0xFFFFFFFF),
        surfaceContainerLow: dark
            ? const Color(0xFF151821)
            : const Color(0xFFFFFFFF),
        surfaceContainer: dark
            ? const Color(0xFF1B1F2B)
            : const Color(0xFFF0F1F6),
        surfaceContainerHigh: dark
            ? const Color(0xFF222736)
            : const Color(0xFFE9EBF2),
        surfaceContainerHighest: dark
            ? const Color(0xFF2A3042)
            : const Color(0xFFE2E5EE),
        outlineVariant: dark
            ? const Color(0xFF262B3A)
            : const Color(0xFFE3E6EE),
      );
  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
  );
  final radius = BorderRadius.circular(12);
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall!.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleMedium: base.textTheme.titleMedium!.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: WidgetStateBorderSide.resolveWith(
        (s) => BorderSide(
          color: s.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outlineVariant,
        ),
      ),
      color: WidgetStateColor.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: dark ? 0.22 : 0.12)
            : scheme.surfaceContainerLow,
      ),
      labelStyle: base.textTheme.labelLarge!.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      checkmarkColor: scheme.primary,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: base.textTheme.titleSmall!.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outlineVariant),
        foregroundColor: scheme.onSurface,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: scheme.outlineVariant),
        selectedBackgroundColor: scheme.primary.withValues(
          alpha: dark ? 0.22 : 0.12,
        ),
        selectedForegroundColor: scheme.primary,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2A3042) : const Color(0xFF1C2030),
        borderRadius: BorderRadius.circular(10),
      ),
      textStyle: base.textTheme.bodySmall!.copyWith(
        color: Colors.white,
        height: 1.5,
        fontFeatures: tabular,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      waitDuration: const Duration(milliseconds: 250),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateColor.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? Colors.transparent
            : scheme.outlineVariant,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
  );
}

/// The amber used for the debug-build warning, readable in both themes.
({Color background, Color foreground}) warningColors(Brightness b) =>
    b == Brightness.dark
    ? (background: const Color(0xFF2B2110), foreground: const Color(0xFFF2C46B))
    : (
        background: const Color(0xFFFFF5E1),
        foreground: const Color(0xFF8A5A00),
      );

/// A rounded card with a hairline border.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: theme.brightness == Brightness.light
            ? const [
                BoxShadow(
                  color: Color(0x0A1C2030),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A small uppercase heading inside a [Panel].
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// A row of pill-shaped tabs in a sunken track; scrolls when narrow.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
    this.leading,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  /// Optional widget before each label, e.g. a colour dot.
  final Widget Function(T)? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in values)
              _Pill(
                selected: v == selected,
                onTap: () => onChanged(v),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!(v),
                      const SizedBox(width: 6),
                    ],
                    Text(label(v)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? (dark ? scheme.surfaceContainerHighest : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: selected && !dark
                  ? const [
                      BoxShadow(
                        color: Color(0x141C2030),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.labelLarge!.copyWith(
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
