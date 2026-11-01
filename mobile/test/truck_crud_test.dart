import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/api/auth_api.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/logistics_home_screen.dart';
import 'package:garbagetrack/screens/truck_form_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

/// Offline tile stub: every tile is a transparent pixel, no network.
class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

User _user(String role, {String id = 'u1'}) => User(
      id: id,
      email: 'u@example.com',
      fullName: 'Test User',
      role: role,
      isActive: true,
    );

Widget _withAuth(AuthProvider auth, Widget home) =>
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(home: home),
    );

Map<String, dynamic> _truckJson(
  String id,
  String plate, {
  String? operatorId,
  String status = 'scheduled',
  List<String> types = const ['plastic'],
  int? capacity = 10,
}) =>
    {
      'id': id,
      'plate_number': plate,
      'status': status,
      'availability': 'available',
      'garbage_types': types,
      'current_location': null,
      'eta_minutes': null,
      'capacity': capacity,
      'load': 0,
      'operator_id': operatorId,
      'created_at': '2026-10-29T00:00:00Z',
    };

Map<String, dynamic> _userJson(String id, String email, String role) => {
      'id': id,
      'email': email,
      'full_name': 'Collector $id',
      'role': role,
      'is_active': true,
      'country': null,
      'created_at': '2026-10-29T00:00:00Z',
    };

void main() {
  group('auth users role filter', () {
    test('listUsers sends the role query when given', () async {
      Uri? seen;
      final api = AuthApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response('[]', 200);
        }),
      ));
      await api.listUsers(role: 'collector');
      expect(seen!.path, '/api/v1/auth/users');
      expect(seen!.queryParameters['role'], 'collector');
    });
  });

  group('truck form', () {
    MockClient formBackend(
      List<String> calls, {
      Map<String, dynamic>? patchBodies,
      int patchStatus = 200,
      String patchDetail = '',
    }) =>
        MockClient((request) async {
          final path = request.url.path;
          calls.add('${request.method} $path');
          if (request.method == 'GET' && path == '/api/v1/auth/users') {
            return http.Response(
              jsonEncode([
                _userJson('c1', 'c1@x.com', 'collector'),
                _userJson('c2', 'c2@x.com', 'collector'),
                _userJson('l1', 'l1@x.com', 'logistics'),
              ]),
              200,
            );
          }
          if (request.method == 'POST' && path == '/api/v1/trucks/schedules') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode(_truckJson(
                't9',
                body['plate_number'] as String,
                status: body['status'] as String? ?? 'scheduled',
                types: (body['garbage_types'] as List).cast<String>(),
                capacity: (body['capacity'] as num?)?.toInt(),
              )),
              201,
            );
          }
          if (request.method == 'PATCH' &&
              RegExp(r'^/api/v1/trucks/[^/]+$').hasMatch(path)) {
            patchBodies?.addAll(jsonDecode(request.body) as Map<String, dynamic>);
            if (patchStatus != 200) {
              return http.Response(
                jsonEncode({'detail': patchDetail}),
                patchStatus,
              );
            }
            return http.Response(jsonEncode(_truckJson('t1', 'AAA-1')), 200);
          }
          return http.Response('not found', 404);
        });

    AuthProvider formAuth(
      List<String> calls, {
      Map<String, dynamic>? patchBodies,
      int patchStatus = 200,
      String patchDetail = '',
    }) =>
        AuthProvider.withUser(
          _user('logistics'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: formBackend(
              calls,
              patchBodies: patchBodies,
              patchStatus: patchStatus,
              patchDetail: patchDetail,
            ),
          ),
        );

    /// Scrolls the form's [ListView] until [finder] matches, then taps it.
    /// (Off-screen rows are built lazily, so plain ensureVisible fails.)
    Future<void> scrollTap(WidgetTester tester, Finder finder) async {
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

    testWidgets('plate is required', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _withAuth(formAuth(calls), const TruckFormScreen()),
      );
      await tester.pumpAndSettle();
      await scrollTap(tester, find.text('Register truck'));
      expect(find.text('Plate number is required'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('POST')), isEmpty);
    });

    testWidgets('at least one garbage type is required', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _withAuth(formAuth(calls), const TruckFormScreen()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'NEW-1');
      await scrollTap(tester, find.text('Register truck'));
      expect(find.text('Pick at least one garbage type'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('POST')), isEmpty);
    });

    testWidgets('create posts the schedule without an operator patch',
        (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _withAuth(formAuth(calls), const TruckFormScreen()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'NEW-1');
      await scrollTap(tester, find.text('Plastic'));
      await scrollTap(tester, find.text('Register truck'));
      // Success pops the form; the schedule posted with no operator patch.
      expect(find.text('New truck'), findsNothing);
      expect(calls, contains('POST /api/v1/trucks/schedules'));
      expect(calls.where((c) => c.startsWith('PATCH')), isEmpty);
    });

    testWidgets('operator picker lists collectors and binds on create',
        (tester) async {
      final calls = <String>[];
      final patchBodies = <String, dynamic>{};
      await tester.pumpWidget(
        _withAuth(formAuth(calls, patchBodies: patchBodies),
            const TruckFormScreen()),
      );
      await tester.pumpAndSettle();
      // Only collectors are offered; the logistics user is filtered out.
      await scrollTap(tester, find.text('Unassigned'));
      expect(find.text('Collector c1 · c1@x.com'), findsOneWidget);
      expect(find.textContaining('l1@x.com'), findsNothing);
      await tester.tap(find.text('Collector c1 · c1@x.com').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'NEW-1');
      await scrollTap(tester, find.text('Plastic'));
      await scrollTap(tester, find.text('Register truck'));
      expect(find.text('New truck'), findsNothing);
      expect(calls, contains('POST /api/v1/trucks/schedules'));
      expect(calls, contains('PATCH /api/v1/trucks/t9'));
      expect(patchBodies['operator_id'], 'c1');
    });

    testWidgets('edit pre-selects the operator and patches fields',
        (tester) async {
      final calls = <String>[];
      final patchBodies = <String, dynamic>{};
      final existing =
          Truck.fromJson(_truckJson('t1', 'AAA-1', operatorId: 'c2'));
      await tester.pumpWidget(
        _withAuth(formAuth(calls, patchBodies: patchBodies),
            TruckFormScreen(existing: existing)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit truck'), findsOneWidget);
      expect(find.text('Collector c2 · c2@x.com'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, 'BBB-2');
      await scrollTap(tester, find.text('Save changes'));
      expect(find.text('Edit truck'), findsNothing);
      expect(calls, contains('PATCH /api/v1/trucks/t1'));
      expect(patchBodies['plate_number'], 'BBB-2');
      expect(patchBodies['operator_id'], 'c2');
      expect(patchBodies['garbage_types'], ['plastic']);
    });

    testWidgets('clearing the picker unassigns with an explicit null',
        (tester) async {
      final calls = <String>[];
      final patchBodies = <String, dynamic>{};
      final existing =
          Truck.fromJson(_truckJson('t1', 'AAA-1', operatorId: 'c2'));
      await tester.pumpWidget(
        _withAuth(formAuth(calls, patchBodies: patchBodies),
            TruckFormScreen(existing: existing)),
      );
      await tester.pumpAndSettle();
      await scrollTap(tester, find.text('Collector c2 · c2@x.com'));
      await tester.tap(find.text('Unassigned').last);
      await tester.pumpAndSettle();
      await scrollTap(tester, find.text('Save changes'));
      expect(patchBodies.containsKey('operator_id'), isTrue);
      expect(patchBodies['operator_id'], isNull);
    });

    testWidgets('double-bind 409 surfaces the server detail', (tester) async {
      final calls = <String>[];
      final existing =
          Truck.fromJson(_truckJson('t1', 'AAA-1', operatorId: 'c2'));
      await tester.pumpWidget(
        _withAuth(
          formAuth(
            calls,
            patchStatus: 409,
            patchDetail: 'collector already assigned to another truck',
          ),
          TruckFormScreen(existing: existing),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTap(tester, find.text('Save changes'));
      expect(
        find.text('collector already assigned to another truck'),
        findsOneWidget,
      );
    });
  });

  group('logistics trucks tab', () {
    MockClient trucksBackend(
      List<Map<String, dynamic>> trucks,
      List<String> calls, {
      int deleteStatus = 204,
      String deleteDetail = '',
    }) =>
        MockClient((request) async {
          final path = request.url.path;
          calls.add('${request.method} $path');
          if (request.method == 'GET' &&
              path == '/api/v1/logistics/garbage/summary') {
            return http.Response(
              jsonEncode({'total': 0, 'by_status': {}, 'by_type': {}}),
              200,
            );
          }
          if (request.method == 'GET' && path == '/api/v1/trucks') {
            return http.Response(jsonEncode(trucks), 200);
          }
          if (request.method == 'GET' && path == '/api/v1/auth/users') {
            return http.Response(
              jsonEncode([_userJson('c1', 'c1@x.com', 'collector')]),
              200,
            );
          }
          if (request.method == 'POST' && path == '/api/v1/trucks/schedules') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final created = _truckJson(
              't9',
              body['plate_number'] as String,
              types: (body['garbage_types'] as List).cast<String>(),
            );
            trucks.add(created);
            return http.Response(jsonEncode(created), 201);
          }
          if (request.method == 'DELETE' &&
              RegExp(r'^/api/v1/trucks/[^/]+$').hasMatch(path)) {
            if (deleteStatus != 204) {
              return http.Response(
                jsonEncode({'detail': deleteDetail}),
                deleteStatus,
              );
            }
            trucks.clear();
            return http.Response('', 204);
          }
          return http.Response('not found', 404);
        });

    AuthProvider trucksAuth(
      List<Map<String, dynamic>> trucks,
      List<String> calls, {
      int deleteStatus = 204,
      String deleteDetail = '',
    }) =>
        AuthProvider.withUser(
          _user('logistics'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: trucksBackend(
              trucks,
              calls,
              deleteStatus: deleteStatus,
              deleteDetail: deleteDetail,
            ),
          ),
        );

    Future<void> openTrucksTab(
      WidgetTester tester,
      AuthProvider auth,
    ) async {
      await tester.pumpWidget(_withAuth(
        auth,
        LogisticsHomeScreen(tileProvider: _StubTileProvider()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trucks'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists trucks with assignment pills and a Truck button',
        (tester) async {
      final calls = <String>[];
      final trucks = [
        _truckJson('t1', 'AAA-1', operatorId: 'c1'),
        _truckJson('t2', 'BBB-2'),
      ];
      await openTrucksTab(tester, trucksAuth(trucks, calls));
      expect(calls, contains('GET /api/v1/trucks'));
      expect(find.text('AAA-1'), findsOneWidget);
      expect(find.text('BBB-2'), findsOneWidget);
      expect(find.text('Assigned'), findsOneWidget);
      expect(find.text('Unassigned'), findsOneWidget);
      expect(find.widgetWithText(FloatingActionButton, 'Truck'), findsOneWidget);
    });

    testWidgets('empty list prompts the Truck button', (tester) async {
      final calls = <String>[];
      await openTrucksTab(tester, trucksAuth([], calls));
      expect(find.text('No trucks yet.'), findsOneWidget);
      expect(find.text('Use the Truck button to add one.'), findsOneWidget);
    });

    testWidgets('Truck button creates and reloads the list', (tester) async {
      final calls = <String>[];
      await openTrucksTab(tester, trucksAuth([], calls));
      await tester.tap(find.widgetWithText(FloatingActionButton, 'Truck'));
      await tester.pumpAndSettle();
      expect(find.text('New truck'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, 'NEW-1');
      for (final label in ['Plastic', 'Register truck']) {
        final target = find.text(label);
        for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
          final rect = tester.getRect(find.byType(ListView).first);
          await tester.dragFrom(
              Offset(rect.right - 4, rect.center.dy), const Offset(0, -400));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(target.first);
        await tester.pumpAndSettle();
        await tester.tap(target.first);
        await tester.pumpAndSettle();
      }
      expect(find.text('Truck registered'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('NEW-1'), findsOneWidget);
    });

    testWidgets('edit opens the prefilled form', (tester) async {
      final calls = <String>[];
      final trucks = [_truckJson('t1', 'AAA-1', operatorId: 'c1')];
      await openTrucksTab(tester, trucksAuth(trucks, calls));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit truck'), findsOneWidget);
      expect(find.text('Collector c1 · c1@x.com'), findsOneWidget);
    });

    testWidgets('delete confirms, deletes, and reloads', (tester) async {
      final calls = <String>[];
      final trucks = [_truckJson('t1', 'AAA-1')];
      await openTrucksTab(tester, trucksAuth(trucks, calls));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete truck?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.startsWith('DELETE')), isEmpty);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Truck deleted'), findsOneWidget);
      expect(calls, contains('DELETE /api/v1/trucks/t1'));
      expect(find.text('No trucks yet.'), findsOneWidget);
    });

    testWidgets('delete 409 surfaces the route-assigned detail', (tester) async {
      final calls = <String>[];
      final trucks = [_truckJson('t1', 'AAA-1')];
      await openTrucksTab(
        tester,
        trucksAuth(trucks, calls,
            deleteStatus: 409, deleteDetail: 'truck has assigned routes'),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('truck has assigned routes'), findsOneWidget);
      expect(find.text('AAA-1'), findsOneWidget);
    });

    testWidgets('delete 404 reloads with truck-not-found', (tester) async {
      final calls = <String>[];
      final trucks = [_truckJson('t1', 'AAA-1')];
      await openTrucksTab(
        tester,
        trucksAuth(trucks, calls,
            deleteStatus: 404, deleteDetail: 'truck not found'),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Truck not found'), findsOneWidget);
    });
  });
}
