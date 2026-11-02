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

bool _pointInRing(LatLng point, List<LatLng> ring) {
  var inside = false;
  var j = ring.length - 1;
  for (var i = 0; i < ring.length; i++) {
    final xi = ring[i].longitude;
    final yi = ring[i].latitude;
    final xj = ring[j].longitude;
    final yj = ring[j].latitude;
    if ((yi > point.latitude) != (yj > point.latitude) &&
        point.longitude <
            (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
    j = i;
  }
  return inside;
}

/// Name of the region containing [point], or null when outside all of
/// them. Holes are respected. Pure so taps resolve without depending on
/// the layer hit notifier (which also fires on mouse hover).
String? regionContaining(List<RegionBoundary> regions, LatLng point) {
  for (final region in regions) {
    for (final poly in region.polygons) {
      if (!_pointInRing(point, poly.first)) continue;
      if (poly.skip(1).any((hole) => _pointInRing(point, hole))) continue;
      return region.name;
    }
  }
  return null;
}

/// Choropleth of report counts per region. Tapping a region (or its count
/// badge) reports its name through [onRegionTap].
///
/// Taps resolve through [regionContaining] on [MapOptions.onTap], never the
/// layer hit notifier: the notifier also fires on mouse hover, which would
/// open the breakdown sheet just for moving the pointer across a region.
class RegionChoropleth extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxCount = counts.values.fold<int>(0, (a, b) => a > b ? a : b);
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLng = double.infinity;
    var maxLng = -double.infinity;
    for (final region in regions) {
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
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter:
                LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
            initialZoom: zoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onTap: (_, ll) {
              final name = regionContaining(regions, ll);
              if (name != null) onRegionTap(name);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.garbagetrack.garbagetrack',
              tileProvider: tileProvider,
            ),
            PolygonLayer(
              polygons: [
                for (final region in regions)
                  for (final poly in region.polygons)
                    Polygon(
                      points: poly.first,
                      holePointsList: poly.skip(1).toList(),
                      color: scheme.primary.withValues(
                        alpha: _fillAlpha(
                            counts[region.name] ?? 0, maxCount),
                      ),
                      borderColor: scheme.primary,
                      borderStrokeWidth: 2,
                      // Labels each polygon with its region (used by tests
                      // to prove every region draws); selection resolves
                      // through onTap, not the hit notifier.
                      hitValue: region.name,
                    ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final region in regions)
                  if ((counts[region.name] ?? 0) > 0)
                    Marker(
                      point: region.centroid,
                      width: 36,
                      height: 36,
                      child: GestureDetector(
                        onTap: () => onRegionTap(region.name),
                        child: _CountBadge(
                            count: counts[region.name]!),
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
