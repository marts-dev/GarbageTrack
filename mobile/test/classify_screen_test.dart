import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbagetrack/api/api_client.dart';
import 'package:garbagetrack/models/models.dart';
import 'package:garbagetrack/screens/classify_screen.dart';
import 'package:garbagetrack/state/auth_provider.dart';
import 'package:garbagetrack/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

/// 1x1 transparent PNG.
Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );

Widget _withAuth(
  AuthProvider auth, {
  Future<XFile?> Function(ImageSource)? imageProvider,
}) =>
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(
        theme: AppTheme.light,
        home: ClassifyScreen(imageProvider: imageProvider),
      ),
    );

AuthProvider _classifyAuth({
  required Map<String, dynamic> Function() response,
  Map<String, dynamic>? capture,
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
          if (request.method == 'POST' &&
              request.url.path == '/api/v1/ai/classify') {
            capture?.addAll(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode(response()), 200);
          }
          return http.Response('not found', 404);
        }),
      ),
    );

Map<String, dynamic> _resultJson({
  List<String> types = const ['plastic'],
  double confidence = 0.82,
  bool placeholder = false,
  String message = 'Visual match: plastic.',
}) =>
    {
      'suggested_types': types,
      'confidence': confidence,
      'placeholder': placeholder,
      'message': message,
    };

void main() {
  group('classify screen', () {
    testWidgets('ask needs a description or a photo', (tester) async {
      await tester.pumpWidget(_withAuth(_classifyAuth(
        response: _resultJson,
      )));
      await tester.pumpAndSettle();

      FilledButton ask() => tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Ask'),
          );
      expect(ask().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'old phone battery');
      await tester.pumpAndSettle();
      expect(ask().onPressed, isNotNull);
    });

    testWidgets('description ask shows suggestion and confidence',
        (tester) async {
      final capture = <String, dynamic>{};
      await tester.pumpWidget(_withAuth(_classifyAuth(
        response: () => _resultJson(
          types: const ['hazardous'],
          confidence: 0.6,
          message: "Matched 'battery' in the description.",
        ),
        capture: capture,
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'old phone battery');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
      await tester.pumpAndSettle();

      expect(capture['description'], 'old phone battery');
      expect(capture.containsKey('image_base64'), isFalse);
      expect(find.text('Hazardous'), findsOneWidget);
      expect(find.text('60% confident'), findsOneWidget);
      expect(
        find.text("Matched 'battery' in the description."),
        findsOneWidget,
      );
    });

    testWidgets('photo ask posts base64 and renders the result',
        (tester) async {
      final bytes = _tinyPng();
      final capture = <String, dynamic>{};
      await tester.pumpWidget(_withAuth(
        _classifyAuth(
          response: _resultJson,
          capture: capture,
        ),
        imageProvider: (_) async =>
            XFile.fromData(bytes, mimeType: 'image/png'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Gallery'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);

      // Photo alone enables Ask; no description is sent.
      await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
      await tester.pumpAndSettle();
      expect(capture['image_base64'], base64Encode(bytes));
      expect(capture.containsKey('description'), isFalse);
      expect(find.text('Plastic'), findsOneWidget);
      expect(find.text('82% confident'), findsOneWidget);
    });

    testWidgets('oversized photo errors and attaches nothing', (tester) async {
      await tester.pumpWidget(_withAuth(
        _classifyAuth(response: _resultJson),
        imageProvider: (_) async => XFile.fromData(
          Uint8List(6 * 1024 * 1024),
          mimeType: 'image/jpeg',
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Gallery'));
      await tester.pumpAndSettle();
      expect(find.text('Image is larger than 5 MB'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('placeholder results keep the wiring notice', (tester) async {
      await tester.pumpWidget(_withAuth(_classifyAuth(
        response: () => _resultJson(
          types: const ['general'],
          confidence: 0.0,
          placeholder: true,
          message: 'Not wired up.',
        ),
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'mystery blob');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
      await tester.pumpAndSettle();
      expect(
        find.text('Placeholder answer — the AI agent is not wired up yet.'),
        findsOneWidget,
      );
    });
  });
}
