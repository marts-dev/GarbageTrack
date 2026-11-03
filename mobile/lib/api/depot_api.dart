import '../models/models.dart';
import 'api_client.dart';

class DepotApi {
  DepotApi(this._client);
  final ApiClient _client;

  Future<Facility> myDepot() async {
    final body = await _client.get('/depots/mine');
    return Facility.fromJson(body as Map<String, dynamic>);
  }

  /// Trucks currently carrying a load: the actionable receive list.
  /// Registers a new depot and binds the caller to it in one call.
  Future<Facility> registerDepot({
    required String name,
    required String kind,
    required double longitude,
    required double latitude,
    required List<String> acceptedTypes,
    String? address,
  }) async {
    final body = await _client.postJson('/depots/mine/register', body: {
      'name': name,
      'kind': kind,
      'location': {'longitude': longitude, 'latitude': latitude},
      'accepted_types': acceptedTypes,
      if (address != null && address.isNotEmpty) 'address': address,
    });
    return Facility.fromJson(body as Map<String, dynamic>);
  }

  /// Binds the caller to an existing depot (e.g. second staff member).
  Future<Facility> joinDepot(String facilityId) async {
    final body = await _client.postJson('/depots/mine/join', body: {
      'facility_id': facilityId,
    });
    return Facility.fromJson(body as Map<String, dynamic>);
  }

  Future<List<Truck>> inboundTrucks() async {
    final body = await _client.get('/depots/mine/trucks');
    return (body as List)
        .map((e) => Truck.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DepotReceipt> receive(String truckId) async {
    final body = await _client.postJson('/depots/mine/receive', body: {
      'truck_id': truckId,
    });
    return DepotReceipt.fromJson(body as Map<String, dynamic>);
  }

  Future<List<DepotReceipt>> receipts({int limit = 50}) async {
    final body = await _client.get('/depots/mine/receipts',
        query: {'limit': '$limit'});
    return (body as List)
        .map((e) => DepotReceipt.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
