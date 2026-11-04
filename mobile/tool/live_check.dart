// Live contract check: exercises the app's Dart API layer against a real
// backend. Expects the API at http://127.0.0.1:8000 with a fresh database.
// Run with: dart run tool/live_check.dart
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:garbagetrack/api/ai_api.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/api/auth_api.dart';
import 'package:garbagetrack/api/garbage_api.dart';
import 'package:garbagetrack/api/logistics_api.dart';
import 'package:garbagetrack/api/truck_api.dart';
import 'package:garbagetrack/api/user_api.dart';
import 'package:garbagetrack/models/models.dart';

var _failures = 0;

void check(bool condition, String label) {
  if (condition) {
    print('ok - $label');
  } else {
    _failures++;
    print('FAIL - $label');
  }
}

Future<void> checkThrows(Future<void> Function() call, int status, String label) async {
  try {
    await call();
    _failures++;
    print('FAIL - $label (no error thrown)');
  } on ApiException catch (e) {
    check(e.statusCode == status, '$label (got ${e.statusCode})');
  }
}

Future<void> main() async {
  var token = '';
  final client = ApiClient(
    baseUrl: 'http://127.0.0.1:8000',
    readToken: () async => token,
  );
  final auth = AuthApi(client);
  final users = UserApi(client);
  final garbage = GarbageApi(client);
  final trucks = TruckApi(client);
  final logistics = LogisticsApi(client);
  final ai = AiApi(client);

  Future<void> loginAs(String email, String password) async {
    final tokens = await auth.login(email: email, password: password);
    token = tokens.accessToken;
  }

  // Seeded admin (driver sets ADMIN_EMAIL/PASSWORD).
  await loginAs('ops@example.com', 'OpsPassword123');
  final allUsers = await auth.listUsers();
  check(allUsers.length == 1 && allUsers.first.role == 'admin', 'admin seeded');

  // Resident flow.
  await auth.register(email: 'r@example.com', password: 'Password123', country: 'Nigeria', fullName: 'Resident User');
  await checkThrows(
    () => auth.register(email: 'r@example.com', password: 'Password123', country: 'Nigeria', fullName: 'Resident User'),
    409,
    'duplicate register -> 409',
  );
  await loginAs('r@example.com', 'Password123');
  final me = await auth.me();
  check(me.role == 'resident' && me.fullName == 'Resident User', 'me has resident role');

  final saved = await users.saveLocation(userId: me.id, longitude: 3.37, latitude: 6.45);
  check(saved.location.latitude == 6.45, 'save location');
  final fetched = await users.getLocation(me.id);
  check(fetched.location.longitude == 3.37, 'read location');

  final image = base64Encode(List<int>.filled(64, 7));
  final post = await garbage.createPost(
    userId: me.id,
    longitude: 3.371,
    latitude: 6.451,
    types: const ['plastic', 'metal'],
    description: 'bags by the gate',
    imageBase64: image,
    imageContentType: 'image/png',
  );
  check(post.hasImage && post.status == 'posted', 'create post with image');
  final mine = await garbage.listPosts(userId: me.id);
  check(mine.length == 1, 'list my posts');
  final near = await garbage.listPosts(longitude: 3.37, latitude: 6.45, maxMeters: 5000);
  check(near.isNotEmpty, 'nearby search');
  final confirmed = await garbage.confirmCollected(post.id);
  check(confirmed.status == 'collected', 'confirm collected');
  await checkThrows(() => garbage.confirmCollected(post.id), 409, 'repeat confirm -> 409');

  final enroute = await trucks.listEnroute();
  check(enroute.isEmpty, 'enroute empty before trucks');
  final classified = await ai.classify(description: 'old phone battery');
  check(classified.placeholder, 'classify placeholder');

  // AuthZ negatives.
  await checkThrows(() => logistics.garbageSummary(), 403, 'resident blocked from logistics');
  await checkThrows(
    () => auth.login(email: 'r@example.com', password: 'Wrongpass1'),
    401,
    'wrong password -> 401',
  );

  // Collector + logistics flow.
  await auth.register(
    email: 'c@example.com',
    password: 'Password123',
    country: 'Nigeria',
    fullName: 'Collector User',
    role: 'collector',
  );
  await auth.register(
    email: 'l@example.com',
    password: 'Password123',
    country: 'Nigeria',
    fullName: 'Logistics User',
    role: 'logistics',
  );
  final post2 = await garbage.createPost(
    userId: me.id,
    longitude: 3.3705,
    latitude: 6.4505,
    types: const ['plastic'],
  );
  check(post2.userId == me.id, 'second post as resident');
  await loginAs('l@example.com', 'Password123');
  final truck = await trucks.createSchedule(
    plateNumber: 'LIVE-1',
    garbageTypes: const ['plastic'],
    longitude: 3.37,
    latitude: 6.45,
    capacity: 5,
  );
  check(truck.plateNumber == 'LIVE-1', 'create truck schedule');
  check(truck.availability == 'available', 'new truck unscheduled');
  await loginAs('c@example.com', 'Password123');
  final route = await trucks.getRoute(truck.id);
  check(route.stops.length == 1 && route.stops.first.distanceMeters != null, 'collector route');

  await loginAs('l@example.com', 'Password123');
  final summary = await logistics.garbageSummary();
  check(summary.total == 2, 'logistics summary');
  final locations = await logistics.truckLocations();
  check(locations.length == 1, 'truck locations');
  final facility = await logistics.createFacility(
    name: 'Live Dump',
    kind: 'dump_site',
    longitude: 3.38,
    latitude: 6.46,
    acceptedTypes: const ['plastic'],
  );
  check(facility.name == 'Live Dump', 'create facility');
  final facilities = await logistics.listFacilities(kind: 'dump_site');
  check(facilities.length == 1, 'list facilities by kind');
  await logistics.updateFacility(facility.id, address: '1 Live Rd');
  await logistics.deleteFacility(facility.id);
  check((await logistics.listFacilities()).isEmpty, 'delete facility');
  await loginAs('r@example.com', 'Password123');
  final post3 = await garbage.createPost(
    userId: me.id,
    longitude: 3.3706,
    latitude: 6.4506,
    types: const ['plastic'],
    district: 'Ojota',
  );
  check(post3.district == 'Ojota', 'district roundtrip');
  await loginAs('l@example.com', 'Password123');
  final depot = await logistics.createFacility(
    name: 'Live Depot',
    kind: 'waste_center',
    longitude: 3.39,
    latitude: 6.47,
    acceptedTypes: const ['plastic'],
  );
  final planned = await logistics.createRoute(
    truckId: truck.id,
    depotIds: [depot.id],
    name: 'Live run',
    postIds: [post3.id],
    collectionPoints: [GeoPoint(longitude: 3.391, latitude: 6.471)],
    district: 'Ojota',
    country: 'Nigeria',
  );
  check(planned.stops.length == 1, 'manual route assignment');
  check(planned.scheduledFor != null, 'route scheduled day defaults');
  check(planned.depotIds.length == 1, 'route depot roundtrip');
  check(planned.collectionPoints.length == 1, 'route collection-point roundtrip');
  check((await logistics.listRoutes(truckId: truck.id)).length == 1, 'list routes');

  // Assignment requires an empty truck, so the vicinity collect happens
  // after the route exists; it picks up both nearby posts.
  await loginAs('c@example.com', 'Password123');
  final collect = await trucks.collectVicinity(truck.id, radiusMeters: 1000);
  check(collect.collectedCount == 2, 'collect vicinity');
  final finished = await trucks.finishRoute(truck.id);
  check(finished.availability == 'available', 'finish route');

  client.close();
  if (_failures > 0) {
    print('LIVE CHECK: $_failures FAILURES');
    throw StateError('live check failed');
  }
  print('LIVE CHECK: ALL PASS');
}
