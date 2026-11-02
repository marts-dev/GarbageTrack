import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Lowercase country name -> bundled ADM1 boundary asset. Mirrors the
/// server's region registry: expanding to a new country is one GeoJSON
/// asset here plus one server file (features with `properties.name` and
/// Polygon/MultiPolygon geometry).
const regionBoundaries = {
  'philippines': 'assets/data/ph_regions.geojson',
};

/// Boundary asset for [country] (case-insensitive), or null when the
/// country has no shipped boundaries.
String? regionBoundariesFor(String? country) {
  if (country == null) return null;
  return regionBoundaries[country.trim().toLowerCase()];
}

/// One parsed boundary feature: outer rings, holes, and a label point.
class RegionBoundary {
  const RegionBoundary({
    required this.name,
    required this.polygons,
    required this.centroid,
  });

  final String name;

  /// Each polygon is a list of rings; the first ring is the outline and
  /// any further rings are holes.
  final List<List<List<LatLng>>> polygons;
  final LatLng centroid;
}

LatLng _ringCentroid(List<LatLng> ring) {
  var lat = 0.0;
  var lng = 0.0;
  for (final p in ring) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / ring.length, lng / ring.length);
}

/// Parses a boundary FeatureCollection. Pure function so it can be unit
/// tested without assets.
List<RegionBoundary> parseRegionBoundaries(String geojson) {
  final collection = jsonDecode(geojson) as Map<String, dynamic>;
  final boundaries = <RegionBoundary>[];
  for (final feature in (collection['features'] as List)) {
    final geometry = feature['geometry'] as Map<String, dynamic>;
    final coords = geometry['coordinates'] as List;
    final polys = geometry['type'] == 'Polygon' ? [coords] : coords;
    var biggest = <LatLng>[];
    final polygons = <List<List<LatLng>>>[];
    for (final poly in polys) {
      final rings = <List<LatLng>>[];
      for (final ring in poly as List) {
        final points = [
          for (final c in ring as List)
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ];
        rings.add(points);
        if (points.length > biggest.length) biggest = points;
      }
      polygons.add(rings);
    }
    boundaries.add(RegionBoundary(
      name: (feature['properties'] as Map<String, dynamic>)['name'] as String,
      polygons: polygons,
      centroid: _ringCentroid(biggest),
    ));
  }
  return boundaries;
}

/// Choropleth of report counts per region. Tapping a region (or its count
/// badge) reports its name through [onRegionTap].
class RegionChoropleth extends StatefulWidget {
  const RegionChoropleth({
    super.key,
    required this.regions,
    required this.counts,
    required this.onRegionTap,
    this.height = 260,
    this.tileProvider,
    this.mapController,
  });

  final List<RegionBoundary> regions;

  /// Region name -> report count. Missing names count as zero.
  final Map<String, int> counts;
  final ValueChanged<String> onRegionTap;
  final double height;
  final TileProvider? tileProvider;

  /// Optional controller (e.g. for tapping region bodies in widget tests).
  final MapController? mapController;

  @override
  State<RegionChoropleth> createState() => _RegionChoroplethState();
}

class _RegionChoroplethState extends State<RegionChoropleth> {
  final LayerHitNotifier<String> _hitNotifier = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _hitNotifier.addListener(_onHit);
  }

  @override
  void dispose() {
    _hitNotifier
      ..removeListener(_onHit)
      ..dispose();
    super.dispose();
  }

  void _onHit() {
    final hit = _hitNotifier.value;
    final name = hit?.hitValues.isNotEmpty == true ? hit!.hitValues.first : null;
    if (name != null) widget.onRegionTap(name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxCount = widget.counts.values.fold<int>(0, (a, b) => a > b ? a : b);
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLng = double.infinity;
    var maxLng = -double.infinity;
    for (final region in widget.regions) {
      for (final poly in region.polygons) {
        for (final ring in poly) {
          for (final p in ring) {
            if (p.latitude < minLat) minLat = p.latitude;
            if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLng) minLng = p.longitude;
            if (p.longitude > maxLng) maxLng = p.longitude;
          }
        }
      }
    }
    // Fixed framing from the data bounds: deterministic in tests and
    // free of fit-animation machinery.
    final span = math.max(maxLat - minLat, maxLng - minLng);
    final zoom = span > 20
        ? 4.0
        : span > 10
            ? 5.0
            : span > 5
                ? 6.0
                : 7.0;
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          mapController: widget.mapController,
          options: MapOptions(
            initialCenter:
                LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
            initialZoom: zoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.garbagetrack.garbagetrack',
              tileProvider: widget.tileProvider,
            ),
            PolygonLayer(
              hitNotifier: _hitNotifier,
              polygons: [
                for (final region in widget.regions)
                  for (final poly in region.polygons)
                    Polygon(
                      points: poly.first,
                      holePointsList: poly.skip(1).toList(),
                      color: scheme.primary.withValues(
                        alpha: _fillAlpha(
                            widget.counts[region.name] ?? 0, maxCount),
                      ),
                      borderColor: scheme.primary,
                      borderStrokeWidth: 2,
                      hitValue: region.name,
                    ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final region in widget.regions)
                  if ((widget.counts[region.name] ?? 0) > 0)
                    Marker(
                      point: region.centroid,
                      width: 36,
                      height: 36,
                      child: GestureDetector(
                        onTap: () => widget.onRegionTap(region.name),
                        child: _CountBadge(
                            count: widget.counts[region.name]!),
                      ),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

double _fillAlpha(int count, int maxCount) {
  // Zero-count regions keep a visible wash so every region's shape reads;
  // counted regions step clearly above it.
  if (count <= 0 || maxCount <= 0) return 0.10;
  return 0.2 + 0.45 * (count / maxCount);
}

/// Tappable count badge pinned at a region's centroid.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.onPrimary, width: 2),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
