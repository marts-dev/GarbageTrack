import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/home_screen.dart';
import 'package:garbagetrack/screens/posts_screen.dart';
import 'package:garbagetrack/screens/new_post_screen.dart';
import 'package:garbagetrack/screens/register_screen.dart';
import 'package:garbagetrack/screens/route_create_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/state/token_store.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/utils/country_viewports.dart';
import 'package:garbagetrack/widgets/geo_map.dart';
import 'package:garbagetrack/widgets/location_picker.dart';
import 'package:garbagetrack/widgets/type_dots.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

/// Offline tile stub: every tile is a transparent pixel, no network.
class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

/// In-memory token store: flutter_secure_storage platform calls never
/// complete in widget tests, which would stall the register/login flow.
class _MemoryTokenStore extends TokenStore {
  final _memory = <String, String?>{};

  @override
  Future<String?> read(String key) async => _memory[key];

  @override
  Future<void> write(String key, String value) async {
    _memory[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _memory.remove(key);
  }
}

User _user(String role, {String? country}) => User(
      id: 'u1',
      email: 'u@example.com',
      fullName: 'Test User',
      role: role,
      isActive: true,
      country: country,
    );

Widget _withAuth(AuthProvider auth, Widget home) =>
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(theme: AppTheme.light, home: home),
    );

Map<String, dynamic> _postJson(
        String id, String? district, double lng, double lat,
        {List<String> types = const ['plastic']}) =>
    {
      'id': id,
      'user_id': 'u9',
      'location': {
        'type': 'Point',
        'coordinates': [lng, lat]
      },
      'types': types,
      'description': null,
      'district': district,
      'country': 'Nigeria',
      'has_image': false,
      'image_content_type': null,
      'status': 'posted',
      'created_at': '2026-10-29T00:00:00Z',
      'collected_at': null,
    };

Map<String, dynamic> _locationJson(double lng, double lat) => {
      'user_id': 'u1',
      'location': {
        'type': 'Point',
        'coordinates': [lng, lat]
      },
      'updated_at': '2026-10-29T00:00:00Z',
    };

Map<String, dynamic> _routeJson() => {
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
    };

/// Mock backend for the route-create screen. Posts are always returned in
/// full so the client-side type filter is what narrows the list.
MockClient _routeBackend({
  required List<Map<String, dynamic>> posts,
  Map<String, dynamic>? Function()? onRouteBody,
}) {
  return MockClient((request) async {
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
            'current_location': null,
            'load': 0,
            'capacity': 10,
          }
        ]),
        200,
      );
    }
    if (request.method == 'GET' && path == '/api/v1/logistics/facilities') {
      return http.Response(
        jsonEncode([
          {
            'id': 'f1',
            'name': 'North Depot',
            'kind': 'dump_site',
            'location': {
              'type': 'Point',
              'coordinates': [3.37, 6.45]
            },
            'accepted_types': ['plastic'],
            'address': null,
            'created_at': '2026-10-29T00:00:00Z',
            'updated_at': '2026-10-29T00:00:00Z',
          },
          {
            'id': 'f2',
            'name': 'East Recycler',
            'kind': 'recycling',
            'location': {
              'type': 'Point',
              'coordinates': [3.40, 6.47]
            },
            'accepted_types': ['plastic'],
            'address': null,
            'created_at': '2026-10-29T00:00:00Z',
            'updated_at': '2026-10-29T00:00:00Z',
          },
        ]),
        200,
      );
    }
    if (request.method == 'GET' && path == '/api/v1/logistics/garbage') {
      return http.Response(jsonEncode(posts), 200);
    }
    if (request.method == 'POST' && path == '/api/v1/logistics/routes') {
      onRouteBody
          ?.call()
          ?.addAll(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode(_routeJson()), 200);
    }
    return http.Response('not found: $path', 404);
  });
}

/// Scrolls the screen's [ListView] until [finder] matches, then reveals it.
/// Drags along the screen edge so map gestures never swallow the scroll.
/// (scrollUntilVisible can't pick among the screen's many Scrollables.)
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

Future<void> _selectTruck(WidgetTester tester) async {
  await _scrollTo(tester, find.byType(DropdownButtonFormField<String>));
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('ABC-123 (Available)').last);
  await tester.pumpAndSettle();
}

/// Jumps to a creation step by tapping its header. Headers precede
/// contents in tree order, so `.first` wins over same-named review rows.
Future<void> _goToStep(WidgetTester tester, String title) async {
  await _scrollTo(tester, find.text(title));
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

/// Picks [name] from the registration country dropdown. The menu only
/// builds visible items, so items past the fold need a scroll first.
Future<void> _selectCountry(WidgetTester tester, String name) async {
  await _scrollTo(tester, find.byType(DropdownButtonFormField<String>));
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  for (var i = 0; i < 10 && find.text(name).evaluate().isEmpty; i++) {
    await tester.drag(
        find.byType(DropdownMenuItem<String>).first, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  group('viewportFor', () {
    test('resolves known countries case-insensitively', () {
      final lagos = viewportFor('Nigeria');
      expect(lagos.center, const LatLng(9.08, 8.68));
      expect(lagos.zoom, 6);
      expect(viewportFor('  nIgErIa ').center, const LatLng(9.08, 8.68));
      final manila = viewportFor('Philippines');
      expect(manila.center, const LatLng(12.88, 121.77));
      expect(manila.zoom, 6);
    });

    test('falls back to the world view', () {
      expect(viewportFor(null).center, const LatLng(0, 0));
      expect(viewportFor(null).zoom, 2);
      expect(viewportFor('').center, const LatLng(0, 0));
      expect(viewportFor('Atlantis').center, const LatLng(0, 0));
    });

    test('dropdown countries all resolve to a viewport', () {
      expect(supportedCountries, isNotEmpty);
      for (final name in supportedCountries) {
        final viewport = viewportFor(name);
        expect(viewport.center, isNot(const LatLng(0, 0)),
            reason: '$name has no viewport entry');
      }
      expect(supportedCountries, contains('Philippines'));
    });
  });

  group('clusterMarkers', () {
    MapMarkerData pin(double lng, double lat) =>
        MapMarkerData(point: GeoPoint(longitude: lng, latitude: lat));

    test('merges identical coordinates at any zoom', () {
      final markers = [pin(3.37, 6.45), pin(3.37, 6.45), pin(3.37, 6.45)];
      for (final zoom in [2.0, 10.0, 18.0]) {
        final clusters = clusterMarkers(markers, zoom: zoom);
        expect(clusters, hasLength(1));
        expect(clusters.single.memberIndices, [0, 1, 2]);
      }
    });

    test('keeps far-apart markers separate', () {
      final markers = [pin(-98.58, 39.83), pin(133.78, -25.27)];
      final clusters = clusterMarkers(markers, zoom: 10);
      expect(clusters, hasLength(2));
      expect(clusters.every((c) => c.isSingle), isTrue);
    });

    test('cluster center averages member positions', () {
      final markers = [pin(0, 0), pin(0, 0)];
      final clusters = clusterMarkers(markers, zoom: 10);
      expect(clusters.single.center, const LatLng(0, 0));
    });

    test('keeps different cluster groups separate', () {
      MapMarkerData grouped(double lng, double lat, String? group) =>
          MapMarkerData(
            point: GeoPoint(longitude: lng, latitude: lat),
            clusterGroup: group,
          );
      final markers = [
        grouped(3.37, 6.45, MarkerGroups.garbage),
        grouped(3.37, 6.45, MarkerGroups.garbage),
        grouped(3.37, 6.45, MarkerGroups.depot),
        grouped(3.37, 6.45, MarkerGroups.depot),
        grouped(3.37, 6.45, MarkerGroups.truck),
      ];
      final clusters = clusterMarkers(markers, zoom: 14);
      expect(clusters, hasLength(3));
      final byGroup = {for (final c in clusters) c.group: c.memberIndices};
      expect(byGroup[MarkerGroups.garbage], [0, 1]);
      expect(byGroup[MarkerGroups.depot], [2, 3]);
      expect(byGroup[MarkerGroups.truck], [4]);
    });

    test('ungrouped markers cluster apart from grouped ones', () {
      final markers = [
        pin(0, 0),
        pin(0, 0),
        MapMarkerData(
          point: GeoPoint(longitude: 0, latitude: 0),
          clusterGroup: MarkerGroups.garbage,
        ),
      ];
      final clusters = clusterMarkers(markers, zoom: 14);
      expect(clusters, hasLength(2));
      final byGroup = {for (final c in clusters) c.group: c.memberIndices};
      expect(byGroup[null], [0, 1]);
      expect(byGroup[MarkerGroups.garbage], [2]);
    });
  });

  group('GarbageMapView clustering and viewport', () {
    testWidgets('clustered identical pins render one count badge',
        (tester) async {
      final point = GeoPoint(longitude: 3.37, latitude: 6.45);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GarbageMapView(
              markers: [
                MapMarkerData(point: point),
                MapMarkerData(point: point),
                MapMarkerData(point: point),
              ],
              clustered: true,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClusterBadge), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.byType(MapPin), findsNothing);
    });

    testWidgets('each cluster group gets its own badge', (tester) async {
      final point = GeoPoint(longitude: 3.37, latitude: 6.45);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GarbageMapView(
              markers: [
                MapMarkerData(point: point, clusterGroup: MarkerGroups.garbage),
                MapMarkerData(point: point, clusterGroup: MarkerGroups.garbage),
                MapMarkerData(point: point, clusterGroup: MarkerGroups.depot),
                MapMarkerData(point: point, clusterGroup: MarkerGroups.depot),
              ],
              clustered: true,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClusterBadge), findsNWidgets(2));
      expect(find.byTooltip('2 posts'), findsOneWidget);
      expect(find.byTooltip('2 depots'), findsOneWidget);
      final badges =
          tester.widgetList<ClusterBadge>(find.byType(ClusterBadge)).toList();
      expect(badges[0].color, isNot(badges[1].color));
      expect(find.byType(MapPin), findsNothing);
    });

    testWidgets('unclustered pins render one MapPin each', (tester) async {
      final point = GeoPoint(longitude: 3.37, latitude: 6.45);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GarbageMapView(
              markers: [
                MapMarkerData(point: point),
                MapMarkerData(point: point),
              ],
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MapPin), findsNWidgets(2));
      expect(find.byType(ClusterBadge), findsNothing);
    });

    testWidgets('empty map uses the country fallback viewport', (tester) async {
      final viewport = viewportFor('Nigeria');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GarbageMapView(
              markers: const [],
              fallbackCenter: viewport.center,
              fallbackZoom: viewport.zoom,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pump();
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter, const LatLng(9.08, 8.68));
      expect(map.options.initialZoom, 6);
    });

    testWidgets('empty map defaults to the world view', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GarbageMapView(
              markers: const [],
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pump();
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter, const LatLng(0, 0));
      expect(map.options.initialZoom, 2);
    });

    testWidgets('marker tap reports the marker index', (tester) async {
      var tapped = -1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GarbageMapView(
              markers: [
                MapMarkerData(point: GeoPoint(longitude: 3.37, latitude: 6.45)),
                MapMarkerData(
                    point: GeoPoint(longitude: -98.58, latitude: 39.83)),
              ],
              onMarkerTap: (i) => tapped = i,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(MapPin).first);
      await tester.pump();
      expect(tapped, isNonNegative);
    });
  });

  group('LocationMapPicker viewport', () {
    testWidgets('unpicked map centers on the country fallback', (tester) async {
      final viewport = viewportFor('Ghana');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: LocationMapPicker(
              onChanged: (_) {},
              fallbackCenter: viewport.center,
              fallbackZoom: viewport.zoom,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pump();
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter, const LatLng(7.95, -1.02));
      expect(map.options.initialZoom, 7);
    });
  });

  group('registration country', () {
    testWidgets('empty country blocks submit', (tester) async {
      final auth = AuthProvider(
        client: ApiClient(
            baseUrl: 'http://x',
            httpClient: MockClient(
              (_) async => http.Response('should not be called', 500),
            )),
      );
      await tester.pumpWidget(_withAuth(auth, const RegisterScreen()));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Email'), 'r@x.com');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password (min 8 characters)'),
          'password1');
      await _scrollTo(
          tester, find.widgetWithText(FilledButton, 'Create account'));
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Select your country'), findsWidgets);
      expect(find.byType(RegisterScreen), findsOneWidget);
    });

    testWidgets('country is sent to the API on register', (tester) async {
      Map<String, dynamic>? seen;
      final userJson = {
        'id': 'u1',
        'email': 'r@x.com',
        'full_name': null,
        'role': 'resident',
        'is_active': true,
        'country': 'Nigeria',
      };
      final auth = AuthProvider(
        tokenStore: _MemoryTokenStore(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/v1/auth/register') {
              seen = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(jsonEncode(userJson), 200);
            }
            if (request.url.path == '/api/v1/auth/login') {
              return http.Response(
                jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
                200,
              );
            }
            if (request.url.path == '/api/v1/auth/me') {
              return http.Response(jsonEncode(userJson), 200);
            }
            return http.Response('not found', 404);
          }),
        ),
      );
      await tester.pumpWidget(_withAuth(auth, const RegisterScreen()));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Email'), 'r@x.com');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password (min 8 characters)'),
          'password1');
      await _selectCountry(tester, 'Nigeria');
      await _scrollTo(
          tester, find.widgetWithText(FilledButton, 'Create account'));
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(seen!['country'], 'Nigeria');
      expect(auth.country, 'Nigeria');
    });
  });

  group('resident-only posting gate', () {
    testWidgets('resident sees the Report garbage entry', (tester) async {
      final auth = AuthProvider.withUser(_user('resident'));
      await tester.pumpWidget(_withAuth(auth, const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Report garbage'), findsOneWidget);
    });

    testWidgets('collector, logistics, and admin do not', (tester) async {
      for (final role in ['collector', 'logistics', 'admin']) {
        final auth = AuthProvider.withUser(_user(role));
        await tester.pumpWidget(_withAuth(auth, const HomeScreen()));
        await tester.pumpAndSettle();
        expect(find.text('Report garbage'), findsNothing,
            reason: 'role $role must not see the posting entry');
      }
    });

    testWidgets('posts screen hides the report action for non-residents',
        (tester) async {
      final auth = AuthProvider.withUser(
        _user('collector'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((_) async => http.Response('[]', 200)),
        ),
      );
      await tester.pumpWidget(_withAuth(auth, const PostsScreen()));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FloatingActionButton, 'Report'), findsNothing);
      expect(find.text('Report garbage'), findsNothing);
    });

    testWidgets('posts screen shows the report action for residents',
        (tester) async {
      final auth = AuthProvider.withUser(
        _user('resident'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((_) async => http.Response('[]', 200)),
        ),
      );
      await tester.pumpWidget(_withAuth(auth, const PostsScreen()));
      await tester.pumpAndSettle();
      expect(
          find.widgetWithText(FloatingActionButton, 'Report'), findsOneWidget);
      expect(find.text('Report garbage'), findsOneWidget);
    });

    testWidgets('new-post screen guards non-residents', (tester) async {
      final auth = AuthProvider.withUser(_user('logistics'));
      await tester.pumpWidget(_withAuth(auth, const NewPostScreen()));
      await tester.pumpAndSettle();
      expect(
        find.text('Only residents can report garbage.'),
        findsOneWidget,
      );
      expect(find.text('Submit report'), findsNothing);
    });

    MockClient locationBackend(Map<String, dynamic>? location, int status) =>
        MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/users/u1/location') {
            if (location == null) {
              return http.Response(jsonEncode({'detail': 'not found'}), status);
            }
            return http.Response(jsonEncode(location), 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/garbage') {
            return http.Response(jsonEncode([]), 200);
          }
          return http.Response(jsonEncode({'detail': 'not found'}), 404);
        });

    AuthProvider locationAuth(Map<String, dynamic>? location,
            {int status = 404}) =>
        AuthProvider.withUser(
          _user('resident', country: 'Nigeria'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: locationBackend(location, status),
          ),
        );

    testWidgets('new-post screen shows district field for residents',
        (tester) async {
      final auth = locationAuth(_locationJson(3.37, 6.45));
      await tester.pumpWidget(
          _withAuth(auth, NewPostScreen(tileProvider: _StubTileProvider())));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'District / region (optional)'),
        findsOneWidget,
      );
      // The confirmation map centers on the saved collection point.
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter, const LatLng(6.45, 3.37));
    });

    testWidgets('report submits the saved collection point', (tester) async {
      Map<String, dynamic>? submitted;
      final auth = AuthProvider.withUser(
        _user('resident', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/v1/users/u1/location') {
              return http.Response(jsonEncode(_locationJson(3.37, 6.45)), 200);
            }
            if (request.method == 'POST' &&
                request.url.path == '/api/v1/garbage') {
              submitted = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                  jsonEncode(_postJson('p9', null, 3.37, 6.45)), 201);
            }
            return http.Response(jsonEncode({'detail': 'not found'}), 404);
          }),
        ),
      );
      await tester.pumpWidget(
          _withAuth(auth, NewPostScreen(tileProvider: _StubTileProvider())));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.widgetWithText(FilterChip, 'Plastic'));
      await tester.tap(find.widgetWithText(FilterChip, 'Plastic'));
      await tester.pumpAndSettle();
      await _scrollTo(
          tester, find.widgetWithText(FilledButton, 'Submit report'));
      await tester.tap(find.widgetWithText(FilledButton, 'Submit report'));
      await tester.pumpAndSettle();
      expect(submitted?['longitude'], 3.37);
      expect(submitted?['latitude'], 6.45);
      expect(submitted?['types'], ['plastic']);
    });

    testWidgets('report without a collection point prompts setup',
        (tester) async {
      final auth = locationAuth(null);
      await tester.pumpWidget(
          _withAuth(auth, NewPostScreen(tileProvider: _StubTileProvider())));
      await tester.pumpAndSettle();
      expect(find.text('Set collection point'), findsOneWidget);
      await _scrollTo(
          tester, find.widgetWithText(FilledButton, 'Submit report'));
      final submit = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Submit report'));
      expect(submit.onPressed, isNull);
    });
  });

  group('collection point gate', () {
    MockClient gateBackend(
            {Map<String, dynamic>? location, int status = 404}) =>
        MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/users/u1/location') {
            if (location == null) {
              return http.Response(jsonEncode({'detail': 'not found'}), status);
            }
            return http.Response(jsonEncode(location), 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/garbage') {
            return http.Response(jsonEncode([]), 200);
          }
          return http.Response(jsonEncode({'detail': 'not found'}), 404);
        });

    AuthProvider gateAuth({Map<String, dynamic>? location, int status = 404}) =>
        AuthProvider.withUser(
          _user('resident'),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: gateBackend(location: location, status: status),
          ),
        );

    testWidgets('resident without a collection point sees setup first',
        (tester) async {
      await tester.pumpWidget(_withAuth(gateAuth(), const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Set collection point'), findsOneWidget);
      expect(find.text('Where should collectors pick up your garbage?'),
          findsOneWidget);
      expect(find.text('Report garbage'), findsNothing);
    });

    testWidgets('resident with a collection point lands on home',
        (tester) async {
      await tester.pumpWidget(_withAuth(
          gateAuth(location: _locationJson(3.37, 6.45)), const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Report garbage'), findsOneWidget);
      expect(find.text('Collection point'), findsOneWidget);
    });

    testWidgets('gate fails open when the check errors', (tester) async {
      await tester
          .pumpWidget(_withAuth(gateAuth(status: 500), const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Report garbage'), findsOneWidget);
    });
  });

  group('route-create screen', () {
    final posts = [
      _postJson('p1', 'Ojota', 3.37, 6.45),
      _postJson('p2', 'Ikeja', 3.40, 6.60),
    ];

    testWidgets('requires at least one depot', (tester) async {
      final auth = AuthProvider.withUser(
        _user('logistics', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: _routeBackend(posts: posts),
        ),
      );
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await _selectTruck(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Pick at least one depot'), findsOneWidget);
    });

    testWidgets('truck dropdown shows the garbage types it collects',
        (tester) async {
      final auth = AuthProvider.withUser(
        _user('logistics', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: _routeBackend(posts: posts),
        ),
      );
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      // The mock truck collects plastic and paper; posts are plastic-only,
      // so the joined type line can only come from the truck dropdown entry.
      expect(find.text('ABC-123 (Available)'), findsOneWidget);
      expect(find.text('Plastic, Paper'), findsOneWidget);
      expect(find.byType(TypeDot), findsWidgets);
    });

    testWidgets('type chips narrow the manual post list', (tester) async {
      final mixedPosts = [
        _postJson('p1', 'Ojota', 3.37, 6.45, types: const ['plastic']),
        _postJson('p2', 'Ikeja', 3.40, 6.60, types: const ['organic']),
      ];
      final auth = AuthProvider.withUser(
        _user('logistics', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: _routeBackend(posts: mixedPosts),
        ),
      );
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      // Manual mode shows the checkbox list.
      await _goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(CheckboxListTile));
      expect(find.byType(CheckboxListTile), findsNWidgets(2));

      // Toggling Organic off hides the Ikeja post.
      await _scrollTo(tester, find.widgetWithText(FilterChip, 'Organic'));
      await tester.tap(find.widgetWithText(FilterChip, 'Organic'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(CheckboxListTile));
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.textContaining('Ojota'), findsWidgets);
      expect(find.textContaining('Ikeja'), findsNothing);

      // Toggling it back on shows everything again.
      await _scrollTo(tester, find.widgetWithText(FilterChip, 'Organic'));
      await tester.tap(find.widgetWithText(FilterChip, 'Organic'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(CheckboxListTile));
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
    });

    testWidgets('type chips follow the truck and submit the subset',
        (tester) async {
      final submitted = <String, dynamic>{};
      final auth = AuthProvider.withUser(
        _user('logistics', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: _routeBackend(
            posts: posts,
            onRouteBody: () => submitted,
          ),
        ),
      );
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      // Without a truck every type is offered.
      await _goToStep(tester, 'Stops');
      await _scrollTo(tester, find.widgetWithText(FilterChip, 'Organic'));
      expect(find.widgetWithText(FilterChip, 'Organic'), findsOneWidget);

      await _goToStep(tester, 'Truck & day');
      await _selectTruck(tester);
      // The mock truck carries plastic and paper only.
      await _goToStep(tester, 'Stops');
      await _scrollTo(tester, find.text('Only types ABC-123 can carry.'));
      expect(find.text('Only types ABC-123 can carry.'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Plastic'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Paper'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Organic'), findsNothing);

      // Narrow to plastic-only for this run.
      await _scrollTo(tester, find.widgetWithText(FilterChip, 'Paper'));
      await tester.tap(find.widgetWithText(FilterChip, 'Paper'));
      await tester.pumpAndSettle();
      await _goToStep(tester, 'Depots');
      await _scrollTo(tester, find.text('North Depot (Dump Site)'));
      await tester.tap(find.text('North Depot (Dump Site)'));
      await tester.pumpAndSettle();
      await _goToStep(tester, 'Review');
      await _scrollTo(tester, find.text('Assign route'));
      await tester.tap(find.text('Assign route'));
      await tester.pumpAndSettle();
      expect(submitted['types'], ['plastic']);
    });

    testWidgets('posted garbage renders marker-clustered', (tester) async {
      final sameSpot = [
        _postJson('p1', 'Ojota', 3.37, 6.45),
        _postJson('p2', 'Ojota', 3.37, 6.45),
      ];
      final auth = AuthProvider.withUser(
        _user('logistics', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: _routeBackend(posts: sameSpot),
        ),
      );
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await _goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(FlutterMap));
      expect(find.byType(ClusterBadge), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('map pin tap toggles the manual selection', (tester) async {
      final auth = AuthProvider.withUser(
        _user('logistics', country: 'Nigeria'),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: _routeBackend(posts: posts),
        ),
      );
      await tester.pumpWidget(
        _withAuth(auth, RouteCreateScreen(tileProvider: _StubTileProvider())),
      );
      await tester.pumpAndSettle();
      await _goToStep(tester, 'Stops');
      await _scrollTo(tester, find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(FlutterMap));
      // Far-apart posts render as single pins at the fitted zoom.
      expect(find.byType(MapPin), findsNWidgets(2));
      await tester.tap(find.byType(MapPin).first);
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byType(CheckboxListTile));
      final tiles = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      expect(tiles.where((t) => t.value == true), hasLength(1));
    });
  });
}
