import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/notification_inbox.dart';
import 'package:homegenie/utils/api/notification_inbox_taps.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = 'staff@example.test';
  final owner = Object();
  RemoteMessage message({
    String id = 'one',
    Map<String, dynamic> changes = const {},
  }) => RemoteMessage(
    messageId: id,
    data: {
      'type': 'DOCUMENT_NOTIFICATION',
      'doctype': 'Lead',
      'docname': 'CRM-1',
      'for_user': user,
      'title': 'New lead',
      ...changes,
    },
  );
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': user,
    });
  });
  tearDown(() async {
    NotificationInboxTaps.unregister(owner);
    await NotificationInbox.cached();
  });

  test(
    'cold-start tap waits for Home and retains the document in the inbox',
    () async {
      var opened = 0;
      await NotificationInboxTaps.open(message());
      expect(opened, 0);
      final cached = await NotificationInbox.cached();
      expect(cached.single.doctype, 'Lead');
      expect(cached.single.reference, 'CRM-1');
      final ready = Completer<void>();
      NotificationInboxTaps.register(owner, () {
        opened++;
        if (!ready.isCompleted) ready.complete();
      });
      await ready.future.timeout(const Duration(seconds: 2));
      expect(opened, 1);
      await NotificationInboxTaps.open(message());
      expect((await NotificationInbox.cached()).length, 1);
    },
  );

  test(
    'rejects wrong recipients, malformed documents, old local users/sites and logout',
    () async {
      var opened = 0;
      NotificationInboxTaps.register(owner, () => opened++);
      for (final changes in [
        {'for_user': 'another@example.test'},
        {'recipient': 'another@example.test'},
        {'_genie_user': 'another@example.test'},
        {'_genie_site': 'https://other.example.test'},
        {'docname': ''},
        {'doctype': ''},
        {'for_user': 'Guest'},
      ]) {
        await NotificationInboxTaps.open(message(changes: changes));
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('session_sid');
      await NotificationInboxTaps.open(message());
      expect(opened, 0);
      expect(await NotificationInbox.cached(), isEmpty);
    },
  );

  for (final field in ['session_sid', 'session_username', 'site']) {
    test('queued tap cannot cross a changed $field', () async {
      await NotificationInboxTaps.open(message());
      if (field == 'site') {
        dotenv.testLoad(fileInput: 'SITE_URL=https://other.example.test');
      } else {
        await (await SharedPreferences.getInstance()).setString(
          field,
          'different',
        );
      }
      NotificationInboxTaps.register(
        owner,
        () => fail('Opened an old session tap'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }

  test(
    'pending work, Event and lead-call pushes all request the inbox',
    () async {
      var opened = 0;
      NotificationInboxTaps.register(owner, () => opened++);
      for (final type in [
        'PENDING_WORK_ASSIGNED',
        'EVENT_ASSIGNED',
        'NEW_LEAD_CALL',
      ]) {
        await NotificationInboxTaps.open(
          message(id: type, changes: {'type': type, 'mobile_no': '9876543210'}),
        );
      }
      expect(opened, 3);
      final rows = await NotificationInbox.cached();
      expect(rows, hasLength(3));
      expect(rows.first.callPhone, '9876543210');
      final restored = InboxNotification.fromJson(rows.first.toJson());
      expect(restored.doctype, 'Lead');
      expect(restored.callPhone, '9876543210');
    },
  );
}
