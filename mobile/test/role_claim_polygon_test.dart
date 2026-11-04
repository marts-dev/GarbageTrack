import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/api/logistics_api.dart';
import 'package:garbagetrack/api/truck_api.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/collector_home_screen.dart';
import 'package:garbagetrack/screens/home_screen.dart';
import 'package:garbagetrack/screens/logistics_home_screen.dart';
import 'package:garbagetrack/screens/route_create_screen.dart';
import 'package:garbagetrack/screens/route_detail_screen.dart';
import 'package:garbagetrack/screens/truck_detail_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/utils/dates.dart';
import 'package:garbagetrack/utils/geo.dart';
import 'package:garbagetrack/widgets/geo_map.dart';
import 'package:garbagetrack/widgets/location_picker.dart';
import 'package:garbagetrack/widgets/route_preview.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

/// Offline tile stub: every tile is a transparent pixel, no network.
class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

User _user(String role, {String id = 'u1', String? country}) => User(
      id: id,
      email: 'u@example.com',
      fullName: 'Test User',
      role: role,
      isActive: true,
      country: country,
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
  List<double>? location,
  String availability = 'working',
}) =>
    {
      'id': id,
      'plate_number': plate,
      'availability': availability,
      'garbage_types': ['plastic'],
      'current_location': location == null
          ? null
          : {
              'type': 'Point',
              'coordinates': location,
            },
      'eta_minutes': null,
      'capacity': 10,
      'load': 0,
      'operator_id': operatorId,
      'created_at': '2026-10-29T00:00:00Z',
    };

Map<String, dynamic> _postJson(String id, double lng, double lat,
        [String? district]) =>
    {
      'id': id,
      'user_id': 'u9',
      'location': {
        'type': 'Point',
        'coordinates': [lng, lat]
      },
      'types': ['plastic'],
      'description': null,
      'district': district,
      'has_image': false,
      'image_content_type': null,
      'status': 'posted',
      'created_at': '2026-10-29T00:00:00Z',
      'collected_at': null,
    };

Map<String, dynamic> _collectionRouteJson({
  List<List<double>>? geometry,
  String geometrySource = 'road',
  bool emptyStops = false,
}) =>
    {
      'truck_id': 't1',
      'origin': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'remaining_capacity': 2,
      'stops': [
        if (!emptyStops)
          {
            'post_id': 'p1',
            'location': {
              'type': 'Point',
              'coordinates': [3.38, 6.46]
            },
            'types': ['plastic'],
            'status': 'posted',
            'distance_meters': 100.0,
          },
      ],
      'geometry': geometry == null
          ? null
          : {
              'type': 'LineString',
              'coordinates': geometry,
            },
      'geometry_source': geometrySource,
    };

/// Assigned-plan payload for `GET /trucks/t1/planned-route`, with one stop
/// and one embedded depot unless [emptyStops] drops the stop list.
Map<String, dynamic> _plannedTruckRouteJson({
  List<List<double>>? geometry,
  bool emptyStops = false,
  int? totalStops = 3,
  String planStatus = 'assigned',
}) =>
    {
      'id': 'r1',
      'truck_id': 't1',
      'name': 'Morning run',
      'origin': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'stops': [
        if (!emptyStops)
          {
            'post_id': 'p1',
            'location': {
              'type': 'Point',
              'coordinates': [3.38, 6.46]
            },
            'types': ['plastic'],
            'distance_meters': 100.0,
          },
      ],
      'status': planStatus,
      'scheduled_for': '2026-12-25',
      if (totalStops != null) 'total_stops': totalStops,
      'created_at': '2026-10-29T00:00:00Z',
      'depot_ids': ['f1'],
      'depots': [
        {
          'id': 'f1',
          'name': 'North Depot',
          'kind': 'dump_site',
          'location': {
            'type': 'Point',
            'coordinates': [3.20, 6.30]
          },
          'accepted_types': ['plastic'],
          'address': null,
        }
      ],
      'collection_points': [],
      'geometry': geometry == null
          ? null
          : {
              'type': 'LineString',
              'coordinates': geometry,
            },
      'geometry_source': geometry == null ? 'straight' : 'road',
    };

/// Scrolls the screen's [ListView] until [finder] matches, then reveals it.
/// Drags along the screen edge so map gestures never swallow the scroll.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  Future<void> sweep(Offset delta) async {
    final rect = tester.getRect(find.byType(ListView).first);
    await tester.dragFrom(Offset(rect.right - 4, rect.center.dy), delta);
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
}

void main() {
  group('pointInPolygon', () {
    final square = [
      GeoPoint(longitude: 0, latitude: 0),
      GeoPoint(longitude: 10, latitude: 0),
      GeoPoint(longitude: 10, latitude: 10),
      GeoPoint(longitude: 0, latitude: 10),
    ];

    test('detects inside and outside points', () {
      expect(
          pointInPolygon(GeoPoint(longitude: 5, latitude: 5), square), isTrue);
      expect(pointInPolygon(GeoPoint(longitude: 15, latitude: 5), square),
          isFalse);
      expect(pointInPolygon(GeoPoint(longitude: 5, latitude: -1), square),
          isFalse);
    });

    test('treats edges and vertices as enclosed', () {
      expect(
          pointInPolygon(GeoPoint(longitude: 0, latitude: 5), square), isTrue);
      expect(
          pointInPolygon(GeoPoint(longitude: 5, latitude: 0), square), isTrue);
      expect(
          pointInPolygon(GeoPoint(longitude: 0, latitude: 0), square), isTrue);
      expect(pointInPolygon(GeoPoint(longitude: 10, latitude: 10), square),
          isTrue);
    });

    test('rejects degenerate rings', () {
      final point = GeoPoint(longitude: 5, latitude: 5);
      expect(pointInPolygon(point, []), isFalse);
      expect(pointInPolygon(point, [square[0]]), isFalse);
      expect(pointInPolygon(point, [square[0], square[1]]), isFalse);
    });

    test('handles concave rings without explicit closure', () {
      // U-shape: the notch (4..6, 5..10) is outside.
      final u = [
        GeoPoint(longitude: 0, latitude: 0),
        GeoPoint(longitude: 10, latitude: 0),
        GeoPoint(longitude: 10, latitude: 10),
        GeoPoint(longitude: 6, latitude: 10),
        GeoPoint(longitude: 6, latitude: 4),
        GeoPoint(longitude: 4, latitude: 4),
        GeoPoint(longitude: 4, latitude: 10),
        GeoPoint(longitude: 0, latitude: 10),
      ];
      expect(pointInPolygon(GeoPoint(longitude: 2, latitude: 8), u), isTrue);
      expect(pointInPolygon(GeoPoint(longitude: 8, latitude: 8), u), isTrue);
      expect(pointInPolygon(GeoPoint(longitude: 5, latitude: 8), u), isFalse);
      expect(pointInPolygon(GeoPoint(longitude: 5, latitude: 2), u), isTrue);
    });

    test('uses longitude as x and latitude as y', () {
      final wide = [
        GeoPoint(longitude: 0, latitude: 0),
        GeoPoint(longitude: 20, latitude: 0),
        GeoPoint(longitude: 20, latitude: 2),
        GeoPoint(longitude: 0, latitude: 2),
      ];
      expect(
          pointInPolygon(GeoPoint(longitude: 10, latitude: 1), wide), isTrue);
      // Swapped coordinates fall outside.
      expect(
          pointInPolygon(GeoPoint(longitude: 1, latitude: 10), wide), isFalse);
    });
  });

  group('operator binding and geometry models', () {
    test('Truck parses operator_id with helpers', () {
      final mine = Truck.fromJson(_truckJson('t1', 'A', operatorId: 'u1'));
      expect(mine.operatorId, 'u1');
      expect(mine.isAssigned, isTrue);
      expect(mine.isOperatedBy('u1'), isTrue);
      expect(mine.isOperatedBy('u2'), isFalse);

      final free = Truck.fromJson(_truckJson('t1', 'A'));
      expect(free.operatorId, isNull);
      expect(free.isAssigned, isFalse);
      expect(free.isOperatedBy('u1'), isFalse);
    });

    test('Truck tolerates legacy payloads without operator_id', () {
      final json = _truckJson('t1', 'A')..remove('operator_id');
      final truck = Truck.fromJson(json);
      expect(truck.operatorId, isNull);
      expect(truck.isAssigned, isFalse);
    });

    test('CollectionRoute parses road geometry', () {
      final route = CollectionRoute.fromJson(_collectionRouteJson(
        geometry: [
          [3.37, 6.45],
          [3.375, 6.455],
          [3.38, 6.46],
        ],
      ));
      expect(route.geometry, hasLength(3));
      expect(route.geometry!.first.longitude, 3.37);
      expect(route.geometrySource, 'road');
      expect(route.displayLine, hasLength(3));
    });

    test('CollectionRoute falls back without geometry', () {
      final route = CollectionRoute.fromJson(_collectionRouteJson());
      expect(route.geometry, isNull);
      expect(route.geometrySource, 'road');
      // Origin + one stop.
      expect(route.displayLine, hasLength(2));

      final legacy = CollectionRoute.fromJson({
        'truck_id': 't1',
        'origin': {
          'type': 'Point',
          'coordinates': [3.37, 6.45]
        },
        'stops': [],
      });
      expect(legacy.geometry, isNull);
      expect(legacy.geometrySource, 'straight');
      expect(legacy.displayLine, hasLength(1));
    });

    test('PlannedRoute parses geometry and depot order', () {
      final route = PlannedRoute.fromJson({
        'id': 'r1',
        'truck_id': 't1',
        'name': null,
        'origin': {
          'type': 'Point',
          'coordinates': [3.37, 6.45]
        },
        'stops': [],
        'status': 'assigned',
        'depot_ids': ['f2', 'f1'],
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [3.37, 6.45],
            [3.40, 6.47],
          ],
        },
        'geometry_source': 'road',
      });
      expect(route.depotIds, ['f2', 'f1']);
      expect(route.geometry, hasLength(2));
      expect(route.displayLine, hasLength(2));
    });

    test('lineStringFromJson rejects malformed shapes', () {
      expect(lineStringFromJson(null), isNull);
      expect(lineStringFromJson({'type': 'LineString'}), isNull);
      expect(lineStringFromJson({'coordinates': []}), isNull);
      expect(
        lineStringFromJson({
          'coordinates': [
            [3.37],
          ],
        }),
        isNull,
      );
      expect(lineStringFromJson('nope'), isNull);
    });
  });

  group('truck CRUD API clients', () {
    test('listTrucks gets the list path with filters', () async {
      Uri? seen;
      final api = TruckApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response(
            jsonEncode([_truckJson('t1', 'A', operatorId: 'u1')]),
            200,
          );
        }),
      ));
      final trucks = await api.listTrucks(availability: 'working');
      expect(seen!.path, '/api/v1/trucks');
      expect(seen!.queryParameters['availability'], 'working');
      expect(trucks, hasLength(1));
      expect(trucks.single.operatorId, 'u1');
    });

    test('updateTruck patches fields and propagates a 409 double-bind',
        () async {
      Map<String, dynamic>? seen;
      final api = TruckApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              jsonEncode(_truckJson('t1', 'B', operatorId: 'u2')), 200);
        }),
      ));
      final truck = await api.updateTruck(
        't1',
        plateNumber: 'B',
        operatorId: 'u2',
        operatorIdSet: true,
      );
      expect(seen, {'plate_number': 'B', 'operator_id': 'u2'});
      expect(truck.operatorId, 'u2');

      final conflicted = TruckApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode(
                  {'detail': 'collector already assigned to another truck'}),
              409,
            )),
      ));
      expect(
        conflicted.updateTruck('t1', operatorId: 'u2', operatorIdSet: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
      );
    });

    test('updateTruck sends an explicit null to unassign', () async {
      String? raw;
      final api = TruckApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          raw = request.body;
          return http.Response(jsonEncode(_truckJson('t1', 'A')), 200);
        }),
      ));
      final truck = await api.updateTruck('t1', operatorIdSet: true);
      expect(jsonDecode(raw!), {'operator_id': null});
      expect(truck.operatorId, isNull);
    });

    test('updateTruck propagates 404 and 422 operator errors', () async {
      TruckApi apiFor(int status, String detail) => TruckApi(ApiClient(
            baseUrl: 'http://x',
            httpClient: MockClient((_) async => http.Response(
                  jsonEncode({'detail': detail}),
                  status,
                )),
          ));
      expect(
        apiFor(404, 'operator user not found')
            .updateTruck('t1', operatorId: 'u9', operatorIdSet: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      expect(
        apiFor(422, 'operator must be a collector user')
            .updateTruck('t1', operatorId: 'u9', operatorIdSet: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 422)),
      );
    });

    test('deleteTruck deletes and propagates 409 and 404', () async {
      String? seen;
      final api = TruckApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = '${request.method} ${request.url.path}';
          return http.Response('', 204);
        }),
      ));
      await api.deleteTruck('t1');
      expect(seen, 'DELETE /api/v1/trucks/t1');

      TruckApi apiFor(int status, String detail) => TruckApi(ApiClient(
            baseUrl: 'http://x',
            httpClient: MockClient((_) async => http.Response(
                  jsonEncode({'detail': detail}),
                  status,
                )),
          ));
      expect(
        apiFor(409, 'truck has assigned routes').deleteTruck('t1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
      );
      expect(
        apiFor(404, 'truck not found').deleteTruck('t1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('deleteRoute deletes and propagates 404', () async {
      String? seen;
      final api = LogisticsApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = '${request.method} ${request.url.path}';
          return http.Response('', 204);
        }),
      ));
      await api.deleteRoute('r1');
      expect(seen, 'DELETE /api/v1/logistics/routes/r1');

      final missing = LogisticsApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'detail': 'route not found'}),
              404,
            )),
      ));
      expect(
        missing.deleteRoute('nope'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });
  });

  group('per-role landings', () {
    MockClient landingBackend() => MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/api/v1/trucks') {
            return http.Response('[]', 200);
          }
          if (request.method == 'GET' &&
              path == '/api/v1/logistics/garbage/summary') {
            return http.Response(
              jsonEncode({'total': 0, 'by_status': {}, 'by_type': {}}),
              200,
            );
          }
          return http.Response('not found', 404);
        });

    AuthProvider authFor(String role) => AuthProvider.withUser(
          _user(role),
          client: ApiClient(baseUrl: 'http://x', httpClient: landingBackend()),
        );

    testWidgets('collector lands directly on the collector screen',
        (tester) async {
      await tester
          .pumpWidget(_withAuth(authFor('collector'), const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Collector'), findsOneWidget);
      expect(find.text('No truck assigned'), findsOneWidget);
      expect(find.byTooltip('Sign out'), findsOneWidget);
    });

    testWidgets('logistics lands directly on the logistics screen',
        (tester) async {
      await tester
          .pumpWidget(_withAuth(authFor('logistics'), const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Logistics'), findsOneWidget);
      for (final tab in ['Overview', 'Trucks', 'Facilities', 'Routes']) {
        expect(find.text(tab), findsOneWidget);
      }
      expect(find.byTooltip('Sign out'), findsOneWidget);
    });

    testWidgets('admin keeps the tabbed overview', (tester) async {
      await tester.pumpWidget(_withAuth(authFor('admin'), const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      // No Collect tab: admins can never operate a truck, so it only ever
      // showed the unassigned empty state.
      for (final label in ['Home', 'Logistics', 'Users']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Collect'), findsNothing);
    });
  });

  group('collector assigned-truck widgets', () {
    final plates = {'t1': 'AAA-1', 't2': 'BBB-2', 't3': 'CCC-3'};

    MockClient collectorBackend(
      Map<String, String?> operators,
      List<String> calls, {
      int collectStatus = 200,
    }) =>
        MockClient((request) async {
          final path = request.url.path;
          calls.add('${request.method} $path');
          if (request.method == 'GET' && path == '/api/v1/trucks') {
            return http.Response(
              jsonEncode([
                for (final id in ['t1', 't2', 't3'])
                  _truckJson(id, plates[id]!, operatorId: operators[id]),
              ]),
              200,
            );
          }
          final detailMatch =
              RegExp(r'^/api/v1/trucks/([^/]+)$').firstMatch(path);
          if (request.method == 'GET' && detailMatch != null) {
            final id = detailMatch.group(1)!;
            return http.Response(
              jsonEncode(
                  _truckJson(id, plates[id]!, operatorId: operators[id])),
              200,
            );
          }
          if (request.method == 'GET' &&
              path == '/api/v1/trucks/t1/planned-route') {
            return http.Response(jsonEncode(_plannedTruckRouteJson()), 200);
          }
          if (request.method == 'POST' &&
              path == '/api/v1/trucks/t1/collect-vicinity') {
            if (collectStatus != 200) {
              return http.Response(
                jsonEncode({'detail': 'truck is not assigned to you'}),
                collectStatus,
              );
            }
            return http.Response(
              jsonEncode({
                'truck_id': 't1',
                'collected_count': 1,
                'post_ids': ['p1'],
                'load': 1,
                'capacity': 10,
                'availability': 'working',
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });

    AuthProvider collectorAuth(
      Map<String, String?> operators,
      List<String> calls, {
      int collectStatus = 200,
    }) =>
        AuthProvider.withUser(
          _user('collector'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: collectorBackend(
              operators,
              calls,
              collectStatus: collectStatus,
            ),
          ),
        );

    Future<void> pumpCollector(
      WidgetTester tester,
      AuthProvider auth,
    ) async {
      await tester.pumpWidget(_withAuth(
        auth,
        CollectorHomeScreen(tileProvider: _StubTileProvider()),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('assigned collector lands directly on the truck detail',
        (tester) async {
      final calls = <String>[];
      final operators = <String, String?>{'t1': 'u1', 't2': 'u9', 't3': null};
      await pumpCollector(tester, collectorAuth(operators, calls));
      expect(calls, contains('GET /api/v1/trucks'));
      // Detail content for the assigned truck, not a truck list.
      expect(find.text('AAA-1'), findsOneWidget);
      expect(find.text('BBB-2'), findsNothing);
      expect(find.text('CCC-3'), findsNothing);
      expect(find.text('Assigned to you'), findsOneWidget);
      for (final tab in ['Route', 'Collect']) {
        expect(find.text(tab), findsOneWidget);
      }
      // No claim UI anywhere.
      expect(find.widgetWithText(FilledButton, 'Claim'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Release'), findsNothing);
      expect(find.text('My truck'), findsNothing);
    });

    testWidgets('unassigned collector sees the empty state', (tester) async {
      final calls = <String>[];
      final operators = <String, String?>{'t1': 'u9', 't2': null, 't3': null};
      await pumpCollector(tester, collectorAuth(operators, calls));
      expect(find.text('No truck assigned'), findsOneWidget);
      expect(find.text('Ask logistics to assign you a truck.'), findsOneWidget);
      expect(find.text('AAA-1'), findsNothing);
      for (final tab in ['Route', 'Collect']) {
        expect(find.text(tab), findsNothing);
      }
    });

    testWidgets('collect 403 surfaces the server detail', (tester) async {
      final calls = <String>[];
      final operators = <String, String?>{'t1': 'u1'};
      await pumpCollector(
        tester,
        collectorAuth(operators, calls, collectStatus: 403),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.textContaining('Marks posted garbage'),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Collect vicinity'));
      await tester.pumpAndSettle();
      expect(find.text('truck is not assigned to you'), findsOneWidget);
    });
  });

  group('truck detail binding and road geometry', () {
    MockClient detailBackend(
      Map<String, String?> operators,
      List<String> calls, {
      List<List<double>>? geometry,
      int finishStatus = 200,
      String truckAvailability = 'working',
      List<double>? truckLocation,
      List<double>? sharedLocation,
      bool plannedEmptiesOnRefetch = false,
      bool plannedEmptyStops = false,
      bool noPlannedRoute = false,
      int? planTotalStops = 3,
      String planStatus = 'assigned',
      Map<String, dynamic>? collectBody,
    }) {
      var routeCalls = 0;
      var shared = false;
      var started = false;
      return MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        if (request.method == 'GET' && path == '/api/v1/trucks/t1') {
          return http.Response(
            jsonEncode(_truckJson('t1', 'AAA-1',
                operatorId: operators['t1'],
                availability: truckAvailability,
                location:
                    shared ? sharedLocation ?? truckLocation : truckLocation)),
            200,
          );
        }
        if (request.method == 'GET' &&
            path == '/api/v1/trucks/t1/planned-route') {
          routeCalls++;
          if (noPlannedRoute) {
            return http.Response(
              jsonEncode({'detail': 'no planned route for this truck'}),
              404,
            );
          }
          return http.Response(
              jsonEncode(_plannedTruckRouteJson(
                geometry: geometry,
                emptyStops: plannedEmptyStops ||
                    (plannedEmptiesOnRefetch && routeCalls > 1),
                totalStops: planTotalStops,
                planStatus: started ? 'in_progress' : planStatus,
              )),
              200);
        }
        if (request.method == 'POST' &&
            path == '/api/v1/trucks/t1/collect-vicinity') {
          if (request.body.isNotEmpty) {
            collectBody
                ?.addAll(jsonDecode(request.body) as Map<String, dynamic>);
          }
          return http.Response(
            jsonEncode({
              'truck_id': 't1',
              'collected_count': 1,
              'post_ids': ['p2'],
              'load': 1,
              'capacity': 10,
              'availability': 'working',
            }),
            200,
          );
        }
        if (request.method == 'GET' &&
            path == '/api/v1/trucks/t1/collect-candidates') {
          return http.Response(
            jsonEncode([
              _postJson('p1', 3.38, 6.46, 'Ojota'),
              _postJson('p2', 3.381, 6.461, 'Ikeja'),
            ]),
            200,
          );
        }
        if (request.method == 'POST' &&
            path == '/api/v1/trucks/t1/start-route') {
          started = true;
          return http.Response(
            jsonEncode(_truckJson('t1', 'AAA-1',
                operatorId: operators['t1'], availability: 'working')),
            200,
          );
        }
        if (request.method == 'POST' &&
            path == '/api/v1/trucks/t1/finish-route') {
          if (finishStatus != 200) {
            return http.Response(
              jsonEncode({'detail': 'truck is not assigned to you'}),
              finishStatus,
            );
          }
          return http.Response(
            jsonEncode(_truckJson('t1', 'AAA-1',
                operatorId: operators['t1'], availability: 'available')),
            200,
          );
        }
        if (request.method == 'POST' &&
            path == '/api/v1/trucks/t1/location' &&
            sharedLocation != null) {
          shared = true;
          return http.Response(
            jsonEncode(_truckJson('t1', 'AAA-1',
                operatorId: operators['t1'], location: sharedLocation)),
            200,
          );
        }
        return http.Response('not found', 404);
      });
    }

    AuthProvider detailAuth(
      Map<String, String?> operators,
      List<String> calls, {
      List<List<double>>? geometry,
      int finishStatus = 200,
      String truckAvailability = 'working',
      List<double>? truckLocation,
      List<double>? sharedLocation,
      bool plannedEmptiesOnRefetch = false,
      bool plannedEmptyStops = false,
      bool noPlannedRoute = false,
      int? planTotalStops = 3,
      String planStatus = 'assigned',
      Map<String, dynamic>? collectBody,
    }) =>
        AuthProvider.withUser(
          _user('collector'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: detailBackend(
              operators,
              calls,
              geometry: geometry,
              finishStatus: finishStatus,
              truckAvailability: truckAvailability,
              truckLocation: truckLocation,
              sharedLocation: sharedLocation,
              plannedEmptiesOnRefetch: plannedEmptiesOnRefetch,
              plannedEmptyStops: plannedEmptyStops,
              noPlannedRoute: noPlannedRoute,
              planTotalStops: planTotalStops,
              planStatus: planStatus,
              collectBody: collectBody,
            ),
          ),
        );

    Future<void> pumpDetail(
      WidgetTester tester,
      AuthProvider auth, {
      Future<Position> Function()? positionProvider,
    }) async {
      await tester.pumpWidget(_withAuth(
        auth,
        TruckDetailScreen(
          truckId: 't1',
          tileProvider: _StubTileProvider(),
          positionProvider: positionProvider,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('unassigned truck shows the binding banner and guards',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': null}, calls));
      expect(find.text('Unassigned'), findsOneWidget);
      expect(
        find.text('Logistics assigns an operator to this truck.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Claim'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Release'), findsNothing);

      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      expect(
        find.text('Only the assigned operator can collect on this truck.'),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      final collect = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Collect vicinity'),
      );
      expect(collect.onPressed, isNull);
    });

    testWidgets('assigned operator sees the share-location button',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      expect(find.text('Share my location'), findsOneWidget);
    });

    testWidgets('other collectors do not see the share-location button',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'c9'}, calls));
      expect(find.text('Share my location'), findsNothing);
    });

    testWidgets('share-location keeps the route and adds a live marker',
        (tester) async {
      // Tall screen so the route tab's loading placeholder fits below
      // the full header (location + share + banner). NOTE: physicalSize
      // is physical pixels and the test binding runs at DPR 3.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final calls = <String>[];
      final gps = Position(
        longitude: 9.9,
        latitude: 9.9,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
      await pumpDetail(
        tester,
        detailAuth(
          {'t1': 'u1'},
          calls,
          truckLocation: [3.37, 6.45],
          sharedLocation: [9.9, 9.9],
          // Any route refetch after the ping would come back with no
          // stops, reproducing the reported bug.
          plannedEmptiesOnRefetch: true,
        ),
        positionProvider: () async => gps,
      );
      List<MapMarkerData> markers() =>
          tester.widget<GarbageMapView>(find.byType(GarbageMapView)).markers;
      // Route loaded; the live marker is skipped while it coincides
      // with the origin.
      expect(find.textContaining('1 stops'), findsOneWidget);
      expect(markers(), hasLength(3));

      await tester.tap(find.text('Share my location'));
      await tester.pumpAndSettle();

      // The ping lands: header shows the new position.
      expect(find.textContaining('Truck location updated'), findsOneWidget);
      expect(find.text('9.9000, 9.9000'), findsOneWidget);
      // The loaded route is untouched: no refetch, no empty state.
      expect(find.textContaining('1 stops'), findsOneWidget);
      expect(find.text('No stops on this route.'), findsNothing);
      expect(
        calls.where((c) => c == 'GET /api/v1/trucks/t1/planned-route'),
        hasLength(1),
      );
      expect(
        calls.where((c) => c == 'GET /api/v1/trucks/t1'),
        hasLength(1),
      );
      expect(calls, contains('POST /api/v1/trucks/t1/location'));
      // ...and the ping shows as its own marker next to the origin pin.
      final after = markers();
      expect(after, hasLength(4));
      expect(after.any((m) => m.label == 'Origin'), isTrue);
      expect(
        after.any((m) =>
            m.label == 'Current location' &&
            m.point.longitude == 9.9 &&
            m.point.latitude == 9.9),
        isTrue,
      );
      // The origin pin is distinct; the truck icon marks the live position.
      expect(
        after.firstWhere((m) => m.label == 'Origin').icon,
        Icons.trip_origin,
      );
      expect(
        after.firstWhere((m) => m.label == 'Current location').icon,
        Icons.local_shipping,
      );
    });

    testWidgets('assigned truck enables collect and status', (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      expect(find.text('Assigned to you'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Release'), findsNothing);

      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      expect(
        find.text('Only the assigned operator can collect on this truck.'),
        findsNothing,
      );
      // Drag from the header text so the map below never swallows the scroll.
      await tester.drag(
        find.textContaining('Marks posted garbage'),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      final collect = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Collect vicinity'),
      );
      expect(collect.onPressed, isNotNull);
    });

    testWidgets('collect radius defaults to 30 meters', (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(TextField));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '30');
    });

    testWidgets('collect tab prefills the collector GPS position',
        (tester) async {
      Position gps() => Position(
            longitude: 9.9,
            latitude: 9.9,
            timestamp: DateTime.fromMillisecondsSinceEpoch(0),
            accuracy: 5,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          );
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls),
        positionProvider: () async => gps(),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      // The progress header pushes the position row below the fold, so
      // scroll it into view (this also builds it) before asserting.
      await _scrollTo(tester, find.text('Use truck location'));
      expect(find.text('Use truck location'), findsOneWidget);
      await _scrollTo(tester, find.text('Picked: 9.9000, 9.9000'));
      expect(find.text('Picked: 9.9000, 9.9000'), findsOneWidget);

      // Clearing falls back to the truck location.
      await _scrollTo(tester, find.text('Use truck location'));
      await tester.tap(find.text('Use truck location'));
      await tester.pumpAndSettle();
      expect(
        find.text('Tap the map to pick a location, or use GPS.'),
        findsOneWidget,
      );
      expect(find.text('Use truck location'), findsNothing);
    });

    testWidgets('collect tab keeps truck fallback when GPS fails',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls),
        positionProvider: () async => throw StateError('denied'),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(
          tester, find.text('Tap the map to pick a location, or use GPS.'));
      expect(
        find.text('Tap the map to pick a location, or use GPS.'),
        findsOneWidget,
      );
      expect(find.text('Use truck location'), findsNothing);
    });

    testWidgets('preview shows nearby posts before collecting', (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Preview nearby'));
      await tester.tap(find.text('Preview nearby'));
      await tester.pumpAndSettle();
      expect(find.text('2 posts within 30 m:'), findsOneWidget);
      expect(find.textContaining('Ojota'), findsOneWidget);
      await _scrollTo(tester, find.textContaining('Ikeja'));
      expect(find.textContaining('Ikeja'), findsOneWidget);
      expect(
        calls,
        contains('GET /api/v1/trucks/t1/collect-candidates'),
      );
    });

    testWidgets('collect tab shows run progress with live distance',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, truckLocation: [3.37, 6.45]),
        positionProvider: () async => throw StateError('denied'),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      expect(find.text('Run progress'), findsOneWidget);
      // One remaining stop of three: two collected.
      expect(find.text('Collected 2 of 3'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final expected = formatDistance(metersBetween(
        GeoPoint(longitude: 3.37, latitude: 6.45),
        GeoPoint(longitude: 3.38, latitude: 6.46),
      ));
      expect(find.text('Next: Plastic · $expected'), findsOneWidget);
    });

    testWidgets('progress falls back without total or position',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, planTotalStops: null),
        positionProvider: () async => throw StateError('denied'),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      expect(find.text('1 stop to go'), findsOneWidget);
      expect(find.text('Next: Plastic'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('progress shows the no-run state without a plan',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, noPlannedRoute: true),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      expect(
        find.text(
            'No active run for this truck. Collects outside a run still work.'),
        findsOneWidget,
      );
    });

    testWidgets('candidates sort nearest-first with per-post collect',
        (tester) async {
      final calls = <String>[];
      final collectBody = <String, dynamic>{};
      Position gps() => Position(
            longitude: 3.381,
            latitude: 6.461,
            timestamp: DateTime.fromMillisecondsSinceEpoch(0),
            accuracy: 5,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          );
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, collectBody: collectBody),
        positionProvider: () async => gps(),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Preview nearby'));
      await tester.tap(find.text('Preview nearby'));
      await tester.pumpAndSettle();
      // The fix sits exactly on Ikeja; Ojota is ~160 m off and sorts last.
      final ojotaMeters = formatDistance(metersBetween(
        GeoPoint(longitude: 3.381, latitude: 6.461),
        GeoPoint(longitude: 3.38, latitude: 6.46),
      ));
      // Scroll the last tile into view first: the list builds lazily, so
      // the Ojota subtitle does not exist until it is on screen.
      await _scrollTo(tester, find.textContaining('Ojota'));
      expect(find.text('0 m · Posted · Ikeja'), findsOneWidget);
      expect(
        find.text('$ojotaMeters · Posted · Ojota'),
        findsOneWidget,
      );
      final ikejaDy = tester.getCenter(find.textContaining('Ikeja')).dy;
      final ojotaDy = tester.getCenter(find.textContaining('Ojota')).dy;
      expect(ikejaDy, lessThan(ojotaDy));

      // One tap collects around the Ikeja post with the current radius.
      final tile = find.ancestor(
        of: find.textContaining('Ikeja'),
        matching: find.byType(Card),
      );
      await _scrollTo(tester, tile);
      await tester.tap(find.descendant(
        of: tile,
        matching: find.widgetWithText(FilledButton, 'Collect'),
      ));
      await tester.pumpAndSettle();
      expect(collectBody['longitude'], 3.381);
      expect(collectBody['latitude'], 6.461);
      expect(collectBody['radius_meters'], 30);
      expect(calls, contains('POST /api/v1/trucks/t1/collect-vicinity'));
      // The preview clears and the result lands.
      expect(find.text('2 posts within 30 m:'), findsNothing);
      expect(find.text('Result'), findsOneWidget);
    });

    testWidgets('collect map shows the run line and numbered stops',
        (tester) async {
      Finder tip(String message) => find.descendant(
            of: find.byType(LocationMapPicker),
            matching: find.byWidgetPredicate(
              (w) => w is Tooltip && w.message == message,
            ),
          );
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls),
        positionProvider: () async => throw StateError('denied'),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(LocationMapPicker));

      // The one remaining stop renders numbered, in run order.
      expect(find.byType(NumberedMapPin), findsOneWidget);
      expect(tip('Stop 1: Plastic'), findsOneWidget);
      expect(tip('Origin'), findsOneWidget);
      expect(tip('Depot: North Depot'), findsOneWidget);
      // Straight fallback: origin straight to the stop.
      final layers = tester
          .widgetList<PolylineLayer>(find.descendant(
            of: find.byType(LocationMapPicker),
            matching: find.byType(PolylineLayer),
          ))
          .toList();
      expect(layers, hasLength(1));
      expect(
        layers.single.polylines.single.points,
        [
          GeoPoint(longitude: 3.37, latitude: 6.45).latLng,
          GeoPoint(longitude: 3.38, latitude: 6.46).latLng,
        ],
      );
    });

    testWidgets('collect map marks only unscheduled candidates',
        (tester) async {
      Finder tip(String message) => find.descendant(
            of: find.byType(LocationMapPicker),
            matching: find.byWidgetPredicate(
              (w) => w is Tooltip && w.message == message,
            ),
          );
      Position gps() => Position(
            longitude: 3.381,
            latitude: 6.461,
            timestamp: DateTime.fromMillisecondsSinceEpoch(0),
            accuracy: 5,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          );
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls),
        positionProvider: () async => gps(),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Preview nearby'));
      await tester.tap(find.text('Preview nearby'));
      await tester.pumpAndSettle();

      // Ikeja is unscheduled: plain candidate pin. Ojota is stop 1, so it
      // keeps only its numbered pin instead of doubling up.
      await _scrollTo(tester, find.byType(LocationMapPicker));
      expect(tip('Plastic · Ikeja'), findsOneWidget);
      expect(tip('Plastic · Ojota'), findsNothing);
      expect(find.byType(NumberedMapPin), findsOneWidget);
      // A live position means no truck-fallback pin.
      expect(tip('Truck location'), findsNothing);
    });

    testWidgets('collect map shows the truck fallback pin without a position',
        (tester) async {
      Finder tip(String message) => find.descendant(
            of: find.byType(LocationMapPicker),
            matching: find.byWidgetPredicate(
              (w) => w is Tooltip && w.message == message,
            ),
          );
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, truckLocation: [3.35, 6.44]),
        positionProvider: () async => throw StateError('denied'),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(LocationMapPicker));
      expect(tip('Truck location'), findsOneWidget);
      // The run layers still render underneath.
      expect(find.byType(NumberedMapPin), findsOneWidget);
    });

    testWidgets('collect map shows the live coverage circle', (tester) async {
      CircleMarker circle() => tester
          .widgetList<CircleLayer>(find.descendant(
            of: find.byType(LocationMapPicker),
            matching: find.byType(CircleLayer),
          ))
          .single
          .circles
          .single;
      Position gps() => Position(
            longitude: 3.381,
            latitude: 6.461,
            timestamp: DateTime.fromMillisecondsSinceEpoch(0),
            accuracy: 5,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          );
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls),
        positionProvider: () async => gps(),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(LocationMapPicker));

      // Centered on the fix with the default 30 m radius.
      expect(
        circle().point,
        GeoPoint(longitude: 3.381, latitude: 6.461).latLng,
      );
      expect(circle().radius, 30);

      // Typing a new radius resizes the circle without previewing.
      await _scrollTo(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), '50');
      await tester.pumpAndSettle();
      expect(circle().radius, 50);

      // Invalid text hides the circle instead of erroring.
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(LocationMapPicker),
          matching: find.byType(CircleLayer),
        ),
        findsNothing,
      );
    });

    testWidgets('collect map hides the circle without a center',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls),
        positionProvider: () async => throw StateError('denied'),
      );
      await tester.tap(find.text('Collect'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(LocationMapPicker));
      // No fix and the truck reports no location: nothing to center on.
      expect(
        find.descendant(
          of: find.byType(LocationMapPicker),
          matching: find.byType(CircleLayer),
        ),
        findsNothing,
      );
    });

    testWidgets('finish run posts and frees the truck', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, planStatus: 'in_progress'),
      );
      expect(
        find.text('1 stops · 1 depot(s) · 25 Dec 2026'),
        findsOneWidget,
      );
      await tester.tap(find.text('Finish run'));
      await tester.pumpAndSettle();
      expect(find.text('Finish run?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
      await tester.pumpAndSettle();
      expect(calls, contains('POST /api/v1/trucks/t1/finish-route'));
      expect(find.text('Run finished. Truck is Available.'), findsOneWidget);
      // The truck is unscheduled, so the button goes away.
      expect(find.text('Finish run'), findsNothing);
    });

    testWidgets('finish run cancel sends nothing', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, planStatus: 'in_progress'),
      );
      await tester.tap(find.text('Finish run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('POST /api/v1/trucks/t1/finish-route')));
    });

    testWidgets('finish 403 surfaces the server detail', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls,
            finishStatus: 403, planStatus: 'in_progress'),
      );
      await tester.tap(find.text('Finish run'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
      await tester.pumpAndSettle();
      expect(find.text('truck is not assigned to you'), findsOneWidget);
    });

    testWidgets('start run posts and flips the button to finish',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      expect(find.text('Start run'), findsOneWidget);
      expect(find.text('Finish run'), findsNothing);

      await tester.tap(find.text('Start run'));
      await tester.pumpAndSettle();
      expect(find.text('Start run?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      expect(calls, contains('POST /api/v1/trucks/t1/start-route'));
      expect(find.text('Run started.'), findsOneWidget);
      // The refetched plan is in progress, so the slot flips to Finish.
      expect(find.text('Start run'), findsNothing);
      expect(find.text('Finish run'), findsOneWidget);
    });

    testWidgets('start run cancel sends nothing', (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      await tester.tap(find.text('Start run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('POST /api/v1/trucks/t1/start-route')));
      expect(find.text('Start run'), findsOneWidget);
    });

    testWidgets('finish shows when the run status is unknown', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, noPlannedRoute: true),
      );
      expect(find.text('Finish run'), findsOneWidget);
      expect(find.text('Start run'), findsNothing);
    });

    testWidgets('finish run hides on an unscheduled truck', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, truckAvailability: 'available'),
      );
      expect(find.text('Finish run'), findsNothing);
    });

    testWidgets('route map draws road geometry when present', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls,
            geometry: [
              [3.37, 6.45],
              [3.371, 6.451],
              [3.375, 6.455],
              [3.38, 6.46],
            ]),
      );
      final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(layer.polylines, hasLength(1));
      expect(layer.polylines.single.points, hasLength(4));
    });

    testWidgets('route map falls back to straight lines', (tester) async {
      final calls = <String>[];
      await pumpDetail(tester, detailAuth({'t1': 'u1'}, calls));
      final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(layer.polylines, hasLength(1));
      // Origin + one stop.
      expect(layer.polylines.single.points, hasLength(2));
    });

    testWidgets('empty route still shows the map with the origin',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth(
          {'t1': 'u1'},
          calls,
          truckLocation: [3.37, 6.45],
          plannedEmptyStops: true,
        ),
      );
      expect(find.byType(GarbageMapView), findsOneWidget);
      final markers =
          tester.widget<GarbageMapView>(find.byType(GarbageMapView)).markers;
      // Origin + depot pins render; the live pin is skipped while it
      // coincides with the origin.
      expect(
        markers.map((m) => m.label),
        containsAll(['Origin', 'Depot: North Depot']),
      );
      expect(
        markers.firstWhere((m) => m.label == 'Origin').icon,
        Icons.trip_origin,
      );
      // The empty notice sits below the map; scroll it into view so the
      // lazily built list item exists.
      await _scrollTo(tester, find.text('No stops on this route.'));
      expect(find.text('No stops on this route.'), findsOneWidget);
    });

    testWidgets('truck without a plan shows the unassigned empty state',
        (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, noPlannedRoute: true),
      );
      expect(find.text('No route assigned.'), findsOneWidget);
      expect(find.byType(GarbageMapView), findsNothing);
    });

    testWidgets('assigned route shows the depot end card', (tester) async {
      final calls = <String>[];
      await pumpDetail(
        tester,
        detailAuth({'t1': 'u1'}, calls, truckLocation: [3.37, 6.45]),
      );
      expect(find.text('Morning run'), findsOneWidget);
      expect(find.byTooltip('Depot: North Depot'), findsOneWidget);
      // The end card sits below the stop list; scroll it into view so the
      // lazily built list item exists.
      await _scrollTo(tester, find.text('Ends at North Depot'));
      expect(find.text('Ends at North Depot'), findsOneWidget);
    });
  });

  group('polygon route creation', () {
    Map<String, dynamic> facilityJson(
            String id, String name, String kind, double lng, double lat) =>
        {
          'id': id,
          'name': name,
          'kind': kind,
          'location': {
            'type': 'Point',
            'coordinates': [lng, lat]
          },
          'accepted_types': ['plastic'],
          'address': null,
          'created_at': '2026-10-29T00:00:00Z',
          'updated_at': '2026-10-29T00:00:00Z',
        };

    MockClient routeBackend({
      required List<Map<String, dynamic>> posts,
      required List<Map<String, dynamic>> facilities,
      List<double>? truckLocation,
      Map<String, dynamic>? Function()? onRouteBody,
    }) =>
        MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/api/v1/trucks') {
            return http.Response(
              jsonEncode([
                {
                  'id': 't1',
                  'plate_number': 'ABC-123',
                  'status': 'scheduled',
                  'availability': 'available',
                  'garbage_types': ['plastic', 'paper'],
                  'current_location': truckLocation == null
                      ? null
                      : {
                          'type': 'Point',
                          'coordinates': truckLocation,
                        },
                  'load': 0,
                  'capacity': 10,
                }
              ]),
              200,
            );
          }
          if (request.method == 'GET' &&
              path == '/api/v1/logistics/facilities') {
            return http.Response(jsonEncode(facilities), 200);
          }
          if (request.method == 'GET' && path == '/api/v1/logistics/garbage') {
            return http.Response(jsonEncode(posts), 200);
          }
          if (request.method == 'POST' && path == '/api/v1/logistics/routes') {
            onRouteBody
                ?.call()
                ?.addAll(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'id': 'r1',
                'truck_id': 't1',
                'name': null,
                'origin': {
                  'type': 'Point',
                  'coordinates': [3.37, 6.45]
                },
                'stops': [],
                'status': 'assigned',
                'created_at': '2026-10-29T00:00:00Z',
                'depot_ids': ['f1'],
                'collection_points': [],
              }),
              200,
            );
          }
          return http.Response('not found: $path', 404);
        });

    AuthProvider routeAuth(MockClient backend) => AuthProvider.withUser(
          _user('logistics', country: 'Nigeria'),
          client: ApiClient(baseUrl: 'http://x', httpClient: backend),
        );

    Future<void> selectTruck(WidgetTester tester) async {
      await _scrollTo(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ABC-123 (Available)').last);
      await tester.pumpAndSettle();
    }

    /// Jumps to a step by tapping its header. `.first` disambiguates the
    /// header (headers precede contents in tree order) from same-named
    /// review rows (InfoRow labels 'Depots'/'Stops') when review is open.
    Future<void> goToStep(WidgetTester tester, String title) async {
      await _scrollTo(tester, find.text(title));
      await tester.tap(find.text(title).first);
      await tester.pumpAndSettle();
    }

    Future<void> tapMap(WidgetTester tester, Offset at) async {
      await tester.tapAt(at);
      // Single taps wait out the double-tap timeout.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    testWidgets('drawn area selects enclosed posts and submits them',
        (tester) async {
      final submitted = <String, dynamic>{};
      final auth = routeAuth(routeBackend(
        posts: [
          _postJson('p1', 3.37, 6.45, 'Ojota'),
          _postJson('p2', 3.60, 6.80, 'Ikeja'),
        ],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        onRouteBody: () => submitted,
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Depots');
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();

      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.text('Draw area'));
      await tester.tap(find.text('Draw area'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(FlutterMap));

      // Box around p1's pin; p2 stays far outside.
      final center = tester.getCenter(find.byTooltip('Plastic · Ojota'));
      for (final corner in [
        center + const Offset(-30, -30),
        center + const Offset(30, -30),
        center + const Offset(30, 30),
        center + const Offset(-30, 30),
      ]) {
        await tapMap(tester, corner);
      }
      expect(find.text('4 vertices · 1 posts inside'), findsOneWidget);

      await _scrollTo(tester, find.text('Close shape'));
      await tester.tap(find.text('Close shape'));
      await tester.pumpAndSettle();

      await goToStep(tester, 'Review');
      // The stops subtitle and the review row agree on the manual set.
      expect(find.text('Manual · 1 posts'), findsNWidgets(2));
      expect(find.text('North Depot · End'), findsOneWidget);
      await _scrollTo(tester, find.text('Assign route'));
      await tester.tap(find.text('Assign route'));
      await tester.pumpAndSettle();

      expect(submitted['truck_id'], 't1');
      expect(submitted['depot_ids'], ['f1']);
      expect(submitted['post_ids'], ['p1']);
      // Placed pins are gone from creation; the body carries stops only.
      expect(submitted.containsKey('collection_points'), isFalse);
    });

    testWidgets('continue validates each step in order', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [_postJson('p1', 3.37, 6.45, 'Ojota')],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        truckLocation: [3.10, 6.10],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();

      // Step 1 needs a truck.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Pick a truck'), findsOneWidget);
      expect(find.text('Depots (pick at least one)'), findsNothing);
      // Expire the snackbar so the next error shows immediately.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await selectTruck(tester);
      // The header subtitles the picked plate (scroll it back into view:
      // the dropdown menu left it outside the lazy viewport).
      await goToStep(tester, 'Truck & day');
      expect(find.text('ABC-123'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Depots (pick at least one)'), findsOneWidget);

      // Step 2 needs a depot.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Pick at least one depot'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Posted garbage'), findsOneWidget);

      // Step 3 passes with the default auto selection; review summarizes.
      await _scrollTo(tester, find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('ABC-123 (Available)'), findsOneWidget);
      expect(find.text(formatDay(todayDay())), findsOneWidget);
      expect(find.text('North Depot · End'), findsOneWidget);
      expect(
        find.text('Auto · Plastic, Paper · within 5 km of ABC-123'),
        findsOneWidget,
      );

      // Back returns to the stops step.
      await _scrollTo(tester, find.text('Back'));
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Posted garbage'), findsOneWidget);
      expect(find.text('North Depot · End'), findsNothing);
    });

    testWidgets('scheduled day picker lands in the submit body',
        (tester) async {
      final submitted = <String, dynamic>{};
      final auth = routeAuth(routeBackend(
        posts: [],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        truckLocation: [3.10, 6.10],
        onRouteBody: () => submitted,
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Depots');
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();

      // New routes default to today.
      await goToStep(tester, 'Truck & day');
      expect(find.text('Scheduled day'), findsOneWidget);
      expect(find.text(formatDay(todayDay())), findsOneWidget);

      // Pick the 15th of next month: always a valid future day.
      await tester.tap(find.text('Scheduled day'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_right).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final today = todayDay();
      final expected = DateTime(today.year, today.month + 1, 15);
      expect(find.text(formatDay(expected)), findsOneWidget);

      await goToStep(tester, 'Review');
      await _scrollTo(tester, find.text('Assign route'));
      await tester.tap(find.text('Assign route'));
      await tester.pumpAndSettle();
      expect(submitted['scheduled_for'], toIsoDay(expected));
    });

    testWidgets('last-selected depot is the labeled route end', (tester) async {
      final submitted = <String, dynamic>{};
      final auth = routeAuth(routeBackend(
        posts: [],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30),
          facilityJson('f2', 'East Recycler', 'recycling', 3.65, 6.85),
        ],
        truckLocation: [3.10, 6.10],
        onRouteBody: () => submitted,
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Depots');
      await _scrollTo(tester, find.text('East Recycler (Recycling)'));
      await tester.tap(find.text('East Recycler (Recycling)'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();

      // The last pick carries the End label; order is preserved.
      expect(find.text('North Depot (Dump Site) · End'), findsOneWidget);
      expect(find.text('East Recycler (Recycling)'), findsOneWidget);

      await goToStep(tester, 'Review');
      await _scrollTo(tester, find.text('Assign route'));
      await tester.tap(find.text('Assign route'));
      await tester.pumpAndSettle();
      expect(submitted['depot_ids'], ['f2', 'f1']);
    });

    testWidgets('route start and end pins render on the map', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [
          _postJson('p1', 3.37, 6.45, 'Ojota'),
          _postJson('p2', 3.60, 6.80, 'Ikeja'),
        ],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        truckLocation: [3.10, 6.10],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Depots');
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();

      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(FlutterMap));
      expect(find.byTooltip('Start: truck position'), findsOneWidget);
      expect(find.byTooltip('End: North Depot'), findsOneWidget);
    });

    testWidgets('pin tap in auto mode flips to manual and selects',
        (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [
          _postJson('p1', 3.37, 6.45, 'Ojota'),
          _postJson('p2', 3.60, 6.80, 'Ikeja'),
        ],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(FlutterMap));
      // Far-apart posts render as single pins at the fitted zoom.
      expect(find.byType(MapPin), findsNWidgets(2));
      expect(
        find.text('Tip: tap a map pin to hand-pick that stop.'),
        findsOneWidget,
      );

      // Auto is on by default; the tap must count, not just highlight.
      await tester.tap(find.byType(MapPin).first);
      await tester.pumpAndSettle();
      final autoSwitch = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Auto-generate stops'),
      );
      expect(autoSwitch.value, isFalse);
      await _scrollTo(tester, find.byType(CheckboxListTile));
      final tiles = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      expect(tiles.where((t) => t.value == true), hasLength(1));

      // Review counts the hand-picked stop.
      await goToStep(tester, 'Review');
      expect(find.text('Manual · 1 posts'), findsNWidgets(2));
    });

    testWidgets('auto review discloses ignored hand-picks', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [
          _postJson('p1', 3.37, 6.45, 'Ojota'),
          _postJson('p2', 3.60, 6.80, 'Ikeja'),
        ],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(FlutterMap));
      await tester.tap(find.byType(MapPin).first);
      await tester.pumpAndSettle();

      // Flipping back to auto keeps the pick but auto wins at submit.
      await _scrollTo(
          tester, find.widgetWithText(SwitchListTile, 'Auto-generate stops'));
      await tester
          .tap(find.widgetWithText(SwitchListTile, 'Auto-generate stops'));
      await tester.pumpAndSettle();
      await goToStep(tester, 'Review');
      expect(
        find.text(
          'Auto · Plastic, Paper · ABC-123 has no position · 1 picked posts ignored',
        ),
        findsOneWidget,
      );
    });

    testWidgets('auto mode draws the inclusion zone on the stops map',
        (tester) async {
      CircleMarker circle() => tester
          .widgetList<CircleLayer>(find.byType(CircleLayer))
          .single
          .circles
          .single;
      final auth = routeAuth(routeBackend(
        posts: [
          _postJson('p1', 3.37, 6.45, 'Ojota'),
          _postJson('p2', 3.60, 6.80, 'Ikeja'),
        ],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        truckLocation: [3.10, 6.10],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(FlutterMap));

      expect(find.byType(CircleLayer), findsOneWidget);
      expect(
        circle().point,
        GeoPoint(longitude: 3.10, latitude: 6.10).latLng,
      );
      expect(circle().radius, autoGenerateMeters);
      expect(circle().useRadiusInMeter, isTrue);

      // Manual picks need no zone: flipping auto off hides it.
      await _scrollTo(
          tester, find.widgetWithText(SwitchListTile, 'Auto-generate stops'));
      await tester
          .tap(find.widgetWithText(SwitchListTile, 'Auto-generate stops'));
      await tester.pumpAndSettle();
      expect(find.byType(CircleLayer), findsNothing);
    });

    testWidgets('stops copy asks for a truck before centering', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [_postJson('p1', 3.37, 6.45, 'Ojota')],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await goToStep(tester, 'Stops');
      expect(find.text('Auto · pick a truck first'), findsOneWidget);
      expect(
        find.text('Pick a truck so auto has a start point'),
        findsOneWidget,
      );
    });

    testWidgets('stops copy states the auto radius and center', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [_postJson('p1', 3.37, 6.45, 'Ojota')],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        truckLocation: [3.10, 6.10],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Stops');
      expect(
        find.text('Auto · within 5 km of ABC-123'),
        findsOneWidget,
      );
      expect(
        find.text('Nearest matching posts within 5 km of ABC-123'),
        findsOneWidget,
      );
    });

    testWidgets('stops copy names the missing truck position', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [_postJson('p1', 3.37, 6.45, 'Ojota')],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Stops');
      expect(
        find.text('Auto · ABC-123 has no position'),
        findsOneWidget,
      );
      expect(
        find.text('Needs ABC-123\u2019s position to center on'),
        findsOneWidget,
      );
    });

    testWidgets('auto without a truck position warns and blocks submit',
        (tester) async {
      final submitted = <String, dynamic>{};
      final auth = routeAuth(routeBackend(
        posts: [_postJson('p1', 3.37, 6.45, 'Ojota')],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
        onRouteBody: () => submitted,
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await selectTruck(tester);
      await goToStep(tester, 'Depots');
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();

      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.textContaining('has no position yet'));
      expect(
        find.text(
          'ABC-123 has no position yet. Auto-generate centers on the truck — have the collector share its location, or switch auto off and hand-pick.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CircleLayer), findsNothing);

      // The step gate stops Continue with the actionable message.
      await _scrollTo(tester, find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'ABC-123 has no position yet — auto-generate centers on the truck',
        ),
        findsOneWidget,
      );

      // Submit is guarded the same way: nothing posts.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await goToStep(tester, 'Review');
      await _scrollTo(tester, find.text('Assign route'));
      await tester.tap(find.text('Assign route'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'ABC-123 has no position yet — auto-generate centers on the truck',
        ),
        findsOneWidget,
      );
      expect(submitted, isEmpty);
    });

    testWidgets('undo and clear edit the drawn area', (tester) async {
      final auth = routeAuth(routeBackend(
        posts: [_postJson('p1', 3.37, 6.45, 'Ojota')],
        facilities: [
          facilityJson('f1', 'North Depot', 'dump_site', 3.20, 6.30)
        ],
      ));
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await goToStep(tester, 'Stops');
      await _scrollTo(tester, find.text('Draw area'));
      await tester.tap(find.text('Draw area'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(FlutterMap));

      await tester.tap(find.byType(FlutterMap));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('1 vertices · 0 posts inside'), findsOneWidget);
      final close = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Close shape'),
      );
      expect(close.onPressed, isNull);

      await _scrollTo(tester, find.text('Undo'));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('vertices'), findsNothing);
    });
  });

  group('routes tab', () {
    Map<String, dynamic> plannedRouteJson(String id, String name) => {
          'id': id,
          'truck_id': 't1',
          'name': name,
          'origin': {
            'type': 'Point',
            'coordinates': [3.37, 6.45]
          },
          'stops': [
            {
              'post_id': 'p1',
              'location': {
                'type': 'Point',
                'coordinates': [3.38, 6.46]
              },
              'types': ['plastic'],
              'distance_meters': 100.0,
            },
          ],
          'status': 'assigned',
          'scheduled_for': '2026-12-25',
          'created_at': '2026-10-29T00:00:00Z',
          'depot_ids': ['f1'],
          'collection_points': [],
        };

    Map<String, dynamic> collectorJson(String id, String name) => {
          'id': id,
          'email': '$id@example.com',
          'full_name': name,
          'role': 'collector',
          'is_active': true,
          'country': null,
        };

    MockClient logisticsBackend(
      List<Map<String, dynamic>> routes,
      List<String> calls, {
      int deleteStatus = 204,
      List<Map<String, dynamic>> facilities = const [],
      Map<String, dynamic>? truck,
      List<Map<String, dynamic>> collectors = const [],
      int usersFailTimes = 0,
    }) {
      var usersCalls = 0;
      return MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        if (request.method == 'GET' && path == '/api/v1/logistics/routes') {
          return http.Response(jsonEncode(routes), 200);
        }
        if (request.method == 'GET' && path == '/api/v1/logistics/facilities') {
          return http.Response(jsonEncode(facilities), 200);
        }
        if (request.method == 'GET' && path == '/api/v1/trucks/t1') {
          if (truck == null) return http.Response('not found', 404);
          return http.Response(jsonEncode(truck), 200);
        }
        if (request.method == 'GET' && path == '/api/v1/auth/users') {
          usersCalls++;
          if (usersCalls <= usersFailTimes) {
            return http.Response(jsonEncode({'detail': 'boom'}), 500);
          }
          return http.Response(jsonEncode(collectors), 200);
        }
        if (request.method == 'DELETE' &&
            path == '/api/v1/logistics/routes/r1') {
          if (deleteStatus != 204) {
            return http.Response(
              jsonEncode({'detail': 'route not found'}),
              deleteStatus,
            );
          }
          routes.clear();
          return http.Response('', 204);
        }
        return http.Response('not found', 404);
      });
    }

    AuthProvider logisticsAuth(
      List<Map<String, dynamic>> routes,
      List<String> calls, {
      int deleteStatus = 204,
      List<Map<String, dynamic>> facilities = const [],
      Map<String, dynamic>? truck,
      List<Map<String, dynamic>> collectors = const [],
      int usersFailTimes = 0,
    }) =>
        AuthProvider.withUser(
          _user('logistics'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: logisticsBackend(
              routes,
              calls,
              deleteStatus: deleteStatus,
              facilities: facilities,
              truck: truck,
              collectors: collectors,
              usersFailTimes: usersFailTimes,
            ),
          ),
        );

    Future<void> openRoutesTab(
      WidgetTester tester,
      AuthProvider auth,
    ) async {
      await tester.pumpWidget(_withAuth(
        auth,
        LogisticsHomeScreen(tileProvider: _StubTileProvider()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Routes'));
      await tester.pumpAndSettle();
    }

    testWidgets('delete confirms, deletes, and reloads', (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      await openRoutesTab(tester, logisticsAuth(routes, calls));
      expect(find.text('Morning run'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete route'));
      await tester.pumpAndSettle();
      expect(find.text('Delete route?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.startsWith('DELETE')), isEmpty);

      await tester.tap(find.byTooltip('Delete route'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Route deleted'), findsOneWidget);
      expect(calls, contains('DELETE /api/v1/logistics/routes/r1'));
      expect(find.text('No routes yet.'), findsOneWidget);
    });

    testWidgets('delete 404 surfaces route-not-found and reloads',
        (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      await openRoutesTab(
          tester, logisticsAuth(routes, calls, deleteStatus: 404));
      await tester.tap(find.byTooltip('Delete route'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Route not found'), findsOneWidget);
    });

    testWidgets('list shows route previews instead of a map', (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      await openRoutesTab(tester, logisticsAuth(routes, calls));
      expect(find.text('Morning run'), findsOneWidget);
      expect(find.byType(RouteGraphPreview), findsOneWidget);
      expect(find.byType(GarbageMapView), findsNothing);
    });

    testWidgets('tapping a route opens the detail map', (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      final auth = logisticsAuth(
        routes,
        calls,
        facilities: [
          {
            'id': 'f1',
            'name': 'North Depot',
            'kind': 'dump_site',
            'location': {
              'type': 'Point',
              'coordinates': [3.20, 6.30]
            },
            'accepted_types': ['plastic'],
            'address': null,
            'created_at': '2026-10-29T00:00:00Z',
            'updated_at': '2026-10-29T00:00:00Z',
          }
        ],
      );
      await openRoutesTab(tester, auth);
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();
      expect(find.byType(RouteDetailScreen), findsOneWidget);
      expect(find.byType(GarbageMapView), findsOneWidget);
      expect(find.text('Stops (1)'), findsOneWidget);
      // Origin + stop + depot pins render on the layered map (the truck
      // lookup 404s here, so no live position pin is added).
      expect(find.byType(MapPin), findsNWidgets(3));
      expect(find.byTooltip('Origin'), findsOneWidget);
      expect(find.byTooltip('Depot: North Depot'), findsOneWidget);
      final markers =
          tester.widget<GarbageMapView>(find.byType(GarbageMapView)).markers;
      // The origin pin is distinct from the truck icon, which is reserved
      // for the collector's live position.
      expect(
        markers.firstWhere((m) => m.label == 'Origin').icon,
        Icons.trip_origin,
      );
    });

    testWidgets('route detail shows the live truck position', (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      final auth = logisticsAuth(
        routes,
        calls,
        truck: _truckJson('t1', 'AAA-1', location: [3.50, 6.60]),
      );
      await openRoutesTab(tester, auth);
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();
      // Origin + live truck + stop pins render on the layered map.
      expect(find.byType(MapPin), findsNWidgets(3));
      expect(find.byTooltip('Origin'), findsOneWidget);
      expect(find.byTooltip('Current location'), findsOneWidget);
      final markers =
          tester.widget<GarbageMapView>(find.byType(GarbageMapView)).markers;
      expect(
        markers.firstWhere((m) => m.label == 'Origin').icon,
        Icons.trip_origin,
      );
      final live = markers.firstWhere((m) => m.label == 'Current location');
      expect(live.icon, Icons.local_shipping);
      expect(live.point.longitude, 3.50);
      expect(live.point.latitude, 6.60);
    });

    testWidgets('header expands to assignment details lazily', (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      final auth = logisticsAuth(
        routes,
        calls,
        facilities: [
          {
            'id': 'f1',
            'name': 'North Depot',
            'kind': 'dump_site',
            'location': {
              'type': 'Point',
              'coordinates': [3.20, 6.30]
            },
            'accepted_types': ['plastic'],
            'address': null,
            'created_at': '2026-10-29T00:00:00Z',
            'updated_at': '2026-10-29T00:00:00Z',
          }
        ],
        truck:
            _truckJson('t1', 'AAA-1', operatorId: 'c1', location: [3.50, 6.60]),
        collectors: [collectorJson('c1', 'Ada Collector')],
      );
      await openRoutesTab(tester, auth);
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();

      // Collapsed summary names the truck and depot; no collector fetch yet.
      expect(find.byTooltip('Show more'), findsOneWidget);
      expect(find.text('AAA-1 · North Depot'), findsOneWidget);
      expect(find.text('Ada Collector'), findsNothing);
      expect(calls.where((c) => c == 'GET /api/v1/auth/users'), isEmpty);

      await tester.tap(find.byTooltip('Show more'));
      await tester.pumpAndSettle();

      expect(find.text('Ada Collector'), findsOneWidget);
      expect(find.text('AAA-1 · Working'), findsOneWidget);
      expect(find.text('North Depot (End)'), findsOneWidget);
      expect(find.text('Scheduled'), findsOneWidget);
      expect(find.text('25 Dec 2026'), findsOneWidget);
      expect(
        calls.where((c) => c == 'GET /api/v1/auth/users'),
        hasLength(1),
      );

      // Collapse and re-expand reuses the loaded directory.
      await tester.tap(find.byTooltip('Show less'));
      await tester.pumpAndSettle();
      expect(find.text('Ada Collector'), findsNothing);
      await tester.tap(find.byTooltip('Show more'));
      await tester.pumpAndSettle();
      expect(find.text('Ada Collector'), findsOneWidget);
      expect(
        calls.where((c) => c == 'GET /api/v1/auth/users'),
        hasLength(1),
      );
    });

    testWidgets('expanded header shows Unassigned without fetching collectors',
        (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      final auth = logisticsAuth(
        routes,
        calls,
        truck: _truckJson('t1', 'AAA-1'),
      );
      await openRoutesTab(tester, auth);
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show more'));
      await tester.pumpAndSettle();

      expect(find.text('Unassigned'), findsOneWidget);
      expect(calls.where((c) => c == 'GET /api/v1/auth/users'), isEmpty);
    });

    testWidgets('collector lookup failure offers retry', (tester) async {
      final calls = <String>[];
      final routes = [plannedRouteJson('r1', 'Morning run')];
      final auth = logisticsAuth(
        routes,
        calls,
        truck: _truckJson('t1', 'AAA-1', operatorId: 'c1'),
        collectors: [collectorJson('c1', 'Ada Collector')],
        usersFailTimes: 1,
      );
      await openRoutesTab(tester, auth);
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show more'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load operator"), findsOneWidget);
      expect(find.text('Ada Collector'), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Ada Collector'), findsOneWidget);
      expect(
        calls.where((c) => c == 'GET /api/v1/auth/users'),
        hasLength(2),
      );
    });
  });

  group('map geometry rendering', () {
    testWidgets('polylines and polygons render from geometry', (tester) async {
      final road = [
        GeoPoint(longitude: 3.37, latitude: 6.45),
        GeoPoint(longitude: 3.375, latitude: 6.455),
        GeoPoint(longitude: 3.38, latitude: 6.46),
      ];
      final ring = [
        GeoPoint(longitude: 3.36, latitude: 6.44),
        GeoPoint(longitude: 3.39, latitude: 6.44),
        GeoPoint(longitude: 3.39, latitude: 6.47),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GarbageMapView(
              tileProvider: _StubTileProvider(),
              markers: [
                MapMarkerData(point: road.first, label: 'Origin'),
              ],
              polylines: [road],
              polygons: [ring],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final lines = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(lines.polylines.single.points, hasLength(3));
      final areas = tester.widget<PolygonLayer>(find.byType(PolygonLayer));
      expect(areas.polygons.single.points, hasLength(3));
      // Degenerate rings never render.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GarbageMapView(
              tileProvider: _StubTileProvider(),
              markers: const [],
              polygons: [
                [GeoPoint(longitude: 0, latitude: 0)],
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PolygonLayer), findsNothing);
    });
  });
}
