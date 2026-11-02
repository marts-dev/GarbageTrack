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

  group('TypeCountRows', () {
    testWidgets('sorts by count and shows share bars', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TypeCountRows({'paper': 1, 'plastic': 3}),
          ),
        ),
      );
      // Biggest stream first despite map order.
      final labels = tester
          .widgetList<Text>(find.descendant(
            of: find.byType(TypeCountRows),
            matching: find.byType(Text),
          ))
          .map((t) => t.data)
          .toList();
      expect(labels, ['Plastic', '3', 'Paper', '1']);
      expect(find.byType(TypeDot), findsNWidgets(2));
      final bars = tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bars.map((b) => b.value), [0.75, 0.25]);
    });

    testWidgets('shows a placeholder without data', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TypeCountRows({})),
        ),
      );
      expect(find.text('No type data yet'), findsOneWidget);
    });
  });
}
