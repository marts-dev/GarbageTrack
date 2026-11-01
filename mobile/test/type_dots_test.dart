import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/widgets/type_dots.dart';

void main() {
  group('garbageTypeColor', () {
    test('maps every known type to a distinct color per brightness', () {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final colors = {
          for (final type in garbageTypes) garbageTypeColor(type, brightness),
        };
        expect(colors, hasLength(garbageTypes.length));
      }
    });

    test('adapts to brightness and falls back to grey', () {
      expect(
        garbageTypeColor('plastic', Brightness.light),
        isNot(garbageTypeColor('plastic', Brightness.dark)),
      );
      expect(
        garbageTypeColor('mystery', Brightness.light),
        Colors.grey[700],
      );
      expect(
        garbageTypeColor('mystery', Brightness.dark),
        Colors.grey[300],
      );
    });
  });

  group('TypeChips', () {
    testWidgets('shows a labeled dot per type', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TypeChips(['plastic', 'paper'])),
        ),
      );
      expect(find.text('Plastic'), findsOneWidget);
      expect(find.text('Paper'), findsOneWidget);
      expect(find.byType(TypeDot), findsNWidgets(2));
    });

    testWidgets('TypeDots renders compact dots without labels', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TypeDots(['plastic', 'paper'])),
        ),
      );
      expect(find.text('Plastic'), findsNothing);
      expect(find.byType(TypeDot), findsNWidgets(2));
    });
  });
}
