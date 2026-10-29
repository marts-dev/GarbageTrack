import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/models/models.dart';

void main() {
  test('GeoPoint parses coordinates as lon/lat', () {
    final point = GeoPoint.fromJson({
      'type': 'Point',
      'coordinates': [3.37, 6.45],
    });
    expect(point.longitude, 3.37);
    expect(point.latitude, 6.45);
    expect(point.short, '6.4500, 3.3700');
  });

  test('GarbagePost parses full payload', () {
    final post = GarbagePost.fromJson({
      'id': 'p1',
      'user_id': 'u1',
      'location': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'types': ['plastic', 'metal'],
      'description': 'bags',
      'has_image': true,
      'image_content_type': 'image/png',
      'status': 'posted',
      'created_at': '2026-10-29T00:00:00Z',
      'collected_at': null,
    });
    expect(post.types, ['plastic', 'metal']);
    expect(post.hasImage, isTrue);
    expect(post.collectedAt, isNull);
  });

  test('Truck exposes remaining capacity', () {
    final truck = Truck.fromJson({
      'id': 't1',
      'plate_number': 'ABC-123',
      'status': 'enroute',
      'availability': 'working',
      'garbage_types': ['plastic'],
      'current_location': null,
      'eta_minutes': 25,
      'capacity': 10,
      'load': 4,
      'created_at': '2026-10-29T00:00:00Z',
    });
    expect(truck.remainingCapacity, 6);
    expect(truck.currentLocation, isNull);
  });

  test('CollectionRoute parses stops with distances', () {
    final route = CollectionRoute.fromJson({
      'truck_id': 't1',
      'origin': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'remaining_capacity': 2,
      'stops': [
        {
          'post_id': 'p1',
          'location': {
            'type': 'Point',
            'coordinates': [3.371, 6.451]
          },
          'types': ['plastic'],
          'status': 'posted',
          'distance_meters': 150.5,
        }
      ],
    });
    expect(route.stops, hasLength(1));
    expect(route.stops.first.distanceMeters, 150.5);
  });

  test('User role helpers treat admin as everything', () {
    final admin = User.fromJson({
      'id': 'u1',
      'email': 'a@x.com',
      'full_name': 'Admin User',
      'role': 'admin',
      'is_active': true,
      'created_at': '2026-10-29T00:00:00Z',
    });
    expect(admin.isAdmin, isTrue);
    expect(admin.isCollector, isTrue);
    expect(admin.isLogistics, isTrue);

    final resident = User.fromJson({
      'id': 'u2',
      'email': 'r@x.com',
      'full_name': 'Resident User',
      'role': 'resident',
      'is_active': true,
      'created_at': '2026-10-29T00:00:00Z',
    });
    expect(resident.isCollector, isFalse);
    expect(admin.displayName, 'Admin User');
    expect(resident.displayName, 'Resident User');

    final nameless = User.fromJson({
      'id': 'u3',
      'email': 'n@x.com',
      'full_name': null,
      'role': 'collector',
      'is_active': true,
      'created_at': '2026-10-29T00:00:00Z',
    });
    expect(nameless.displayName, 'Collector');
  });

  test('Facility and summary parse', () {
    final facility = Facility.fromJson({
      'id': 'f1',
      'name': 'North Recycler',
      'kind': 'recycling',
      'location': {
        'type': 'Point',
        'coordinates': [3.38, 6.46]
      },
      'accepted_types': ['plastic'],
      'address': null,
      'created_at': '2026-10-29T00:00:00Z',
      'updated_at': '2026-10-29T00:00:00Z',
    });
    expect(facility.kind, 'recycling');

    final summary = GarbageSummary.fromJson({
      'total': 2,
      'by_status': {'posted': 2},
      'by_type': {'plastic': 1, 'organic': 1},
    });
    expect(summary.total, 2);
    expect(summary.byType['organic'], 1);
  });

  test('pretty formats snake_case labels', () {
    expect(pretty('dump_site'), 'Dump Site');
    expect(pretty('enroute'), 'Enroute');
  });
}
