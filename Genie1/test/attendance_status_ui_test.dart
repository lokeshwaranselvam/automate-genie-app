import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/attendance_page.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(
    () => dotenv.testLoad(
      fileInput:
          'URL=https://erp.example.test/api/method/hrms.api\nSITE_URL=https://erp.example.test',
    ),
  );

  testWidgets(
    'ERP checkout shows Completed; deleting records and refreshing restores Check In',
    (tester) async {
      SharedPreferences.setMockInitialValues({'token': 'test-token'});
      var hasIn = true;
      var hasOut = false;
      Map<String, dynamic> status = {};
      late StateSetter update;
      Future<void> refresh() async {
        final current = await Check.getStatus('staff@example.test');
        update(() => status = current);
      }

      final client = MockClient((request) async {
        if (request.url.path.endsWith('.get_checkin_checkout_status')) {
          // Exact failing live shape: paired flags are true, while the old
          // checkout availability endpoint would be false.
          return http.Response(
            jsonEncode({
              'message': {'checked_in': true, 'checked_out': true},
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/Employee')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'EMP-1'},
              ],
            }),
            200,
          );
        }
        if (request.url.pathSegments.last == 'Employee Checkin') {
          final filters =
              jsonDecode(request.url.queryParameters['filters']!) as List;
          final today = filters.any(
            (filter) => filter[0] == 'time' && filter[1] == '>=',
          );
          return http.Response(
            jsonEncode({
              'data': [
                if (today && hasOut)
                  {
                    'name': 'OUT',
                    'log_type': 'OUT',
                    'time': '2026-10-12 20:04:22',
                  },
                if (today && hasIn)
                  {
                    'name': 'IN',
                    'log_type': 'IN',
                    'time': '2026-10-12 20:03:44',
                  },
              ],
            }),
            200,
          );
        }
        fail('Unexpected endpoint: ${request.url}');
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return AttendancePage(
                    checkedIn: status['checked_in'] == true,
                    completedToday: status['completed_today'] == true,
                    previousDayPendingCheckout: false,
                    loading: false,
                    actionLoading: false,
                    status: status,
                    position: null,
                    accuracy: null,
                    currentAddress: 'Office',
                    onRefresh: refresh,
                    onBack: () {},
                    onOpenHistory: () {},
                    onAttendanceAction: () {},
                    onLeaveApplication: () {},
                  );
                },
              ),
            ),
          ),
        );
        await refresh();
        await tester.pumpAndSettle();
        expect(find.text('Check Out'), findsOneWidget);
        expect(find.text('Checked In'), findsOneWidget);

        hasOut = true;
        await refresh();
        await tester.pumpAndSettle();
        expect(find.text('Check Out'), findsNothing);
        expect(find.text('Checked In'), findsNothing);
        expect(find.text('Completed'), findsNWidgets(2));
        final completedButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Completed'),
        );
        expect(completedButton.onPressed, isNull);

        hasIn = false;
        hasOut = false;
        // Use the screen's real pull-to-refresh callback after the ERP deletion.
        await tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await tester.pumpAndSettle();
        expect(find.text('Completed'), findsNothing);
        expect(find.text('Check In'), findsOneWidget);
        expect(find.text('Not Checked In'), findsOneWidget);
        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Check In'),
              )
              .onPressed,
          isNotNull,
        );
      }, () => client);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unknown server state disables the action and offers retry', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttendancePage(
            checkedIn: true,
            previousDayPendingCheckout: false,
            statusError: 'Could not refresh attendance.',
            loading: false,
            actionLoading: false,
            status: const {},
            position: null,
            accuracy: null,
            currentAddress: '',
            onRefresh: () async {
              retries++;
            },
            onBack: () {},
            onOpenHistory: () {},
            onAttendanceAction: () {},
            onLeaveApplication: () {},
          ),
        ),
      ),
    );
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    expect(retries, 1);
    await tester.scrollUntilVisible(find.text('Check Out'), 150);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Check Out'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'previous-day option uses checkout and refresh restores today check-in',
    (tester) async {
      var pending = true;
      var actions = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AttendancePage(
                  checkedIn: false,
                  previousDayPendingCheckout: pending,
                  completedToday: false,
                  loading: false,
                  actionLoading: false,
                  status: const {'check_in_time': '2026-10-14 09:30:00'},
                  position: null,
                  accuracy: null,
                  currentAddress: 'Office',
                  onRefresh: () async => update(() => pending = false),
                  onBack: () {},
                  onOpenHistory: () {},
                  onAttendanceAction: () => actions++,
                  onLeaveApplication: () {},
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('Previous Day Checkout'), findsOneWidget);
      expect(find.text('Checkout Pending'), findsOneWidget);
      expect(
        find.text('Your previous day check-in is still open'),
        findsOneWidget,
      );
      expect(find.text('09:30 AM'), findsOneWidget);
      expect(find.text('Check In'), findsNothing);
      await tester.scrollUntilVisible(find.text('Previous Day Checkout'), 150);
      await tester.ensureVisible(find.text('Previous Day Checkout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Previous Day Checkout'));
      expect(actions, 1);
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      expect(find.text('Previous Day Checkout'), findsNothing);
      expect(find.text('Check In'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Check In'),
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('Leave Application'), findsNothing);
    },
  );
}
