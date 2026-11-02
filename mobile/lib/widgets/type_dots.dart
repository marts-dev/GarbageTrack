import 'package:flutter/material.dart';

import '../models/models.dart';

/// Fixed color identity per garbage type, readable in both brightnesses.
/// (Deliberately no purple/violet family.)
const _typeSwatches = <String, MaterialColor>{
  'plastic': Colors.blue,
  'organic': Colors.green,
  'paper': Colors.amber,
  'glass': Colors.cyan,
  'metal': Colors.blueGrey,
  'electronic': Colors.deepOrange,
  'hazardous': Colors.red,
  'textile': Colors.pink,
  'general': Colors.brown,
};

/// The display color for a garbage [type]; unknown types fall back to grey.
Color garbageTypeColor(String type, Brightness brightness) {
  final swatch = _typeSwatches[type] ?? Colors.grey;
  return brightness == Brightness.dark ? swatch[300]! : swatch[700]!;
}

/// A small color dot identifying one garbage type.
class TypeDot extends StatelessWidget {
  const TypeDot(this.type, {super.key, this.size = 10});

  final String type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Tooltip(
      message: pretty(type),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: garbageTypeColor(type, brightness),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Compact row of color dots for a list of types (for use next to text).
class TypeDots extends StatelessWidget {
  const TypeDots(this.types, {super.key, this.size = 10});

  final List<String> types;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < types.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          TypeDot(types[i], size: size),
        ],
      ],
    );
  }
}

/// Sorted count rows with a share-of-mix bar per garbage type, for the
/// logistics dashboard and the region drill sheet.
class TypeCountRows extends StatelessWidget {
  const TypeCountRows(this.byType, {super.key});

  /// Garbage type -> report count.
  final Map<String, int> byType;

  @override
  Widget build(BuildContext context) {
    final entries = byType.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    if (entries.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Text(
        'No type data yet',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    final total = entries.fold<int>(0, (sum, e) => sum + e.value);
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _TypeCountRow(
            type: entries[i].key,
            count: entries[i].value,
            share: total > 0 ? entries[i].value / total : 0,
          ),
        ],
      ],
    );
  }
}

class _TypeCountRow extends StatelessWidget {
  const _TypeCountRow({
    required this.type,
    required this.count,
    required this.share,
  });

  final String type;
  final int count;
  final double share;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          children: [
            TypeDot(type, size: 12),
            const SizedBox(width: 8),
            Expanded(
              child: Text(pretty(type), style: theme.textTheme.bodyMedium),
            ),
            Text('$count', style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: share,
            minHeight: 6,
            color: garbageTypeColor(type, theme.brightness),
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

/// Wrapped dot + label chips for a list of types.
class TypeChips extends StatelessWidget {
  const TypeChips(this.types, {super.key});

  final List<String> types;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final type in types)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TypeDot(type, size: 9),
              const SizedBox(width: 4),
              Text(pretty(type), style: style),
            ],
          ),
      ],
    );
  }
}
