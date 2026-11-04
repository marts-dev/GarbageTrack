import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/widgets/async_view.dart';
import 'package:garbagetrack/widgets/cards.dart';

void main() {
  group('AppTheme', () {
    test('uses green seed with Material 3', () {
      expect(AppTheme.seedColor, const Color(0xFF43A047));
      expect(AppTheme.secondaryColor, const Color(0xFFF9A825));
      expect(AppTheme.light.useMaterial3, isTrue);
      expect(AppTheme.dark.useMaterial3, isTrue);
    });

    test('light and dark differ only in brightness', () {
      expect(AppTheme.light.colorScheme.brightness, Brightness.light);
      expect(AppTheme.dark.colorScheme.brightness, Brightness.dark);
    });

    test('shares radius-12 tokens across card/input/snackbar', () {
      final cardShape =
          AppTheme.light.cardTheme.shape as RoundedRectangleBorder;
      expect(cardShape.borderRadius, BorderRadius.circular(12));
      final inputBorder =
          AppTheme.light.inputDecorationTheme.border as OutlineInputBorder;
      expect(inputBorder.borderRadius, BorderRadius.circular(12));
      final snackShape =
          AppTheme.light.snackBarTheme.shape as RoundedRectangleBorder;
      expect(snackShape.borderRadius, BorderRadius.circular(12));
    });
  });

  group('EmptyState', () {
    testWidgets('renders icon, title and subtitle', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nothing here',
              subtitle: 'Try again later',
            ),
          ),
        ),
      );
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.text('Try again later'), findsOneWidget);
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    });

    testWidgets('action button fires callback', (tester) async {
      var pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nothing here',
              actionLabel: 'Retry now',
              onAction: () => pressed = true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Retry now'));
      expect(pressed, isTrue);
    });

    testWidgets('hides action when label or callback missing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(icon: Icons.inbox_outlined, title: 'No action'),
          ),
        ),
      );
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('LoadingView', () {
    testWidgets('shows spinner and optional label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LoadingView(label: 'Loading trucks')),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading trucks'), findsOneWidget);
    });
  });

  group('StatusPill', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: StatusPill(label: 'Collected', status: 'collected'),
          ),
        ),
      );
      expect(find.text('Collected'), findsOneWidget);
    });
  });

  group('CardIcon', () {
    testWidgets('renders icon in tinted container', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: CardIcon(icon: Icons.delete_outline, status: 'full'),
          ),
        ),
      );
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });
  });

  group('RefreshableEmpty', () {
    testWidgets('pull-to-refresh triggers onRefresh', (tester) async {
      var refreshed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RefreshableEmpty(
              onRefresh: () async => refreshed = true,
              empty: const EmptyState(
                icon: Icons.inbox_outlined,
                title: 'Nothing here',
              ),
            ),
          ),
        ),
      );
      await tester.fling(
        find.text('Nothing here'),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(refreshed, isTrue);
    });
  });
}
