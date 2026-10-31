import '../models/models.dart';
import 'api_client.dart';

class TruckApi {
  TruckApi(this._client);
  final ApiClient _client;

  Future<Truck> createSchedule({
    required String plateNumber,
    required List<String> garbageTypes,
    String status = 'scheduled',
    String availability = 'available',
    double? longitude,
    double? latitude,
    int? etaMinutes,
    int? capacity,
  }) async {
    final body = await _client.postJson('/trucks/schedules', body: {
      'plate_number': plateNumber,
      'garbage_types': garbageTypes,
      'status': status,
      'availability': availability,
      if (longitude != null && latitude != null)
        'current_location': {'longitude': longitude, 'latitude': latitude},
      if (etaMinutes != null) 'eta_minutes': etaMinutes,
      if (capacity != null) 'capacity': capacity,
    });
    return Truck.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Truck>> listEnroute({
    double? longitude,
    double? latitude,
    double maxMeters = 10000,
    int limit = 50,
  }) async {
    final query = <String, String>{'max_meters': '$maxMeters', 'limit': '$limit'};
    if (longitude != null && latitude != null) {
      query['longitude'] = '$longitude';
      query['latitude'] = '$latitude';
    }
    final body = await _client.get('/trucks/enroute', query: query);
    return (body as List).map((e) => Truck.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Truck> getTruck(String truckId) async {
    final body = await _client.get('/trucks/$truckId');
    return Truck.fromJson(body as Map<String, dynamic>);
  }

  Future<CollectionRoute> getRoute(
    String truckId, {
    double? longitude,
    double? latitude,
    double maxMeters = 5000,
    int limit = 20,
    List<String>? types,
  }) async {
    final query = <String, String>{'max_meters': '$maxMeters', 'limit': '$limit'};
    if (longitude != null && latitude != null) {
      query['longitude'] = '$longitude';
      query['latitude'] = '$latitude';
    }
    final body = await _client.get(
      '/trucks/$truckId/route',
      query: query,
      queryAll: types == null || types.isEmpty ? null : {'types': types},
    );
    return CollectionRoute.fromJson(body as Map<String, dynamic>);
  }

  Future<CollectResult> collectVicinity(
    String truckId, {
    double? longitude,
    double? latitude,
    double radiusMeters = 500,
    List<String>? types,
  }) async {
    final body = await _client.postJson('/trucks/$truckId/collect-vicinity', body: {
      if (longitude != null) 'longitude': longitude,
      if (latitude != null) 'latitude': latitude,
      'radius_meters': radiusMeters,
      if (types != null) 'types': types,
    });
    return CollectResult.fromJson(body as Map<String, dynamic>);
  }

  Future<Truck> setAvailability(String truckId, String availability) async {
    final body = await _client
        .patchJson('/trucks/$truckId/availability', body: {'availability': availability});
    return Truck.fromJson(body as Map<String, dynamic>);
  }
}
