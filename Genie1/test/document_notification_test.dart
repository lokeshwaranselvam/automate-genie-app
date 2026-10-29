import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/document_notification.dart';
import 'package:homegenie/utils/api/fcm_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const alarm = MethodChannel('ai.automategenie/event_assignment_alarm');
  const data = <String, dynamic>{
    'type': 'DOCUMENT_NOTIFICATION',
    'doctype': 'Lead',
    'docname': 'CRM-1',
    'for_user': 'staff@example.test',
    'title': 'New lead assigned',
    'body': 'Please contact the customer.',
    'alarm_enabled': '1',
  };
  final shows = <Map>[];
  var alarms = 0;
  var alarmStarts = true;
  final owner = Object();
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': 'staff@example.test',
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shows.clear();
    alarms = 0;
    alarmStarts = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'initialize') return true;
          if (call.method == 'show') shows.add(call.arguments as Map);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(alarm, (call) async {
          alarms++;
          return alarmStarts;
        });
  });
  tearDown(() {
    DocumentNotificationTaps.unregister(owner);
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(alarm, null);
  });

  Future<bool> send({
    String id = 'push-1',
    Map<String, dynamic> changes = const {},
  }) => showDocumentNotification(
    RemoteMessage(messageId: id, data: {...data, ...changes}),
  );

  test('displays mapped fields and rings once for repeat deliveries', () async {
    expect(await Future.wait([send(), send()]), [true, false]);
    expect(shows, hasLength(1));
    expect(shows.single['title'], data['title']);
    expect(shows.single['body'], data['body']);
    expect(jsonDecode(shows.single['payload'])['docname'], 'CRM-1');
    expect(alarms, 1);
    expect(await send(id: 'push-2'), isTrue);
    expect(alarms, 2); // Another rule/update for the same document is allowed.
  });

  test(
    'server flag alone controls alarm; missing flags remain silent',
    () async {
      for (final flag in ['0', '', 'true']) {
        await send(id: flag, changes: {'alarm_enabled': flag});
      }
      expect(shows, hasLength(3));
      expect(alarms, 0);
    },
  );

  test(
    'native failure uses alarm channel with the same notification ID',
    () async {
      alarmStarts = false;
      await send();
      expect(shows, hasLength(2));
      expect(shows.first['id'], shows.last['id']);
      expect(
        shows.last['platformSpecifics']['channelId'],
        'document_notification_alarm_v1',
      );
    },
  );

  test(
    'rejects wrong recipients, malformed payloads and logged-out users',
    () async {
      for (final change in [
        {'for_user': 'other@example.test'},
        {'for_user': ''},
        {'docname': ''},
        {'doctype': ''},
        {'type': 'EVENT_ASSIGNED'},
      ]) {
        expect(await send(changes: change), isFalse);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('session_sid');
      expect(await send(), isFalse);
      expect(shows, isEmpty);
      expect(alarms, 0);
    },
  );

  test(
    'delivery failure remains retryable; logout during display suppresses alarm',
    () async {
      await expectLater(
        DocumentNotificationAlerts.deliver(
          data: data,
          receipt: 'retry',
          notify: () async => throw StateError('failed'),
        ),
        throwsStateError,
      );
      expect(
        await DocumentNotificationAlerts.deliver(
          data: data,
          receipt: 'retry',
          notify: () async {},
        ),
        isTrue,
      );
      await DocumentNotificationAlerts.deliver(
        data: data,
        receipt: 'logout',
        notify: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('session_sid');
        },
        playSound: () async => fail('Alarm after logout'),
      );
    },
  );

  test('tap waits for Home and rejects a changed account or site', () async {
    final opened = <DocumentNotification>[];
    await DocumentNotificationTaps.open(data);
    expect(opened, isEmpty);
    DocumentNotificationTaps.register(owner, opened.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(opened.single.docname, 'CRM-1');
    await DocumentNotificationTaps.open({
      ...data,
      '_genie_site': 'https://other.test',
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_username', 'other@example.test');
    await DocumentNotificationTaps.open(data);
    expect(opened, hasLength(1));
  });

  test(
    'queued tap cannot cross sessions and document URLs encode path segments',
    () async {
      await DocumentNotificationTaps.open(data);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_sid', 'new-session');
      DocumentNotificationTaps.register(owner, (_) => fail('Old session tap'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final uri =
          DocumentNotification.fromData({
            ...data,
            'doctype': 'Expense Claim',
            'docname': 'EXP/1?#test',
          })!.documentUri!;
      expect(uri.host, 'erp.example.test');
      expect(uri.pathSegments, ['app', 'expense-claim', 'EXP/1?#test']);
      expect(uri.query, isEmpty);
    },
  );
}
