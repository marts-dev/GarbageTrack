import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/enroute_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/widgets/cards.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

/// Offline tile stub: every tile is a transparent pixel, no network.
class _StubTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

Map<String, dynamic> _truckJson(String id, String plate) => {
      'id': id,
      'plate_number': plate,
      'availability': 'working',
      'garbage_types': ['plastic'],
      'current_location': {
        'type': 'Point',
        'coordinates': [3.38, 6.46]
      },
      'eta_minutes': null,
      'capacity': 10,
      'load': 0,
      'operator_id': 'c1',
      'created_at': '2026-10-29T00:00:00Z',
    };

AuthProvider _enrouteAuth({
  Map<String, String>? enrouteQuery,
  List<Map<String, dynamic>>? trucks,
  bool withPoint = true,
}) =>
    AuthProvider.withUser(
      User(
        id: 'u1',
        email: 'u@example.com',
        fullName: 'Test User',
        role: 'resident',
        isActive: true,
      ),
      client: ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/api/v1/users/u1/location') {
            if (!withPoint) {
              return http.Response(jsonEncode({'detail': 'nope'}), 404);
            }
            return http.Response(
              jsonEncode({
                'user_id': 'u1',
                'location': {
                  'type': 'Point',
                  'coordinates': [3.37, 6.45]
                },
                'updated_at': '2026-10-29T00:00:00Z',
              }),
              200,
            );
          }
          if (request.method == 'GET' && path == '/api/v1/trucks/enroute') {
            enrouteQuery?.addAll(request.url.queryParameters);
            return http.Response(
              jsonEncode(trucks ?? [_truckJson('t1', 'AAA-1')]),
              200,
            );
          }
          return http.Response(jsonEncode({'detail': 'nope'}), 404);
        }),
      ),
    );

Future<void> _pumpEnroute(WidgetTester tester, AuthProvider auth) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(
        theme: AppTheme.light,
        home: EnrouteScreen(tileProvider: _StubTileProvider()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('enroute screen', () {
    testWidgets('centers the live list on the collection point',
        (tester) async {
      final query = <String, String>{};
      await _pumpEnroute(tester, _enrouteAuth(enrouteQuery: query));

      expect(query['longitude'], '3.37');
      expect(query['latitude'], '6.45');
      expect(find.text('AAA-1'), findsOneWidget);
      // The resident's own point pins the map; no unfiltered note.
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'You',
        ),
        findsOneWidget,
      );
      expect(find.text('Showing all live trucks'), findsNothing);
    });

    testWidgets('falls back to unfiltered with a note', (tester) async {
      final query = <String, String>{};
      await _pumpEnroute(
        tester,
        _enrouteAuth(enrouteQuery: query, withPoint: false),
      );

      expect(query.containsKey('longitude'), isFalse);
      expect(find.text('AAA-1'), findsOneWidget);
      expect(find.text('Showing all live trucks'), findsOneWidget);
      expect(
        find.text('Save a collection point to filter by distance.'),
        findsOneWidget,
      );
    });

    testWidgets('empty fleet shows the empty state', (tester) async {
      await _pumpEnroute(tester, _enrouteAuth(trucks: []));
      expect(find.text('No trucks enroute.'), findsOneWidget);
      expect(find.byType(TruckCard), findsNothing);
    });
  });
}
