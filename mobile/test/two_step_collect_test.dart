import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/api/garbage_api.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/post_detail_screen.dart';
import 'package:garbagetrack/screens/resident_home_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/utils/dates.dart';
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

User _user({String id = 'u1', String role = 'resident'}) => User(
      id: id,
      email: 'u@example.com',
      fullName: 'Test User',
      role: role,
      isActive: true,
    );

Widget _withAuth(AuthProvider auth, Widget home) =>
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(theme: AppTheme.light, home: home),
    );

/// Tall screen so the whole post detail (card + map + buttons) builds at
/// once without scrolling.
void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Map<String, dynamic> _postJson(String id, String status) => {
      'id': id,
      'user_id': 'u1',
      'location': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'types': ['plastic'],
      'description': 'bags',
      'district': null,
      'has_image': false,
      'image_content_type': null,
      'status': status,
      'created_at': '2026-11-01T00:00:00Z',
      'collected_at': status == 'pending_confirmation' || status == 'collected'
          ? '2026-11-02T00:00:00Z'
          : null,
    };

Map<String, dynamic> _assignmentJson({String? routeName = 'Morning run'}) => {
      'truck_id': 't1',
      'plate_number': 'AAA-1',
      'route_id': 'r1',
      'route_name': routeName,
      'route_status': 'in_progress',
    };

/// Backend for post-detail tests: mutable post status so confirm/dispute
/// reloads observe the transition; collection 404s when [assignment] is null.
MockClient _detailBackend(
  List<String> calls, {
  required String status,
  Map<String, dynamic>? assignment,
  void Function(String status)? onStatus,
}) {
  var current = status;
  return MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    if (request.method == 'GET' && path == '/api/v1/garbage/p1') {
      return http.Response(jsonEncode(_postJson('p1', current)), 200);
    }
    if (request.method == 'GET' && path == '/api/v1/garbage/p1/collection') {
      if (assignment == null) {
        return http.Response(
          jsonEncode({'detail': 'no collection assignment for this post'}),
          404,
        );
      }
      return http.Response(jsonEncode(assignment), 200);
    }
    if (request.method == 'PATCH' &&
        path == '/api/v1/garbage/p1/confirm-collected') {
      current = 'collected';
      onStatus?.call(current);
      return http.Response(jsonEncode(_postJson('p1', current)), 200);
    }
    if (request.method == 'PATCH' &&
        path == '/api/v1/garbage/p1/dispute-collected') {
      current = 'posted';
      onStatus?.call(current);
      return http.Response(jsonEncode(_postJson('p1', current)), 200);
    }
    return http.Response('not found', 404);
  });
}

AuthProvider _detailAuth(
  List<String> calls, {
  required String status,
  Map<String, dynamic>? assignment,
}) =>
    AuthProvider.withUser(
      _user(),
      client: ApiClient(
        baseUrl: 'http://x',
        httpClient: _detailBackend(
          calls,
          status: status,
          assignment: assignment,
        ),
      ),
    );

Future<Color> _pillColor(WidgetTester tester, String status) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: StatusPill(label: pretty(status), status: status),
      ),
    ),
  );
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(StatusPill),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).color!;
}

void main() {
  group('two-step collect models', () {
    test('garbageStatuses includes pending_confirmation', () {
      expect(garbageStatuses,
          ['posted', 'scheduled', 'pending_confirmation', 'collected']);
    });

    test('CollectionAssignment parses the assignment payload', () {
      final a = CollectionAssignment.fromJson(_assignmentJson());
      expect(a.truckId, 't1');
      expect(a.plateNumber, 'AAA-1');
      expect(a.routeId, 'r1');
      expect(a.routeName, 'Morning run');
      expect(a.routeStatus, 'in_progress');
    });

    test('CollectionAssignment tolerates a null route name', () {
      final a = CollectionAssignment.fromJson(_assignmentJson(routeName: null));
      expect(a.routeName, isNull);
    });

    testWidgets('pending pill shares the scheduled tertiary color',
        (tester) async {
      final pending = await _pillColor(tester, 'pending_confirmation');
      final scheduled = await _pillColor(tester, 'scheduled');
      final posted = await _pillColor(tester, 'posted');
      expect(pending, scheduled);
      expect(pending, isNot(posted));
    });
  });

  group('garbage api two-step endpoints', () {
    test('disputeCollected patches the dispute endpoint', () async {
      Uri? seen;
      final api = GarbageApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = request.url;
          expect(request.method, 'PATCH');
          return http.Response(jsonEncode(_postJson('p1', 'posted')), 200);
        }),
      ));
      final post = await api.disputeCollected('p1');
      expect(seen!.path, '/api/v1/garbage/p1/dispute-collected');
      expect(post.status, 'posted');
    });

    test('getCollection parses the assignment payload', () async {
      Uri? seen;
      final api = GarbageApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response(jsonEncode(_assignmentJson()), 200);
        }),
      ));
      final assignment = await api.getCollection('p1');
      expect(seen!.path, '/api/v1/garbage/p1/collection');
      expect(assignment, isNotNull);
      expect(assignment!.plateNumber, 'AAA-1');
      expect(assignment.routeName, 'Morning run');
    });

    test('getCollection maps 404 to null', () async {
      final api = GarbageApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'detail': 'no collection assignment for this post'}),
              404,
            )),
      ));
      expect(await api.getCollection('p1'), isNull);
    });

    test('getCollection rethrows non-404 errors', () async {
      final api = GarbageApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((_) async =>
            http.Response(jsonEncode({'detail': 'forbidden'}), 403)),
      ));
      expect(
        () => api.getCollection('p1'),
        throwsA(isA<ApiException>().having(
          (e) => e.statusCode,
          'status',
          403,
        )),
      );
    });
  });

  group('post detail two-step buttons', () {
    testWidgets('pending shows Confirm and Dispute', (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(calls, status: 'pending_confirmation'),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Pending Confirmation'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Confirm collected'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Dispute collection'),
        findsOneWidget,
      );
    });

    testWidgets('confirm calls the endpoint and reloads as collected',
        (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(calls, status: 'pending_confirmation'),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm collected'));
      await tester.pumpAndSettle();
      expect(
        calls,
        contains('PATCH /api/v1/garbage/p1/confirm-collected'),
      );
      expect(find.text('Marked as collected'), findsOneWidget);
      expect(find.widgetWithText(StatusPill, 'Collected'), findsOneWidget);
      expect(find.text('Confirm collected'), findsNothing);
      expect(find.text('Dispute collection'), findsNothing);
    });

    testWidgets('dispute calls the endpoint and reloads as posted',
        (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(calls, status: 'pending_confirmation'),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dispute collection'));
      await tester.pumpAndSettle();
      expect(
        calls,
        contains('PATCH /api/v1/garbage/p1/dispute-collected'),
      );
      expect(find.text('Collection disputed'), findsOneWidget);
      expect(find.text('Posted'), findsOneWidget);
      expect(find.text('Confirm collected'), findsNothing);
      expect(find.text('Dispute collection'), findsNothing);
    });

    for (final status in ['posted', 'scheduled']) {
      testWidgets('$status shows no confirm or dispute button', (tester) async {
        _useTallSurface(tester);
        final calls = <String>[];
        await tester.pumpWidget(_withAuth(
          _detailAuth(calls, status: status),
          PostDetailScreen(
            postId: 'p1',
            tileProvider: _StubTileProvider(),
          ),
        ));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(StatusPill, pretty(status)),
          findsOneWidget,
        );
        expect(find.text('Confirm collected'), findsNothing);
        expect(find.text('Dispute collection'), findsNothing);
        expect(
          calls.where((c) => c.contains('confirm-collected')),
          isEmpty,
        );
      });
    }

    testWidgets('collected shows no action buttons', (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(calls, status: 'collected'),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(StatusPill, 'Collected'), findsOneWidget);
      expect(find.text('Confirm collected'), findsNothing);
      expect(find.text('Dispute collection'), findsNothing);
    });
  });

  group('post detail pickup timeline', () {
    // Fixture timestamps are UTC midnights; expectations convert to local
    // the same way the timeline does so any timezone passes.
    String localDay(String iso) => formatDay(DateTime.parse(iso).toLocal());

    testWidgets('timeline shows the full journey when assigned',
        (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(
          calls,
          status: 'pending_confirmation',
          assignment: _assignmentJson(),
        ),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(calls, contains('GET /api/v1/garbage/p1/collection'));
      expect(find.text('Pickup progress'), findsOneWidget);
      for (final step in ['Reported', 'Scheduled', 'Picked up', 'Confirmed']) {
        expect(find.text(step), findsOneWidget);
      }
      expect(
        find.text(localDay('2026-11-01T00:00:00Z')),
        findsOneWidget,
      );
      expect(
        find.text('Morning run · Truck AAA-1'),
        findsOneWidget,
      );
      expect(
        find.text(localDay('2026-11-02T00:00:00Z')),
        findsOneWidget,
      );
      expect(find.text('Was it really collected?'), findsOneWidget);
      expect(find.text('Confirm collected'), findsOneWidget);
      expect(find.text('Dispute collection'), findsOneWidget);
    });

    testWidgets('scheduled step shows the pickup day and rolling run',
        (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(
          calls,
          status: 'scheduled',
          assignment: {
            ..._assignmentJson(),
            'scheduled_for': '2026-12-25',
          },
        ),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('25 Dec 2026 · Morning run · Truck AAA-1'),
        findsOneWidget,
      );
      // The run started but this post isn't swept: pickup is underway.
      expect(find.text('Collection underway'), findsOneWidget);
      expect(find.text('Confirm collected'), findsNothing);
    });

    testWidgets('falls back to the route id when the name is null',
        (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(
          calls,
          status: 'collected',
          assignment: _assignmentJson(routeName: null),
        ),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('r1 · Truck AAA-1'), findsOneWidget);
      // Collected is final: no actions.
      expect(find.text('Confirm collected'), findsNothing);
      expect(find.text('Dispute collection'), findsNothing);
    });

    testWidgets('timeline without assignment shows plain steps',
        (tester) async {
      _useTallSurface(tester);
      final calls = <String>[];
      await tester.pumpWidget(_withAuth(
        _detailAuth(calls, status: 'posted'),
        PostDetailScreen(
          postId: 'p1',
          tileProvider: _StubTileProvider(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(calls, contains('GET /api/v1/garbage/p1/collection'));
      expect(find.text('Pickup progress'), findsOneWidget);
      expect(find.text('Not on a run yet'), findsOneWidget);
      expect(find.text('Morning run'), findsNothing);
      // The post itself still renders.
      expect(find.text('Posted'), findsOneWidget);
    });
  });

  group('resident home pending badge', () {
    AuthProvider badgeAuth(
      List<Uri> seen, {
      required int pendingCount,
    }) =>
        AuthProvider.withUser(
          _user(),
          client: ApiClient(
            baseUrl: 'http://x',
            httpClient: MockClient((request) async {
              seen.add(request.url);
              return http.Response(
                jsonEncode([
                  for (var i = 0; i < pendingCount; i++)
                    _postJson('p$i', 'pending_confirmation'),
                ]),
                200,
              );
            }),
          ),
        );

    testWidgets('shows the pending count on My reports', (tester) async {
      final seen = <Uri>[];
      await tester.pumpWidget(_withAuth(
        badgeAuth(seen, pendingCount: 3),
        const ResidentHomeScreen(),
      ));
      await tester.pumpAndSettle();
      final pendingCall = seen.singleWhere(
        (u) =>
            u.path == '/api/v1/garbage' &&
            u.queryParameters['status'] == 'pending_confirmation',
      );
      expect(pendingCall.queryParameters['user_id'], 'u1');
      expect(find.byType(Badge), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('My reports'), findsOneWidget);
    });

    testWidgets('hides the badge when nothing is pending', (tester) async {
      final seen = <Uri>[];
      await tester.pumpWidget(_withAuth(
        badgeAuth(seen, pendingCount: 0),
        const ResidentHomeScreen(),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(Badge), findsNothing);
      expect(find.text('My reports'), findsOneWidget);
    });

    testWidgets('hides the badge when the count call fails', (tester) async {
      final auth = AuthProvider.withUser(
        _user(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((_) async => http.Response('boom', 500)),
        ),
      );
      await tester.pumpWidget(_withAuth(auth, const ResidentHomeScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(Badge), findsNothing);
      expect(find.text('My reports'), findsOneWidget);
    });

    testWidgets('badge clears after confirming all pending pickups',
        (tester) async {
      var pending = 3;
      final auth = AuthProvider.withUser(
        _user(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            if (request.url.path != '/api/v1/garbage') {
              return http.Response('not found', 404);
            }
            return http.Response(
              jsonEncode([
                for (var i = 0; i < pending; i++)
                  _postJson('p$i', 'pending_confirmation'),
              ]),
              200,
            );
          }),
        ),
      );
      await tester.pumpWidget(_withAuth(auth, const ResidentHomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);

      // Confirming happens on the reports screens; by the time the
      // resident returns home, nothing is pending anymore.
      pending = 0;
      await tester.tap(find.text('My reports'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(Badge), findsNothing);
      expect(find.text('My reports'), findsOneWidget);
    });
  });
}
