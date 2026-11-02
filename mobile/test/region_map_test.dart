import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/logistics_home_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/widgets/region_map.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

const _fakeGeojson = '''
{"type": "FeatureCollection", "features": [
  {"type": "Feature",
   "properties": {"name": "Northland", "iso": "PH-01"},
   "geometry": {"type": "Polygon", "coordinates": [
     [[120.0, 15.0], [121.0, 15.0], [121.0, 16.0], [120.0, 16.0], [120.0, 15.0]]
   ]}},
  {"type": "Feature",
   "properties": {"name": "Southland", "iso": "PH-02"},
   "geometry": {"type": "MultiPolygon", "coordinates": [[
     [[120.0, 13.0], [121.0, 13.0], [121.0, 14.0], [120.0, 14.0], [120.0, 13.0]]
   ]]}},
  {"type": "Feature",
   "properties": {"name": "Gapland", "iso": "PH-03"},
   "geometry": {"type": "Polygon", "coordinates": [
     [[122.0, 15.0], [123.0, 15.0], [123.0, 16.0], [122.0, 16.0], [122.0, 15.0]],
     [[122.2, 15.2], [122.8, 15.2], [122.8, 15.8], [122.2, 15.8], [122.2, 15.2]]
   ]}}
]}''';

void main() {
  group('parseRegionBoundaries', () {
    test('parses polygons, multipolygons, and holes', () {
      final regions = parseRegionBoundaries(_fakeGeojson);
      expect(regions.map((r) => r.name),
          ['Northland', 'Southland', 'Gapland']);
      expect(regions[0].polygons, hasLength(1));
      expect(regions[1].polygons, hasLength(1));
      // Gapland keeps its hole ring.
      expect(regions[2].polygons.single, hasLength(2));
      expect(regions[0].centroid, const LatLng(15.4, 120.4));
    });

    test('parses the shipped Philippines boundaries', () {
      // Plain file read: widget-test asset-bundle loading hangs (see
      // regionBoundariesLoader), so the real asset is covered here instead.
      final raw =
          File('assets/data/ph_regions.geojson').readAsStringSync();
      final regions = parseRegionBoundaries(raw);
      expect(regions.map((r) => r.name).toSet(), hasLength(17));
    });
  });

  group('regionBoundariesFor', () {
    test('resolves the Philippines case-insensitively', () {
      expect(regionBoundariesFor('Philippines'),
          'assets/data/ph_regions.geojson');
      expect(regionBoundariesFor('philippines'),
          'assets/data/ph_regions.geojson');
    });

    test('returns null without shipped boundaries', () {
      expect(regionBoundariesFor('Nigeria'), isNull);
      expect(regionBoundariesFor(null), isNull);
    });
  });

  group('RegionSummary model', () {
    test('parses the regional breakdown', () {
      final summary = GarbageSummary.fromJson({
        'total': 3,
        'by_status': {'posted': 3},
        'by_type': {'plastic': 3},
        'by_region': {
          'Northland': {
            'total': 2,
            'by_status': {'posted': 2},
            'by_type': {'plastic': 2},
          },
        },
      });
      expect(summary.byRegion['Northland']!.total, 2);
      expect(summary.byRegion['Northland']!.byType, {'plastic': 2});
    });

    test('defaults to empty without a regional breakdown', () {
      final summary = GarbageSummary.fromJson({
        'total': 1,
        'by_status': {'posted': 1},
        'by_type': {'plastic': 1},
      });
      expect(summary.byRegion, isEmpty);
    });
  });

  group('RegionChoropleth', () {
    testWidgets('badges report counts and tap through the region name',
        (tester) async {
      final seen = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RegionChoropleth(
              regions: parseRegionBoundaries(_fakeGeojson),
              counts: const {'Northland': 2},
              onRegionTap: seen.add,
              tileProvider: _StubTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Only counted regions get a badge.
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(seen, ['Northland']);
    });

    testWidgets('tapping a region body reports its name', (tester) async {
      final seen = <String>[];
      final controller = MapController();
      addTearDown(controller.dispose);
      final regions = parseRegionBoundaries(_fakeGeojson);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RegionChoropleth(
              regions: regions,
              counts: const {},
              onRegionTap: seen.add,
              tileProvider: _StubTileProvider(),
              mapController: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Southland has no badge: the body tap is the only path.
      final southland =
          regions.firstWhere((r) => r.name == 'Southland').centroid;
      final mapRect = tester.getRect(find.byType(FlutterMap));
      final at = mapRect.topLeft +
          controller.camera.getOffsetFromOrigin(southland);
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(seen, ['Southland']);
      // Drain the map's double-tap-hold timer before teardown.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    });

    testWidgets('every shipped region reaches the polygon layer',
        (tester) async {
      final controller = MapController();
      addTearDown(controller.dispose);
      final raw =
          File('assets/data/ph_regions.geojson').readAsStringSync();
      final regions = parseRegionBoundaries(raw);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RegionChoropleth(
              regions: regions,
              counts: const {'National Capital Region (NCR)': 3},
              onRegionTap: (_) {},
              tileProvider: _StubTileProvider(),
              mapController: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final layer = tester
          .widgetList(find.byWidgetPredicate((w) => w is PolygonLayer))
          .single as PolygonLayer;
      final drawn = {for (final p in layer.polygons) p.hitValue};
      expect(drawn, regions.map((r) => r.name).toSet());
      // Framed on the country, not a single region.
      expect(controller.camera.center.latitude, closeTo(12.8, 0.5));
      expect(controller.camera.center.longitude, closeTo(121.8, 0.5));
      expect(controller.camera.zoom, 5);
    });
  });

  group('overview region section', () {
    AuthProvider overviewAuth(String? country, Map<String, dynamic> summary) =>
        AuthProvider.withUser(
          User(
            id: 'u1',
            email: 'l@example.com',
            role: 'logistics',
            isActive: true,
            country: country,
          ),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: MockClient((request) async {
              if (request.method == 'GET' &&
                  request.url.path == '/api/v1/logistics/garbage/summary') {
                return http.Response(jsonEncode(summary), 200);
              }
              return http.Response(jsonEncode({'detail': 'not found'}), 404);
            }),
          ),
        );

    Map<String, dynamic> summaryJson() => {
          'total': 7,
          'by_status': {'posted': 7},
          'by_type': {'plastic': 7},
          'by_region': {
            'Northland': {
              'total': 2,
              'by_status': {'posted': 2},
              'by_type': {'plastic': 2},
            },
            'Southland': {
              'total': 5,
              'by_status': {'posted': 4, 'scheduled': 1},
              'by_type': {'plastic': 5},
            },
          },
        };

    testWidgets('tapping a region opens its breakdown', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: overviewAuth('Philippines', summaryJson()),
          child: MaterialApp(
            theme: AppTheme.light,
            home: LogisticsHomeScreen(
              tileProvider: _StubTileProvider(),
              regionBoundariesLoader: (_) async => _fakeGeojson,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('By region'), findsOneWidget);
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(find.text('Northland'), findsOneWidget);
      expect(find.text('2 reports'), findsOneWidget);
      expect(find.text('Posted · 2'), findsOneWidget);
      expect(find.text('Plastic'), findsOneWidget);
      final bars = tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bars.map((b) => b.value), [1.0]);
    });

    testWidgets('map stays hidden without shipped boundaries', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: overviewAuth('Nigeria', summaryJson()),
          child: MaterialApp(
            theme: AppTheme.light,
            home: LogisticsHomeScreen(tileProvider: _StubTileProvider()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('By region'), findsNothing);
      // Pills still carry the totals.
      expect(find.text('By status'), findsOneWidget);
    });
  });
}
