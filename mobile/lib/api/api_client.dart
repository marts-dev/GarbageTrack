import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thrown for API-level failures (non-2xx or unreachable host).
class ApiException implements Exception {
  final int statusCode;
  final String message;

  /// [statusCode] is 0 when the request never reached the server.
  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin JSON wrapper over package:http with bearer auth and one refresh retry.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.readToken,
    this.refreshTokens,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;

  /// Returns the current access token, or null for anonymous calls.
  final Future<String?> Function()? readToken;

  /// Refreshes tokens. Returns true when the call may be retried.
  final Future<bool> Function()? refreshTokens;

  final http.Client _http;

  Uri _uri(String path,
      [Map<String, String>? query, Map<String, List<String>>? queryAll]) {
    final base = Uri.parse('$baseUrl/api/v1$path');
    final merged = <String, List<String>>{...base.queryParametersAll};
    query?.forEach((key, value) => merged[key] = [value]);
    queryAll?.forEach((key, values) => merged[key] = [...?merged[key], ...values]);
    if (merged.isEmpty) return base;
    final parts = <String>[];
    merged.forEach((key, values) {
      for (final value in values) {
        parts.add('${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}');
      }
    });
    return base.replace(query: parts.join('&'));
  }

  Future<Map<String, String>> _headers({bool auth = true, bool json = true}) async {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    if (auth) {
      final token = await readToken?.call();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode == 204 || response.body.isEmpty) return null;
    final body = jsonDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    final detail = body is Map ? body['detail'] : null;
    throw ApiException(response.statusCode, detail?.toString() ?? 'Request failed');
  }

  Future<http.Response> _guarded(
    Future<http.Response> Function(Map<String, String> headers) call,
    Map<String, String> headers,
  ) async {
    try {
      return await call(headers);
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Cannot reach server: ${e.message}');
    }
  }

  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) call, {
    bool auth = true,
  }) async {
    final response = await _guarded(call, await _headers(auth: auth));
    if (response.statusCode != 401 || !auth || refreshTokens == null) return response;
    final refreshed = await refreshTokens!();
    if (!refreshed) return response;
    return _guarded(call, await _headers(auth: auth));
  }

  Future<dynamic> get(
    String path, {
    Map<String, String>? query,
    Map<String, List<String>>? queryAll,
    bool auth = true,
  }) async {
    final response = await _send(
      (h) => _http.get(_uri(path, query, queryAll), headers: h),
      auth: auth,
    );
    return _decode(response);
  }

  Future<dynamic> postJson(String path, {Object? body, bool auth = true}) async {
    final response = await _send(
      (h) => _http.post(_uri(path), headers: h, body: body == null ? null : jsonEncode(body)),
      auth: auth,
    );
    return _decode(response);
  }

  Future<dynamic> postForm(String path, {required Map<String, String> fields}) async {
    try {
      final response = await _http.post(_uri(path), body: fields);
      return _decode(response);
    } on ApiException {
      rethrow;
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Cannot reach server: ${e.message}');
    }
  }

  Future<dynamic> putJson(String path, {Object? body, bool auth = true}) async {
    final response = await _send(
      (h) => _http.put(_uri(path), headers: h, body: body == null ? null : jsonEncode(body)),
      auth: auth,
    );
    return _decode(response);
  }

  Future<dynamic> patchJson(String path, {Object? body, bool auth = true}) async {
    final response = await _send(
      (h) => _http.patch(_uri(path), headers: h, body: body == null ? null : jsonEncode(body)),
      auth: auth,
    );
    return _decode(response);
  }

  Future<void> delete(String path, {bool auth = true}) async {
    final response =
        await _send((h) => _http.delete(_uri(path), headers: h), auth: auth);
    _decode(response);
  }

  void close() => _http.close();
}
