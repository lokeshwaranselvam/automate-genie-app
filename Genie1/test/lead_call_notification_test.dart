import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/fcm_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:homegenie/utils/api/lead_call_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const alarmChannel = MethodChannel('ai.automategenie/event_assignment_alarm');
  final shows = <Map>[];
  final alarmCalls = <MethodCall>[];
  bool alarmStarts = true;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shows.clear();
    alarmCalls.clear();
    alarmStarts = true;
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': 'staff@example.test',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(alarmChannel, (call) async {
          alarmCalls.add(call);
          return alarmStarts;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'initialize') return true;
          if (call.method == 'show') shows.add(call.arguments as Map);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(alarmChannel, null);
  });

  Map<String, dynamic> payload({String doctype = 'Lead'}) => {
    'type': 'NEW_LEAD_CALL',
    'doctype': doctype,
    'docname': 'CRM-1',
    'customer_name': 'Customer',
    'mobile_no': '+91 (98765) 43210',
    'auto_call': '1',
  };

  test('accepts both exact payloads emitted by the supplied FCM trigger', () {
    for (final doctype in ['Lead', 'Opportunity']) {
      final lead = LeadCallNotification.fromData(payload(doctype: doctype))!;
      expect(lead.doctype, doctype);
      expect(lead.docname, 'CRM-1');
      expect(lead.title, 'New ${doctype.toLowerCase()} assigned');
      expect(lead.phone, '+919876543210');
      expect(lead.dialUri.scheme, 'tel');
      expect(lead.dialUri.path, '+919876543210');
      expect(lead.body, contains('Customer'));
    }
  });

  test('does not claim existing pending-work notification types', () {
    expect(
      LeadCallNotification.fromData({
        ...payload(),
        'type': 'PENDING_WORK_ASSIGNED',
      }),
      isNull,
    );
  });

  test('rejects malformed destinations and unsupported documents', () {
    for (final phone in [
      '',
      '123',
      '++919876543210',
      'tel:1234567',
      '9876543210;123',
      '1234567890123456',
    ]) {
      expect(
        LeadCallNotification.fromData({...payload(), 'mobile_no': phone}),
        isNull,
        reason: phone,
      );
    }
    expect(LeadCallNotification.fromData(payload(doctype: 'User')), isNull);
    expect(
      LeadCallNotification.fromData({...payload(), 'docname': ''}),
      isNull,
    );
  });

  test('falls back to document name when customer name is absent', () {
    expect(
      LeadCallNotification.fromData({
        ...payload(),
        'customer_name': '',
      })!.customerName,
      'CRM-1',
    );
  });
  test(
    'data-only lead notification displays customer and binds tap to account',
    () async {
      await showLeadCallNotification(RemoteMessage(data: payload()));
      expect(shows, hasLength(1));
      expect(shows.single['title'], 'New lead assigned');
      expect(shows.single['body'], contains('Customer'));
      final stored = jsonDecode(shows.single['payload'] as String) as Map;
      expect(stored['_genie_user'], 'staff@example.test');
      expect(stored['docname'], 'CRM-1');
      // auto_call remains data. Displaying a push does not invoke a call.
      expect(stored['auto_call'], '1');
    },
  );

  test(
    'signed out and other-recipient lead pushes are not displayed',
    () async {
      await showLeadCallNotification(
        RemoteMessage(data: {...payload(), 'for_user': 'other@example.test'}),
      );
      SharedPreferences.setMockInitialValues({});
      await showLeadCallNotification(RemoteMessage(data: payload()));
      expect(shows, isEmpty);
    },
  );
  test(
    'background Event assignment starts native alarm once for its recipient',
    () async {
      const data = {
        'type': 'EVENT_ASSIGNED',
        'doctype': 'Event',
        'docname': 'EVENT-1',
        'assignment_id': 'TODO-1',
        'alarm_enabled': '1',
        'for_user': 'staff@example.test',
        'title': 'New event assigned',
        'body': 'Bank visit',
      };
      expect(
        await showEventAssignmentNotification(const RemoteMessage(data: data)),
        isTrue,
      );
      expect(
        await showEventAssignmentNotification(const RemoteMessage(data: data)),
        isFalse,
      );
      expect(
        await showEventAssignmentNotification(
          RemoteMessage(
            data: {
              ...data,
              'assignment_id': 'TODO-2',
              'for_user': 'other@example.test',
            },
          ),
        ),
        isFalse,
      );
      expect(shows, hasLength(1));
      expect(shows.single['title'], 'New event assigned');
      final android = shows.single['platformSpecifics'] as Map;
      expect(android['channelId'], 'event_assignment_visual_v1');
      expect(android['playSound'], isFalse);
      expect(alarmCalls.map((call) => call.method), ['play']);
    },
  );
  test(
    'foreground Event also uses native alarm rather than media playback',
    () async {
      await showEventAssignmentNotification(
        const RemoteMessage(
          data: {
            'type': 'EVENT_ASSIGNED',
            'doctype': 'Event',
            'docname': 'EV-2',
            'assignment_id': 'TODO-2',
            'alarm_enabled': '1',
            'for_user': 'staff@example.test',
          },
        ),
        playAlarm: true,
      );
      expect(alarmCalls, hasLength(1));
      expect(shows, hasLength(1));
      expect((shows.single['platformSpecifics'] as Map)['playSound'], isFalse);
    },
  );
  test(
    'blocked background service falls back to dedicated alarm-stream channel',
    () async {
      alarmStarts = false;
      await showEventAssignmentNotification(
        const RemoteMessage(
          data: {
            'type': 'EVENT_ASSIGNED',
            'doctype': 'Event',
            'docname': 'EV-3',
            'assignment_id': 'TODO-3',
            'alarm_enabled': '1',
            'for_user': 'staff@example.test',
          },
        ),
      );
      expect(alarmCalls, hasLength(1));
      expect(shows, hasLength(2));
      expect(shows.first['id'], shows.last['id']);
      final fallback = shows.last['platformSpecifics'] as Map;
      expect(fallback['channelId'], 'event_assignment_alarm_v1');
      expect(fallback['playSound'], isTrue);
      expect(fallback['sound'], 'work_assigned');
      expect(
        fallback['audioAttributesUsage'],
        AudioAttributesUsage.alarm.value,
      );
    },
  );
  test(
    'noneligible and legacy Event pushes stay visible without native or fallback alarm',
    () async {
      alarmStarts = false;
      var sequence = 0;
      for (final playAlarm in [false, true]) {
        for (final flag in [null, '0', 'true', true, 1]) {
          final before = shows.length;
          await showEventAssignmentNotification(
            RemoteMessage(
              data: {
                'type': 'EVENT_ASSIGNED',
                'doctype': 'Event',
                'docname': 'EV-QUIET',
                'assignment_id': 'TODO-QUIET-${sequence++}',
                'for_user': 'staff@example.test',
                if (flag != null) 'alarm_enabled': flag,
              },
            ),
            playAlarm: playAlarm,
          );
          expect(shows, hasLength(before + 1));
          final android = shows.last['platformSpecifics'] as Map;
          expect(android['channelId'], 'event_assignment_visual_v1');
          expect(android['playSound'], isFalse);
          expect(alarmCalls, isEmpty);
        }
      }
    },
  );
  test(
    'pending work retains its existing sound channel and does not start Event service',
    () async {
      await showPendingWorkNotification(
        const RemoteMessage(
          data: {'type': 'PENDING_WORK_ASSIGNED', 'title': 'Pending work'},
        ),
      );
      expect(alarmCalls, isEmpty);
      expect(
        (shows.single['platformSpecifics'] as Map)['channelId'],
        'work_assignment',
      );
      expect((shows.single['platformSpecifics'] as Map)['playSound'], isTrue);
    },
  );
}
