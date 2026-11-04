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

  Map<String, dynamic> row(String type, String office) => {
    'name': '$type-1',
    'log_type': type,
    'time': '2026-10-25 09:11:00',
    'custom_office_type': office,
  };

  Future<Map<String, dynamic>> read(
    List<Map<String, dynamic>> today, {
    List<Map<String, dynamic>> prior = const [],
    bool recordsFirst = false,
    int? optionalFieldError,
  }) => http.runWithClient(
    () => Check.getStatus('staff@example.test', recordsFirst: recordsFirst),
    () => MockClient((request) async {
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
        final fields =
            jsonDecode(request.url.queryParameters['fields']!) as List;
        if (optionalFieldError != null &&
            fields.contains('custom_office_type')) {
          return http.Response('{}', optionalFieldError);
        }
        final filters =
            jsonDecode(request.url.queryParameters['filters']!) as List;
        expect(filters.first, ['employee', '=', 'EMP-1']);
        final isToday = filters.any((f) => f[0] == 'time' && f[1] == '>=');
        final logs = isToday ? today : prior;
        return http.Response(
          jsonEncode({
            'data': [
              for (final log in logs) {for (final key in fields) key: log[key]},
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'message': {
            'checked_in': true,
            'checked_out': false,
            'office_type': 'Old office',
          },
        }),
        200,
      );
    }),
  );

  for (final recordsFirst in [false, true]) {
    test('saved office is loaded, recordsFirst=$recordsFirst', () async {
      final status = await read([
        row('IN', 'Head Office - DsignDoors'),
      ], recordsFirst: recordsFirst);
      expect(status['office_type'], 'Head Office - DsignDoors');
      expect(status['checked_in'], isTrue);
      expect(status['attendance_records_verified'], isTrue);
    });
  }

  test('uses IN location when OUT has a different location', () async {
    final status = await read([
      row('OUT', 'Other office'),
      row('IN', 'Head Office - Madurai'),
    ]);
    expect(status['office_type'], 'Head Office - Madurai');
    expect(status['completed_today'], isTrue);
  });

  test('pending previous-day checkin uses its saved location', () async {
    final status = await read([], prior: [row('IN', 'Bioman - Ayanambakkam')]);
    expect(status['office_type'], 'Bioman - Ayanambakkam');
    expect(status['previous_checkout_pending'], isTrue);
  });

  test('no checkin clears the previous location', () async {
    final status = await read([]);
    expect(status['office_type'], '');
    expect(status['checked_in'], isFalse);
  });

  for (final error in [403, 417]) {
    test(
      'optional location rejection $error preserves attendance lookup',
      () async {
        final status = await read(
          [row('IN', 'Head Office - Chennai')],
          recordsFirst: true,
          optionalFieldError: error,
        );
        expect(status['checked_in'], isTrue);
        expect(status['attendance_records_verified'], isTrue);
        expect(status.containsKey('office_type'), isFalse);
      },
    );
  }

  testWidgets('Attendance displays saved selection under Shift', (
    tester,
  ) async {
    final status = await read([row('IN', 'Head Office - DsignDoors')]);
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
    expect(find.text('Head Office - DsignDoors'), findsOneWidget);
    expect(find.text('At Head Office - DsignDoors'), findsOneWidget);
    expect(find.text('Office'), findsNothing);
  });
}
