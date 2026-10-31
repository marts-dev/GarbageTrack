import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/models.dart';
import '../utils/geo.dart';

/// One pin on a [GarbageMapView].
class MapMarkerData {
  const MapMarkerData({
    required this.point,
    this.icon = Icons.location_on,
    this.color,
    this.label,
  });

  final GeoPoint point;
  final IconData icon;
  final Color? color;
  final String? label;
}

/// Read-only OpenStreetMap view with markers, optional route polylines and
/// mandatory OSM attribution. Renders on web and Android.
class GarbageMapView extends StatelessWidget {
  const GarbageMapView({
    super.key,
    required this.markers,
    this.polylines = const [],
    this.height = 220,
    this.initialZoom = 14,
    this.tileProvider,
  });

  final List<MapMarkerData> markers;
  final List<List<GeoPoint>> polylines;
  final double height;
  final double initialZoom;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  /// Defaults to the standard network tile provider.
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final points = markers.map((m) => m.point.latLng).toList();
    final lines = polylines.where((line) => line.length >= 2).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: height,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: points.isEmpty ? const LatLng(0, 0) : points.first,
            initialZoom: points.isEmpty ? 2 : initialZoom,
            initialCameraFit: points.length > 1
                ? CameraFit.coordinates(
                    coordinates: points,
                    padding: const EdgeInsets.all(32),
                    maxZoom: 15,
                  )
                : null,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.garbagetrack.garbagetrack',
              tileProvider: tileProvider,
            ),
            if (lines.isNotEmpty)
              PolylineLayer(
                polylines: [
                  for (final line in lines)
                    Polyline(
                      points: line.map((p) => p.latLng).toList(),
                      strokeWidth: 4,
                      color: scheme.primary,
                    ),
                ],
              ),
            MarkerLayer(
              markers: [
                for (final marker in markers)
                  Marker(
                    point: marker.point.latLng,
                    width: 40,
                    height: 40,
                    child: Tooltip(
                      message: marker.label ?? marker.point.short,
                      child: MapPin(
                        icon: marker.icon,
                        color: marker.color ?? scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular map pin, centered on its coordinates.
class MapPin extends StatelessWidget {
  const MapPin({super.key, required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}
