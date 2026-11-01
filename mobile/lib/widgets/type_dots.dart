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
