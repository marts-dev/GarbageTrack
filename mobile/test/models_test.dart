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
    expect(truck.operatorId, isNull);
    expect(truck.isAssigned, isFalse);
  });

  test('Truck parses operator_id and tolerates legacy payloads', () {
    Map<String, dynamic> payload({Object? operatorId = 'missing'}) => {
          'id': 't1',
          'plate_number': 'ABC-123',
          'status': 'scheduled',
          'availability': 'available',
          'garbage_types': ['plastic'],
          'current_location': null,
          'eta_minutes': null,
          'capacity': null,
          'load': 0,
          if (operatorId != 'missing') 'operator_id': operatorId,
          'created_at': '2026-10-29T00:00:00Z',
        };
    final assigned = Truck.fromJson(payload(operatorId: 'u1'));
    expect(assigned.operatorId, 'u1');
    expect(assigned.isAssigned, isTrue);
    expect(assigned.isOperatedBy('u1'), isTrue);
    expect(assigned.isOperatedBy('u2'), isFalse);

    final legacy = Truck.fromJson(payload());
    expect(legacy.operatorId, isNull);
    expect(legacy.isAssigned, isFalse);
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

  test('User parses country and depot binding', () {
    final withCountry = User.fromJson({
      'id': 'u1',
      'email': 'r@x.com',
      'full_name': null,
      'role': 'resident',
      'is_active': true,
      'country': 'Nigeria',
    });
    expect(withCountry.country, 'Nigeria');
    expect(withCountry.depotId, isNull);

    final bound = User.fromJson({
      'id': 'u9',
      'email': 'd@x.com',
      'full_name': null,
      'role': 'depot',
      'is_active': true,
      'country': 'Nigeria',
      'depot_id': 'f1',
    });
    expect(bound.depotId, 'f1');

    final legacy = User.fromJson({
      'id': 'u2',
      'email': 'old@x.com',
      'full_name': null,
      'role': 'resident',
      'is_active': true,
      'country': null,
    });
    expect(legacy.country, isNull);

    final missingKey = User.fromJson({
      'id': 'u3',
      'email': 'older@x.com',
      'full_name': null,
      'role': 'resident',
      'is_active': true,
    });
    expect(missingKey.country, isNull);
    expect(missingKey.depotId, isNull);
  });

  test('DepotReceipt parses a receive record', () {
    final receipt = DepotReceipt.fromJson({
      'id': 'r1',
      'depot_id': 'f1',
      'truck_id': 't1',
      'plate_number': 'DEP-1',
      'load_cleared': 2,
      'received_by': 'u9',
      'received_at': '2026-11-03T08:00:00Z',
    });
    expect(receipt.plateNumber, 'DEP-1');
    expect(receipt.loadCleared, 2);
    expect(receipt.receivedAt, DateTime.parse('2026-11-03T08:00:00Z'));
  });

  test('isResident is true only for residents', () {
    User userWith(String role) => User(
          id: 'u1',
          email: 'u@x.com',
          role: role,
          isActive: true,
        );
    expect(userWith('resident').isResident, isTrue);
    expect(userWith('collector').isResident, isFalse);
    expect(userWith('logistics').isResident, isFalse);
    expect(userWith('admin').isResident, isFalse);
  });

  test('GarbagePost parses district, null, and missing key', () {
    GarbagePost postWith(Object? district, {bool includeKey = true}) =>
        GarbagePost.fromJson({
          'id': 'p1',
          'user_id': 'u1',
          'location': {
            'type': 'Point',
            'coordinates': [3.37, 6.45]
          },
          'types': ['plastic'],
          'description': null,
          if (includeKey) 'district': district,
          'has_image': false,
          'image_content_type': null,
          'status': 'posted',
          'created_at': '2026-10-29T00:00:00Z',
          'collected_at': null,
        });
    expect(postWith('Ojota').district, 'Ojota');
    expect(postWith(null).district, isNull);
    expect(postWith(null, includeKey: false).district, isNull);
  });

  test('PlannedRoute parses depot_ids and collection_points', () {
    final route = PlannedRoute.fromJson({
      'id': 'r1',
      'truck_id': 't1',
      'name': 'Morning run',
      'origin': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'stops': [],
      'status': 'assigned',
      'created_at': '2026-10-29T00:00:00Z',
      'depot_ids': ['f1', 'f2'],
      'collection_points': [
        {
          'type': 'Point',
          'coordinates': [3.38, 6.46]
        },
      ],
    });
    expect(route.depotIds, ['f1', 'f2']);
    expect(route.collectionPoints, hasLength(1));
    expect(route.collectionPoints.first.short, '6.4600, 3.3800');
  });

  test('PlannedRoute defaults missing depot/point keys to empty', () {
    final route = PlannedRoute.fromJson({
      'id': 'r1',
      'truck_id': 't1',
      'name': null,
      'origin': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'stops': [],
      'status': 'assigned',
      'created_at': '2026-10-29T00:00:00Z',
    });
    expect(route.depotIds, isEmpty);
    expect(route.collectionPoints, isEmpty);
  });
}
