import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/expense_claim_api.dart';
import 'package:homegenie/utils/api_business_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const method = '/api/method/create_expense_claim_from_mobile';
const options = {
  'employee': 'EMP-1',
  'expense_approver': 'approver@example.test',
  'currency': 'INR',
  'supports_multiple_expenses': true,
  'employee_options': [
    {'value': 'EMP-1', 'label': 'Staff'},
  ],
  'expense_approver_options': [
    {'value': 'approver@example.test', 'label': 'Approver'},
  ],
  'expense_types': [
    {'value': 'Food', 'label': 'Food'},
  ],
};
http.Response created() => http.Response(
  jsonEncode({
    'message': {
      'name': 'EXP-1',
      'expense_row': 'ROW-1',
      'bill_file_url': '/private/files/bill.jpg',
      'expenses': [{}, {}],
      'bill_files': [
        {'file_url': '/private/files/bill.jpg'},
        {'file_url': '/private/files/bill2.jpg'},
      ],
    },
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late List<String> bills;
  setUp(() async {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'session',
      'session_username': 'staff@example.test',
    });
    directory = await Directory.systemTemp.createTemp('expense_csrf_test_');
    bills = [];
    for (var i = 0; i < 2; i++) {
      final bill = File('${directory.path}/bill$i.jpg');
      await bill.writeAsString('bill-image-$i');
      bills.add(bill.path);
    }
  });
  tearDown(() => directory.delete(recursive: true));

  Future<ExpenseClaimCreationResult> submit(String token) =>
      ExpenseClaimApi.submitExpenses(
        employee: 'EMP-1',
        expenseApprover: 'approver@example.test',
        expenses: const [
          ExpenseClaimLine(
            expenseType: 'Food',
            amount: '1,000.00',
            expenseDate: '2026-10-15',
            description: 'Food',
          ),
          ExpenseClaimLine(
            expenseType: 'Food',
            amount: '50',
            expenseDate: '2026-10-14',
            description: 'Lunch',
          ),
        ],
        csrfToken: token,
        billPaths: bills,
        supportsMultipleExpenses: true,
      );

  Future<void> run(
    Future<void> Function() action,
    Future<http.Response> Function(http.Request) handler, {
    String token = 'form-token',
  }) => http.runWithClient(
    action,
    () => MockClient((request) async {
      if (request.url.path.endsWith('frappe.auth.get_logged_user')) {
        return http.Response(
          jsonEncode({'message': 'staff@example.test'}),
          200,
        );
      }
      if (request.method == 'GET' && request.url.path == method) {
        return http.Response(
          jsonEncode({
            'message': {...options, 'csrf_token': token},
          }),
          200,
        );
      }
      return handler(request);
    }),
  );

  test(
    'API can permit an expense without description or bill attachments',
    () async {
      await run(
        () async {
          final result = await ExpenseClaimApi.submitExpenses(
            employee: 'EMP-1',
            expenseApprover: 'approver@example.test',
            expenses: const [
              ExpenseClaimLine(
                expenseType: 'Food',
                amount: '10',
                expenseDate: '2026-10-26',
                description: '',
              ),
            ],
            csrfToken: 'form-token',
            billPaths: [],
            supportsMultipleExpenses: true,
            businessPolicy: ApiBusinessPolicy.fromApi({
              'fields': {
                'description': {'required': false},
              },
              'rules': {},
              'uploads': {'min_count': 0},
            }),
          );
          expect(result.name, 'EXP-OPTIONAL');
        },
        (request) async {
          expect(request.body, isNot(contains('filename=')));
          return http.Response(
            jsonEncode({
              'message': {
                'name': 'EXP-OPTIONAL',
                'expenses': [{}],
                'bill_files': [],
                'bill_file_url': '',
              },
            }),
            200,
          );
        },
      );
    },
  );

  void checkMultipart(http.Request request, String token) {
    expect(request.method, 'POST');
    expect(request.followRedirects, isFalse);
    expect(request.headers['Cookie'], 'sid=session');
    expect(request.headers['X-Frappe-CSRF-Token'], token);
    expect(request.body, contains('name="csrf_token"\r\n\r\n$token'));
    expect(request.body, contains('name="employee"\r\n\r\nEMP-1'));
    expect(request.body, contains('name="expenses"'));
    expect(request.body, contains('"amount":"1000.00"'));
    for (var i = 0; i < 2; i++) {
      expect(request.body, contains('filename="bill$i.jpg"'));
      expect(request.body, contains('bill-image-$i'));
    }
  }

  test(
    'multipart sends CSRF header and body with all rows and bills',
    () async {
      var posts = 0;
      await run(
        () async {
          final form = await ExpenseClaimApi.loadFormOptions();
          expect((await submit(form.csrfToken)).name, 'EXP-1');
        },
        (request) async {
          posts++;
          checkMultipart(request, 'form-token');
          return created();
        },
      );
      expect(posts, 1);
    },
  );

  test('missing form token bootstraps from the same session', () async {
    var bootstraps = 0;
    await run(
      () async {
        await ExpenseClaimApi.loadFormOptions();
        await submit('');
      },
      (request) async {
        if (request.url.path == '/app') {
          bootstraps++;
          expect(request.headers['Cookie'], 'sid=session');
          expect(request.followRedirects, isFalse);
          return http.Response("frappe.csrf_token = 'fresh';", 200);
        }
        checkMultipart(request, 'fresh');
        return created();
      },
      token: '',
    );
    expect(bootstraps, 1);
  });

  test(
    'explicit CSRF failure refreshes once and rebuilds both bill streams',
    () async {
      var posts = 0;
      var bootstraps = 0;
      await run(
        () async {
          await ExpenseClaimApi.loadFormOptions();
          await submit('form-token');
          await submit(
            'form-token',
          ); // A later submit must reuse the refreshed token.
        },
        (request) async {
          if (request.url.path == '/app') {
            bootstraps++;
            return http.Response("frappe.csrf_token = 'fresh';", 200);
          }
          posts++;
          checkMultipart(request, posts == 1 ? 'form-token' : 'fresh');
          return posts == 1
              ? http.Response(
                jsonEncode({
                  'exc_type': 'CSRFTokenError',
                  'message': 'Invalid Request',
                }),
                400,
              )
              : created();
        },
      );
      expect(posts, 3);
      expect(bootstraps, 1);
    },
  );

  for (final failure in ['validation', 'timeout', 'csrf']) {
    test('$failure does not cause repeated claim creation', () async {
      var posts = 0;
      await run(
        () async {
          await ExpenseClaimApi.loadFormOptions();
          await expectLater(
            submit('form-token'),
            throwsA(anyOf(isA<StateError>(), isA<TimeoutException>())),
          );
        },
        (request) async {
          if (request.url.path == '/app') {
            return http.Response("frappe.csrf_token = 'fresh';", 200);
          }
          posts++;
          if (failure == 'timeout') throw TimeoutException('test timeout');
          return http.Response(
            jsonEncode({
              'exc_type':
                  failure == 'csrf' ? 'CSRFTokenError' : 'ValidationError',
              'message': 'Invalid Request',
            }),
            400,
          );
        },
      );
      expect(posts, failure == 'csrf' ? 2 : 1);
    });
  }

  test('session change prevents sending old form data', () async {
    await run(() async {
      await ExpenseClaimApi.loadFormOptions();
      await (await SharedPreferences.getInstance()).setString(
        'session_sid',
        'another',
      );
      await expectLater(submit('form-token'), throwsStateError);
    }, (_) async => throw StateError('No POST allowed'));
  });

  test(
    'bootstrap refuses cross-site redirects without leaking cookies',
    () async {
      var calls = 0;
      await run(
        () async {
          await ExpenseClaimApi.loadFormOptions();
          await expectLater(submit(''), throwsStateError);
        },
        (request) async {
          calls++;
          expect(request.url.origin, 'https://erp.example.test');
          return http.Response(
            '',
            302,
            headers: {'location': 'https://other.example.test/app'},
          );
        },
        token: '',
      );
      expect(calls, 1);
    },
  );

  test(
    'Frappe validation detail takes precedence over generic message',
    () async {
      await run(
        () async {
          await ExpenseClaimApi.loadFormOptions();
          await expectLater(
            submit('form-token'),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Expense account is required.',
              ),
            ),
          );
        },
        (_) async => http.Response(
          jsonEncode({
            'message': 'Invalid Request',
            '_server_messages': jsonEncode([
              jsonEncode({'message': 'Expense account is required.'}),
            ]),
          }),
          417,
        ),
      );
    },
  );
}
