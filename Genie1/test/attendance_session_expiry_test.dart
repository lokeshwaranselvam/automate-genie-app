import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/utils/widget/attendance_session_notice.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'token': 'old-token'});
    dotenv.testLoad(
      fileInput:
          'SITE_URL=https://erp.example.test\n'
          'URL=https://erp.example.test/api/method/hrms.api',
    );
  });

  for (final recordsFirst in [false, true]) {
    for (final failure in [
      (401, '{}'),
      (403, jsonEncode({'exc_type': 'AuthenticationError'})),
      (
        417,
        jsonEncode({
          'exception': 'frappe.exceptions.AuthenticationError: expired',
        }),
      ),
      (400, jsonEncode({'exc_type': 'SessionExpired'})),
    ]) {
      test(
        'confirmed auth failure ${failure.$1}, recordsFirst=$recordsFirst',
        () async {
          await http.runWithClient(
            () => expectLater(
              Check.getStatus('staff@example.test', recordsFirst: recordsFirst),
              throwsA(isA<AttendanceAuthenticationException>()),
            ),
            () =>
                MockClient((_) async => http.Response(failure.$2, failure.$1)),
          );
        },
      );
    }
  }

  for (final failure in [
    (403, jsonEncode({'exc_type': 'PermissionError'})),
    (417, jsonEncode({'exc_type': 'ValidationError'})),
    (429, '{}'),
    (500, jsonEncode({'exc_type': 'AuthenticationError'})),
    (503, '<html>Unavailable</html>'),
  ]) {
    test(
      'HTTP ${failure.$1} without authentication evidence stays retryable',
      () async {
        final result = await http.runWithClient(
          () => Check.getStatus('staff@example.test'),
          () => MockClient((_) async => http.Response(failure.$2, failure.$1)),
        );
        expect(result['attendance_records_verified'], isFalse);
      },
    );
  }

  test('timeouts remain retryable and do not expire the saved login', () async {
    final result = await http.runWithClient(
      () => Check.getStatus('staff@example.test'),
      () => MockClient((_) async => throw TimeoutException('offline')),
    );
    expect(result['attendance_records_verified'], isFalse);
    expect(
      (await SharedPreferences.getInstance()).getString('token'),
      'old-token',
    );
  });

  test('auth failure on permission fallback is not swallowed', () async {
    var employeeReads = 0;
    await http.runWithClient(
      () => expectLater(
        Check.getStatus('staff@example.test', recordsFirst: true),
        throwsA(isA<AttendanceAuthenticationException>()),
      ),
      () => MockClient((_) async {
        employeeReads++;
        return employeeReads == 1
            ? http.Response(jsonEncode({'exc_type': 'PermissionError'}), 403)
            : http.Response('{}', 401);
      }),
    );
    expect(employeeReads, 2);
  });

  testWidgets('one popup waits for acknowledgement then opens login', (
    tester,
  ) async {
    final notice = AttendanceSessionNotice();
    var acknowledged = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    void acknowledge() {
                      acknowledged++;
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(
                          builder:
                              (_) => const Scaffold(body: Text('Login screen')),
                        ),
                        (_) => false,
                      );
                    }

                    notice.show(context, onAcknowledged: acknowledge);
                    notice.show(context, onAcknowledged: acknowledge);
                  },
                  child: const Text('Expired attendance response'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Expired attendance response'));
    await tester.pumpAndSettle();
    expect(find.text('Session Expired'), findsOneWidget);
    expect(
      find.text(
        'Your login credentials are no longer valid. Please sign in again.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Close'), findsNothing);
    expect(
      find.text(
        'Could not refresh attendance. Check your connection and retry.',
      ),
      findsNothing,
    );
    expect(acknowledged, 0);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Session Expired'), findsOneWidget);
    expect(acknowledged, 0);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(acknowledged, 1);
    expect(find.text('Login screen'), findsOneWidget);
    expect(find.text('Session Expired'), findsNothing);
  });
}
