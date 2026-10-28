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

  Future<Map<String, dynamic>> read({
    String shift = 'Requested Shift',
    int policyStatus = 200,
    bool includeShift = true,
    bool recordsFirst = false,
    String? policyLocation,
    bool denyLocationField = false,
  }) => http.runWithClient(
    () => Check.getStatus(
      'staff@example.test',
      includeShift: includeShift,
      recordsFirst: recordsFirst,
    ),
    () => MockClient((request) async {
      if (request.url.path.endsWith('/mobile_business_policy')) {
        expect(includeShift, isTrue);
        expect(request.headers['Authorization'], 'test-token');
        expect(request.url.queryParameters, {
          'feature': 'attendance',
          'action': 'get',
        });
        return http.Response(
          jsonEncode({
            'message': {
              'policy': {
                'attendance': {
                  'shift': shift,
                  'checkin_location':
                      policyLocation ?? 'Head Office - DsignDoors',
                  'status': {
                    'attendance_records_verified': true,
                    'attendance_status_source': 'business_policy',
                    'checked_in': true,
                    'checked_out': false,
                    'completed_today': false,
                    'previous_checkout_pending': false,
                    'check_in_time': '2026-10-28 09:00:00',
                  },
                },
              },
            },
          }),
          policyStatus,
        );
      }
      expect(
        includeShift,
        isFalse,
        reason:
            'Attendance page must use only Business Policy, including before camera',
      );
      if (request.url.path.endsWith('/Employee')) {
        return http.Response(
          jsonEncode({
            'data': [
              {'name': 'EMP-1', 'default_shift': 'Legacy Shift'},
            ],
          }),
          200,
        );
      }
      if (request.url.pathSegments.last == 'Employee Checkin') {
        final fields =
            jsonDecode(request.url.queryParameters['fields']!) as List;
        if (denyLocationField && fields.contains('custom_office_type')) {
          return http.Response('{}', 403);
        }
        final filters =
            jsonDecode(request.url.queryParameters['filters']!) as List;
        final today = filters.any((f) => f[0] == 'time' && f[1] == '>=');
        return http.Response(
          jsonEncode({
            'data':
                today
                    ? [
                      {
                        'name': 'IN-1',
                        'log_type': 'IN',
                        'time': '2026-10-28 09:00:00',
                        if (!denyLocationField)
                          'custom_office_type': 'Head Office - DsignDoors',
                      },
                    ]
                    : [],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'message': {'checked_in': true, 'checked_out': false},
        }),
        200,
      );
    }),
  );

  for (final recordsFirst in [false, true]) {
    test(
      'API shift and saved IN location, recordsFirst=$recordsFirst',
      () async {
        final status = await read(recordsFirst: recordsFirst);
        expect(status['attendance_shift'], 'Requested Shift');
        expect(status['office_type'], 'Head Office - DsignDoors');
        expect(status['attendance_records_verified'], isTrue);
        expect(status['checked_in'], isTrue);
      },
    );
  }

  test('other status consumers do not request business policy', () async {
    final status = await read(includeShift: false);
    expect(status.containsKey('attendance_shift'), isFalse);
    expect(status['attendance_records_verified'], isTrue);
  });

  test(
    'Employee mapping returned by policy controls the displayed location',
    () async {
      final status = await read(policyLocation: 'Head Office');
      expect(status['office_type'], 'Head Office');
      expect(status['checked_in'], isTrue);
    },
  );

  test(
    'empty Employee mapping does not display an unrelated saved location',
    () async {
      final status = await read(policyLocation: '');
      expect(status['office_type'], '');
      expect(status['checked_in'], isTrue);
    },
  );

  test(
    'policy restores saved location when optional REST field is denied',
    () async {
      final status = await read(
        policyLocation: 'Head Office - Chennai',
        denyLocationField: true,
      );
      expect(status['office_type'], 'Head Office - Chennai');
      expect(status['checked_in'], isTrue);
      expect(status['attendance_records_verified'], isTrue);
    },
  );

  test('unavailable policy leaves attendance unverified for retry', () async {
    final status = await read(policyStatus: 417);
    expect(status['attendance_records_verified'], isFalse);
    expect(status['checked_in'], isNull);
  });

  test('policy authentication failure remains a session failure', () async {
    await expectLater(
      read(policyStatus: 401),
      throwsA(isA<AttendanceAuthenticationException>()),
    );
  });

  for (final shift in ['Requested Shift', 'General Shift', '']) {
    testWidgets('page displays API-owned shift "$shift"', (tester) async {
      final status = await read(shift: shift);
      await tester.pumpWidget(
        MaterialApp(
          home: AttendancePage(
            checkedIn: true,
            previousDayPendingCheckout: false,
            loading: false,
            actionLoading: false,
            status: status,
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
      expect(find.text(shift.isEmpty ? 'Not assigned' : shift), findsOneWidget);
      expect(find.text('Legacy Shift'), findsNothing);
      expect(find.text('Head Office - DsignDoors'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
