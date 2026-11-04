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

    testWidgets('coverage circle renders in meters when set', (tester) async {
      final center = GeoPoint(longitude: 19.04, latitude: 47.49);
      await tester.pumpWidget(
        _wrap(
          GarbageMapView(
            markers: markers,
            coverageCircle: (center: center, radiusMeters: 5000),
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      final layers =
          tester.widgetList<CircleLayer>(find.byType(CircleLayer)).toList();
      expect(layers, hasLength(1));
      final circle = layers.single.circles.single;
      expect(circle.point, center.latLng);
      expect(circle.radius, 5000);
      expect(circle.useRadiusInMeter, isTrue);

      await tester.pumpWidget(
        _wrap(
          GarbageMapView(
            markers: markers,
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircleLayer), findsNothing);
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

    testWidgets('follows an externally changed pick', (tester) async {
      final a = GeoPoint(longitude: 19.04, latitude: 47.49);
      final b = GeoPoint(longitude: 19.06, latitude: 47.51);
      Widget frame(GeoPoint? initial) => _wrap(
            LocationMapPicker(
              onChanged: (_) {},
              initial: initial,
              tileProvider: _StubTileProvider(),
            ),
          );
      await tester.pumpWidget(frame(a));
      await tester.pump();
      expect(find.text('Picked: ${a.short}'), findsOneWidget);
      await tester.pumpWidget(frame(b));
      await tester.pump();
      expect(find.text('Picked: ${b.short}'), findsOneWidget);
      await tester.pumpWidget(frame(null));
      await tester.pump();
      expect(
        find.text('Tap the map to pick a location, or use GPS.'),
        findsOneWidget,
      );
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

    testWidgets('renders reference lines and markers under the pick',
        (tester) async {
      final initial = GeoPoint(longitude: 19.04, latitude: 47.49);
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (_) {},
            initial: initial,
            tileProvider: _StubTileProvider(),
            polylines: [
              [
                GeoPoint(longitude: 19.04, latitude: 47.49),
                GeoPoint(longitude: 19.0405, latitude: 47.4905),
              ],
              // Too short to draw.
              [GeoPoint(longitude: 19.0406, latitude: 47.4906)],
            ],
            extraMarkers: [
              MapMarkerData(
                point: GeoPoint(longitude: 19.0405, latitude: 47.4905),
                number: 1,
                label: 'Stop 1: Plastic',
              ),
              MapMarkerData(
                point: GeoPoint(longitude: 19.0406, latitude: 47.4906),
                label: 'Depot: North',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      final layers =
          tester.widgetList<PolylineLayer>(find.byType(PolylineLayer)).toList();
      expect(layers, hasLength(1));
      expect(layers.single.polylines, hasLength(1));
      expect(find.byType(NumberedMapPin), findsOneWidget);
      expect(find.text('1', skipOffstage: false), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Stop 1: Plastic',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Depot: North',
        ),
        findsOneWidget,
      );
      // The picked pin stays on top of the reference pins.
      expect(find.byType(MapPin), findsNWidgets(2));
    });

    testWidgets('renders the coverage circle in meters', (tester) async {
      final center = GeoPoint(longitude: 19.04, latitude: 47.49);
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (_) {},
            initial: center,
            tileProvider: _StubTileProvider(),
            coverageCircle: (center: center, radiusMeters: 30),
          ),
        ),
      );
      await tester.pump();
      final layers =
          tester.widgetList<CircleLayer>(find.byType(CircleLayer)).toList();
      expect(layers, hasLength(1));
      final circle = layers.single.circles.single;
      expect(circle.point, center.latLng);
      expect(circle.radius, 30);
      expect(circle.useRadiusInMeter, isTrue);
    });

    testWidgets('draws no circle without coverage', (tester) async {
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (_) {},
            tileProvider: _StubTileProvider(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircleLayer), findsNothing);
    });

    testWidgets('stays tappable with reference layers on', (tester) async {
      GeoPoint? picked;
      await tester.pumpWidget(
        _wrap(
          LocationMapPicker(
            onChanged: (p) => picked = p,
            tileProvider: _StubTileProvider(),
            polylines: [
              [
                GeoPoint(longitude: 19.04, latitude: 47.49),
                GeoPoint(longitude: 19.05, latitude: 47.50),
              ],
            ],
            extraMarkers: [
              MapMarkerData(
                point: GeoPoint(longitude: 19.05, latitude: 47.50),
                number: 1,
                label: 'Stop 1',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FlutterMap));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
    });
  });
}
