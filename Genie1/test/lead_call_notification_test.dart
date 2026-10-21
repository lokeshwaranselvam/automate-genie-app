import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/fcm_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:homegenie/utils/api/lead_call_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final shows = <Map>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shows.clear();
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': 'staff@example.test',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'show') shows.add(call.arguments as Map);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
}
