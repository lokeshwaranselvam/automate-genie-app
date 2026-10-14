import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/site_visits_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final allowed in [true, false]) {
    testWidgets('New Visit visibility follows server permission: $allowed', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'email': 'sales@example.test',
        'token': 'test-token',
        'session_username': 'sales@example.test',
        'session_sid': 'test-session',
      });
      dotenv.testLoad(
        fileInput:
            'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/hrms.api',
      );
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: SiteVisitsPage()));
          expect(find.text('New Visit'), findsNothing);
          await tester.pumpAndSettle();
          expect(
            find.text('New Visit'),
            allowed ? findsOneWidget : findsNothing,
          );
          expect(find.text('No scheduled visits.'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.queryParameters['action'] == 'can_create') {
            return http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  'current_user': 'sales@example.test',
                  'can_create': allowed,
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/ping')) {
            return http.Response(jsonEncode({'message': 'pong'}), 200);
          }
          return http.Response(jsonEncode({'message': []}), 200);
        }),
      );
    });
  }
}
