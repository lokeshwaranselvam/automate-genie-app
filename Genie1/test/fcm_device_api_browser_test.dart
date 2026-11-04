@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/fcm_device_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'session_sid': 'browser-generation',
      'token': 'token key:secret',
    });
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Genie',
      packageName: 'genie.test',
      version: '1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });

  for (final scenario in ['success', 'csrf', 'validation', 'timeout']) {
    test('Browser API-token registration: $scenario', () async {
      var gets = 0;
      var posts = 0;
      await http.runWithClient(
        () => FcmDeviceApi.registerToken('browser-fcm-token'),
        () => MockClient((request) async {
          // A browser marker must never be supplied as an actual SID cookie.
          expect(request.headers.containsKey('Cookie'), isFalse);
          if (request.method == 'GET') {
            gets++;
            expect(request.url.path, '/app');
            expect(request.followRedirects, isTrue);
            return http.Response('frappe.csrf_token = "csrf$gets";', 200);
          }
          posts++;
          expect(request.headers['Authorization'], 'token key:secret');
          expect(request.headers['X-Frappe-CSRF-Token'], 'csrf$gets');
          final body = jsonDecode(request.body) as Map;
          expect(body['csrf_token'], 'csrf$gets');
          expect(body['fcm_token'], 'browser-fcm-token');
          if (scenario == 'timeout') throw TimeoutException('offline');
          if (posts == 1 && ['csrf', 'validation'].contains(scenario)) {
            return http.Response(
              jsonEncode({
                'exc_type':
                    scenario == 'csrf' ? 'CSRFTokenError' : 'ValidationError',
              }),
              400,
            );
          }
          return http.Response('{"message":{"status":"success"}}', 200);
        }),
      );
      expect(posts, scenario == 'csrf' ? 2 : 1);
      expect(gets, scenario == 'csrf' ? 2 : 1);
    });
  }

  test(
    'Browser refuses a token obtained after a cross-origin redirect',
    () async {
      var posts = 0;
      await http.runWithClient(
        () => FcmDeviceApi.registerToken('browser-fcm-token'),
        () => MockClient.streaming((request, _) async {
          if (request.method == 'POST') posts++;
          return _ResponseWithUrl(
            Stream.value(utf8.encode('frappe.csrf_token = "wrong-site";')),
            200,
            url: Uri.parse('https://other.example.test/app'),
          );
        }),
      );
      expect(posts, 0);
    },
  );
}

class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  @override
  final Uri url;
  _ResponseWithUrl(super.stream, super.statusCode, {required this.url});
}
