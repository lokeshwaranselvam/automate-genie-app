import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/sales_summary_webview_page.dart';
import 'package:homegenie/utils/api/notification_inbox.dart';
import 'package:homegenie/utils/api/sales_summary_notification.dart';

void main() {
  test('existing collection payload uses the fixed sales summary route', () {
    final data = <String, dynamic>{
      'type': 'DOCUMENT_NOTIFICATION',
      'notification_name': 'TOMORROW-COLLECTION',
      'doctype': 'User',
      'docname': 'staff@example.test',
      'link': 'https://outside.test',
    };
    expect(isSalesSummaryPush(data), isTrue);
    expect(isSalesSummaryPush({...data, 'doctype': '', 'docname': ''}), isTrue);
    expect(isSalesSummaryPush({...data, 'type': 'OTHER'}), isFalse);
    expect(
      isSalesSummaryPush({...data, 'notification_name': 'CHECKOUT-REMINDER'}),
      isFalse,
    );
  });

  test('old collection cache is recognized without linking User reminders', () {
    final old = <String, dynamic>{
      'id': 'push:old',
      'title': 'Tomorrow Collection',
      'body': 'TOMORROW COLLECTION\n\nGood morning!',
      'doctype': 'User',
      'reference': 'staff@example.test',
    };
    final collection = InboxNotification.fromJson(old);
    expect(collection.isSalesSummary, isTrue);
    expect(collection.hasErpDocumentLink, isFalse);
    expect(
      InboxNotification.fromJson(collection.toJson()).isSalesSummary,
      isTrue,
    );
    final reminder = InboxNotification.fromJson({
      ...old,
      'title': 'TEST: Check-out Reminder',
      'body': 'Check out today.',
    });
    expect(reminder.isSalesSummary, isFalse);
    expect(reminder.hasErpDocumentLink, isFalse);
    expect(
      InboxNotification.fromJson({
        ...old,
        'title': 'Task assigned',
        'doctype': 'Task',
        'reference': 'TASK-1',
      }).hasErpDocumentLink,
      isTrue,
    );
    expect(
      InboxNotification.fromJson({
        ...old,
        'doctype': '',
        'reference': '',
        'title': 'Information',
      }).hasErpDocumentLink,
      isFalse,
    );
  });

  test('summary route accepts only the exact internal page', () {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    final page = salesSummaryPageUri()!;
    expect(page.toString(), 'https://erp.example.test/genie-sales-summary');
    for (final url in ['$page', '$page/', '$page?x=1']) {
      expect(isSalesSummaryWebLocation(page, url), isTrue);
    }
    for (final url in [
      'http://erp.example.test/genie-sales-summary',
      'https://outside.test/genie-sales-summary',
      'https://user@erp.example.test/genie-sales-summary',
      'https://erp.example.test/app',
      'https://erp.example.test:444/genie-sales-summary',
    ]) {
      expect(isSalesSummaryWebLocation(page, url), isFalse);
    }
    for (final route in [
      'https://outside.test/genie-sales-summary',
      '//outside.test',
      '/app',
      '/genie-sales-summary?user=someone',
      'javascript:alert(1)',
    ]) {
      expect(salesSummaryPageRoute(route), isEmpty);
    }
  });
  test(
    'only the dedicated summary subtype gets a stable reminder identity',
    () {
      final data = <String, dynamic>{
        'type': 'DOCUMENT_NOTIFICATION',
        'notification_kind': 'SALES_SUMMARY',
        'doctype': 'Notification Log',
        'docname': 'sales-summary-123',
        'notification_log': 'sales-summary-123',
        'page_route': salesSummaryRoute,
      };
      expect(isSalesSummaryPush(data), isTrue);
      for (final changes in [
        {'doctype': 'Lead'},
        {'notification_log': 'other'},
        {'page_route': 'https://outside.test'},
        {'notification_kind': 'OTHER'},
      ]) {
        expect(isSalesSummaryPush({...data, ...changes}), isFalse);
      }
    },
  );
  test(
    'summary routes survive cache reload while arbitrary links are dropped',
    () {
      const row = InboxNotification(
        id: 'one',
        title: 'Summary',
        body: '',
        created: '',
        category: 'Other',
        pageRoute: salesSummaryRoute,
      );
      expect(InboxNotification.fromJson(row.toJson()).isSalesSummary, isTrue);
      expect(
        InboxNotification.fromJson({
          ...row.toJson(),
          'page_route': 'https://outside.test',
        }).isSalesSummary,
        isFalse,
      );
      expect(InboxNotification.fromJson({'id': 'old'}).isSalesSummary, isFalse);
    },
  );
  testWidgets('invalid ERP config offers Retry without creating a WebView', (
    tester,
  ) async {
    dotenv.testLoad(fileInput: 'SITE_URL=http://erp.example.test');
    await tester.pumpWidget(const MaterialApp(home: SalesSummaryWebViewPage()));
    await tester.pumpAndSettle();
    expect(find.text('Configure a valid HTTPS ERP site.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
