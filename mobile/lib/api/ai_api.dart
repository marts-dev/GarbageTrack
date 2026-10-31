import '../models/models.dart';
import 'api_client.dart';

class AiApi {
  AiApi(this._client);
  final ApiClient _client;

  Future<ClassifyResult> classify({required String description, String? imageBase64}) async {
    final body = await _client.postJson('/ai/classify', body: {
      'description': description,
      if (imageBase64 != null) 'image_base64': imageBase64,
    });
    return ClassifyResult.fromJson(body as Map<String, dynamic>);
  }
}
