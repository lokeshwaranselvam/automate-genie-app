import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/site_visits_page.dart';
import 'package:homegenie/Screen/home_dashboard_view.dart';
import 'package:homegenie/utils/api/site_visit_creation_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'Accounts visit access preserves explicit Opportunities restriction',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'accounts@example.test',
        'session_sid': 'test-session',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      for (final opportunities in [false, true, null]) {
        final access = await http.runWithClient(
          () => SiteVisitCreationApi.homeQuickActionAccess(),
          () => MockClient((request) async {
            if (request.url.path.endsWith('/get_logged_user')) {
              return http.Response(
                jsonEncode({'message': 'accounts@example.test'}),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  'current_user': 'accounts@example.test',
                  'can_create': true,
                  if (opportunities != null)
                    'can_view_opportunities': opportunities,
                  'can_create_lead': false,
                  'can_view_pending': false,
                },
              }),
              200,
            );
          }),
        );
        expect(access.canCreateVisit, isTrue);
        expect(access.canViewVisits, isTrue);
        expect(access.canViewOpportunities, opportunities ?? true);
        expect(access.canAddLead, isFalse);
        expect(access.canViewPending, isFalse);
      }
    },
  );

  testWidgets('Bottom navigation excludes Pending and preserves tab indices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final salesAccess in [false, true]) {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: HomeNavigationBar(
              currentIndex: 0,
              showVisits: true,
              showLeads: salesAccess,
              onTap: (index) => selected = index,
            ),
          ),
        ),
      );
      expect(find.text('Pending'), findsNothing);
      for (final entry
          in {
            'Home': 0,
            'Tasks': 1,
            'Visits': 2,
            if (salesAccess) 'Leads': 3,
            'More': 4,
          }.entries) {
        await tester.tap(find.text(entry.key));
        expect(selected, entry.value);
      }
      expect(tester.takeException(), isNull);
    }
  });

  test(
    'Home access rejects missing identity and respects explicit Pending denial',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'sales@example.test',
        'session_sid': 'test-session',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      for (final verified in [false, true]) {
        final operation = http.runWithClient(
          () => SiteVisitCreationApi.homeQuickActionAccess(),
          () => MockClient(
            (_) async => http.Response(
              jsonEncode({
                'message': {
                  if (verified) 'current_user': 'sales@example.test',
                  'can_create_lead': true,
                  'can_create': true,
                  'can_view_pending': false,
                },
              }),
              200,
            ),
          ),
        );
        if (verified) {
          expect((await operation).canViewPending, isFalse);
        } else {
          await expectLater(operation, throwsFormatException);
        }
      }
    },
  );

  test(
    'Home quick actions use session-verified lead and visit permissions',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'sales@example.test',
        'session_sid': 'test-session',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      for (final permission in [
        (false, false),
        (true, false),
        (true, true),
        (false, true),
      ]) {
        final access = await http.runWithClient(
          () => SiteVisitCreationApi.homeQuickActionAccess(),
          () => MockClient((request) async {
            expect(request.url.queryParameters['action'], 'can_create');
            expect(request.headers['Cookie'], 'sid=test-session');
            return http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  'current_user': 'sales@example.test',
                  'can_create_lead': permission.$1,
                  'can_create': permission.$2,
                  'can_view_pending': permission.$1,
                },
              }),
              200,
            );
          }),
        );
        expect(access.canAddLead, permission.$1);
        expect(access.canCreateVisit, permission.$2);
        expect(access.canViewVisits, isTrue);
        expect(access.canViewPending, permission.$1);
      }
    },
  );
  test(
    'Production role capability shows Pending without sales access',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'production@example.test',
        'session_sid': 'production-session',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      final access = await http.runWithClient(
        () => SiteVisitCreationApi.homeQuickActionAccess(),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              'message': {
                'current_user': 'production@example.test',
                'can_create': false,
                'can_create_lead': false,
                'can_view_pending': true,
              },
            }),
            200,
          ),
        ),
      );
      expect(access.canAddLead, isFalse);
      expect(access.canCreateVisit, isFalse);
      expect(access.canViewPending, isTrue);
    },
  );
  test(
    'all verified users can view Visits without granting creation',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'designer@example.test',
        'session_sid': 'designer-session',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      for (final flag in [true, false, null, 'true']) {
        final access = await http.runWithClient(
          () => SiteVisitCreationApi.homeQuickActionAccess(),
          () => MockClient(
            (_) async => http.Response(
              jsonEncode({
                'message': {
                  'current_user': 'designer@example.test',
                  'can_create': false,
                  'can_view_visits': flag,
                },
              }),
              200,
            ),
          ),
        );
        expect(access.canViewVisits, flag != false);
        expect(access.canCreateVisit, isFalse);
        expect(access.canAddLead, isFalse);
        expect(access.canViewPending, isFalse);
      }
    },
  );

  testWidgets(
    'Designer opens assigned Visits from navigation without New Visit',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'email': 'designer@example.test',
        'token': 'designer-token',
        'session_username': 'designer@example.test',
        'session_sid': 'designer-session',
      });
      dotenv.testLoad(
        fileInput:
            'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/hrms.api',
      );
      int? selected;
      await http.runWithClient(
        () async {
          final access = await SiteVisitCreationApi.homeQuickActionAccess();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: const SiteVisitsPage(),
                bottomNavigationBar: HomeNavigationBar(
                  currentIndex: 0,
                  showVisits: access.canViewVisits,
                  showLeads: access.canAddLead,
                  onTap: (index) => selected = index,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('New Visit'), findsNothing);
          expect(find.text('Assigned designer visit'), findsOneWidget);
          expect(find.text('Leads'), findsNothing);
          await tester.tap(find.text('Visits'));
          expect(selected, 2);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          if (request.url.queryParameters['action'] == 'can_create') {
            return http.Response(
              jsonEncode({
                'message': {
                  'current_user': 'designer@example.test',
                  'can_create': false,
                  'can_view_visits': true,
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/ping')) {
            return http.Response('{"message":"pong"}', 200);
          }
          if (request.url.path.endsWith('event_list')) {
            expect(
              request.url.queryParameters['user'],
              'designer@example.test',
            );
            return http.Response(
              jsonEncode({
                'message': [
                  {
                    'name': 'DESIGN-1',
                    'subject': 'Assigned designer visit',
                    'starts_on':
                        DateTime.now()
                            .add(const Duration(hours: 1))
                            .toIso8601String(),
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{"message":[]}', 200);
        }),
      );
    },
  );

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
