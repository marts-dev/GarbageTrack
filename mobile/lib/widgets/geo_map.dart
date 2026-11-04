import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/models.dart';
import '../utils/geo.dart';

/// Well-known [MapMarkerData.clusterGroup] buckets. Only markers sharing a
/// bucket merge into one count badge, so garbage, depots, and trucks each
/// keep their own clusters on a shared map.
abstract class MarkerGroups {
  static const garbage = 'garbage';
  static const depot = 'depot';
  static const truck = 'truck';
  static const collectionPoint = 'collectionPoint';
}

/// One pin on a [GarbageMapView].
class MapMarkerData {
  const MapMarkerData({
    required this.point,
    this.icon = Icons.location_on,
    this.color,
    this.label,
    this.clusterGroup,
    this.number,
  });

  final GeoPoint point;
  final IconData icon;
  final Color? color;
  final String? label;

  /// Stop order, rendered as a numbered badge instead of the icon pin
  /// (e.g. route stops on the collect map). Null keeps the icon pin.
  final int? number;

  /// Clustering bucket: pins only merge with pins in the same bucket.
  /// Null (the default) clusters with other ungrouped pins, preserving the
  /// legacy single-cluster behavior.
  final String? clusterGroup;
}

/// One rendered pin group: either a single marker or a cluster of markers
/// whose pins would overlap at the current zoom.
class MarkerCluster {
  const MarkerCluster({
    required this.memberIndices,
    required this.center,
    this.group,
  });

  /// Indices into the [GarbageMapView.markers] list.
  final List<int> memberIndices;

  /// Average position of the members.
  final LatLng center;

  /// Shared [MapMarkerData.clusterGroup] of the members.
  final String? group;

  bool get isSingle => memberIndices.length == 1;
}

/// Groups marker indices whose pins fall within [radiusPx] screen pixels of
/// each other at [zoom], using web-mercator projection. Markers only merge
/// within their [MapMarkerData.clusterGroup] bucket. Pure function so it
/// can be unit tested without a map.
List<MarkerCluster> clusterMarkers(
  List<MapMarkerData> markers, {
  required double zoom,
  double radiusPx = 60,
}) {
  final points = [for (final m in markers) m.point.latLng];
  final projected = [for (final p in points) _project(p, zoom)];
  final byGroup = <String?, List<int>>{};
  for (var i = 0; i < markers.length; i++) {
    byGroup.putIfAbsent(markers[i].clusterGroup, () => []).add(i);
  }
  final clusters = <MarkerCluster>[];
  for (final entry in byGroup.entries) {
    final unassigned = List.of(entry.value);
    while (unassigned.isNotEmpty) {
      final seed = unassigned.removeAt(0);
      final members = [seed];
      unassigned.removeWhere((i) {
        final dx = projected[i].x - projected[seed].x;
        final dy = projected[i].y - projected[seed].y;
        if (dx * dx + dy * dy <= radiusPx * radiusPx) {
          members.add(i);
          return true;
        }
        return false;
      });
      var lat = 0.0;
      var lng = 0.0;
      for (final i in members) {
        lat += points[i].latitude;
        lng += points[i].longitude;
      }
      clusters.add(MarkerCluster(
        memberIndices: members,
        center: LatLng(lat / members.length, lng / members.length),
        group: entry.key,
      ));
    }
  }
  return clusters;
}

math.Point<double> _project(LatLng ll, double zoom) {
  final scale = 256.0 * math.pow(2, zoom).toDouble();
  final x = (ll.longitude + 180.0) / 360.0 * scale;
  final sinLat = math.sin(ll.latitude * math.pi / 180.0).clamp(-0.9999, 0.9999);
  final y =
      (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale;
  return math.Point(x, y);
}

/// Badge fill per cluster bucket, matching the bucket's pin color so a badge
/// reads as its category at a glance.
Color _badgeColor(ColorScheme scheme, String? group) => switch (group) {
      MarkerGroups.depot => scheme.secondary,
      MarkerGroups.truck => Colors.blue,
      MarkerGroups.collectionPoint => scheme.tertiary,
      _ => scheme.primary,
    };

/// Badge tooltip per cluster bucket. Badges only render for two or more
/// members, so nouns stay plural.
String _badgeTooltip(String? group, int count) {
  final noun = switch (group) {
    MarkerGroups.garbage => 'posts',
    MarkerGroups.depot => 'depots',
    MarkerGroups.truck => 'trucks',
    MarkerGroups.collectionPoint => 'collection points',
    null => 'reports',
    _ => 'markers',
  };
  return '$count $noun';
}

/// Read-only OpenStreetMap view with markers, optional route polylines,
/// optional filled polygons and mandatory OSM attribution. Renders on web
/// and Android.
///
/// Pass [clustered] to merge nearby pins into countable badges (re-clustered
/// on every zoom change), [onMarkerTap] to make pins tappable (by marker
/// index), and [onMapTap] to receive taps on empty map area.
class GarbageMapView extends StatefulWidget {
  const GarbageMapView({
    super.key,
    required this.markers,
    this.overlayMarkers = const [],
    this.polylines = const [],
    this.polygons = const [],
    this.coverageCircle,
    this.height = 220,
    this.initialZoom = 14,
    this.tileProvider,
    this.clustered = false,
    this.onMarkerTap,
    this.onMapTap,
    this.fallbackCenter,
    this.fallbackZoom,
  });

  final List<MapMarkerData> markers;

  /// Extra pins drawn singly on top: never clustered and never part of the
  /// camera fit (e.g. in-progress polygon vertices).
  final List<MapMarkerData> overlayMarkers;

  final List<List<GeoPoint>> polylines;

  /// Filled areas (e.g. the route-create selection polygon). Rings with
  /// fewer than 3 points are skipped.
  final List<List<GeoPoint>> polygons;

  /// Translucent coverage circle (e.g. the auto-generate inclusion zone).
  /// Null draws nothing.
  final ({GeoPoint center, double radiusMeters})? coverageCircle;

  final double height;
  final double initialZoom;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  /// Defaults to the standard network tile provider.
  final TileProvider? tileProvider;

  /// Merge nearby pins into count badges. Defaults to off so single-pin
  /// screens keep their exact current rendering.
  final bool clustered;

  /// Called with the marker index when a pin is tapped. Null keeps pins
  /// non-interactive.
  final ValueChanged<int>? onMarkerTap;

  /// Called with the tapped position. Null keeps the map itself
  /// non-interactive.
  final ValueChanged<LatLng>? onMapTap;

  /// Map center/zoom used when [markers] is empty, e.g. the user's country
  /// viewport. Defaults to the world view.
  final LatLng? fallbackCenter;
  final double? fallbackZoom;

  @override
  State<GarbageMapView> createState() => _GarbageMapViewState();
}

class _GarbageMapViewState extends State<GarbageMapView> {
  late final MapController _controller;
  double? _zoom;

  /// Last marker set the camera fit was computed from. The fit object is
  /// rebuilt only when the coordinates actually change: rebuilding it on
  /// every parent setState would make flutter_map refit (and visibly move)
  /// the camera on each rebuild.
  List<LatLng>? _fitPoints;
  CameraFit? _fit;

  static bool _samePoints(List<LatLng> a, List<LatLng>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _controller = MapController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onMapEvent(MapEvent event) {
    if (_zoom != event.camera.zoom) {
      setState(() => _zoom = event.camera.zoom);
    }
  }

  void _zoomInto(LatLng center) {
    final zoom = math.min((_zoom ?? widget.initialZoom) + 2, 18.0);
    _controller.move(center, zoom);
  }

  /// One unclustered pin: a numbered badge for ordered stops, else the
  /// plain icon pin.
  Marker _singleMarker(
    ColorScheme scheme,
    MarkerCluster cluster,
    MapMarkerData marker,
  ) {
    final number = marker.number;
    return Marker(
      point: cluster.center,
      width: 40,
      height: 40,
      child: _Tappable(
        onTap: widget.onMarkerTap == null
            ? null
            : () => widget.onMarkerTap!(cluster.memberIndices.single),
        child: Tooltip(
          message: marker.label ?? marker.point.short,
          child: number != null
              ? NumberedMapPin(
                  number: number,
                  color: marker.color ?? scheme.primary,
                )
              : MapPin(
                  icon: marker.icon,
                  color: marker.color ?? scheme.primary,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final points = widget.markers.map((m) => m.point.latLng).toList();
    final lines = widget.polylines.where((line) => line.length >= 2).toList();
    final areas = widget.polygons.where((ring) => ring.length >= 3).toList();
    final emptyCenter = widget.fallbackCenter ?? const LatLng(0, 0);
    final emptyZoom = widget.fallbackZoom ?? 2;
    if (!_samePoints(points, _fitPoints)) {
      _fitPoints = List.of(points);
      _fit = points.length > 1
          ? CameraFit.coordinates(
              coordinates: points,
              padding: const EdgeInsets.all(32),
              maxZoom: 15,
            )
          : null;
    }

    final clusters = widget.clustered && widget.markers.length > 1
        ? clusterMarkers(widget.markers, zoom: _zoom ?? widget.initialZoom)
        : [
            for (var i = 0; i < widget.markers.length; i++)
              MarkerCluster(
                memberIndices: [i],
                center: points[i],
                group: widget.markers[i].clusterGroup,
              ),
          ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: widget.height,
        child: FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: points.isEmpty ? emptyCenter : points.first,
            initialZoom: points.isEmpty ? emptyZoom : widget.initialZoom,
            initialCameraFit: _fit,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapEvent: _onMapEvent,
            onTap: widget.onMapTap == null
                ? null
                : (_, ll) => widget.onMapTap!(ll),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.garbagetrack.garbagetrack',
              tileProvider: widget.tileProvider,
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
            if (areas.isNotEmpty)
              PolygonLayer(
                polygons: [
                  for (final ring in areas)
                    Polygon(
                      points: ring.map((p) => p.latLng).toList(),
                      borderStrokeWidth: 2,
                      borderColor: scheme.tertiary,
                      color: scheme.tertiary.withValues(alpha: 0.2),
                    ),
                ],
              ),
            if (widget.coverageCircle case final circle?)
              CircleLayer(
                circles: [
                  coverageCircleMarker(
                    center: circle.center,
                    radiusMeters: circle.radiusMeters,
                    scheme: scheme,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                for (final cluster in clusters)
                  if (cluster.isSingle)
                    _singleMarker(
                      scheme,
                      cluster,
                      widget.markers[cluster.memberIndices.single],
                    )
                  else
                    Marker(
                      point: cluster.center,
                      width: 44,
                      height: 44,
                      child: _Tappable(
                        onTap: () => _zoomInto(cluster.center),
                        child: Tooltip(
                          message: _badgeTooltip(
                              cluster.group, cluster.memberIndices.length),
                          child: ClusterBadge(
                            count: cluster.memberIndices.length,
                            color: _badgeColor(scheme, cluster.group),
                          ),
                        ),
                      ),
                    ),
                for (final overlay in widget.overlayMarkers)
                  Marker(
                    point: overlay.point.latLng,
                    width: 40,
                    height: 40,
                    child: Tooltip(
                      message: overlay.label ?? overlay.point.short,
                      child: MapPin(
                        icon: overlay.icon,
                        color: overlay.color ?? scheme.primary,
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

/// Assigned-route overlay shared by the collector and logistics route
/// views: the distinct origin pin, the live truck position, stop pins, and
/// extra pins (collection points, depots) over the route polyline.
class RouteMapView extends StatelessWidget {
  const RouteMapView({
    super.key,
    required this.origin,
    this.live,
    this.stopMarkers = const [],
    this.extraMarkers = const [],
    required this.displayLine,
    this.height = 220,
    this.tileProvider,
  });

  /// Fixed route start. Always rendered with the distinct origin pin.
  final GeoPoint origin;

  /// Collector's live position. Skipped while unknown or coinciding with
  /// the origin pin.
  final GeoPoint? live;

  final List<MapMarkerData> stopMarkers;
  final List<MapMarkerData> extraMarkers;
  final List<GeoPoint> displayLine;
  final double height;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = this.live;
    final showLive = live != null &&
        (live.longitude != origin.longitude ||
            live.latitude != origin.latitude);
    return GarbageMapView(
      height: height,
      tileProvider: tileProvider,
      markers: [
        MapMarkerData(
          point: origin,
          icon: Icons.trip_origin,
          color: scheme.primary,
          label: 'Origin',
        ),
        if (showLive)
          MapMarkerData(
            point: live,
            icon: Icons.local_shipping,
            color: Colors.blue,
            label: 'Current location',
          ),
        ...stopMarkers,
        ...extraMarkers,
      ],
      polylines: [displayLine],
    );
  }
}

/// Gesture wrapper that stays out of the tree when [onTap] is null.
class _Tappable extends StatelessWidget {
  const _Tappable({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return GestureDetector(onTap: onTap, child: child);
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

/// Translucent coverage circle (collect radius, auto-generate zone).
/// The wash is strong enough to read over street tiles but light enough
/// to see pins through it; the solid ring marks the exact boundary.
CircleMarker coverageCircleMarker({
  required GeoPoint center,
  required double radiusMeters,
  required ColorScheme scheme,
}) =>
    CircleMarker(
      point: center.latLng,
      radius: radiusMeters,
      useRadiusInMeter: true,
      color: scheme.primary.withValues(alpha: 0.25),
      borderColor: scheme.primary,
      borderStrokeWidth: 3,
    );

/// Circular numbered badge for one ordered pin (e.g. stop 3 of a run),
/// styled like [MapPin] so it reads as a pin, not a cluster.
class NumberedMapPin extends StatelessWidget {
  const NumberedMapPin({super.key, required this.number, required this.color});

  final int number;
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
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
  }
}

/// Circular count badge for a cluster of pins, styled like [MapPin].
class ClusterBadge extends StatelessWidget {
  const ClusterBadge({super.key, required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Center(
        child: Text(
          '$count',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
