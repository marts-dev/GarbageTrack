import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/api/auth_api.dart';
import 'package:garbagetrack/api/garbage_api.dart';
import 'package:garbagetrack/api/logistics_api.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _client(
  Future<http.Response> Function(http.Request request) handler,
) =>
    ApiClient(baseUrl: 'http://x', httpClient: MockClient(handler));

Map<String, dynamic> _postJson({String? district}) => {
      'id': 'p1',
      'user_id': 'u1',
      'location': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'types': ['plastic'],
      'description': null,
      'district': district,
      'country': 'Nigeria',
      'has_image': false,
      'image_content_type': null,
      'status': 'posted',
      'created_at': '2026-10-29T00:00:00Z',
      'collected_at': null,
    };

void main() {
  test('register sends country', () async {
    Map<String, dynamic>? seen;
    final api = AuthApi(_client((request) async {
      seen = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'id': 'u1',
          'email': 'r@x.com',
          'full_name': null,
          'role': 'resident',
          'is_active': true,
          'country': 'Nigeria',
        }),
        200,
      );
    }));
    final user = await api.register(
      email: 'r@x.com',
      password: 'password1',
      country: 'Nigeria',
    );
    expect(seen!['country'], 'Nigeria');
    expect(user.country, 'Nigeria');
  });

  test('createPost sends district and omits it when empty', () async {
    Map<String, dynamic>? seen;
    final api = GarbageApi(_client((request) async {
      seen = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode(_postJson(district: 'Ojota')), 200);
    }));
    final post = await api.createPost(
      userId: 'u1',
      longitude: 3.37,
      latitude: 6.45,
      types: const ['plastic'],
      district: 'Ojota',
    );
    expect(seen!['district'], 'Ojota');
    expect(post.district, 'Ojota');

    await api.createPost(
      userId: 'u1',
      longitude: 3.37,
      latitude: 6.45,
      types: const ['plastic'],
    );
    expect(seen!.containsKey('district'), isFalse);
  });

  test('listPosts sends district and country filters', () async {
    Uri? seen;
    final api = GarbageApi(_client((request) async {
      seen = request.url;
      return http.Response('[]', 200);
    }));
    await api.listPosts(district: 'Ojota', country: 'Nigeria');
    expect(seen!.queryParameters['district'], 'Ojota');
    expect(seen!.queryParameters['country'], 'Nigeria');
  });

  test('listAllPosts sends district and country filters', () async {
    Uri? seen;
    final api = LogisticsApi(_client((request) async {
      seen = request.url;
      return http.Response('[]', 200);
    }));
    await api.listAllPosts(status: 'posted', district: 'Ikeja', country: 'Nigeria');
    expect(seen!.path, '/api/v1/logistics/garbage');
    expect(seen!.queryParameters['district'], 'Ikeja');
    expect(seen!.queryParameters['country'], 'Nigeria');
  });

  test('createRoute sends depot_ids and flat collection_points', () async {
    Map<String, dynamic>? seen;
    final api = LogisticsApi(_client((request) async {
      seen = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
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
          'depot_ids': ['f1', 'f2'],
          'collection_points': [
            {
              'type': 'Point',
              'coordinates': [3.38, 6.46]
            },
          ],
        }),
        200,
      );
    }));
    final route = await api.createRoute(
      truckId: 't1',
      depotIds: const ['f1', 'f2'],
      postIds: const ['p1'],
      collectionPoints: [GeoPoint(longitude: 3.38, latitude: 6.46)],
      district: 'Ojota',
      country: 'Nigeria',
    );
    expect(seen!['depot_ids'], ['f1', 'f2']);
    expect(
      seen!['collection_points'],
      [
        {'longitude': 3.38, 'latitude': 6.46}
      ],
    );
    expect(seen!['district'], 'Ojota');
    expect(seen!['country'], 'Nigeria');
    expect(route.depotIds, ['f1', 'f2']);
    expect(route.collectionPoints, hasLength(1));
  });

  test('createRoute omits empty collection_points', () async {
    Map<String, dynamic>? seen;
    final api = LogisticsApi(_client((request) async {
      seen = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
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
          'depot_ids': ['f1'],
          'collection_points': [],
        }),
        200,
      );
    }));
    await api.createRoute(truckId: 't1', depotIds: const ['f1']);
    expect(seen!['depot_ids'], ['f1']);
    expect(seen!.containsKey('collection_points'), isFalse);
  });
}
