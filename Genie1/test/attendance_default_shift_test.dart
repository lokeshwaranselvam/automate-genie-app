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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'token': 'test-token'});
    dotenv.testLoad(
      fileInput:
          'URL=https://erp.example.test/api/method/app.api\nSITE_URL=https://erp.example.test',
    );
  });

  for (final recordsFirst in [false, true]) {
    test(
      'loads Employee.default_shift with attendance, recordsFirst=$recordsFirst',
      () async {
        var employeeReads = 0;
        await http.runWithClient(
          () async {
            final status = await Check.getStatus(
              'staff@example.test',
              recordsFirst: recordsFirst,
            );
            expect(status['default_shift'], 'General Shift');
            expect(status['attendance_records_verified'], isTrue);
            expect(status['checked_in'], isFalse);
          },
          () => MockClient((request) async {
            expect(request.headers['Authorization'], 'test-token');
            if (request.url.path.endsWith('/Employee')) {
              employeeReads++;
              expect(jsonDecode(request.url.queryParameters['fields']!), [
                'name',
                'default_shift',
              ]);
              expect(jsonDecode(request.url.queryParameters['filters']!), {
                'user_id': 'staff@example.test',
                'status': 'Active',
              });
              return http.Response(
                jsonEncode({
                  'data': [
                    {'name': 'EMP-1', 'default_shift': 'General Shift'},
                  ],
                }),
                200,
              );
            }
            if (request.url.pathSegments.last == 'Employee Checkin') {
              return http.Response(jsonEncode({'data': []}), 200);
            }
            return http.Response(
              jsonEncode({
                'message': {'checked_in': false, 'checked_out': false},
              }),
              200,
            );
          }),
        );
        expect(employeeReads, 1); // No extra profile or Shift Type request.
      },
    );
  }

  test(
    'shift remains available when checkin record permission requires paired-status fallback',
    () async {
      await http.runWithClient(
        () async {
          final status = await Check.getStatus('staff@example.test');
          expect(status['default_shift'], 'Day Shift');
          expect(status['attendance_status_source'], 'paired_server_status');
          expect(status['checked_in'], isTrue);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/Employee')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'name': 'EMP-1', 'default_shift': 'Day Shift'},
                ],
              }),
              200,
            );
          }
          if (request.url.pathSegments.last == 'Employee Checkin')
            return http.Response('{}', 403);
          return http.Response(
            jsonEncode({
              'message': {'checked_in': true, 'checked_out': false},
            }),
            200,
          );
        }),
      );
    },
  );

  test(
    'optional field rejection preserves name-only attendance lookup',
    () async {
      final queries = <List>[];
      await http.runWithClient(
        () async {
          final status = await Check.getStatus(
            'staff@example.test',
            recordsFirst: true,
          );
          expect(status['attendance_records_verified'], isTrue);
          expect(status.containsKey('default_shift'), isFalse);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/Employee')) {
            final fields =
                jsonDecode(request.url.queryParameters['fields']!) as List;
            queries.add(fields);
            if (fields.contains('default_shift'))
              return http.Response('{}', 403);
            return http.Response(
              jsonEncode({
                'data': [
                  {'name': 'EMP-1'},
                ],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'data': []}), 200);
        }),
      );
      expect(queries, [
        ['name', 'default_shift'],
        ['name'],
      ]);
    },
  );

  for (final shift in ['General Shift', null]) {
    testWidgets('Attendance Shift row shows Employee.default_shift=$shift', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AttendancePage(
            checkedIn: false,
            previousDayPendingCheckout: false,
            loading: false,
            actionLoading: false,
            status: {
              'default_shift': shift,
              if (shift != null) 'shift_name': 'Other shift',
            },
            position: null,
            accuracy: null,
            currentAddress: '',
            onRefresh: () async {},
            onBack: () {},
            onOpenHistory: () {},
            onAttendanceAction: () {},
            onLeaveApplication: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(shift ?? 'Not assigned'), findsOneWidget);
      expect(find.text('Other shift'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
