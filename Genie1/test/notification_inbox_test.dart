import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/notifications_page.dart';
import 'package:homegenie/utils/api/notification_inbox.dart';
import 'package:homegenie/utils/widget/notification_bell.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'staff@example.test';
Future<void> settleInbox(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': user,
    });
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });
  tearDown(() async {
    // Finish disposal writes before resetting preferences for the next test.
    await NotificationInbox.cached();
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
    'supplied lead-call payload has a meaningful inbox title and body',
    () async {
      await NotificationInbox.capture(
        const RemoteMessage(
          messageId: 'lead-call-1',
          data: {
            'type': 'NEW_LEAD_CALL',
            'doctype': 'Lead',
            'docname': 'LEAD-1',
            'customer_name': 'Customer',
            'mobile_no': '9876543210',
            'auto_call': '1',
          },
        ),
      );
      final items = await NotificationInbox.cached();
      expect(items.single.title, 'New lead assigned');
      expect(items.single.body, contains('Customer'));
      expect(items.single.reference, 'LEAD-1');
    },
  );

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

  test(
    'viewed notifications do not return from ERP or duplicate push delivery',
    () async {
      await http.runWithClient(() async {
        final rows = await NotificationInbox.load();
        final scope = (await NotificationInbox.sessionScope())!;
        await NotificationInbox.dismissViewed(
          rows.map((row) => row.id).toSet(),
          scope: scope,
        );
        expect(await NotificationInbox.cached(), isEmpty);
        expect(await NotificationInbox.load(), isEmpty);
        await NotificationInbox.capture(
          const RemoteMessage(
            data: {'notification_log': 'LOG-Task', 'title': 'Task assigned'},
          ),
        );
        expect(await NotificationInbox.cached(), isEmpty);
      }, () => client());
    },
  );

  test(
    'clearing viewed IDs preserves a notification arriving after the snapshot',
    () async {
      await NotificationInbox.capture(push('seen', 'TASK_ASSIGNED'));
      final rows = await NotificationInbox.cached();
      final scope = (await NotificationInbox.sessionScope())!;
      await NotificationInbox.capture(push('new', 'VISIT_ASSIGNED'));
      await NotificationInbox.dismissViewed(
        rows.map((row) => row.id).toSet(),
        scope: scope,
      );
      expect((await NotificationInbox.cached()).single.id, 'push:new');
    },
  );

  test(
    'an in-flight ERP response cannot restore dismissed items or lose new pushes',
    () async {
      await http.runWithClient(() async {
        await NotificationInbox.load();
        final scope = (await NotificationInbox.sessionScope())!;
        final rows = await NotificationInbox.cached();
        await http.runWithClient(
          () async {
            final items = await NotificationInbox.load();
            expect(items.map((row) => row.id), ['push:new']);
          },
          () => client(
            duringLoad: () async {
              await NotificationInbox.dismissViewed(
                rows.map((row) => row.id).toSet(),
                scope: scope,
              );
              await NotificationInbox.capture(push('new', 'VISIT_ASSIGNED'));
            },
          ),
        );
      }, () => client());
    },
  );

  test('old screen cleanup cannot clear another account or site', () async {
    await NotificationInbox.capture(push('same-id', 'TASK_ASSIGNED'));
    final scope = (await NotificationInbox.sessionScope())!;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_username', 'other@example.test');
    await NotificationInbox.capture(push('same-id', 'TASK_ASSIGNED'));
    await NotificationInbox.dismissViewed({'push:same-id'}, scope: scope);
    expect(await NotificationInbox.cached(), hasLength(1));
    await prefs.setString('session_username', user);
    dotenv.testLoad(fileInput: 'SITE_URL=https://other.example.test');
    await NotificationInbox.capture(push('same-id', 'TASK_ASSIGNED'));
    await NotificationInbox.dismissViewed({'push:same-id'}, scope: scope);
    expect(await NotificationInbox.cached(), hasLength(1));
  });

  test('ERP notifications already read are excluded', () async {
    await http.runWithClient(
      () async {
        final rows = await NotificationInbox.load();
        expect(rows.any((row) => row.id == 'LOG-Task'), isFalse);
      },
      () => client(
        rows:
            logs()
                .map(
                  (row) => {...row, if (row['name'] == 'LOG-Task') 'read': 1},
                )
                .toList(),
      ),
    );
  });

  testWidgets(
    'leaving notifications clears the viewed inbox and the bell dot; a new push restores it',
    (tester) async {
      await http.runWithClient(() async {
        await tester.runAsync(() => NotificationInbox.load());
        expect(
          await tester.runAsync(() => NotificationInbox.cached()),
          hasLength(4),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder:
                  (context) => Scaffold(
                    body: NotificationBell(
                      onPressed:
                          () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => const NotificationsPage(),
                            ),
                          ),
                    ),
                  ),
            ),
          ),
        );
        await settleInbox(tester);
        expect(
          find.byKey(const ValueKey('notification-unread-dot')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Notifications'));
        await settleInbox(tester);
        expect(find.text('Task assigned'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await settleInbox(tester);
        expect(
          await tester.runAsync(() => NotificationInbox.cached()),
          isEmpty,
        );
        expect(
          find.byKey(const ValueKey('notification-unread-dot')),
          findsNothing,
        );
        final capture = NotificationInbox.capture(
          push('fresh', 'TASK_ASSIGNED'),
        );
        await settleInbox(tester);
        await capture;
        await settleInbox(tester);
        expect(
          find.byKey(const ValueKey('notification-unread-dot')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client());
    },
  );

  testWidgets('empty inbox has no bell dot', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: NotificationBell(onPressed: () {}))),
      );
      await settleInbox(tester);
      expect(
        find.byKey(const ValueKey('notification-unread-dot')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client(rows: []));
  });

  testWidgets(
    'a push displayed on the open screen is cleared on exit without refetching ERP',
    (tester) async {
      var historyRequests = 0;
      final server = client(rows: []);
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
          await settleInbox(tester);
          final capture = NotificationInbox.capture(
            push('on-screen', 'VISIT_ASSIGNED'),
          );
          await settleInbox(tester);
          await capture;
          await settleInbox(tester);
          expect(find.text('VISIT_ASSIGNED assigned'), findsOneWidget);
          expect(historyRequests, 1);
          await tester.pumpWidget(const SizedBox.shrink());
          await settleInbox(tester);
          expect(await NotificationInbox.cached(), isEmpty);
        },
        () => MockClient((request) async {
          if (request.url.path.contains('Notification')) historyRequests++;
          return server.get(request.url, headers: request.headers);
        }),
      );
    },
  );

  testWidgets(
    'notification page shows all items without filters, expands details, and refreshes',
    (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
        await settleInbox(tester);
        expect(find.text('Notifications'), findsOneWidget);
        expect(find.text('Task assigned'), findsOneWidget);
        expect(find.text('Lead assigned'), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.text('Event assigned'), findsOneWidget);
        expect(find.text('Stock Entry assigned'), findsOneWidget);
        await tester.tap(find.text('Task assigned'));
        await settleInbox(tester);
        expect(find.text('New Task details'), findsOneWidget);
        await tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await settleInbox(tester);
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
        await settleInbox(tester);
        expect(find.text('Could not load notifications'), findsOneWidget);
        expect(find.byType(RefreshIndicator), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client(status: 500));
    },
  );
}
