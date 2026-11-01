import 'package:latlong2/latlong.dart';

/// Default map viewport per country so empty maps open on the user's country
/// instead of the whole world.
typedef CountryViewport = ({LatLng center, double zoom});

const worldViewport = (center: LatLng(0, 0), zoom: 2.0);

/// Lowercase country name -> (latitude, longitude, zoom).
const _countryViewports = <String, (double, double, double)>{
  'nigeria': (9.08, 8.68, 6),
  'ghana': (7.95, -1.02, 7),
  'cameroon': (7.37, 12.35, 6),
  'kenya': (0.51, 37.53, 6),
  'ethiopia': (9.15, 40.49, 6),
  'egypt': (26.82, 30.80, 6),
  'south africa': (-28.61, 24.68, 5),
  'united states': (39.83, -98.58, 4),
  'usa': (39.83, -98.58, 4),
  'canada': (56.13, -106.35, 4),
  'brazil': (-10.83, -52.95, 4),
  'united kingdom': (54.09, -2.37, 6),
  'uk': (54.09, -2.37, 6),
  'germany': (51.17, 10.45, 6),
  'france': (46.60, 2.44, 6),
  'hungary': (47.16, 19.50, 7),
  'india': (22.0, 79.0, 5),
  'australia': (-25.27, 133.78, 4),
  'philippines': (12.88, 121.77, 6),
};

/// Looks up [country] case-insensitively; unknown, null, or blank values
/// fall back to the world view.
CountryViewport viewportFor(String? country) {
  final key = country?.trim().toLowerCase() ?? '';
  final entry = _countryViewports[key];
  if (entry == null) return worldViewport;
  return (center: LatLng(entry.$1, entry.$2), zoom: entry.$3);
}
