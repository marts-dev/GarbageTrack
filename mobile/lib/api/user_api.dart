import '../models/models.dart';
import 'api_client.dart';

class UserApi {
  UserApi(this._client);
  final ApiClient _client;

  Future<UserLocation> saveLocation({
    required String userId,
    required double longitude,
    required double latitude,
  }) async {
    final body = await _client.putJson('/users/$userId/location', body: {
      'longitude': longitude,
      'latitude': latitude,
    });
    return UserLocation.fromJson(body as Map<String, dynamic>);
  }

  Future<UserLocation> getLocation(String userId) async {
    final body = await _client.get('/users/$userId/location');
    return UserLocation.fromJson(body as Map<String, dynamic>);
  }
}
