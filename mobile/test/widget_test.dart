import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/main.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/home_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:provider/provider.dart';

/// Pumps the app past async plugin calls (secure storage), which need real
/// async rather than the fake-async clock used by pumpWidget.
Future<void> pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const GarbageTrackApp());
  await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows login when no session is stored', (tester) async {
    await pumpApp(tester);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('login validates email and password', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(find.text('At least 8 characters'), findsOneWidget);
  });

  User userWith(String role, [String? name]) => User(
        id: 'u1',
        email: 'u@example.com',
        fullName: name ?? 'Test User',
        role: role,
        isActive: true,
      );

  testWidgets('single-role user gets one screen without bottom nav', (tester) async {
    final auth = AuthProvider.withUser(userWith('resident'));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Hello, Test User'), findsOneWidget);
    expect(find.text('Resident'), findsOneWidget);
  });

  testWidgets('nameless user gets role-based greeting', (tester) async {
    final auth = AuthProvider.withUser(User(
      id: 'u1',
      email: 'u@example.com',
      role: 'resident',
      isActive: true,
    ));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hello, Resident'), findsOneWidget);
  });

  testWidgets('admin gets bottom nav with all tabs', (tester) async {
    final auth = AuthProvider.withUser(userWith('admin'));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in ['Home', 'Collect', 'Logistics', 'Users']) {
      expect(find.text(label), findsOneWidget);
    }
  });
}
