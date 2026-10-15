import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(
    () => dotenv.testLoad(
      fileInput:
          'URL=https://erp.example.test/api/method/hrms.api\nSITE_URL=https://erp.example.test',
    ),
  );
  setUp(() => SharedPreferences.setMockInitialValues({'token': 'test-token'}));

  MockClient recordClient(
    List<Map<String, dynamic>> logs, {
    Map<String, dynamic> legacy = const {
      'checked_in': true,
      'checked_out': true,
    },
    List<Map<String, dynamic>> prior = const [],
    bool permissionDenied = false,
    int legacyStatus = 200,
  }) => MockClient((request) async {
    expect(request.headers['Cache-Control'], 'no-cache, no-store');
    expect(request.headers['Authorization'], 'test-token');
    if (request.url.path.endsWith('.get_checkin_checkout_status')) {
      return http.Response(jsonEncode({'message': legacy}), legacyStatus);
    }
    if (request.url.path.endsWith('/Employee')) {
      expect(jsonDecode(request.url.queryParameters['filters']!), {
        'user_id': 'staff@example.test',
        'status': 'Active',
      });
      return permissionDenied
          ? http.Response('{}', 403)
          : http.Response(
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
      expect(filters.first, ['employee', '=', 'EMP-1']);
      final today = filters.any(
        (filter) => filter[0] == 'time' && filter[1] == '>=',
      );
      return http.Response(jsonEncode({'data': today ? logs : prior}), 200);
    }
    fail(
      'Unexpected endpoint: ${request.url}. Legacy availability flags must not be used.',
    );
  });

  const inRow = {
    'name': 'IN-1',
    'log_type': 'IN',
    'time': '2026-10-12 20:03:44',
  };
  const outRow = {
    'name': 'OUT-1',
    'log_type': 'OUT',
    'time': '2026-10-12 20:04:22',
  };

  test(
    'camera preparation does not wait for legacy status when rows are verified',
    () async {
      final client = recordClient([inRow]);
      final status = await http.runWithClient(
        () => Check.getStatus('staff@example.test', recordsFirst: true),
        () => MockClient((request) async {
          expect(
            request.url.path.endsWith('.get_checkin_checkout_status'),
            isFalse,
          );
          final forwarded = http.Request(request.method, request.url)
            ..headers.addAll(request.headers);
          return http.Response.fromStream(await client.send(forwarded));
        }),
      );
      expect(status['checked_in'], isTrue);
      expect(status['attendance_records_verified'], isTrue);
      client.close();
    },
  );

  test(
    'camera preparation retains paired-status fallback when records are denied',
    () async {
      final status = await http.runWithClient(
        () => Check.getStatus('staff@example.test', recordsFirst: true),
        () => recordClient(
          [],
          permissionDenied: true,
          legacy: {'checked_in': true, 'checked_out': false},
        ),
      );
      expect(status['checked_in'], isTrue);
      expect(status['attendance_records_verified'], isTrue);
      expect(status['attendance_status_source'], 'paired_server_status');
    },
  );

  for (final state in [
    (
      logs: <Map<String, dynamic>>[outRow, inRow],
      active: false,
      complete: true,
    ),
    (logs: <Map<String, dynamic>>[inRow], active: true, complete: false),
    (logs: <Map<String, dynamic>>[], active: false, complete: false),
    (logs: <Map<String, dynamic>>[outRow], active: false, complete: false),
  ]) {
    test(
      'actual records ${state.logs.length} override stale legacy flags',
      () async {
        final status = await http.runWithClient(
          () => Check.getStatus('staff@example.test'),
          () => recordClient(state.logs),
        );
        expect(status['attendance_records_verified'], isTrue);
        expect(status['attendance_status_source'], 'employee_checkin_records');
        expect(status['checked_in'], state.active);
        expect(status['completed_today'], state.complete);
      },
    );
  }

  test(
    'live ERP response checked_out true is never replaced by checkout_status false',
    () async {
      final status = await http.runWithClient(
        () => Check.getStatus('staff@example.test'),
        () => recordClient([outRow, inRow]),
      );
      expect(status['completed_today'], isTrue);
      expect(status['check_out_time'], '2026-10-12 20:04:22');
      expect(status['checked_in'], isFalse);
    },
  );

  test(
    'deleting OUT reopens the remaining IN; deleting both resets check-in',
    () async {
      var logs = <Map<String, dynamic>>[outRow, inRow];
      Future<Map<String, dynamic>> read() => http.runWithClient(
        () => Check.getStatus('staff@example.test'),
        () => recordClient(logs),
      );
      expect((await read())['completed_today'], isTrue);
      logs = [inRow];
      expect((await read())['checked_in'], isTrue);
      logs = [];
      final status = await read();
      expect(status['checked_in'], isFalse);
      expect(status['completed_today'], isFalse);
    },
  );

  test('latest IN after a prior OUT is active rather than completed', () async {
    final status = await http.runWithClient(
      () => Check.getStatus('staff@example.test'),
      () => recordClient([
        {'name': 'IN-2', 'log_type': 'IN', 'time': '2026-10-12 21:00:00'},
        outRow,
        inRow,
      ]),
    );
    expect(status['checked_in'], isTrue);
    expect(status['completed_today'], isFalse);
  });

  test(
    'only an actual prior IN creates pending previous-day checkout',
    () async {
      final status = await http.runWithClient(
        () => Check.getStatus('staff@example.test'),
        () => recordClient(
          [],
          prior: [inRow],
          legacy: {'checked_in': false, 'checked_out': false},
        ),
      );
      expect(status['previous_checkout_pending'], isTrue);
      expect(status['completed_today'], isFalse);
    },
  );

  test('record query can recover when legacy status fails', () async {
    final status = await http.runWithClient(
      () => Check.getStatus('staff@example.test'),
      () => recordClient([outRow, inRow], legacyStatus: 500),
    );
    expect(status['completed_today'], isTrue);
    expect(status['attendance_records_verified'], isTrue);
  });

  test(
    'permission-limited user uses main endpoint paired flags, not availability flags',
    () async {
      final status = await http.runWithClient(
        () => Check.getStatus('staff@example.test'),
        () => recordClient([], permissionDenied: true),
      );
      expect(status['completed_today'], isTrue);
      expect(status['attendance_status_source'], 'paired_server_status');
    },
  );

  test('missing paired flags and unavailable records remain unknown', () async {
    final status = await http.runWithClient(
      () => Check.getStatus('staff@example.test'),
      () => recordClient(
        [],
        permissionDenied: true,
        legacy: {'checked_in': true},
      ),
    );
    expect(status['attendance_records_verified'], isFalse);
    expect(status.containsKey('completed_today'), isFalse);
  });

  test('completion helper also reads real rows', () async {
    final completed = await http.runWithClient(
      () => Check.hasCompletedAttendanceToday('staff@example.test'),
      () => recordClient([outRow, inRow]),
    );
    expect(completed, isTrue);
  });

  for (final response in [
    (message: 'Check-Out Created Successfully', code: 200, status: 'Success'),
    (message: 'Employee Already checked out!', code: 403, status: 'Success'),
    (message: 'Not permitted to check out', code: 403, status: 'Warning'),
  ]) {
    test('checkout ${response.code} ${response.message}', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['face_verification'], 'receipt-id');
        expect(request.url.queryParameters['include_timings'], '1');
        return http.Response(
          jsonEncode({'message': response.message}),
          response.code,
        );
      });
      final result = await http.runWithClient(
        () => Check.checkout(
          'staff@example.test',
          13.01,
          80.1,
          'Office',
          '',
          '0 m',
          'Office',
          const [],
          faceVerification: 'receipt-id',
        ),
        () => client,
      );
      expect(result['status'], response.status);
    });
  }

  test(
    'check-in preserves receipt, photo and success with optional diagnostics',
    () async {
      var calls = 0;
      final result = await http.runWithClient(
        () => Check.checkin(
          'staff@example.test',
          13.01,
          80.1,
          'Office & entrance',
          'Head Office',
          photoUrl: '/private/files/photo.jpg',
          faceVerification: 'receipt-id',
        ),
        () => MockClient((request) async {
          calls++;
          expect(request.url.queryParameters['address'], 'Office & entrance');
          expect(
            request.url.queryParameters['photo_url'],
            '/private/files/photo.jpg',
          );
          expect(
            request.url.queryParameters['face_verification'],
            'receipt-id',
          );
          expect(request.url.queryParameters['include_timings'], '1');
          expect(request.headers['authorization'], 'test-token');
          return http.Response(
            jsonEncode({
              'message': 'Check-In Created Successfully',
              'attendance_timings_ms': {'guard_total': 3, 'attach_total': 4},
            }),
            200,
          );
        }),
      );
      expect(result['status'], 'Success');
      expect(calls, 1);
    },
  );
}
