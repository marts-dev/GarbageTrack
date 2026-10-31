import '../models/models.dart';
import 'api_client.dart';

class LogisticsApi {
  LogisticsApi(this._client);
  final ApiClient _client;

  Future<List<GarbagePost>> listAllPosts({
    String? status,
    String? type,
    String? userId,
    int limit = 100,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (status != null) query['status'] = status;
    if (type != null) query['type'] = type;
    if (userId != null) query['user_id'] = userId;
    final body = await _client.get('/logistics/garbage', query: query);
    return (body as List)
        .map((e) => GarbagePost.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<GarbageSummary> garbageSummary() async {
    final body = await _client.get('/logistics/garbage/summary');
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
    String? name,
    List<String>? postIds,
    double? longitude,
    double? latitude,
    double maxMeters = 5000,
    int limit = 20,
    List<String>? types,
  }) async {
    final body = await _client.postJson('/logistics/routes', body: {
      'truck_id': truckId,
      if (name != null && name.isNotEmpty) 'name': name,
      if (postIds != null) 'post_ids': postIds,
      if (longitude != null) 'longitude': longitude,
      if (latitude != null) 'latitude': latitude,
      'max_meters': maxMeters,
      'limit': limit,
      if (types != null) 'types': types,
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
}
