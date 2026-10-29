import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('attaches bearer token and decodes JSON', () async {
    String? seenAuth;
    final client = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((request) async {
        seenAuth = request.headers['Authorization'];
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
      readToken: () async => 'abc',
    );
    final body = await client.get('/garbage');
    expect(body, {'ok': true});
    expect(seenAuth, 'Bearer abc');
  });

  test('retries once after a successful refresh on 401', () async {
    var calls = 0;
    var refreshed = false;
    final client = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((request) async {
        calls++;
        if (request.headers['Authorization'] == 'Bearer new') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response(jsonEncode({'detail': 'nope'}), 401);
      }),
      readToken: () async => refreshed ? 'new' : 'old',
      refreshTokens: () async {
        refreshed = true;
        return true;
      },
    );
    final body = await client.get('/garbage');
    expect(body, {'ok': true});
    expect(calls, 2);
  });

  test('surfaces server detail message on errors', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((_) async => http.Response(jsonEncode({'detail': 'forbidden'}), 403)),
    );
    expect(
      () => client.get('/logistics/garbage'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403).having(
          (e) => e.message, 'message', 'forbidden')),
    );
  });

  test('maps connection failures to status 0', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((_) async => throw http.ClientException('down')),
    );
    expect(
      () => client.get('/garbage'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 0)),
    );
  });

  test('encodes repeated query params', () async {
    Uri? seen;
    final client = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((request) async {
        seen = request.url;
        return http.Response('[]', 200);
      }),
    );
    await client.get('/t/route', query: {'limit': '20'}, queryAll: {
      'types': ['plastic', 'paper']
    });
    expect(seen!.queryParametersAll['types'], ['plastic', 'paper']);
    expect(seen!.queryParameters['limit'], '20');
  });

  test('delete treats 204 as success', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((_) async => http.Response('', 204)),
    );
    await client.delete('/logistics/facilities/f1');
  });
}
