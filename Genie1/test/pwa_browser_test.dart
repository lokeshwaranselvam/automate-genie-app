@TestOn('browser')
library;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/session_auth.dart';
import 'package:homegenie/utils/api/mobile_login_device.dart';
import 'package:homegenie/utils/platform/platform_file.dart';
import 'package:homegenie/utils/platform/multipart_file.dart';
import 'package:homegenie/utils/widget/gps_photo_stamper.dart';
import 'package:homegenie/utils/face/face_embedding_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/itgenie.api_utils');
  });
  test('browser login verifies identity without reading Set-Cookie', () async {
    expect(kIsWeb, isTrue);
    var verified = false;
    await http.runWithClient(() async {
      final result = await SessionAuthApi.login('employee', 'test-password');
      expect(result['username'], 'staff@example.test');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_sid'), startsWith('browser-'));
      expect(prefs.getString('token'), 'token key:secret');
      expect(prefs.getBool('single_device_login'), isTrue);
      expect(verified, isTrue);
    }, () => MockClient((request) async {
      if (request.url.path.endsWith('.login')) {
        final body = jsonDecode(request.body) as Map;
        expect(body['platform'], 'android');
        expect(body['device_key'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(body['android_id'], matches(RegExp(r'^[0-9a-f]{16}$')));
        return http.Response(jsonEncode({'message': 'Logged In', 'email': 'staff@example.test', 'full_name': 'Staff', 'token': 'token key:secret', 'single_device_login': true, 'android_device_binding': true}), 200);
      }
      verified = true;
      return http.Response(jsonEncode({'message': 'staff@example.test'}), 200);
    }));
  });
  test('browser login retries explicit CSRF rejection once with the same identifiers', () async {
    var posts = 0;
    String? firstBody;
    await http.runWithClient(() async {
      await SessionAuthApi.login('employee', 'test-password');
      expect(posts, 2);
    }, () => MockClient((request) async {
      if (request.url.path == '/app') {
        return http.Response('frappe.csrf_token = "login-csrf";', 200);
      }
      if (request.url.path.endsWith('.login')) {
        posts++;
        if (posts == 1) {
          firstBody = request.body;
          return http.Response('{"exc_type":"CSRFTokenError"}', 400);
        }
        expect(request.body, firstBody);
        expect(request.headers['X-Frappe-CSRF-Token'], 'login-csrf');
        return http.Response(jsonEncode({'message': 'Logged In', 'email': 'staff@example.test', 'token': 'token key:secret', 'single_device_login': true, 'android_device_binding': true}), 200);
      }
      return http.Response('{"message":"staff@example.test"}', 200);
    }));
  });
  test('browser login never retries wrong credentials', () async {
    var requests = 0;
    await http.runWithClient(() async {
      await expectLater(SessionAuthApi.login('employee', 'wrong-password'), throwsException);
    }, () => MockClient((_) async {
      requests++;
      return http.Response('{"message":"Incorrect password"}', 401);
    }));
    expect(requests, 1);
  });
  test('browser test identifiers ignore browser-specific storage and preference cleanup', () async {
    FlutterSecureStorage.setMockInitialValues({
      'genie_pwa_test_android_id': '1111111111111111',
      'genie_mobile_installation_key': 'a' * 43,
    });
    final values = await Future.wait([MobileLoginDevice.androidId(), MobileLoginDevice.androidId()]);
    expect(values[0], '7ac19e04b582d63f');
    expect(values[0], values[1]);
    expect(values[0], matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(values[0], isNot('0000000000000000'));
    expect(values[0], isNot('9774d56d682e549c'));
    final key = await MobileLoginDevice.key();
    expect(key, isNot('a' * 43));
    FlutterSecureStorage.setMockInitialValues({
      'genie_pwa_test_android_id': '2222222222222222',
      'genie_mobile_installation_key': 'b' * 43,
    });
    await (await SharedPreferences.getInstance()).clear();
    expect(await MobileLoginDevice.androidId(), values[0]);
    expect(await MobileLoginDevice.key(), key);
  });
  test('browser logout releases its mock installation using the same device key and CSRF', () async {
    SharedPreferences.setMockInitialValues({'session_sid': 'browser-current', 'token': 'token key:secret'});
    final endpoint = Uri.parse('https://erp.example.test/api/method/itgenie.api_utils.mobile_logout');
    final key = await MobileLoginDevice.key();
    await MobileLoginDevice.rememberSession(endpoint, 'staff@example.test');
    var attempts = 0;
    await http.runWithClient(() async {
      await SessionAuthApi.logout();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_sid'), isNull);
      expect(prefs.getString('token'), isNull);
    }, () => MockClient((request) async {
      if (request.url.path == '/app') {
        return http.Response('frappe.csrf_token = "browser-csrf";', 200);
      }
      expect(request.url, endpoint);
      final body = jsonDecode(request.body) as Map;
      expect(body['device_key'], key);
      expect(body['user'], 'staff@example.test');
      attempts++;
      if (attempts == 1) {
        return http.Response('{"exc_type":"CSRFTokenError"}', 400);
      }
      expect(request.headers['X-Frappe-CSRF-Token'], 'browser-csrf');
      return http.Response('{"message":{"status":"success"}}', 200);
    }));
    expect(attempts, 2);
  });
  test('failed browser logout preserves local session for retry', () async {
    SharedPreferences.setMockInitialValues({'session_sid': 'browser-current', 'token': 'token key:secret'});
    await MobileLoginDevice.rememberSession(
      Uri.parse('https://erp.example.test/api/method/itgenie.api_utils.mobile_logout'),
      'staff@example.test',
    );
    await http.runWithClient(() async {
      await expectLater(SessionAuthApi.logout(), throwsStateError);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_sid'), 'browser-current');
      expect(prefs.getString('token'), 'token key:secret');
    }, () => MockClient((_) async => http.Response('{}', 500)));
  });
  test('different browser session identity clears stale local credentials', () async {
    SharedPreferences.setMockInitialValues({'session_sid': 'browser-old', 'session_username': 'old@example.test', 'token': 'token old:secret'});
    await http.runWithClient(() async {
      expect(await SessionAuthApi.getActiveSessionUser(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('session_sid'), isNull);
    }, () => MockClient((_) async => http.Response(jsonEncode({'message': 'other@example.test'}), 200)));
  });
  test('GPS stamping and multipart preserve captured browser photo bytes', () async {
    final original = img.Image(width: 320, height: 320);
    img.fill(original, color: img.ColorRgb8(210, 220, 230));
    final source = await File('/memory/test/photo.jpg').writeAsBytes(img.encodeJpg(original));
    final stamped = await GpsPhotoStamper.stamp(file: source, lat: 12.9716, lng: 77.5946, address: 'Test location', includeMapThumbnail: false);
    expect(stamped.path, endsWith('_gps.jpg'));
    final bytes = await stamped.readAsBytes();
    expect(img.decodeJpg(bytes), isNotNull);
    expect(bytes, isNot(orderedEquals(await source.readAsBytes())));
    final multipart = await platformMultipartFile('file', stamped.path, filename: 'photo.jpg');
    expect(await multipart.finalize().toBytes(), orderedEquals(bytes));
    await stamped.delete();
    expect(await stamped.exists(), isFalse);
  });
  test('face verification never falls back to an unverified browser selfie', () async {
    final photo = await File('/memory/test/face.jpg').writeAsBytes([1, 2, 3]);
    await expectLater(FaceEmbeddingService.instance.embeddingFromCapture(photo), throwsA(isA<FaceEmbeddingException>()));
    expect(FaceEmbeddingService.pilotCosineThreshold, 0.5);
    expect(FaceEmbeddingService.modelVersion, 'opencv-sface-2021dec-int8bq-v1');
  });
}
