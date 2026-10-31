import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/leave_application_webview_page.dart';

void main() {
  test('leave bridge is restricted to the exact configured HTTPS ERP page', () {
    final page = Uri.parse('https://erp.example.test/genie-leave-application');
    for (final url in [
      page.toString(),
      '${page.toString()}/',
      '${page.toString()}?v=1',
    ]) {
      expect(isLeaveApplicationWebPageLocation(page, url), isTrue);
    }
    for (final url in [
      'http://erp.example.test/genie-leave-application',
      'https://outside.test/genie-leave-application',
      'https://erp.example.test.outside.test/genie-leave-application',
      'https://erp.example.test/genie-opportunities',
      'https://erp.example.test/app',
      'https://user@erp.example.test/genie-leave-application',
      'https://erp.example.test:444/genie-leave-application',
      'javascript:alert(1)',
      'about:blank',
    ]) {
      expect(
        isLeaveApplicationWebPageLocation(page, url),
        isFalse,
        reason: url,
      );
    }
  });

  testWidgets(
    'invalid leave ERP route fails safely and Back returns to its existing caller',
    (tester) async {
      dotenv.testLoad(fileInput: 'SITE_URL=http://erp.example.test');
      var backs = 0;
      var notifications = 0;
      final key = GlobalKey<LeaveApplicationWebViewPageState>();
      await tester.pumpWidget(
        MaterialApp(
          home: LeaveApplicationWebViewPage(
            key: key,
            onBack: () => backs++,
            onNotifications: () => notifications++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The ERP site URL is not configured.'), findsOneWidget);
      await key.currentState!.handleBack();
      expect(backs, 1);
      expect(notifications, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
