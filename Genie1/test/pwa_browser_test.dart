@TestOn('browser')
library;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/session_auth.dart';
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
      expect(verified, isTrue);
    }, () => MockClient((request) async {
      if (request.url.path.endsWith('.login')) {
        expect(jsonDecode(request.body)['platform'], 'web');
        return http.Response(jsonEncode({'message': 'Logged In', 'email': 'staff@example.test', 'full_name': 'Staff', 'token': 'token key:secret', 'single_device_login': true}), 200);
      }
      verified = true;
      return http.Response(jsonEncode({'message': 'staff@example.test'}), 200);
    }));
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
