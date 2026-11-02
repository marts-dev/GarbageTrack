import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/main.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/home_screen.dart';
import 'package:garbagetrack/screens/users_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  testWidgets('enter key submits the login form', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
    await tester.showKeyboard(find.byType(TextFormField).last);
    await tester.testTextInput.receiveAction(TextInputAction.done);
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
    for (final label in ['Home', 'Logistics', 'Users']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Collect'), findsNothing);
  });

  testWidgets('admin can deactivate and reactivate a user', (tester) async {
    var active = true;
    final calls = <String>[];
    Map<String, dynamic> userJson() => {
          'id': 'u2',
          'email': 'gone@example.com',
          'full_name': 'Gone User',
          'role': 'resident',
          'country': null,
          'is_active': active,
          'created_at': '2026-10-29T00:00:00Z',
        };
    final auth = AuthProvider.withUser(
      userWith('admin'),
      client: ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          final path = request.url.path;
          calls.add('${request.method} $path');
          if (request.method == 'GET' && path == '/api/v1/auth/users') {
            return http.Response(jsonEncode([userJson()]), 200);
          }
          if (request.method == 'PATCH' &&
              path == '/api/v1/auth/users/u2/active') {
            active =
                (jsonDecode(request.body) as Map)['is_active'] as bool;
            return http.Response(jsonEncode(userJson()), 200);
          }
          return http.Response(jsonEncode({'detail': 'not found'}), 404);
        }),
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(home: UsersScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('gone@example.com'), findsOneWidget);
    expect(find.byTooltip('Deactivate user'), findsOneWidget);

    await tester.tap(find.byTooltip('Deactivate user'));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate gone@example.com?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inactive'), findsOneWidget);
    expect(find.byTooltip('Activate user'), findsOneWidget);
    expect(calls, contains('PATCH /api/v1/auth/users/u2/active'));

    await tester.tap(find.byTooltip('Activate user'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inactive'), findsNothing);
  });
}
