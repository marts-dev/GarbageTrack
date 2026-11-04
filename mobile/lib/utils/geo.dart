import 'package:latlong2/latlong.dart';

import '../models/models.dart';

/// Coordinate conversions between the API model and flutter_map.
///
/// [GeoPoint] stores GeoJSON order (longitude, latitude) while [LatLng]
/// stores (latitude, longitude); these extensions keep the swap in one place.
extension GeoPointLatLng on GeoPoint {
  LatLng get latLng => LatLng(latitude, longitude);
}

extension LatLngGeoPoint on LatLng {
  GeoPoint get geoPoint => GeoPoint(longitude: longitude, latitude: latitude);
}

/// Great-circle distance in meters between two points.
double metersBetween(GeoPoint a, GeoPoint b) =>
    const Distance()(a.latLng, b.latLng);

/// '40 m' below a kilometer, '1.2 km' above ('5 km' when whole, and
/// whole kilometers past 10).
String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000;
  if (km >= 10) return '${km.toStringAsFixed(0)} km';
  final one = km.toStringAsFixed(1);
  return '${one.endsWith('.0') ? one.substring(0, one.length - 2) : one} km';
}

/// Ray-casting point-in-polygon test (longitude = x, latitude = y).
///
/// Returns true for points strictly inside [ring] and for points on an edge
/// or vertex. Rings with fewer than 3 vertices never contain anything; the
/// ring is treated as implicitly closed.
bool pointInPolygon(GeoPoint point, List<GeoPoint> ring) {
  if (ring.length < 3) return false;
  final x = point.longitude;
  final y = point.latitude;
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude;
    final yi = ring[i].latitude;
    final xj = ring[j].longitude;
    final yj = ring[j].latitude;
    // On-segment check so boundary points count as enclosed.
    final cross = (y - yi) * (xj - xi) - (x - xi) * (yj - yi);
    if (cross == 0 &&
        x >= (xi < xj ? xi : xj) &&
        x <= (xi > xj ? xi : xj) &&
        y >= (yi < yj ? yi : yj) &&
        y <= (yi > yj ? yi : yj)) {
      return true;
    }
    if ((yi > y) != (yj > y)) {
      final intersectX = xi + (xj - xi) * (y - yi) / (yj - yi);
      if (x < intersectX) inside = !inside;
    }
  }
  return inside;
}
