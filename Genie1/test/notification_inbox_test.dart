import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/notifications_page.dart';
import 'package:homegenie/Screen/session_webview.dart';
import 'package:homegenie/Screen/sales_summary_webview_page.dart';
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
  Future<void> seedPushes() async {
    for (final row in logs()) {
      await NotificationInbox.capture(
        RemoteMessage(
          messageId: row['name'] as String,
          data: {
            'notification_log': row['name'],
            'title': row['subject'],
            'body': row['email_content'],
            'for_user': row['for_user'],
            'doctype': row['document_type'],
            'docname': row['document_name'],
          },
        ),
      );
    }
  }

  MockClient client({int status = 200, String sid = 'sid'}) =>
      MockClient((request) async {
        expect(request.headers['Cookie'], 'sid=$sid');
        // Inbox refresh must never fetch ERP Notification Log/history.
        expect(request.url.path, '/api/method/frappe.auth.get_logged_user');
        return http.Response(
          jsonEncode({'message': status == 200 ? user : 'Denied'}),
          status,
        );
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
    'push notifications are recipient scoped, categorized and stripped of HTML',
    () async {
      await seedPushes();
      await NotificationInbox.capture(
        push('other', 'LEAD_ASSIGNED', recipient: 'other@example.test'),
      );
      await http.runWithClient(() async {
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
      }, () => client());
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
    'pushes with an ERP log ID remain visible once without loading ERP history',
    () async {
      const message = RemoteMessage(
        messageId: 'push',
        data: {'notification_log': 'LOG-Task', 'title': 'Task push'},
      );
      await NotificationInbox.capture(message);
      await NotificationInbox.capture(message);
      await http.runWithClient(() async {
        final items = await NotificationInbox.load();
        expect(items, hasLength(1));
        expect(items.single.id, 'LOG-Task');
        expect(items.single.title, 'Task push');
        expect(items.single.receivedViaPush, isTrue);
      }, () => client());
    },
  );

  test(
    'refresh uses the local push inbox without requesting ERP notification history',
    () async {
      await NotificationInbox.capture(push('one', 'VISIT_ASSIGNED'));
      await http.runWithClient(() async {
        expect((await NotificationInbox.load()).single.id, 'push:one');
      }, () => client());
    },
  );

  test(
    'a session switch during refresh cannot return another account inbox',
    () async {
      await NotificationInbox.capture(push('one', 'TASK_ASSIGNED'));
      await http.runWithClient(
        () async {
          await expectLater(NotificationInbox.load(), throwsStateError);
        },
        () => MockClient((request) async {
          await (await SharedPreferences.getInstance()).setString(
            'session_sid',
            'different-sid',
          );
          return http.Response(jsonEncode({'message': user}), 200);
        }),
      );
    },
  );

  test(
    'viewed notifications do not return from ERP or duplicate push delivery',
    () async {
      await seedPushes();
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
    'refresh does not restore dismissed pushes or lose new arrivals',
    () async {
      await NotificationInbox.capture(push('old', 'TASK_ASSIGNED'));
      final scope = (await NotificationInbox.sessionScope())!;
      await NotificationInbox.dismissViewed({'push:old'}, scope: scope);
      await NotificationInbox.capture(push('new', 'VISIT_ASSIGNED'));
      await http.runWithClient(() async {
        expect((await NotificationInbox.load()).map((row) => row.id), [
          'push:new',
        ]);
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

  test(
    'legacy ERP-only cache entries are hidden from the page and bell',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final key =
          'notification_inbox_${base64UrlEncode(utf8.encode('https://erp.example.test|$user'))}';
      await prefs.setString(
        key,
        jsonEncode([
          {'id': 'LOG-ERP-ONLY', 'title': 'ERP only', 'read': false},
          {'id': 'LOG-OLD-MERGE', 'title': 'Old imported row', 'read': true},
        ]),
      );
      expect(await NotificationInbox.cached(), isEmpty);
      expect(await NotificationInbox.hasUnseen(), isFalse);
      await http.runWithClient(() async {
        expect(await NotificationInbox.load(), isEmpty);
      }, () => client());
      // A real push sharing that log ID must now be accepted, rather than
      // discarded because its ERP-only copy was previously cached.
      await NotificationInbox.capture(
        const RemoteMessage(
          messageId: 'real',
          data: {'notification_log': 'LOG-ERP-ONLY', 'title': 'Actual push'},
        ),
      );
      expect((await NotificationInbox.cached()).single.title, 'Actual push');
      expect(await NotificationInbox.hasUnseen(), isTrue);
    },
  );

  test('legacy push IDs and marked log-ID pushes survive cache reload', () async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'notification_inbox_${base64UrlEncode(utf8.encode('https://erp.example.test|$user'))}';
    await prefs.setString(
      key,
      jsonEncode([
        {'id': 'push:legacy', 'title': 'Legacy push'},
        {'id': 'LOG-PUSH', 'title': 'Marked push', 'received_via_push': true},
        {'id': 'LOG-ERP', 'title': 'ERP only'},
      ]),
    );
    expect((await NotificationInbox.cached()).map((row) => row.id), [
      'push:legacy',
      'LOG-PUSH',
    ]);
  });

  testWidgets(
    'leaving notifications retains items; only the header trash clears them',
    (tester) async {
      await tester.runAsync(seedPushes);
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
          hasLength(4),
        );
        expect(
          find.byKey(const ValueKey('notification-unread-dot')),
          findsNothing,
        );
        await tester.tap(find.byTooltip('Notifications'));
        await settleInbox(tester);
        expect(find.text('Task assigned'), findsOneWidget);
        await tester.tap(find.byTooltip('Clear notifications'));
        await settleInbox(tester);
        expect(find.text('No notifications yet'), findsOneWidget);
        await tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await settleInbox(tester);
        expect(find.text('No notifications yet'), findsOneWidget);
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

  test(
    'seen state retains messages, survives reload, and isolates sessions',
    () async {
      await NotificationInbox.capture(push('seen', 'TASK_ASSIGNED'));
      final scope = (await NotificationInbox.sessionScope())!;
      expect(await NotificationInbox.hasUnseen(), isTrue);
      await NotificationInbox.markSeen({'push:seen'}, scope: scope);
      expect(await NotificationInbox.hasUnseen(), isFalse);
      expect(await NotificationInbox.cached(), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(await NotificationInbox.hasUnseen(), isFalse);
      await NotificationInbox.capture(push('new', 'TASK_ASSIGNED'));
      expect(await NotificationInbox.hasUnseen(), isTrue);
      await prefs.setString('session_username', 'other@example.test');
      await NotificationInbox.capture(push('new', 'TASK_ASSIGNED'));
      await NotificationInbox.markSeen({'push:new'}, scope: scope);
      expect(await NotificationInbox.hasUnseen(), isTrue);
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
    }, () => client());
  });

  testWidgets(
    'a push displayed on the open screen remains on exit without refetching ERP',
    (tester) async {
      var historyRequests = 0;
      final server = client();
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
          expect(historyRequests, 0);
          await tester.pumpWidget(const SizedBox.shrink());
          await settleInbox(tester);
          expect(await NotificationInbox.cached(), hasLength(1));
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
      await tester.runAsync(seedPushes);
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

  testWidgets('ERP opens only after choosing the inbox item action', (
    tester,
  ) async {
    await tester.runAsync(seedPushes);
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
        await settleInbox(tester);
        expect(find.byType(SessionWebView), findsNothing);
        await tester.tap(find.text('Task assigned'));
        await settleInbox(tester);
        expect(find.byType(SessionWebView), findsNothing);
        await tester.tap(find.text('Open in ERP').first);
        await settleInbox(tester);
        final web = tester.widget<SessionWebView>(find.byType(SessionWebView));
        final uri = Uri.parse(web.url);
        expect(uri.origin, 'https://erp.example.test');
        expect(uri.pathSegments, ['app', 'task', 'Task-1']);
        expect(web.blockSystemBack, isFalse);
        await tester.binding.handlePopRoute();
        await settleInbox(tester);
        expect(find.byType(NotificationsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      () => MockClient(
        (request) async =>
            request.url.path.endsWith('get_logged_user')
                ? http.Response(jsonEncode({'message': user}), 200)
                : http.Response(jsonEncode({'data': logs()}), 200),
      ),
    );
  });

  testWidgets(
    'inbox document action refuses navigation after account switching',
    (tester) async {
      await tester.runAsync(seedPushes);
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
          await settleInbox(tester);
          await tester.tap(find.text('Task assigned'));
          await settleInbox(tester);
          await (await SharedPreferences.getInstance()).setString(
            'session_username',
            'another@example.test',
          );
          await tester.tap(find.text('Open in ERP').first);
          await settleInbox(tester);
          expect(find.byType(SessionWebView), findsNothing);
          expect(
            find.text('Your session changed. Reopen Notifications.'),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient(
          (request) async =>
              request.url.path.endsWith('get_logged_user')
                  ? http.Response(jsonEncode({'message': user}), 200)
                  : http.Response(jsonEncode({'data': logs()}), 200),
        ),
      );
    },
  );

  test('push inbox retains the captured lead call action', () async {
    await NotificationInbox.capture(
      const RemoteMessage(
        messageId: 'lead',
        data: {
          'type': 'NEW_LEAD_CALL',
          'doctype': 'Lead',
          'docname': 'Lead-1',
          'for_user': user,
          'mobile_no': '9876543210',
          'notification_log': 'LOG-Lead',
        },
      ),
    );
    await http.runWithClient(() async {
      final rows = await NotificationInbox.load();
      final lead = rows.singleWhere((row) => row.id == 'LOG-Lead');
      expect(lead.callPhone, '9876543210');
      expect(lead.doctype, 'Lead');
    }, () => client());
  });

  testWidgets('session check failure shows an error and permits swipe retry', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
      await settleInbox(tester);
      expect(find.text('Could not load notifications'), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client(status: 401));
  });

  testWidgets('sales-summary push opens only through the inbox action', (
    tester,
  ) async {
    await tester.runAsync(
      () => NotificationInbox.capture(
        const RemoteMessage(
          messageId: 'summary',
          data: {
            'type': 'DOCUMENT_NOTIFICATION',
            'notification_kind': 'SALES_SUMMARY',
            'doctype': 'Notification Log',
            'docname': 'sales-summary-123',
            'notification_log': 'sales-summary-123',
            'for_user': user,
            'title': 'Your sales summary is ready',
            'body': 'View your counts.',
            'page_route': '/genie-sales-summary',
          },
        ),
      ),
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
      await settleInbox(tester);
      expect((await NotificationInbox.cached()).single.isSalesSummary, isTrue);
      expect(find.byType(SalesSummaryWebViewPage), findsNothing);
      await tester.tap(find.text('Your sales summary is ready'));
      await settleInbox(tester);
      expect(find.text('View sales summary'), findsOneWidget);
      expect(find.text('Open in ERP'), findsNothing);
      await tester.tap(find.text('View sales summary'));
      await settleInbox(tester);
      expect(find.byType(SalesSummaryWebViewPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleInbox(tester);
    }, () => client());
  });

  test(
    'collection payload retains routing after reload and rejects another recipient',
    () async {
      for (final recipient in ['another@example.test', user]) {
        await NotificationInbox.capture(
          RemoteMessage(
            messageId: recipient,
            data: {
              'type': 'DOCUMENT_NOTIFICATION',
              'notification_name': 'TOMORROW-COLLECTION',
              'doctype': 'User',
              'docname': recipient,
              'for_user': recipient,
              'title': 'Tomorrow Collection',
              'body': 'Your collection details.',
            },
          ),
        );
      }
      final item = (await NotificationInbox.cached()).single;
      expect(item.notificationName, 'TOMORROW-COLLECTION');
      expect(item.isSalesSummary, isTrue);
      expect(item.hasErpDocumentLink, isFalse);
      expect(InboxNotification.fromJson(item.toJson()).isSalesSummary, isTrue);
    },
  );

  testWidgets(
    'User reminders have no ERP action but collection retains its action',
    (tester) async {
      await tester.runAsync(() async {
        for (final name in ['CHECKOUT-REMINDER', 'TOMORROW-COLLECTION']) {
          await NotificationInbox.capture(
            RemoteMessage(
              messageId: name,
              data: {
                'type': 'DOCUMENT_NOTIFICATION',
                'notification_name': name,
                'doctype': 'User',
                'docname': user,
                'for_user': user,
                'title': name,
                'body': 'Notification details.',
              },
            ),
          );
        }
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
        await settleInbox(tester);
        await tester.tap(find.text('CHECKOUT-REMINDER'));
        await settleInbox(tester);
        expect(find.text('Open in ERP'), findsNothing);
        expect(find.text('View sales summary'), findsNothing);
        await tester.tap(find.text('TOMORROW-COLLECTION'));
        await settleInbox(tester);
        expect(find.text('View sales summary'), findsOneWidget);
        expect(find.text('Open in ERP'), findsNothing);
        await tester.tap(find.text('View sales summary'));
        await settleInbox(tester);
        expect(find.byType(SalesSummaryWebViewPage), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await settleInbox(tester);
      }, () => client());
    },
  );

  test(
    'cleared log-linked and ordinary pushes stay cleared after logout and login',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', 'old-token');
      await prefs.setString('email', user);
      await prefs.setBool('is_employee_checked_in', true);
      await seedPushes();
      await http.runWithClient(() async {
        await NotificationInbox.load();
        await NotificationInbox.capture(push('cleared-push', 'TASK_ASSIGNED'));
        final scope = (await NotificationInbox.sessionScope())!;
        final ids =
            (await NotificationInbox.cached()).map((item) => item.id).toSet();
        expect(ids, contains('LOG-Task'));
        expect(ids, contains('push:cleared-push'));
        await NotificationInbox.dismissViewed(ids, scope: scope);
      }, () => client());

      await NotificationInbox.clearPreferencesPreservingDismissals(prefs);
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('session_sid'), isNull);
      expect(prefs.getString('session_username'), isNull);
      expect(prefs.getString('email'), isNull);
      expect(prefs.getBool('is_employee_checked_in'), isNull);
      expect(prefs.getKeys(), hasLength(1));
      expect(prefs.getKeys().single, endsWith('_viewed'));

      await prefs.setString('session_username', user);
      await prefs.setString('session_sid', 'new-sid');
      await http.runWithClient(() async {
        expect(await NotificationInbox.load(), isEmpty);
        await NotificationInbox.capture(push('cleared-push', 'TASK_ASSIGNED'));
        expect(await NotificationInbox.cached(), isEmpty);
        await NotificationInbox.capture(push('new-push', 'TASK_ASSIGNED'));
        expect((await NotificationInbox.cached()).single.id, 'push:new-push');
        expect(await NotificationInbox.hasUnseen(), isTrue);
      }, () => client(sid: 'new-sid'));
    },
  );

  test(
    'logout preserves only dismissal IDs and keeps accounts and sites isolated',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await NotificationInbox.capture(push('same-id', 'TASK_ASSIGNED'));
      await NotificationInbox.dismissViewed({
        'push:same-id',
      }, scope: (await NotificationInbox.sessionScope())!);
      await NotificationInbox.clearPreferencesPreservingDismissals(prefs);

      await prefs.setString('session_username', 'other@example.test');
      await prefs.setString('session_sid', 'other-sid');
      await NotificationInbox.capture(push('same-id', 'TASK_ASSIGNED'));
      expect((await NotificationInbox.cached()).single.id, 'push:same-id');
      await NotificationInbox.dismissViewed({
        'push:same-id',
      }, scope: (await NotificationInbox.sessionScope())!);
      await NotificationInbox.clearPreferencesPreservingDismissals(prefs);
      expect(prefs.getKeys(), hasLength(2));

      await prefs.setString('session_username', user);
      await prefs.setString('session_sid', 'site-sid');
      dotenv.testLoad(fileInput: 'SITE_URL=https://other.example.test');
      await NotificationInbox.capture(push('same-id', 'TASK_ASSIGNED'));
      expect((await NotificationInbox.cached()).single.id, 'push:same-id');
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      expect(await NotificationInbox.cached(), isEmpty);
      await prefs.setString('session_username', 'other@example.test');
      expect(await NotificationInbox.cached(), isEmpty);
    },
  );

  test('logout cleanup waits for pending notification clears', () async {
    await NotificationInbox.capture(push('pending-clear', 'TASK_ASSIGNED'));
    final prefs = await SharedPreferences.getInstance();
    final scope = (await NotificationInbox.sessionScope())!;
    final clear = NotificationInbox.dismissViewed({
      'push:pending-clear',
    }, scope: scope);
    await NotificationInbox.clearPreferencesPreservingDismissals(prefs);
    await clear;
    await prefs.setString('session_username', user);
    await prefs.setString('session_sid', 'next-sid');
    await NotificationInbox.capture(push('pending-clear', 'TASK_ASSIGNED'));
    expect(await NotificationInbox.cached(), isEmpty);
  });
}
