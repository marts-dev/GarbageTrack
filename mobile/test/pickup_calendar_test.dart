import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/api/garbage_api.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/pickup_calendar_screen.dart';
import 'package:garbagetrack/screens/resident_home_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:garbagetrack/utils/dates.dart';
import 'package:garbagetrack/widgets/cards.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

User _user() => User(
      id: 'u1',
      email: 'u@example.com',
      fullName: 'Test User',
      role: 'resident',
      isActive: true,
    );

Widget _withAuth(AuthProvider auth, Widget home) =>
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(theme: AppTheme.light, home: home),
    );

Map<String, dynamic> _pickupJson({
  required String postId,
  required DateTime day,
  String routeStatus = 'assigned',
  String plate = 'AAA-1',
  String? routeName = 'Morning run',
  List<String> types = const ['plastic'],
  String? district = 'Ojota',
}) =>
    {
      'post_id': postId,
      'types': types,
      'status': 'scheduled',
      'district': district,
      'route_id': 'r1',
      'route_name': routeName,
      'route_status': routeStatus,
      'scheduled_for': toIsoDay(day),
      'plate_number': plate,
    };

AuthProvider _pickupsAuth(List<Map<String, dynamic>> pickups) =>
    AuthProvider.withUser(
      _user(),
      client: ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/garbage/mine/pickups') {
            return http.Response(jsonEncode(pickups), 200);
          }
          return http.Response('not found', 404);
        }),
      ),
    );

/// Home-screen backend: saved collection point (past the setup gate),
/// configurable pickups, and an empty pending badge.
AuthProvider _homeAuth({
  List<Map<String, dynamic>> pickups = const [],
  int pickupsStatus = 200,
}) =>
    AuthProvider.withUser(
      _user(),
      client: ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' &&
              path == '/api/v1/users/u1/location') {
            return http.Response(
              jsonEncode({
                'user_id': 'u1',
                'location': {
                  'type': 'Point',
                  'coordinates': [3.37, 6.45]
                },
                'updated_at': '2026-11-01T00:00:00Z',
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              path == '/api/v1/garbage/mine/pickups') {
            if (pickupsStatus != 200) {
              return http.Response(
                  jsonEncode({'detail': 'boom'}), pickupsStatus);
            }
            return http.Response(jsonEncode(pickups), 200);
          }
          if (request.method == 'GET' && path == '/api/v1/garbage') {
            return http.Response('[]', 200);
          }
          return http.Response('not found', 404);
        }),
      ),
    );

/// Tall surface so the month grid and the day list fit without scrolling.
void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  group('scheduled day helpers', () {
    test('tryParseDay reads ISO days as local midnights', () {
      final day = tryParseDay('2026-12-25')!;
      expect((day.year, day.month, day.day), (2026, 12, 25));
      expect(day.hour, 0);
    });

    test('tryParseDay tolerates full ISO strings and DateTimes', () {
      expect(
        tryParseDay('2026-12-25T10:30:00Z'),
        DateTime(2026, 12, 25),
      );
      expect(
        tryParseDay(DateTime(2026, 12, 25, 15, 30)),
        DateTime(2026, 12, 25),
      );
    });

    test('tryParseDay returns null for missing or bad values', () {
      expect(tryParseDay(null), isNull);
      expect(tryParseDay(''), isNull);
      expect(tryParseDay('not-a-date'), isNull);
    });

    test('formatters round-trip the ISO day', () {
      final day = DateTime(2026, 12, 25);
      expect(toIsoDay(day), '2026-12-25');
      expect(formatDay(day), '25 Dec 2026');
      expect(formatMonthYear(day), 'December 2026');
      expect(sameDay(day, DateTime(2026, 12, 25, 23, 59)), isTrue);
      expect(sameDay(day, DateTime(2026, 12, 26)), isFalse);
    });

    test('relativeDay names nearby days and counts the rest', () {
      final today = DateTime(2026, 11, 4);
      expect(relativeDay(today, today: today), 'Today');
      expect(
        relativeDay(DateTime(2026, 11, 5), today: today),
        'Tomorrow',
      );
      expect(
        relativeDay(DateTime(2026, 11, 9), today: today),
        'In 5 days',
      );
      expect(
        relativeDay(DateTime(2026, 11, 3), today: today),
        'Yesterday',
      );
      expect(
        relativeDay(DateTime(2026, 11, 1), today: today),
        '3 days ago',
      );
    });
  });

  group('pickup models', () {
    test('ScheduledPickup parses the pickups payload', () {
      final pickup = ScheduledPickup.fromJson(_pickupJson(
        postId: 'p1',
        day: DateTime(2026, 12, 25),
        routeStatus: 'in_progress',
      ));
      expect(pickup.postId, 'p1');
      expect(pickup.types, ['plastic']);
      expect(pickup.routeStatus, 'in_progress');
      expect(pickup.scheduledFor, DateTime(2026, 12, 25));
      expect(pickup.plateNumber, 'AAA-1');
    });

    test('PlannedRoute parses scheduled_for and tolerates its absence', () {
      final route = PlannedRoute.fromJson(_routeJson('2026-12-25'));
      expect(route.scheduledFor, DateTime(2026, 12, 25));
      final legacy = PlannedRoute.fromJson(_routeJson(null));
      expect(legacy.scheduledFor, isNull);
    });

    test('CollectionAssignment parses the pickup day', () {
      final assignment = CollectionAssignment.fromJson({
        'truck_id': 't1',
        'plate_number': 'AAA-1',
        'route_id': 'r1',
        'route_name': 'Morning run',
        'route_status': 'assigned',
        'scheduled_for': '2026-12-25',
      });
      expect(assignment.scheduledFor, DateTime(2026, 12, 25));
    });
  });

  group('pickups api', () {
    test('getMyPickups hits the endpoint and parses entries', () async {
      Uri? seen;
      final api = GarbageApi(ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response(
            jsonEncode([
              _pickupJson(postId: 'p1', day: DateTime(2026, 12, 25)),
            ]),
            200,
          );
        }),
      ));
      final pickups = await api.getMyPickups();
      expect(seen!.path, '/api/v1/garbage/mine/pickups');
      expect(pickups, hasLength(1));
      expect(pickups.single.postId, 'p1');
      expect(pickups.single.scheduledFor, DateTime(2026, 12, 25));
    });
  });

  group('pickup calendar screen', () {
    testWidgets('tapping a marked day lists its pickups', (tester) async {
      _useTallSurface(tester);
      final today = todayDay();
      // A day in this month that is never today.
      final day =
          DateTime(today.year, today.month, today.day == 1 ? 3 : 1);
      await tester.pumpWidget(_withAuth(
        _pickupsAuth([
          _pickupJson(postId: 'p1', day: day),
          _pickupJson(
            postId: 'p2',
            day: day,
            routeStatus: 'in_progress',
            plate: 'BBB-2',
            routeName: 'Evening run',
            types: const ['paper', 'glass'],
          ),
        ]),
        const PickupCalendarScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text(formatMonthYear(today)), findsOneWidget);
      for (final label in weekdayLabels) {
        expect(find.text(label), findsOneWidget);
      }
      // Today starts selected with nothing on it.
      expect(find.text('No pickups on ${formatDay(today)}.'), findsOneWidget);

      await tester.tap(find.text('${day.day}').first);
      await tester.pumpAndSettle();
      expect(find.text('Plastic'), findsOneWidget);
      expect(find.text('Paper, Glass'), findsOneWidget);
      expect(find.text('Morning run · AAA-1 · Ojota'), findsOneWidget);
      expect(find.text('Evening run · BBB-2 · Ojota'), findsOneWidget);
      expect(find.widgetWithText(StatusPill, 'Assigned'), findsOneWidget);
      expect(find.widgetWithText(StatusPill, 'In Progress'), findsOneWidget);
    });

    testWidgets('chevrons navigate to other months', (tester) async {
      _useTallSurface(tester);
      final today = todayDay();
      final nextMonth = DateTime(today.year, today.month + 1, 15);
      await tester.pumpWidget(_withAuth(
        _pickupsAuth([
          _pickupJson(postId: 'p9', day: nextMonth, district: null),
        ]),
        const PickupCalendarScreen(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text(formatMonthYear(nextMonth)), findsOneWidget);
      await tester.tap(find.text('15').first);
      await tester.pumpAndSettle();
      expect(find.text('Morning run · AAA-1'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      expect(find.text(formatMonthYear(today)), findsOneWidget);
    });

    testWidgets('empty pickups show the empty day message', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(_withAuth(
        _pickupsAuth([]),
        const PickupCalendarScreen(),
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('No pickups on ${formatDay(todayDay())}.'),
        findsOneWidget,
      );
      expect(find.byType(StatusPill), findsNothing);
    });

    testWidgets('resident home links to the pickup calendar', (tester) async {
      final auth = AuthProvider.withUser(
        _user(),
        client: ApiClient(
          baseUrl: 'http://x',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (request.method == 'GET' &&
                path == '/api/v1/users/u1/location') {
              return http.Response(
                jsonEncode({
                  'user_id': 'u1',
                  'location': {
                    'type': 'Point',
                    'coordinates': [3.37, 6.45]
                  },
                  'updated_at': '2026-11-01T00:00:00Z',
                }),
                200,
              );
            }
            if (request.method == 'GET' &&
                path == '/api/v1/garbage/mine/pickups') {
              return http.Response('[]', 200);
            }
            // Pending badge on My reports.
            if (request.method == 'GET' && path == '/api/v1/garbage') {
              return http.Response('[]', 200);
            }
            return http.Response('not found', 404);
          }),
        ),
      );
      await tester.pumpWidget(_withAuth(auth, const ResidentHomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Pickup calendar'), findsOneWidget);
      await tester.tap(find.text('Pickup calendar'));
      await tester.pumpAndSettle();
      expect(find.text(formatMonthYear(todayDay())), findsOneWidget);
    });
  });

  group('next pickup card', () {
    testWidgets('shows the earliest run and drills into the calendar',
        (tester) async {
      final today = todayDay();
      final soon = DateTime(today.year, today.month, today.day + 1);
      final later = DateTime(today.year, today.month, today.day + 3);
      await tester.pumpWidget(_withAuth(
        _homeAuth(pickups: [
          _pickupJson(postId: 'p2', day: later, plate: 'BBB-2'),
          _pickupJson(postId: 'p1', day: soon),
        ]),
        const ResidentHomeScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Next pickup · Tomorrow'), findsOneWidget);
      expect(
        find.text('${formatDay(soon)} · Morning run · AAA-1'),
        findsOneWidget,
      );
      expect(find.widgetWithText(StatusPill, 'Assigned'), findsOneWidget);

      await tester.tap(find.text('Next pickup · Tomorrow'));
      await tester.pumpAndSettle();
      expect(find.text(formatMonthYear(today)), findsOneWidget);
    });

    testWidgets('overdue pickups call out the delay', (tester) async {
      final today = todayDay();
      final late = DateTime(today.year, today.month, today.day - 1);
      await tester.pumpWidget(_withAuth(
        _homeAuth(pickups: [
          _pickupJson(postId: 'p1', day: late, routeStatus: 'in_progress'),
        ]),
        const ResidentHomeScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Pickup overdue · Yesterday'), findsOneWidget);
      expect(find.widgetWithText(StatusPill, 'In Progress'), findsOneWidget);
    });

    testWidgets('empty pickups show the no-upcoming card', (tester) async {
      await tester.pumpWidget(_withAuth(
        _homeAuth(pickups: []),
        const ResidentHomeScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('No upcoming pickups'), findsOneWidget);
      await tester.tap(find.text('No upcoming pickups'));
      await tester.pumpAndSettle();
      expect(find.text(formatMonthYear(todayDay())), findsOneWidget);
    });

    testWidgets('card hides when the pickups call fails', (tester) async {
      await tester.pumpWidget(_withAuth(
        _homeAuth(pickupsStatus: 500),
        const ResidentHomeScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Next pickup'), findsNothing);
      expect(find.textContaining('Pickup overdue'), findsNothing);
      expect(find.text('No upcoming pickups'), findsNothing);
      // The rest of home is unaffected.
      expect(find.text('My reports'), findsOneWidget);
      expect(find.text('Pickup calendar'), findsOneWidget);
    });
  });
}

Map<String, dynamic> _routeJson(String? scheduledFor) => {
      'id': 'r1',
      'truck_id': 't1',
      'name': 'Morning run',
      'origin': {
        'type': 'Point',
        'coordinates': [3.37, 6.45]
      },
      'stops': [],
      'status': 'assigned',
      if (scheduledFor != null) 'scheduled_for': scheduledFor,
      'created_at': '2026-11-01T00:00:00Z',
      'depot_ids': [],
      'collection_points': [],
      'geometry': null,
      'geometry_source': 'straight',
    };
