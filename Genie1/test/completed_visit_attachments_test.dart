import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/completed_visit_attachments.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test/');
    SharedPreferences.setMockInitialValues({'token': 'token test:secret'});
  });
  const screen = MaterialApp(
    home: Scaffold(body: CompletedVisitAttachments(eventId: 'EVENT-1')),
  );

  testWidgets('loads saved Event attachments and rejects foreign URLs', (
    tester,
  ) async {
    var reads = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(screen);
        await tester.pumpAndSettle();
        expect(find.text('Attachments (2)'), findsOneWidget);
        expect(find.text('visit.pdf'), findsOneWidget);
        expect(find.text('recording.mp3'), findsOneWidget);
        expect(find.text('foreign.txt'), findsNothing);
        await tester.pump();
        expect(reads, 1);
      },
      () => MockClient((request) async {
        reads++;
        expect(request.method, 'GET');
        expect(request.url.path, '/api/method/event_visit_report');
        expect(request.url.queryParameters, {
          'action': 'get',
          'event_id': 'EVENT-1',
        });
        expect(request.headers['Authorization'], 'token test:secret');
        return http.Response(
          jsonEncode({
            'message': {
              'event_id': 'EVENT-1',
              'status': 'success',
              'attachments': [
                {
                  'file_name': 'visit.pdf',
                  'file_url': '/private/files/visit.pdf',
                },
                {
                  'file_name': 'recording.mp3',
                  'file_url': '/files/recording.mp3',
                },
                {
                  'file_name': 'foreign.txt',
                  'file_url': 'https://other.test/foreign.txt',
                },
              ],
            },
          }),
          200,
        );
      }),
    );
  });

  testWidgets('failure offers retry and does not show a false empty state', (
    tester,
  ) async {
    var reads = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(screen);
        await tester.pumpAndSettle();
        expect(find.text('Could not load visit attachments.'), findsOneWidget);
        expect(find.text('No attachments yet'), findsNothing);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('No attachments yet'), findsOneWidget);
        expect(reads, 2);
      },
      () => MockClient(
        (_) async =>
            ++reads == 1
                ? http.Response('{}', 403)
                : http.Response(
                  jsonEncode({
                    'message': {'event_id': 'EVENT-1', 'attachments': []},
                  }),
                  200,
                ),
      ),
    );
  });

  testWidgets(
    'old server response requires retry instead of claiming no files',
    (tester) async {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(screen);
          await tester.pumpAndSettle();
          expect(find.text('Retry'), findsOneWidget);
          expect(find.text('No attachments yet'), findsNothing);
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'message': {'event_id': 'EVENT-1'},
            }),
            200,
          ),
        ),
      );
    },
  );
}
