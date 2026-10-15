import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/notifications_page.dart';
import 'package:homegenie/utils/api/notification_inbox.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'staff@example.test';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': user,
    });
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });
  RemoteMessage push(String id, String type, {String? recipient}) =>
      RemoteMessage(
        messageId: id,
        sentTime: DateTime(2026, 10, 15, 12),
        data: {
          'type': type,
          'title': '$type assigned',
          'body': 'New work',
          if (recipient != null) 'for_user': recipient,
        },
      );
  List<Map<String, dynamic>> logs() => [
    for (final type in ['Task', 'Lead', 'Event', 'Stock Entry'])
      {
        'name': 'LOG-$type',
        'subject': '<b>$type assigned</b>',
        'email_content': '<p>New $type details</p>',
        'for_user': user,
        'document_type': type,
        'document_name': '$type-1',
        'read': 0,
        'creation': '2026-10-15 13:00:00',
      },
  ];
  MockClient client({
    int status = 200,
    List<Map<String, dynamic>>? rows,
    Future<void> Function()? duringLoad,
  }) => MockClient((request) async {
    expect(request.headers['Cookie'], 'sid=sid');
    if (request.url.path.endsWith('get_logged_user')) {
      return http.Response(jsonEncode({'message': user}), 200);
    }
    expect(request.url.path, '/api/resource/Notification%20Log');
    expect(request.followRedirects, isFalse);
    expect(jsonDecode(request.url.queryParameters['filters']!), [
      ['for_user', '=', user],
    ]);
    expect(request.url.queryParameters['limit_page_length'], '100');
    if (duringLoad != null) await duringLoad();
    return http.Response(jsonEncode({'data': rows ?? logs()}), status);
  });

  test(
    'notifications are recipient scoped, categorized and stripped of HTML',
    () async {
      await http.runWithClient(
        () async {
          final items = await NotificationInbox.load();
          expect(items.map((item) => item.category).toSet(), {
            'Tasks',
            'Leads',
            'Visits',
            'Pending Work',
          });
          expect(items.first.title, isNot(contains('<b>')));
          expect(items.first.body, contains('details'));
          expect(items.first.reference, isNotEmpty);
        },
        () => client(
          rows: [
            ...logs(),
            {
              'name': 'OTHER',
              'for_user': 'other@example.test',
              'subject': 'Private',
            },
          ],
        ),
      );
    },
  );

  test(
    'pushes are retained once and isolated across accounts and sites',
    () async {
      await NotificationInbox.capture(push('one', 'TASK_ASSIGNED'));
      await NotificationInbox.capture(push('one', 'TASK_ASSIGNED'));
      await NotificationInbox.capture(
        push('other', 'LEAD_ASSIGNED', recipient: 'other@example.test'),
      );
      expect(await NotificationInbox.cached(), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_username', 'other@example.test');
      expect(await NotificationInbox.cached(), isEmpty);
      await prefs.setString('session_username', user);
      dotenv.testLoad(fileInput: 'SITE_URL=https://other.example.test');
      expect(await NotificationInbox.cached(), isEmpty);
    },
  );

  test('signed out pushes cannot be attached to a later login', () async {
    SharedPreferences.setMockInitialValues({});
    await NotificationInbox.capture(push('one', 'TASK_ASSIGNED'));
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': user,
    });
    expect(await NotificationInbox.cached(), isEmpty);
  });

  test(
    'ERP and push events sharing a notification log ID are merged',
    () async {
      await NotificationInbox.capture(
        RemoteMessage(
          messageId: 'push',
          data: {'notification_log': 'LOG-Task', 'title': 'Task push'},
        ),
      );
      await http.runWithClient(() async {
        final items = await NotificationInbox.load();
        expect(items, hasLength(4));
        expect(items.where((row) => row.id == 'LOG-Task'), hasLength(1));
      }, () => client());
    },
  );

  test(
    'history errors do not erase previously received push notifications',
    () async {
      await NotificationInbox.capture(push('one', 'VISIT_ASSIGNED'));
      await http.runWithClient(() async {
        await expectLater(NotificationInbox.load(), throwsStateError);
        expect(await NotificationInbox.cached(), hasLength(1));
      }, () => client(status: 403));
    },
  );

  test('changing account during loading rejects the response', () async {
    await http.runWithClient(
      () async {
        await expectLater(NotificationInbox.load(), throwsStateError);
      },
      () => client(
        duringLoad: () async {
          await (await SharedPreferences.getInstance()).setString(
            'session_username',
            'other@example.test',
          );
        },
      ),
    );
  });

  testWidgets(
    'notification page shows all items without filters, expands details, and refreshes',
    (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
        await tester.pumpAndSettle();
        expect(find.text('Notifications'), findsOneWidget);
        expect(find.text('Task assigned'), findsOneWidget);
        expect(find.text('Lead assigned'), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.text('Event assigned'), findsOneWidget);
        expect(find.text('Stock Entry assigned'), findsOneWidget);
        await tester.tap(find.text('Task assigned'));
        await tester.pumpAndSettle();
        expect(find.text('New Task details'), findsOneWidget);
        await tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await tester.pumpAndSettle();
        expect(find.text('Task assigned'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client());
    },
  );

  testWidgets(
    'notification API failure shows an error and permits swipe retry',
    (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
        await tester.pumpAndSettle();
        expect(find.text('Could not load notifications'), findsOneWidget);
        expect(find.byType(RefreshIndicator), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client(status: 500));
    },
  );
}
