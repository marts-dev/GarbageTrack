import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/depot_home_screen.dart';
import 'package:garbagetrack/screens/depot_setup_screen.dart';
import 'package:garbagetrack/screens/facility_form_screen.dart';
import 'package:garbagetrack/screens/home_screen.dart';
import 'package:garbagetrack/screens/users_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

Map<String, dynamic> _depotJson() => {
      'id': 'f1',
      'name': 'North Depot',
      'kind': 'dump_site',
      'location': {
        'type': 'Point',
        'coordinates': [3.38, 6.46]
      },
      'accepted_types': ['plastic'],
      'address': '1 Depot Rd',
      'created_at': '2026-10-29T00:00:00Z',
      'updated_at': '2026-10-29T00:00:00Z',
    };

Map<String, dynamic> _truckJson({int load = 2}) => {
      'id': 't1',
      'plate_number': 'DEP-1',
      'status': 'enroute',
      'availability': 'working',
      'garbage_types': ['plastic'],
      'current_location': null,
      'eta_minutes': null,
      'capacity': 10,
      'load': load,
      'operator_id': 'c1',
      'created_at': '2026-10-29T00:00:00Z',
    };

Map<String, dynamic> _receiptJson() => {
      'id': 'r1',
      'depot_id': 'f1',
      'truck_id': 't1',
      'plate_number': 'DEP-1',
      'load_cleared': 2,
      'received_by': 'u9',
      'received_at': '2026-11-03T08:00:00Z',
    };

User _depotUser() => User(
      id: 'u9',
      email: 'd@example.com',
      fullName: 'Depot Staff',
      role: 'depot',
      isActive: true,
      country: 'Nigeria',
      depotId: 'f1',
    );

/// Scrolls the form's [ListView] until [finder] matches, then taps it.
Future<void> _scrollTap(WidgetTester tester, Finder finder) async {
  Future<void> sweep(Offset delta) async {
    final rect = tester.getRect(find.byType(ListView).first);
    await tester.dragFrom(
        Offset(rect.right - 4, rect.center.dy), delta);
    await tester.pumpAndSettle();
  }

  for (var i = 0; i < 15 && finder.evaluate().isEmpty; i++) {
    await sweep(const Offset(0, -400));
  }
  for (var i = 0; i < 15 && finder.evaluate().isEmpty; i++) {
    await sweep(const Offset(0, 400));
  }
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  group('DepotHomeScreen', () {
    testWidgets('shows depot, inbound truck, and receives with confirm',
        (tester) async {
      var received = false;
      Map<String, dynamic>? seenBody;
      final auth = AuthProvider.withUser(
        _depotUser(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (request.method == 'GET' && path == '/api/v1/depots/mine') {
              return http.Response(jsonEncode(_depotJson()), 200);
            }
            if (request.method == 'GET' &&
                path == '/api/v1/depots/mine/trucks') {
              return http.Response(
                  jsonEncode(received ? [] : [_truckJson()]), 200);
            }
            if (request.method == 'POST' &&
                path == '/api/v1/depots/mine/receive') {
              seenBody = jsonDecode(request.body) as Map<String, dynamic>;
              received = true;
              return http.Response(jsonEncode(_receiptJson()), 200);
            }
            if (request.method == 'GET' &&
                path == '/api/v1/depots/mine/receipts') {
              return http.Response(
                  jsonEncode(received ? [_receiptJson()] : []), 200);
            }
            return http.Response(jsonEncode({'detail': 'not found'}), 404);
          }),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: const MaterialApp(home: DepotHomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('North Depot'), findsOneWidget);
      expect(find.text('DEP-1'), findsOneWidget);
      expect(find.text('Load 2 / 10 · Working'), findsOneWidget);
      expect(find.text('No receipts yet.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Receive'));
      await tester.pumpAndSettle();
      expect(find.text('Receive DEP-1?'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Receive'),
      ));
      await tester.pumpAndSettle();

      expect(seenBody, {'truck_id': 't1'});
      expect(find.text('Received 2 from DEP-1'), findsOneWidget);
      expect(find.text('No trucks carrying a load.'), findsOneWidget);
      expect(find.textContaining('2 cleared'), findsOneWidget);
    });

    testWidgets('unbound depot user joins through setup', (tester) async {
      Map<String, dynamic>? seenBody;
      Map<String, dynamic> meJson() => {
            'id': 'u9',
            'email': 'd@example.com',
            'full_name': null,
            'role': 'depot',
            'country': 'Nigeria',
            'is_active': true,
            'depot_id': 'f1',
            'created_at': '2026-10-29T00:00:00Z',
          };
      final auth = AuthProvider.withUser(
        User(
          id: 'u9',
          email: 'd@example.com',
          role: 'depot',
          isActive: true,
          country: 'Nigeria',
        ),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (request.method == 'GET' &&
                path == '/api/v1/logistics/facilities') {
              return http.Response(jsonEncode([_depotJson()]), 200);
            }
            if (request.method == 'POST' &&
                path == '/api/v1/depots/mine/join') {
              seenBody = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(jsonEncode(_depotJson()), 200);
            }
            if (request.method == 'GET' && path == '/api/v1/auth/me') {
              return http.Response(jsonEncode(meJson()), 200);
            }
            if (request.method == 'GET' && path == '/api/v1/depots/mine') {
              return http.Response(jsonEncode(_depotJson()), 200);
            }
            if (request.method == 'GET' &&
                (path == '/api/v1/depots/mine/trucks' ||
                    path == '/api/v1/depots/mine/receipts')) {
              return http.Response(jsonEncode([]), 200);
            }
            return http.Response(jsonEncode({'detail': 'not found'}), 404);
          }),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: const MaterialApp(home: DepotHomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Set up your depot'), findsOneWidget);
      expect(find.text('North Depot (Dump Site)'), findsOneWidget);

      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Join depot'));
      await tester.pumpAndSettle();

      expect(seenBody, {'facility_id': 'f1'});
      // Bound now: the gate lifts and the depot home shows.
      expect(find.text('Set up your depot'), findsNothing);
      expect(find.text('North Depot'), findsOneWidget);
      expect(find.text('Inbound trucks'), findsOneWidget);
    });
  });

  group('DepotSetupScreen', () {
    testWidgets('register navigates to the self-register form', (tester) async {
      final auth = AuthProvider.withUser(
        _depotUser(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/v1/logistics/facilities') {
              return http.Response(jsonEncode([]), 200);
            }
            return http.Response(jsonEncode({'detail': 'not found'}), 404);
          }),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: MaterialApp(
            home: DepotSetupScreen(
              onSaved: () async {},
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No depots registered yet — set yours up below.'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Register depot'));
      await tester.pumpAndSettle();
      expect(find.text('New facility'), findsOneWidget);
    });

    testWidgets('self-register posts to the depot endpoint', (tester) async {
      final calls = <String>[];
      final postBodies = <String, dynamic>{};
      final auth = AuthProvider.withUser(
        _depotUser(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            calls.add('${request.method} $path');
            if (request.method == 'POST' &&
                path == '/api/v1/depots/mine/register') {
              postBodies.addAll(
                  jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response(jsonEncode(_depotJson()), 201);
            }
            return http.Response(jsonEncode({'detail': 'not found'}), 404);
          }),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: MaterialApp(
            home: FacilityFormScreen(
              selfRegister: true,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'South Depot');
      await _scrollTap(tester, find.widgetWithText(FilterChip, 'Plastic'));
      await _scrollTap(tester, find.byType(FlutterMap));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await _scrollTap(
          tester, find.widgetWithText(FilledButton, 'Register facility'));

      expect(calls, contains('POST /api/v1/depots/mine/register'));
      expect(postBodies['name'], 'South Depot');
      expect(postBodies['accepted_types'], ['plastic']);
      expect(
          (postBodies['location'] as Map)['longitude'], isA<double>());
      expect(find.text('New facility'), findsNothing);
    });
  });

  group('depot role routing', () {
    testWidgets('depot user lands on the depot screen', (tester) async {
      final auth = AuthProvider.withUser(
        _depotUser(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (request.method == 'GET' && path == '/api/v1/depots/mine') {
              return http.Response(jsonEncode(_depotJson()), 200);
            }
            if (request.method == 'GET') {
              return http.Response(jsonEncode([]), 200);
            }
            return http.Response(jsonEncode({'detail': 'not found'}), 404);
          }),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Depot'), findsOneWidget);
      expect(find.text('North Depot'), findsOneWidget);
    });
  });

  group('admin depot assignment', () {
    testWidgets('assigns a depot user to a facility', (tester) async {
      var depotId = 'f1';
      Map<String, dynamic> userJson() => {
            'id': 'u2',
            'email': 'staff@example.com',
            'full_name': null,
            'role': 'depot',
            'country': 'Nigeria',
            'is_active': true,
            'depot_id': depotId,
            'created_at': '2026-10-29T00:00:00Z',
          };
      final auth = AuthProvider.withUser(
        User(
          id: 'a1',
          email: 'a@example.com',
          role: 'admin',
          isActive: true,
        ),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (request.method == 'GET' && path == '/api/v1/auth/users') {
              return http.Response(jsonEncode([userJson()]), 200);
            }
            if (request.method == 'GET' &&
                path == '/api/v1/logistics/facilities') {
              return http.Response(jsonEncode([_depotJson()]), 200);
            }
            if (request.method == 'PATCH' &&
                path == '/api/v1/auth/users/u2/depot') {
              depotId =
                  (jsonDecode(request.body) as Map)['depot_id'] as String;
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
      expect(find.textContaining('Bound'), findsOneWidget);
      expect(find.byTooltip('Assign depot'), findsOneWidget);

      await tester.tap(find.byTooltip('Assign depot'));
      await tester.pumpAndSettle();
      expect(find.text('North Depot (Dump Site)'), findsOneWidget);
      expect(find.text('Unassigned'), findsOneWidget);
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Depot assigned'), findsOneWidget);
    });

    testWidgets('unbound depot user shows Unassigned', (tester) async {
      final auth = AuthProvider.withUser(
        User(
          id: 'a1',
          email: 'a@example.com',
          role: 'admin',
          isActive: true,
        ),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/v1/auth/users') {
              return http.Response(
                  jsonEncode([
                    {
                      'id': 'u2',
                      'email': 'staff@example.com',
                      'full_name': null,
                      'role': 'depot',
                      'country': 'Nigeria',
                      'is_active': true,
                      'depot_id': null,
                      'created_at': '2026-10-29T00:00:00Z',
                    }
                  ]),
                  200);
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
      expect(find.textContaining('Unassigned'), findsOneWidget);
    });
  });
}
