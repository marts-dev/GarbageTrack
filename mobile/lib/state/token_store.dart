import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token persistence with an in-memory fallback for platforms where secure
/// storage is unavailable (e.g. some desktop builds).
class TokenStore {
  static const accessKey = 'garbagetrack_access_token';
  static const refreshKey = 'garbagetrack_refresh_token';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final Map<String, String?> _memory = {};

  Future<String?> read(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null) return value;
    } catch (_) {
      // Fall through to the in-memory copy.
    }
    return _memory[key];
  }

  Future<void> write(String key, String value) async {
    _memory[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // In-memory copy already saved.
    }
  }

  Future<void> delete(String key) async {
    _memory.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Nothing more to do.
    }
  }

  Future<void> clear() async {
    await delete(accessKey);
    await delete(refreshKey);
  }
}
