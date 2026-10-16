import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  var nativeActive = false;

  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'email': 'employee@example.test',
      'session_sid': 'test-session',
      'token': 'token key:secret',
    });
    calls.clear();
    nativeActive = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveLocationService.platform, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'startLocationTracking':
              nativeActive = true;
              return 'started';
            case 'stopLocationTracking':
              nativeActive = false;
              return 'stopped';
            case 'isLocationTracking':
              return nativeActive;
          }
          throw PlatformException(code: 'UNEXPECTED_CALL');
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveLocationService.platform, null);
  });

  test('event restart cannot start live tracking without attendance', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('with_event', true);
    await LiveLocationService().startTracking();
    expect(calls, ['stopLocationTracking']);
    expect(nativeActive, isFalse);
  });

  test('successful current attendance permits live tracking', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_employee_checked_in', true);
    await LiveLocationService().startTracking();
    expect(calls, ['startLocationTracking', 'isLocationTracking']);
    expect(nativeActive, isTrue);
  });

  test(
    'previous-day state stops tracking and event restart stays stopped',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_employee_checked_in', true);
      await LiveLocationService().startTracking();
      calls.clear();

      // Attendance refresh switches to Previous Day Checkout, not today's IN.
      await prefs.setBool('is_employee_checked_in', false);
      await prefs.setBool('with_event', true);
      await LiveLocationService().ensureTracking();
      await LiveLocationService().startTracking();

      expect(calls, ['stopLocationTracking', 'stopLocationTracking']);
      expect(nativeActive, isFalse);
      expect(LiveLocationService().isTracking, isFalse);
    },
  );

  test('resume of active attendance does not duplicate native start', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_employee_checked_in', true);
    nativeActive = true;
    await LiveLocationService().ensureTracking();
    expect(calls, ['isLocationTracking']);
    expect(nativeActive, isTrue);
  });
}
