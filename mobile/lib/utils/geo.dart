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
