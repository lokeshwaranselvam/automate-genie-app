import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/event_details.dart';
import 'package:homegenie/Screen/site_visits_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Inspect the real detail route, then simulate returning before native plugins
// mount. This tests list loading, ID matching, tab selection and return behavior.
class _VisitObserver extends NavigatorObserver {
  final opened = <String>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null || route is! MaterialPageRoute<void>) return;
    final page = route.builder(navigator!.context);
    if (page is EventDetails) {
      opened.add(page.eventid);
      Future.microtask(() => navigator!.removeRoute(route));
    }
  }
}

void main() {
  for (final target in ['S1', 'C1', 'H1', 'O1', 'missing']) {
    testWidgets('schedule destination resolves $target by ID and current state', (
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
      final today = DateTime.now();
      final rows = [
        {
          'name': 'S1',
          'subject': 'Scheduled target',
          'starts_on': today.toIso8601String(),
        },
        {
          'name': 'C1',
          'subject': 'Completed target',
          'starts_on': today.toIso8601String(),
        },
        {
          'name': 'O1',
          'subject': 'Overdue target',
          'starts_on':
              today.subtract(const Duration(days: 1)).toIso8601String(),
        },
        {
          'name': 'H1',
          'subject': 'History-only target',
          'starts_on': today.toIso8601String(),
        },
      ];
      final observer = _VisitObserver();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [observer],
              home: SiteVisitsPage(initialEventId: target),
            ),
          );
          await tester.pumpAndSettle();
          if (target == 'missing') {
            expect(observer.opened, isEmpty);
            expect(
              find.text('Could not find this visit. Refresh and try again.'),
              findsOneWidget,
            );
          } else {
            expect(observer.opened, [target]);
            final subject =
                rows.firstWhere((row) => row['name'] == target)['subject']!;
            expect(find.text(subject), findsWidgets);
            for (final row in rows.where((row) => row['name'] != target)) {
              final sameCompletedTab =
                  ['C1', 'H1'].contains(target) &&
                  ['C1', 'H1'].contains(row['name']);
              expect(
                find.text(row['subject']!),
                sameCompletedTab ? findsWidgets : findsNothing,
              );
            }
            await tester.pumpAndSettle();
            expect(observer.opened, [target]);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/ping')) {
            return http.Response('{"message":"pong"}', 200);
          }
          if (request.url.queryParameters['action'] == 'can_create') {
            return http.Response(
              jsonEncode({
                'message': {
                  'current_user': 'sales@example.test',
                  'can_create': false,
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('.event_list')) {
            return http.Response(
              jsonEncode({
                'message': rows.where((row) => row['name'] != 'H1').toList(),
              }),
              200,
            );
          }
          if (request.url.path.endsWith('.history_list')) {
            // A stale scheduled row must be superseded by the completed history.
            return http.Response(
              jsonEncode({
                'message': [
                  {...rows[1], 'custom_check_out': today.toIso8601String()},
                  {...rows[3], 'custom_check_out': today.toIso8601String()},
                ],
              }),
              200,
            );
          }
          throw StateError('Unexpected API: ${request.url.path}');
        }),
      );
    });
  }
}
