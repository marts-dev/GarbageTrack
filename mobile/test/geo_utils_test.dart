import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/utils/geo.dart';

void main() {
  group('distance helpers', () {
    test('metersBetween is zero for identical points and symmetric', () {
      final a = GeoPoint(longitude: 3.37, latitude: 6.45);
      final b = GeoPoint(longitude: 3.38, latitude: 6.46);
      expect(metersBetween(a, a), 0);
      expect(metersBetween(a, b), metersBetween(b, a));
    });

    test('metersBetween matches known separations', () {
      // One degree of latitude is about 110.6 km.
      expect(
        metersBetween(
          GeoPoint(longitude: 0, latitude: 0),
          GeoPoint(longitude: 0, latitude: 1),
        ),
        closeTo(110600, 200),
      );
      // About 1.57 km diagonally across Quezon City test points.
      expect(
        metersBetween(
          GeoPoint(longitude: 3.37, latitude: 6.45),
          GeoPoint(longitude: 3.38, latitude: 6.46),
        ),
        closeTo(1566, 10),
      );
    });

    test('formatDistance switches units at a kilometer', () {
      expect(formatDistance(0), '0 m');
      expect(formatDistance(40.4), '40 m');
      expect(formatDistance(1566), '1.6 km');
      expect(formatDistance(12400), '12 km');
    });
  });
}
