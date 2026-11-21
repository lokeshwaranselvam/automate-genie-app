import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/site_visits_page.dart';
import 'package:homegenie/Screen/visit_verification_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'email': 'fe@test',
      'token': 'token test',
    });
    dotenv.testLoad(
      fileInput:
          'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/example.api',
    );
  });
  for (final visible in [false, true]) {
    testWidgets('API visible=$visible controls section and completed list', (
      tester,
    ) async {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: SiteVisitsPage()));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Verification ('),
            visible ? findsOneWidget : findsNothing,
          );
          await tester.tap(find.textContaining('Completed ('));
          await tester.pumpAndSettle();
          expect(
            find.text('Customer visit'),
            visible ? findsNothing : findsWidgets,
          );
          if (visible) {
            await tester.tap(find.textContaining('Verification ('));
            await tester.pumpAndSettle();
            expect(find.text('Not Verified'), findsOneWidget);
            expect(find.text('Customer visit'), findsOneWidget);
            expect(find.text('Enter OTP'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/ping')) {
            return http.Response('{"message":"pong"}', 200);
          }
          if (path.endsWith('.event_list')) {
            return http.Response('{"message":[]}', 200);
          }
          if (path.endsWith('.history_list')) {
            return http.Response(
              jsonEncode({
                'message': [
                  {
                    'name': 'E1',
                    'subject': 'Customer visit',
                    'custom_check_out': '2026-11-18 12:00:00',
                  },
                ],
              }),
              200,
            );
          }
          if (path.endsWith('/event_visit_report')) {
            if (request.bodyFields['action'] == 'verification_policy') {
              return http.Response(
                jsonEncode({
                  'message': {
                    'verification_policy': {
                      'current_user': 'fe@test',
                      'visible': visible,
                      'otp_length': 6,
                    },
                  },
                }),
                200,
              );
            }
            return http.Response(
              '{"message":{"events":[{"event_id":"E1","verification_required":true,"is_verified":false}]}}',
              200,
            );
          }
          return http.Response('{}', 403); // Creation permission fails closed.
        }),
      );
    });
  }

  testWidgets(
    'scheduled visits render while history and verification are still pending',
    (tester) async {
      final history = Completer<http.Response>();
      final policy = Completer<http.Response>();
      final started = <String>{};
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: SiteVisitsPage()));
          await tester.pumpAndSettle();
          expect(started, containsAll(['history', 'policy', 'scheduled']));
          expect(find.text('Fast scheduled visit'), findsWidgets);
          expect(find.textContaining('Verification ('), findsNothing);
          history.complete(http.Response('{"message":[]}', 200));
          policy.complete(
            http.Response(
              '{"message":{"verification_policy":{"current_user":"fe@test","visible":false}}}',
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Fast scheduled visit'), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/ping')) {
            return http.Response('{"message":"pong"}', 200);
          }
          if (path.endsWith('.event_list')) {
            started.add('scheduled');
            return http.Response(
              jsonEncode({
                'message': [
                  {
                    'name': 'S1',
                    'subject': 'Fast scheduled visit',
                    'starts_on': DateTime.now().toIso8601String(),
                  },
                ],
              }),
              200,
            );
          }
          if (path.endsWith('.history_list')) {
            started.add('history');
            return history.future;
          }
          if (path.endsWith('/event_visit_report')) {
            started.add('policy');
            return policy.future;
          }
          return http.Response('{}', 403);
        }),
      );
    },
  );

  testWidgets(
    'inline verification tab fits phone and moves verified Event with only OTP card action',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var verified = false;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: SiteVisitsPage()));
          await tester.pumpAndSettle();
          final scheduled = find.textContaining('Scheduled (');
          final verification = find.textContaining('Verification (');
          final completed = find.textContaining('Completed (');
          final overdue = find.textContaining('Overdue (');
          expect(
            tester.getCenter(scheduled).dx,
            lessThan(tester.getCenter(verification).dx),
          );
          expect(
            tester.getCenter(verification).dx,
            lessThan(tester.getCenter(completed).dx),
          );
          expect(
            tester.getCenter(completed).dx,
            lessThan(tester.getCenter(overdue).dx),
          );
          expect(find.text('Not Verified'), findsNothing);
          await tester.tap(verification);
          await tester.pumpAndSettle();
          expect(find.text('Site Visits'), findsOneWidget);
          expect(find.byType(VisitVerificationPage), findsNothing);
          expect(find.text('Not Verified'), findsOneWidget);
          expect(find.text('Customer visit'), findsOneWidget);
          expect(find.text('Enter OTP'), findsOneWidget);
          expect(find.text('View report'), findsNothing);
          expect(find.text('Start Visit'), findsNothing);
          expect(find.text('Navigate'), findsNothing);
          expect(find.text('New Visit'), findsNothing);
          await tester.enterText(find.byType(TextField), 'missing');
          await tester.pumpAndSettle();
          expect(find.text('Customer visit'), findsNothing);
          await tester.enterText(find.byType(TextField), 'Customer');
          await tester.pumpAndSettle();
          await tester.tap(find.text('Enter OTP'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextField, 'Customer OTP'),
            '012345',
          );
          await tester.tap(find.text('Verify'));
          await tester.pumpAndSettle();
          expect(verified, true);
          expect(find.text('Customer visit'), findsNothing);
          expect(find.text('Enter OTP'), findsNothing);
          await tester.tap(find.text('Verified'));
          await tester.pumpAndSettle();
          expect(find.text('Customer visit'), findsOneWidget);
          expect(find.text('Enter OTP'), findsNothing);
          await tester.tap(completed);
          await tester.pumpAndSettle();
          expect(find.text('Customer visit'), findsNothing);
          expect(find.text('Not Verified'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/ping')) {
            return http.Response('{"message":"pong"}', 200);
          }
          if (path.endsWith('.event_list')) {
            return http.Response('{"message":[]}', 200);
          }
          if (path.endsWith('.history_list')) {
            return http.Response(
              jsonEncode({
                'message': [
                  {
                    'name': 'E1',
                    'subject': 'Customer visit',
                    'custom_check_out': '2026-11-18 12:00:00',
                  },
                ],
              }),
              200,
            );
          }
          if (path.endsWith('/event_visit_report')) {
            switch (request.bodyFields['action']) {
              case 'verification_policy':
                return http.Response(
                  '{"message":{"verification_policy":{"current_user":"fe@test","visible":true,"otp_length":6}}}',
                  200,
                );
              case 'verification_states':
                return http.Response(
                  jsonEncode({
                    'message': {
                      'events': [
                        {
                          'event_id': 'E1',
                          'verification_required': true,
                          'is_verified': verified,
                        },
                      ],
                    },
                  }),
                  200,
                );
              case 'verify':
                verified = true;
                expect(request.bodyFields['custom_validate'], '012345');
                return http.Response(
                  '{"message":{"status":"success","event_id":"E1","is_verified":true}}',
                  200,
                );
            }
          }
          return http.Response('{}', 403);
        }),
      );
    },
  );

  testWidgets(
    'wrong OTP remains pending, duplicate submit blocked, correct OTP moves to Verified',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(
              home: VisitVerificationPage(
                visits: [
                  {
                    'event_id': 'E1',
                    'subject': 'Customer visit',
                    'is_verified': false,
                  },
                ],
                otpLength: 6,
              ),
            ),
          );
          await tester.tap(find.text('Enter OTP'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '123');
          await tester.tap(find.text('Verify'));
          await tester.pumpAndSettle();
          expect(find.text('Enter the 6-digit customer OTP.'), findsOneWidget);
          expect(calls, 0);
          await tester.enterText(find.byType(TextField), '654321');
          await tester.tap(find.text('Verify'));
          await tester.pumpAndSettle();
          expect(find.text('Invalid OTP.'), findsOneWidget);
          await tester.enterText(find.byType(TextField), '012345');
          await tester.tap(find.text('Verify'));
          await tester.pump();
          await tester.tap(find.text('Verify'));
          expect(calls, 2);
          pending.complete(
            http.Response(
              '{"message":{"status":"success","event_id":"E1","is_verified":true}}',
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Enter OTP'), findsNothing);
          await tester.tap(find.text('Verified'));
          await tester.pumpAndSettle();
          expect(find.text('Customer visit'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              '{"message":{"status":"error","detail":"Invalid OTP.","is_verified":false}}',
              200,
            );
          }
          expect(request.bodyFields['custom_validate'], '012345');
          return pending.future;
        }),
      );
    },
  );
}
