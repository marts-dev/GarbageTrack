import '../models/models.dart';
import 'api_client.dart';

class GarbageApi {
  GarbageApi(this._client);
  final ApiClient _client;

  Future<GarbagePost> createPost({
    required String userId,
    required double longitude,
    required double latitude,
    required List<String> types,
    String? description,
    String? district,
    String? imageBase64,
    String? imageContentType,
  }) async {
    final body = await _client.postJson('/garbage', body: {
      'user_id': userId,
      'longitude': longitude,
      'latitude': latitude,
      'types': types,
      if (description != null && description.isNotEmpty) 'description': description,
      if (district != null && district.isNotEmpty) 'district': district,
      if (imageBase64 != null) 'image_base64': imageBase64,
      if (imageContentType != null) 'image_content_type': imageContentType,
    });
    return GarbagePost.fromJson(body as Map<String, dynamic>);
  }

  Future<List<GarbagePost>> listPosts({
    String? userId,
    String? status,
    String? district,
    String? country,
    double? longitude,
    double? latitude,
    double maxMeters = 5000,
    int limit = 50,
  }) async {
    final query = <String, String>{'max_meters': '$maxMeters', 'limit': '$limit'};
    if (userId != null) query['user_id'] = userId;
    if (status != null) query['status'] = status;
    if (district != null && district.isNotEmpty) query['district'] = district;
    if (country != null && country.isNotEmpty) query['country'] = country;
    if (longitude != null && latitude != null) {
      query['longitude'] = '$longitude';
      query['latitude'] = '$latitude';
    }
    final body = await _client.get('/garbage', query: query);
    return (body as List)
        .map((e) => GarbagePost.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<GarbagePost> getPost(String postId) async {
    final body = await _client.get('/garbage/$postId');
    return GarbagePost.fromJson(body as Map<String, dynamic>);
  }

  Future<GarbagePost> confirmCollected(String postId) async {
    final body = await _client.patchJson('/garbage/$postId/confirm-collected');
    return GarbagePost.fromJson(body as Map<String, dynamic>);
  }
}
