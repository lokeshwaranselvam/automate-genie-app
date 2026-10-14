import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/leave_application_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response options({String token = ''}) => http.Response(
  jsonEncode({
    'message': {
      'employee': 'EMP-1',
      'employee_name': 'Staff',
      'csrf_token': token,
      'leave_types': [
        {'value': 'Casual Leave', 'label': 'Casual Leave'},
      ],
    },
  }),
  200,
);
http.Response saved() => http.Response(
  jsonEncode({
    'message': {'status': 'success', 'name': 'LEAVE-1', 'total_leave_days': 1},
  }),
  200,
);
Future<LeaveApplicationResult> submit(
  LeaveApplicationApi api, {
  String token = 'old',
}) => api.submitApplication(
  leaveType: 'Casual Leave',
  fromDate: DateTime(2026, 10, 14),
  toDate: DateTime(2026, 10, 14),
  reason: 'Family',
  halfDay: false,
  csrfToken: token,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({'session_sid': 'leave-session'});
  });

  test(
    'missing options token initializes Desk with the same session',
    () async {
      final api = LeaveApplicationApi(
        client: MockClient((request) async {
          expect(request.headers['cookie'], 'sid=leave-session');
          if (request.url.path == '/app') {
            return http.Response('frappe.csrf_token = "fresh";', 200);
          }
          return options();
        }),
      );
      addTearDown(api.close);
      expect((await api.loadOptions()).csrfToken, 'fresh');
    },
  );

  test(
    'explicit CSRF rejection refreshes the token and retries once',
    () async {
      var posts = 0;
      final api = LeaveApplicationApi(
        client: MockClient((request) async {
          expect(request.headers['cookie'], 'sid=leave-session');
          if (request.method == 'GET') {
            return http.Response('frappe.csrf_token = "fresh";', 200);
          }
          posts++;
          if (posts == 1) {
            return http.Response(
              jsonEncode({
                'exc_type': 'CSRFTokenError',
                'message': 'Invalid Request',
              }),
              400,
            );
          }
          expect(request.headers['x-frappe-csrf-token'], 'fresh');
          expect(request.bodyFields['csrf_token'], 'fresh');
          expect(request.bodyFields['description'], 'Family');
          return saved();
        }),
      );
      addTearDown(api.close);
      expect((await submit(api)).name, 'LEAVE-1');
      expect(posts, 2);
    },
  );

  test(
    'ordinary Invalid Request and server validation errors are never retried',
    () async {
      for (final type in ['ValidationError', 'PermissionError']) {
        var calls = 0;
        final api = LeaveApplicationApi(
          client: MockClient((request) async {
            calls++;
            return http.Response(
              jsonEncode({'exc_type': type, 'message': 'Invalid Request'}),
              400,
            );
          }),
        );
        await expectLater(submit(api), throwsStateError);
        expect(calls, 1);
        api.close();
      }
    },
  );

  test('repeated CSRF failure stops after one retry', () async {
    var posts = 0;
    final api = LeaveApplicationApi(
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response('frappe.csrf_token = "fresh";', 200);
        }
        posts++;
        return http.Response(
          jsonEncode({
            'exc_type': 'CSRFTokenError',
            'message': 'Invalid Request',
          }),
          400,
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(submit(api), throwsStateError);
    expect(posts, 2);
  });

  test('session switch after loading options blocks submission', () async {
    var posts = 0;
    final api = LeaveApplicationApi(
      client: MockClient((request) async {
        if (request.method == 'POST') posts++;
        return options(token: 'valid');
      }),
    );
    addTearDown(api.close);
    await api.loadOptions();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_sid', 'other-session');
    await expectLater(submit(api), throwsStateError);
    expect(posts, 0);
  });

  test('Desk redirects never forward a session to another origin', () async {
    var calls = 0;
    final api = LeaveApplicationApi(
      client: MockClient((request) async {
        calls++;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://other.example.test/app'},
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(submit(api, token: ''), throwsStateError);
    expect(calls, 1);
  });
}
