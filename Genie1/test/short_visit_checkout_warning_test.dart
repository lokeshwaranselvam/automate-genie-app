import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/session_webview.dart';
import 'package:homegenie/utils/short_visit_checkout_notice.dart';
import 'package:homegenie/utils/widget/warning.dart';
import 'package:shared_preferences/shared_preferences.dart';

const serverMessage =
    '<b>Checkout Restricted</b><br><br>'
    'You have <b>3 pending short visit reason(s)</b> for today.<br><br>'
    'Please submit all pending reasons before checking out.<br><br>'
    '<a href="https://erp.itgenie.online/SVR" target="_blank">'
    '<b>Review Pending Short Visits &#8599;</b></a>';

Future<void> showWarning(
  WidgetTester tester,
  String message, {
  VoidCallback? onAction,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed:
                  () => Warning.show(
                    context,
                    message,
                    'Warning',
                    actionLabel: onAction == null ? null : 'Retry',
                    onAction: onAction,
                  ),
              child: const Text('Show warning'),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('Show warning'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test/');
  });

  test('only pending short visit checkout restrictions are recognized', () {
    final notice = ShortVisitCheckoutNotice.fromMessage(serverMessage)!;
    expect(notice.pendingCount, 3);
    expect(notice.message, contains('3 pending short visit reasons for today'));
    expect(notice.message, isNot(contains('<')));
    expect(notice.message, isNot(contains('erp.itgenie.online')));
    expect(
      ShortVisitCheckoutNotice.fromMessage('Checkout Restricted: active event'),
      isNull,
    );
    expect(
      ShortVisitCheckoutNotice.fromMessage('3 pending short visits loaded'),
      isNull,
    );
  });

  test('singular and missing counts produce clear messages', () {
    expect(
      ShortVisitCheckoutNotice.fromMessage(
        'Checkout Restricted: 1 pending short visit reason',
      )!.message,
      contains('1 pending short visit reason for today'),
    );
    expect(
      ShortVisitCheckoutNotice.fromMessage(
        'Checkout Restricted: pending short visit reasons',
      )!.message,
      startsWith('You have pending short visit reasons for today.'),
    );
  });

  testWidgets('restriction popup is readable and opens the exact SVR WebView', (
    tester,
  ) async {
    await showWarning(tester, serverMessage);
    expect(find.text('Checkout restricted'), findsOneWidget);
    expect(
      find.textContaining('3 pending short visit reasons'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Return to Attendance and check out again'),
      findsOneWidget,
    );
    expect(find.text(serverMessage), findsNothing);
    expect(find.text(ShortVisitCheckoutNotice.url), findsNothing);
    expect(find.text('SVR'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('SVR'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final webview = tester.widget<SessionWebView>(find.byType(SessionWebView));
    expect(webview.url, 'https://erp.example.test/SVR');
    expect(webview.title, 'SVR');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Show warning'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OK dismisses the restriction without navigating', (
    tester,
  ) async {
    await showWarning(tester, serverMessage);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SessionWebView), findsNothing);
  });

  testWidgets('unrelated warning and existing custom action are preserved', (
    tester,
  ) async {
    var retried = false;
    await showWarning(
      tester,
      'Location permission denied.',
      onAction: () => retried = true,
    );
    expect(find.text('Warning'), findsOneWidget);
    expect(find.text('Location permission denied.'), findsOneWidget);
    expect(find.text(ShortVisitCheckoutNotice.url), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retried, isTrue);
    expect(find.byType(Dialog), findsNothing);
  });
}
