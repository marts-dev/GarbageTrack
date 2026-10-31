import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/utils/geo.dart';
import 'package:garbagetrack/widgets/geo_map.dart';
import 'package:garbagetrack/widgets/location_picker.dart';
import 'package:latlong2/latlong.dart';

/// Offline tile stub: every tile is a transparent pixel, no network.
class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: child),
    );

void main() {
  group('geo conversions', () {
    test('GeoPoint (lon,lat) maps to LatLng (lat,lon)', () {
      final point = GeoPoint(longitude: 19.04, latitude: 47.49);
      expect(point.latLng, const LatLng(47.49, 19.04));
    });

    test('round trip preserves coordinates', () {
      const ll = LatLng(47.49, 19.04);
      expect(ll.geoPoint.latLng, ll);
    });
  });

  group('GarbageMapView', () {
    final markers = [
      MapMarkerData(
        point: GeoPoint(longitude: 19.04, latitude: 47.49),
        label: 'Bin A',
      ),
      MapMarkerData(
        point: GeoPoint(longitude: 19.05, latitude: 47.50),
        label: 'Bin B',
      ),
    ];

    testWidgets('renders one pin per marker plus attribution', (tester) async {
      await tester.pumpWidget(
        _wrap(
          GarbageMapView(
            markers: markers,
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byType(MapPin), findsNWidgets(2));
      expect(find.byType(RichAttributionWidget), findsOneWidget);
      final attribution = tester.widget<RichAttributionWidget>(
        find.byType(RichAttributionWidget),
      );
      expect(
        (attribution.attributions.single as TextSourceAttribution).text,
        'OpenStreetMap contributors',
      );
    });

    testWidgets('empty markers render map without pins', (tester) async {
      await tester.pumpWidget(
        _wrap(
          GarbageMapView(
            markers: [],
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byType(MapPin), findsNothing);
      expect(find.byType(RichAttributionWidget), findsOneWidget);
    });

    testWidgets('short polylines are skipped, long ones drawn', (tester) async {
      await tester.pumpWidget(
        _wrap(
          GarbageMapView(
            markers: [markers[0]],
            polylines: [
              [GeoPoint(longitude: 19.04, latitude: 47.49)],
            ],
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PolylineLayer), findsNothing);

      await tester.pumpWidget(
        _wrap(
          GarbageMapView(
            markers: markers,
            polylines: [
              [
                GeoPoint(longitude: 19.04, latitude: 47.49),
                GeoPoint(longitude: 19.05, latitude: 47.50),
              ],
            ],
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PolylineLayer), findsOneWidget);
    });
  });

  group('LocationMapPicker', () {
    testWidgets('shows hint when nothing picked', (tester) async {
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (_) {},
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Tap the map to pick a location, or use GPS.'),
        findsOneWidget,
      );
      expect(find.byType(MapPin), findsNothing);
    });

    testWidgets('shows initial pick with marker', (tester) async {
      final initial = GeoPoint(longitude: 19.04, latitude: 47.49);
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (_) {},
            initial: initial,
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Picked: ${initial.short}'), findsOneWidget);
      expect(find.byType(MapPin), findsOneWidget);
    });

    testWidgets('GPS button is present without locating spinner', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (_) {},
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.widgetWithIcon(FloatingActionButton, Icons.my_location),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('tapping the map reports the picked point', (tester) async {
      GeoPoint? picked;
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (p) => picked = p,
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FlutterMap));
      // Single taps wait out the double-tap timeout; advance fake time past it.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(find.textContaining('Picked:'), findsOneWidget);
    });
  });
}
