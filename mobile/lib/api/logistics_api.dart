import '../models/models.dart';
import 'api_client.dart';

class LogisticsApi {
  LogisticsApi(this._client);
  final ApiClient _client;

  Future<List<GarbagePost>> listAllPosts({
    String? status,
    String? type,
    String? userId,
    String? district,
    String? country,
    int limit = 100,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (status != null) query['status'] = status;
    if (type != null) query['type'] = type;
    if (userId != null) query['user_id'] = userId;
    if (district != null && district.isNotEmpty) query['district'] = district;
    if (country != null && country.isNotEmpty) query['country'] = country;
    final body = await _client.get('/logistics/garbage', query: query);
    return (body as List)
        .map((e) => GarbagePost.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<GarbageSummary> garbageSummary({String? country}) async {
    final body = await _client.get(
      '/logistics/garbage/summary',
      query: country == null ? null : {'country': country},
    );
    return GarbageSummary.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Truck>> truckLocations({String? status, String? availability}) async {
    final query = <String, String>{};
    if (status != null) query['status'] = status;
    if (availability != null) query['availability'] = availability;
    // TruckLocationResponse shares the fields Truck needs except id/plate naming.
    final body = await _client.get('/logistics/trucks/locations', query: query);
    return (body as List).map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return Truck(
        id: m['truck_id'] as String,
        plateNumber: m['plate_number'] as String,
        status: m['status'] as String,
        availability: m['availability'] as String? ?? 'available',
        garbageTypes: const [],
        load: (m['load'] as num?)?.toInt() ?? 0,
        currentLocation: m['current_location'] == null
            ? null
            : GeoPoint.fromJson(m['current_location'] as Map<String, dynamic>),
        capacity: (m['capacity'] as num?)?.toInt(),
        operatorId: m['operator_id'] as String?,
      );
    }).toList();
  }

  Future<Facility> createFacility({
    required String name,
    required String kind,
    required double longitude,
    required double latitude,
    required List<String> acceptedTypes,
    String? address,
  }) async {
    final body = await _client.postJson('/logistics/facilities', body: {
      'name': name,
      'kind': kind,
      'location': {'longitude': longitude, 'latitude': latitude},
      'accepted_types': acceptedTypes,
      if (address != null && address.isNotEmpty) 'address': address,
    });
    return Facility.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Facility>> listFacilities({
    String? kind,
    double? longitude,
    double? latitude,
    double maxMeters = 10000,
    int limit = 50,
  }) async {
    final query = <String, String>{'max_meters': '$maxMeters', 'limit': '$limit'};
    if (kind != null) query['kind'] = kind;
    if (longitude != null && latitude != null) {
      query['longitude'] = '$longitude';
      query['latitude'] = '$latitude';
    }
    final body = await _client.get('/logistics/facilities', query: query);
    return (body as List).map((e) => Facility.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Facility> updateFacility(
    String facilityId, {
    String? name,
    String? kind,
    double? longitude,
    double? latitude,
    List<String>? acceptedTypes,
    String? address,
  }) async {
    final body = await _client.patchJson('/logistics/facilities/$facilityId', body: {
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (longitude != null && latitude != null)
        'location': {'longitude': longitude, 'latitude': latitude},
      if (acceptedTypes != null) 'accepted_types': acceptedTypes,
      if (address != null) 'address': address,
    });
    return Facility.fromJson(body as Map<String, dynamic>);
  }

  Future<void> deleteFacility(String facilityId) async {
    await _client.delete('/logistics/facilities/$facilityId');
  }

  Future<PlannedRoute> createRoute({
    required String truckId,
    required List<String> depotIds,
    String? name,
    List<String>? postIds,
    List<GeoPoint>? collectionPoints,
    double? longitude,
    double? latitude,
    double maxMeters = 5000,
    int limit = 20,
    List<String>? types,
    String? district,
    String? country,
  }) async {
    final body = await _client.postJson('/logistics/routes', body: {
      'truck_id': truckId,
      'depot_ids': depotIds,
      if (name != null && name.isNotEmpty) 'name': name,
      if (postIds != null) 'post_ids': postIds,
      // Flat {longitude, latitude} shape; the API returns GeoJSON.
      if (collectionPoints != null && collectionPoints.isNotEmpty)
        'collection_points': [
          for (final p in collectionPoints)
            {'longitude': p.longitude, 'latitude': p.latitude},
        ],
      if (longitude != null) 'longitude': longitude,
      if (latitude != null) 'latitude': latitude,
      'max_meters': maxMeters,
      'limit': limit,
      if (types != null) 'types': types,
      // district/country narrow stop candidates on the auto-generate path;
      // the manual post_ids path ignores them.
      if (district != null && district.isNotEmpty) 'district': district,
      if (country != null && country.isNotEmpty) 'country': country,
    });
    return PlannedRoute.fromJson(body as Map<String, dynamic>);
  }

  Future<List<PlannedRoute>> listRoutes({String? truckId, String? status}) async {
    final query = <String, String>{};
    if (truckId != null) query['truck_id'] = truckId;
    if (status != null) query['status'] = status;
    final body = await _client.get('/logistics/routes', query: query);
    return (body as List)
        .map((e) => PlannedRoute.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Deletes a planned route, releasing its scheduled stops back to posted.
  /// 404 when the route id is unknown.
  Future<void> deleteRoute(String routeId) async {
    await _client.delete('/logistics/routes/$routeId');
  }
}
