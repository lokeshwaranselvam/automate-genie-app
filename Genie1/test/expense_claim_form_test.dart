import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/expense_claim_webview_page.dart';
import 'package:homegenie/utils/api/expense_claim_api.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

class FakeBillPicker extends ImagePickerPlatform {
  final List<XFile> bills;
  FakeBillPicker(this.bills);

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => bills;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => bills.first;
}

const formOptions = {
  'employee': 'EMP-1',
  'expense_approver': 'approver@example.test',
  'currency': 'INR',
  'csrf_token': 'csrf',
  'supports_multiple_expenses': true,
  'employee_options': [
    {'value': 'EMP-1', 'label': 'Staff (EMP-1)'},
  ],
  'expense_approver_options': [
    {'value': 'approver@example.test', 'label': 'Approver'},
  ],
  'expense_types': [
    {'value': 'Travel', 'label': 'Travel'},
    {'value': 'Meals', 'label': 'Meals'},
  ],
};

Finder rowCard(int index) =>
    find
        .ancestor(
          of: find.text('Expense $index'),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.key is ObjectKey,
          ),
        )
        .first;

Finder rowField(int index, String hint) => find.descendant(
  of: rowCard(index),
  matching: find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == hint,
  ),
);

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> fillRow(
  WidgetTester tester,
  int index,
  String amount,
  String description,
) async {
  await tester.ensureVisible(rowField(index, 'Enter amount'));
  await tester.enterText(rowField(index, 'Enter amount'), amount);
  await tester.ensureVisible(rowField(index, 'Enter expense details'));
  await tester.enterText(rowField(index, 'Enter expense details'), description);
  await tester.pumpAndSettle();
}

Future<void> attachBills(WidgetTester tester) async {
  await tapVisible(tester, find.text('Add Photos'));
  await tester.runAsync(() async {
    await tester.tap(find.text('Choose from gallery'));
  });
  await tester.pumpAndSettle();
}

Future<void> chooseDate(WidgetTester tester, int index, DateTime date) async {
  await tapVisible(
    tester,
    find.descendant(
      of: rowCard(index),
      matching: find.byIcon(Icons.calendar_month_outlined),
    ),
  );
  await tapVisible(tester, find.byTooltip('Switch to input'));
  final dialog = find.byType(DatePickerDialog);
  final context = tester.element(dialog);
  await tester.enterText(
    find.descendant(of: dialog, matching: find.byType(TextField)),
    MaterialLocalizations.of(context).formatCompactDate(date),
  );
  await tapVisible(tester, find.text('OK'));
}

Future<void> submitAndWait(
  WidgetTester tester,
  Completer<dynamic> posted,
) async {
  await tester.ensureVisible(find.text('Submit Claim'));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.text('Submit Claim'));
    final elapsed = Stopwatch()..start();
    while (!posted.isCompleted &&
        elapsed.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Let the response stream complete before advancing frame animations.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  expect(
    posted.isCompleted,
    isTrue,
    reason: 'The multipart POST must complete.',
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> createdResponse(int rows, int bills) => {
  'name': 'HR-EXP-TEST',
  'expense_row': 'EXP-1',
  'bill_file_url': '/private/files/bill1.png',
  'expenses': List.generate(rows, (i) => {'name': 'EXP-${i + 1}'}),
  'bill_files': List.generate(
    bills,
    (i) => {'file_url': '/private/files/bill${i + 1}.png'},
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<XFile> bills;
  late ImagePickerPlatform originalPicker;

  setUp(() async {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'session',
      'session_username': 'staff@example.test',
    });
    // Reuse existing image assets as read-only upload fixtures. Flutter may
    // keep decoded files mapped on Windows, so these need no deletion.
    bills = [
      XFile(File('assets/images/logoAG.png').absolute.path),
      XFile(File('assets/images/logo.jpeg').absolute.path),
    ];
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FakeBillPicker(bills);
  });

  tearDown(() async {
    ImagePickerPlatform.instance = originalPicker;
  });

  MockClient client({
    bool multiple = true,
    Future<http.Response> Function(http.Request)? onPost,
  }) => MockClient((request) async {
    expect(request.headers['Cookie'], 'sid=session');
    if (request.url.path.endsWith('frappe.auth.get_logged_user')) {
      return http.Response(jsonEncode({'message': 'staff@example.test'}), 200);
    }
    expect(request.url.path, '/api/method/create_expense_claim_from_mobile');
    if (request.method == 'POST') {
      expect(request.headers['X-Frappe-CSRF-Token'], 'csrf');
      return onPost!(request);
    }
    final options = Map<String, dynamic>.from(formOptions);
    if (!multiple) options.remove('supports_multiple_expenses');
    return http.Response(jsonEncode({'message': options}), 200);
  });

  Future<void> withForm(
    WidgetTester tester,
    Future<void> Function() check, {
    bool multiple = true,
    Size size = const Size(600, 1400),
    Future<http.Response> Function(http.Request)? onPost,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    try {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: ExpenseClaimWebViewPage()));
        await tester.pumpAndSettle();
        await check();
      }, () => client(multiple: multiple, onPost: onPost));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  }

  testWidgets(
    'adding and removing rows preserves other row values and updates the total',
    (tester) async {
      await withForm(tester, () async {
        await fillRow(tester, 1, '1,000.25', 'Taxi');
        await tapVisible(tester, find.text('Add Expense'));
        await fillRow(tester, 2, '80.50', 'Lunch');
        final dropdown = find.descendant(
          of: rowCard(2),
          matching: find.byType(DropdownButton<String>),
        );
        await tapVisible(tester, dropdown);
        await tester.tap(find.text('Meals').last);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('expense-total'))).data,
          'INR 1,080.75',
        );
        await tapVisible(tester, find.byTooltip('Remove expense 1'));
        expect(find.text('Expense 2'), findsNothing);
        expect(
          tester
              .widget<TextField>(rowField(1, 'Enter amount'))
              .controller!
              .text,
          '80.50',
        );
        expect(
          tester
              .widget<TextField>(rowField(1, 'Enter expense details'))
              .controller!
              .text,
          'Lunch',
        );
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.descendant(
                  of: rowCard(1),
                  matching: find.byType(DropdownButton<String>),
                ),
              )
              .value,
          'Meals',
        );
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('expense-total'))).data,
          'INR 80.50',
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Remove expense 1',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('every row is validated before submitting', (tester) async {
    await withForm(tester, () async {
      await fillRow(tester, 1, '100', 'Taxi');
      await tapVisible(tester, find.text('Add Expense'));
      await tapVisible(tester, find.text('Submit Claim'));
      expect(find.text('Enter an amount greater than zero.'), findsOneWidget);
      expect(find.text('Description is required.'), findsOneWidget);
      await fillRow(tester, 2, 'NaN', 'Lunch');
      await tapVisible(tester, find.text('Submit Claim'));
      expect(find.text('Enter an amount greater than zero.'), findsOneWidget);
    });
  });

  testWidgets('one or more bills remain required for the claim', (
    tester,
  ) async {
    await withForm(tester, () async {
      await fillRow(tester, 1, '100', 'Taxi');
      await tapVisible(tester, find.text('Submit Claim'));
      expect(
        find.text('Attach a bill photo before submitting.'),
        findsOneWidget,
      );
      await attachBills(tester);
      expect(find.byTooltip('Remove bill 2'), findsOneWidget);
      await tapVisible(tester, find.byTooltip('Remove bill 1'));
      expect(find.byTooltip('Remove bill 2'), findsNothing);
      expect(find.byTooltip('Remove bill 1'), findsOneWidget);
    });
  });

  testWidgets(
    'two expenses and bills use one multipart POST and reset after success',
    (tester) async {
      final posted = Completer<http.Request>();
      var postCount = 0;
      final secondDate = DateTime.now().subtract(const Duration(days: 1));
      await withForm(
        tester,
        () async {
          await fillRow(tester, 1, '125.50', 'Taxi');
          await tapVisible(tester, find.text('Add Expense'));
          await fillRow(tester, 2, '80', 'Lunch');
          await chooseDate(tester, 2, secondDate);
          await tapVisible(
            tester,
            find.descendant(
              of: rowCard(2),
              matching: find.byType(DropdownButton<String>),
            ),
          );
          await tester.tap(find.text('Meals').last);
          await tester.pumpAndSettle();
          await attachBills(tester);
          await submitAndWait(tester, posted);
          final body = latin1.decode((await posted.future).bodyBytes);
          final rowsJson =
              RegExp(
                r'name="expenses"\r\n\r\n(.*?)\r\n--',
                dotAll: true,
              ).firstMatch(body)!.group(1)!;
          final rows = jsonDecode(rowsJson) as List;
          expect(rows.map((row) => row['description']), ['Taxi', 'Lunch']);
          expect(rows.map((row) => row['amount']), ['125.50', '80']);
          expect(rows.map((row) => row['expense_type']), ['Travel', 'Meals']);
          expect(
            rows[1]['expense_date'],
            DateFormat('yyyy-MM-dd').format(secondDate),
          );
          expect(RegExp(r'name="file"; filename=').allMatches(body).length, 2);
          expect(postCount, 1);
          expect(find.text('Expense 2'), findsNothing);
          expect(
            tester
                .widget<TextField>(rowField(1, 'Enter amount'))
                .controller!
                .text,
            isEmpty,
          );
          expect(find.byTooltip('Remove bill 1'), findsNothing);
          expect(find.text('Staff (EMP-1)'), findsOneWidget);
          expect(
            find.textContaining('HR-EXP-TEST was created'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
        onPost: (request) async {
          postCount++;
          posted.complete(request);
          return http.Response(
            jsonEncode({'message': createdResponse(2, 2)}),
            200,
          );
        },
      );
    },
  );

  testWidgets('failed submission retains rows and attachments for correction', (
    tester,
  ) async {
    final posted = Completer<void>();
    await withForm(
      tester,
      () async {
        await fillRow(tester, 1, '125.50', 'Taxi');
        await tapVisible(tester, find.text('Add Expense'));
        await fillRow(tester, 2, '80', 'Lunch');
        await attachBills(tester);
        await submitAndWait(tester, posted);
        expect(find.text('Expense 2'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(rowField(2, 'Enter expense details'))
              .controller!
              .text,
          'Lunch',
        );
        expect(find.byTooltip('Remove bill 2'), findsOneWidget);
        expect(find.text('Expense 2 is invalid'), findsOneWidget);
      },
      onPost: (request) async {
        posted.complete();
        return http.Response(
          jsonEncode({'message': 'Expense 2 is invalid'}),
          417,
        );
      },
    );
  });

  testWidgets('legacy server keeps one row and single-photo selection', (
    tester,
  ) async {
    await withForm(tester, () async {
      await tapVisible(tester, find.text('Add Expense'));
      expect(find.text('Expense 2'), findsNothing);
      await attachBills(tester);
      expect(find.byTooltip('Remove bill 1'), findsOneWidget);
      expect(find.byTooltip('Remove bill 2'), findsNothing);
      expect(find.text('Replace Photo'), findsOneWidget);
    }, multiple: false);
  });

  testWidgets('multiple expense cards fit a narrow mobile screen', (
    tester,
  ) async {
    await withForm(tester, () async {
      await fillRow(tester, 1, '100', 'Taxi');
      await tapVisible(tester, find.text('Add Expense'));
      await fillRow(tester, 2, '80', 'Lunch');
      await tapVisible(tester, find.text('Add Expense'));
      expect(find.text('Expense 3'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('expense-total')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, size: const Size(360, 800));
  });

  test(
    'legacy submitClaim sends its original fields and accepts the original response',
    () async {
      await http.runWithClient(
        () async {
          final result = await ExpenseClaimApi.submitClaim(
            employee: 'EMP-1',
            expenseApprover: 'approver@example.test',
            expenseType: 'Travel',
            amount: '125.50',
            expenseDate: '2026-10-13',
            description: 'Taxi',
            csrfToken: 'csrf',
            billPath: bills.first.path,
          );
          expect(result.name, 'HR-EXP-TEST');
        },
        () => client(
          onPost: (request) async {
            final body = latin1.decode(request.bodyBytes);
            expect(body, contains('name="expense_type"\r\n\r\nTravel'));
            expect(body, isNot(contains('name="expenses"')));
            expect(
              RegExp(r'name="file"; filename=').allMatches(body).length,
              1,
            );
            return http.Response(
              jsonEncode({
                'message': {
                  'name': 'HR-EXP-TEST',
                  'expense_row': 'EXP-1',
                  'bill_file_url': '/private/files/bill.png',
                },
              }),
              200,
            );
          },
        ),
      );
    },
  );

  test('multiple rows cannot silently fall back to a legacy server', () async {
    await expectLater(
      ExpenseClaimApi.submitExpenses(
        employee: 'EMP-1',
        expenseApprover: 'approver@example.test',
        expenses: List.generate(
          2,
          (_) => const ExpenseClaimLine(
            expenseType: 'Travel',
            amount: '100',
            expenseDate: '2026-10-13',
            description: 'Taxi',
          ),
        ),
        csrfToken: 'csrf',
        billPaths: [bills.first.path],
      ),
      throwsStateError,
    );
  });

  test(
    'a partial server confirmation requires checking the saved claim',
    () async {
      await http.runWithClient(
        () async {
          await expectLater(
            ExpenseClaimApi.submitExpenses(
              employee: 'EMP-1',
              expenseApprover: 'approver@example.test',
              expenses: List.generate(
                2,
                (_) => const ExpenseClaimLine(
                  expenseType: 'Travel',
                  amount: '100',
                  expenseDate: '2026-10-13',
                  description: 'Taxi',
                ),
              ),
              csrfToken: 'csrf',
              billPaths: [bills.first.path],
              supportsMultipleExpenses: true,
            ),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                contains('Check this claim before retrying'),
              ),
            ),
          );
        },
        () => client(
          onPost:
              (request) async => http.Response(
                jsonEncode({'message': createdResponse(1, 1)}),
                200,
              ),
        ),
      );
    },
  );
}
