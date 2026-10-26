import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:homegenie/utils/api/event_assignment_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const data = {
    'type': 'EVENT_ASSIGNED',
    'doctype': 'Event',
    'docname': 'EVENT-1',
    'assignment_id': 'TODO-1',
    'for_user': 'designer@example.test',
  };
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': 'designer@example.test',
    });
  });
  test(
    'only the assigned signed-in user is alerted and duplicate deliveries ring once',
    () async {
      var notifications = 0;
      var alarms = 0;
      Future<bool> deliver(Map<String, dynamic> payload) =>
          EventAssignmentAlerts.deliver(
            data: payload,
            notify: () async {
              notifications++;
            },
            playSound: () async {
              alarms++;
            },
          );
      expect(
        await deliver({...data, 'for_user': 'someone@example.test'}),
        isFalse,
      );
      final results = await Future.wait([deliver(data), deliver(data)]);
      expect(results, [true, false]);
      expect(notifications, 1);
      expect(alarms, 1);
      expect(await deliver({...data, 'assignment_id': 'TODO-2'}), isTrue);
      expect(alarms, 2);
    },
  );
  test(
    'malformed or unrelated pushes cannot trigger an Event assignment alarm',
    () async {
      for (final change in [
        {'type': 'PENDING_WORK_ASSIGNED'},
        {'doctype': 'Task'},
        {'assignment_id': ''},
        {'docname': ''},
        {'for_user': ''},
      ]) {
        expect(
          await EventAssignmentAlerts.deliver(
            data: {...data, ...change},
            notify: () async => fail('Unexpected notification'),
          ),
          isFalse,
        );
      }
    },
  );
  test('signed-out users are not alerted', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_sid');
    expect(
      await EventAssignmentAlerts.deliver(
        data: data,
        notify: () async => fail('Signed-out notification'),
      ),
      isFalse,
    );
  });
  test('a failed notification can retry without losing the alarm', () async {
    await expectLater(
      EventAssignmentAlerts.deliver(
        data: data,
        notify: () async => throw StateError('notification failed'),
      ),
      throwsStateError,
    );
    expect(
      await EventAssignmentAlerts.deliver(data: data, notify: () async {}),
      isTrue,
    );
  });
  test(
    'logout during notification prevents foreground audio in the next account',
    () async {
      var alarm = false;
      await EventAssignmentAlerts.deliver(
        data: data,
        notify: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('session_username', 'someone@example.test');
        },
        playSound: () async {
          alarm = true;
        },
      );
      expect(alarm, isFalse);
    },
  );
}
