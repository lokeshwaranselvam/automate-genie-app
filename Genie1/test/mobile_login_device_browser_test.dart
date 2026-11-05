@TestOn('browser')
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/mobile_login_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'browser identity survives repeated reads and has API-compatible format',
    () async {
      final id = await MobileLoginDevice.androidId();
      final key = await MobileLoginDevice.key();
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(await MobileLoginDevice.androidId(), id);
      expect(await MobileLoginDevice.key(), key);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'genie_web_android_id_v1'), id);
      expect(await storage.read(key: 'genie_web_installation_key_v1'), key);
    },
  );

  test('separate browser storage receives a different identity', () async {
    final firstId = await MobileLoginDevice.androidId();
    final firstKey = await MobileLoginDevice.key();
    FlutterSecureStorage.setMockInitialValues({});
    expect(await MobileLoginDevice.androidId(), isNot(firstId));
    expect(await MobileLoginDevice.key(), isNot(firstKey));
  });

  test('concurrent calls share one persisted identity', () async {
    final ids = await Future.wait(
      List.generate(8, (_) => MobileLoginDevice.androidId()),
    );
    final keys = await Future.wait(
      List.generate(8, (_) => MobileLoginDevice.key()),
    );
    expect(ids.toSet(), hasLength(1));
    expect(keys.toSet(), hasLength(1));
    expect(await MobileLoginDevice.androidId(), ids.first);
    expect(await MobileLoginDevice.key(), keys.first);
  });
}
