import '../models/models.dart';
import 'api_client.dart';

class AuthApi {
  AuthApi(this._client);
  final ApiClient _client;

  Future<User> register({
    required String email,
    required String password,
    required String country,
    String? fullName,
    String role = 'resident',
  }) async {
    final body = await _client.postJson('/auth/register', auth: false, body: {
      'email': email,
      'password': password,
      'country': country,
      if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
      'role': role,
    });
    return User.fromJson(body as Map<String, dynamic>);
  }

  Future<Tokens> login({required String email, required String password}) async {
    final body = await _client.postForm('/auth/login', fields: {
      'username': email,
      'password': password,
    });
    return Tokens.fromJson(body as Map<String, dynamic>);
  }

  Future<Tokens> refresh(String refreshToken) async {
    final body = await _client.postJson('/auth/refresh', auth: false, body: {
      'refresh_token': refreshToken,
    });
    return Tokens.fromJson(body as Map<String, dynamic>);
  }

  Future<User> me() async {
    final body = await _client.get('/auth/me');
    return User.fromJson(body as Map<String, dynamic>);
  }

  Future<List<User>> listUsers({String? role}) async {
    final body = await _client.get(
      '/auth/users',
      query: role == null ? null : {'role': role},
    );
    return (body as List).map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<User> updateProfile(String fullName) async {
    final body = await _client.patchJson('/auth/me', body: {'full_name': fullName});
    return User.fromJson(body as Map<String, dynamic>);
  }

  Future<User> updateRole(String userId, String role) async {
    final body = await _client.patchJson('/auth/users/$userId/role', body: {'role': role});
    return User.fromJson(body as Map<String, dynamic>);
  }
}
