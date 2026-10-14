import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var active = false;
  setUp(() {
    calls.clear();
    active = false;
    dotenv.testLoad(
      fileInput:
          'SITE_URL=https://erp.example.test/\nURL=https://erp.example.test/api/method/app.api',
    );
    SharedPreferences.setMockInitialValues({
      'email': 'staff@example.test',
      'session_sid': 'test-session',
      'token': 'token test-key:test-secret',
      'is_employee_checked_in': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveLocationService.platform, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'startLocationTracking':
              active = true;
              return 'started';
            case 'stopLocationTracking':
              active = false;
              return 'stopped';
            case 'isLocationTracking':
              return active;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveLocationService.platform, null);
  });

  test(
    'check-in starts native tracking with API authorization, not the session cookie',
    () async {
      await LiveLocationService().startTracking();
      final start = calls.singleWhere(
        (call) => call.method == 'startLocationTracking',
      );
      expect(start.arguments, {
        'userId': 'staff@example.test',
        'authToken': 'token test-key:test-secret',
        'siteUrl': 'https://erp.example.test/',
      });
      expect(calls.any((call) => call.method == 'isLocationTracking'), isTrue);
      expect(LiveLocationService().isTracking, isTrue);
    },
  );

  test(
    'missing native service is restored even when Dart thinks it is tracking',
    () async {
      await LiveLocationService().startTracking();
      active = false;
      await LiveLocationService().ensureTracking();
      expect(
        calls.where((call) => call.method == 'startLocationTracking').length,
        2,
      );
      expect(active, isTrue);
      await LiveLocationService().ensureTracking();
      expect(
        calls.where((call) => call.method == 'startLocationTracking').length,
        2,
      );
    },
  );

  test('checked-out attendance never restores tracking', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_employee_checked_in', false);
    await LiveLocationService().ensureTracking();
    expect(calls, isEmpty);
  });

  test('logout or missing API credentials cannot start a service', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_sid');
    await expectLater(LiveLocationService().startTracking(), throwsStateError);
    expect(calls, isEmpty);
    await prefs.setString('session_sid', 'test-session');
    await prefs.remove('token');
    await expectLater(LiveLocationService().startTracking(), throwsStateError);
    expect(calls, isEmpty);
  });

  test(
    'checkout waits for an in-flight start and leaves tracking stopped',
    () async {
      final launched = Completer<void>();
      final release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveLocationService.platform, (call) async {
            calls.add(call);
            if (call.method == 'startLocationTracking') {
              launched.complete();
              await release.future;
              active = true;
              return 'started';
            }
            if (call.method == 'isLocationTracking') return active;
            if (call.method == 'stopLocationTracking') {
              active = false;
              return 'stopped';
            }
            return null;
          });
      final start = LiveLocationService().startTracking();
      await launched.future;
      final stop = LiveLocationService().stopTracking();
      release.complete();
      await Future.wait([start, stop]);
      expect(active, isFalse);
      expect(LiveLocationService().isTracking, isFalse);
      expect(calls.last.method, 'stopLocationTracking');
    },
  );

  test(
    'native startup failure clears tracking and still permits a retry',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveLocationService.platform, (call) async {
            calls.add(call);
            if (call.method == 'startLocationTracking') {
              throw PlatformException(code: 'PERMISSION_DENIED');
            }
            return 'stopped';
          });
      await expectLater(
        LiveLocationService().startTracking(),
        throwsA(isA<PlatformException>()),
      );
      expect(LiveLocationService().isTracking, isFalse);
      expect(calls.last.method, 'stopLocationTracking');
    },
  );
}
