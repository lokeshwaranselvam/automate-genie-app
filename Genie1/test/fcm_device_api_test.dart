// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/fcm_device_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const endpoint = '/api/method/itgenie.fcm.devices.register_device';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/firebase_messaging'),
          null,
        );
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({'session_sid': 'login-sid'});
    FlutterSecureStorage.setMockInitialValues({
      'genie_mobile_installation_key': 'private-login-key',
    });
    PackageInfo.setMockInitialValues(
      appName: 'Genie',
      packageName: 'test.genie',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
    );
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });

  http.Response success() => http.Response(
    jsonEncode({
      'message': {'status': 'success'},
    }),
    200,
  );
  test(
    'every registration sends all metadata with a stable independent device ID',
    () async {
      final records = <Map>[];
      await http.runWithClient(
        () async {
          await FcmDeviceApi.registerToken('token-one');
          // Device identity survives ordinary preference cleanup at logout.
          SharedPreferences.setMockInitialValues({
            'session_sid': 'second-login-sid',
          });
          await FcmDeviceApi.registerToken('token-two');
        },
        () => MockClient((request) async {
          if (request.url.path == '/app') {
            return http.Response("frappe.csrf_token = 'csrf';", 200);
          }
          expect(request.url.path, endpoint);
          expect(request.followRedirects, isFalse);
          expect(request.headers['X-Frappe-CSRF-Token'], 'csrf');
          expect(
            request.headers['Cookie'],
            records.isEmpty ? 'sid=login-sid' : 'sid=second-login-sid',
          );
          records.add(jsonDecode(request.body) as Map);
          return success();
        }),
      );
      expect(records, hasLength(2));
      expect(records[0]['device_id'], matches(RegExp(r'^[A-Za-z0-9_-]{32}$')));
      expect(records[0]['device_id'], records[1]['device_id']);
      expect(records[0]['device_id'], isNot('private-login-key'));
      for (final record in records) {
        expect(record['app_version'], '1.2.3');
        expect(record['build_version'], '42');
        expect(record['platform'], isNotEmpty);
        expect(record.containsKey('is_active'), isFalse); // Set by the backend.
        expect(record['csrf_token'], 'csrf');
        expect(
          record.containsKey('user'),
          isFalse,
        ); // Server session owns mapping.
        expect(
          record.containsKey('last_seen'),
          isFalse,
        ); // Server clock owns time.
      }
      expect(records.map((record) => record['fcm_token']), [
        'token-one',
        'token-two',
      ]);
    },
  );

  for (final scenario in [
    'login',
    'restore',
    'denied',
    'failure',
    'session-change',
  ]) {
    test(
      '$scenario controls token rotation and saves only the current token',
      () async {
        final calls = <String>[];
        final tokens = <String>[];
        var token = 'existing-token';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/firebase_messaging'),
              (call) async {
                calls.add(call.method);
                if (call.method == 'Messaging#requestPermission') {
                  if (scenario == 'session-change') {
                    await (await SharedPreferences.getInstance()).setString(
                      'session_sid',
                      'other-sid',
                    );
                  }
                  return {'authorizationStatus': scenario == 'denied' ? 0 : 1};
                }
                if (call.method == 'Messaging#deleteToken') {
                  if (scenario == 'failure') {
                    throw PlatformException(code: 'unavailable');
                  }
                  token = 'fresh-token-${calls.length}';
                  return <String, dynamic>{};
                }
                if (call.method == 'Messaging#getToken')
                  return {'token': token};
                return null;
              },
            );
        await http.runWithClient(
          () async {
            await FcmDeviceApi.requestPermissionAndRegister(
              rotateToken: scenario != 'restore',
            );
            if (scenario == 'login') {
              // Another successful password login must rotate again.
              await FcmDeviceApi.requestPermissionAndRegister(
                rotateToken: true,
              );
            }
          },
          () => MockClient((request) async {
            if (request.url.path == '/app') {
              return http.Response("frappe.csrf_token = 'csrf';", 200);
            }
            tokens.add(
              (jsonDecode(request.body) as Map)['fcm_token'] as String,
            );
            return success();
          }),
        );
        if (scenario == 'login') {
          expect(calls, [
            'Messaging#requestPermission',
            'Messaging#deleteToken',
            'Messaging#getToken',
            'Messaging#requestPermission',
            'Messaging#deleteToken',
            'Messaging#getToken',
          ]);
          expect(tokens, ['fresh-token-2', 'fresh-token-5']);
        } else if (scenario == 'restore') {
          expect(calls, ['Messaging#requestPermission', 'Messaging#getToken']);
          expect(tokens, ['existing-token']);
        } else {
          expect(tokens, isEmpty);
          expect(calls.contains('Messaging#getToken'), isFalse);
          if (scenario != 'failure') {
            expect(calls.contains('Messaging#deleteToken'), isFalse);
          }
        }
      },
    );
  }

  for (final failure in ['csrf', 'validation', 'timeout']) {
    test(
      '$failure registration uses bounded recovery without breaking login',
      () async {
        var posts = 0;
        var bootstraps = 0;
        await http.runWithClient(
          () => FcmDeviceApi.registerToken('token'),
          () => MockClient((request) async {
            if (request.url.path == '/app') {
              bootstraps++;
              return http.Response(
                "frappe.csrf_token = 'csrf$bootstraps';",
                200,
              );
            }
            posts++;
            if (failure == 'timeout') throw TimeoutException('network timeout');
            if (posts == 1) {
              return http.Response(
                jsonEncode({
                  'exc_type':
                      failure == 'csrf' ? 'CSRFTokenError' : 'ValidationError',
                }),
                400,
              );
            }
            expect(request.headers['X-Frappe-CSRF-Token'], 'csrf2');
            return success();
          }),
        );
        expect(posts, failure == 'csrf' ? 2 : 1);
        expect(bootstraps, failure == 'csrf' ? 2 : 1);
      },
    );
  }

  test('registration is skipped when signed out', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await http.runWithClient(
      () => FcmDeviceApi.registerToken('token'),
      () => MockClient((_) async {
        calls++;
        return success();
      }),
    );
    expect(calls, 0);
  });

  test('session change during bootstrap prevents upload', () async {
    var posts = 0;
    await http.runWithClient(
      () => FcmDeviceApi.registerToken('token'),
      () => MockClient((request) async {
        if (request.method == 'POST') posts++;
        await (await SharedPreferences.getInstance()).setString(
          'session_sid',
          'other-sid',
        );
        return http.Response("frappe.csrf_token = 'csrf';", 200);
      }),
    );
    expect(posts, 0);
  });

  test('bootstrap does not forward session cookies to another site', () async {
    var calls = 0;
    await http.runWithClient(
      () => FcmDeviceApi.registerToken('token'),
      () => MockClient((request) async {
        calls++;
        expect(request.url.origin, 'https://erp.example.test');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://other.example.test/app'},
        );
      }),
    );
    expect(calls, 1);
  });
}
