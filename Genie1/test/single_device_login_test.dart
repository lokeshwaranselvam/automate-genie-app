import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:homegenie/utils/api/login_api.dart';
import 'package:homegenie/utils/api/mobile_login_device.dart';
import 'package:homegenie/utils/api/session_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'staff@example.test';
const api = '/api/method/ts_homegenie.ts_homegenie.utils.api';

http.Response loggedIn({
  bool guarded = true,
  String? token = 'token key:secret',
}) => http.Response(
  jsonEncode({
    'message': 'Logged In',
    'email': user,
    'full_name': 'Staff Member',
    'employee_id': 'EMP-1',
    'token': token,
    'single_device_login': guarded,
  }),
  200,
  headers: {'set-cookie': 'sid=mobile-sid; HttpOnly; Path=/'},
);

http.Response loggedOut() => http.Response(
  jsonEncode({
    'message': {'status': 'success'},
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dotenv.testLoad(
      fileInput:
          'SITE_URL=https://erp.example.test\nURL=https://erp.example.test$api',
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('login sends the mobile platform: ${platform.name}', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await http.runWithClient(
        () async {
          expect((await LoginApi.login(user, 'password'))['error'], isNull);
        },
        () => MockClient((request) async {
          if (request.url.path == '$api.login') {
            final body = jsonDecode(request.body) as Map;
            expect(
              body['platform'],
              platform == TargetPlatform.iOS ? 'ios' : 'android',
            );
            expect(body['device_key'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
            return loggedIn();
          }
          return http.Response(jsonEncode({'message': user}), 200);
        }),
      );
    });
  }

  test(
    'one guarded login supplies API token and verified Frappe session',
    () async {
      final paths = <String>[];
      await http.runWithClient(
        () async {
          final result = await LoginApi.login(user, 'password');
          expect(result['error'], isNull);
          expect(result['token'], 'token key:secret');
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('session_sid'), 'mobile-sid');
          expect(prefs.getString('email'), user);
          expect(prefs.getBool('single_device_login'), isTrue);
          expect(prefs.getString('api_secret'), isNull);
        },
        () => MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '$api.login') {
            final body = jsonDecode(request.body) as Map;
            expect(body['usr'], user);
            expect(body['pwd'], 'password');
            expect(body['platform'], 'android');
            expect(body['device_key'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
            expect(request.headers['Cookie'], isNull);
            return loggedIn();
          }
          expect(request.headers['Cookie'], 'sid=mobile-sid');
          return http.Response(jsonEncode({'message': user}), 200);
        }),
      );
      expect(paths, ['$api.login', '/api/method/frappe.auth.get_logged_user']);
      expect(paths, isNot(contains('/api/method/login')));
    },
  );

  test(
    'UserID login stores the verified canonical user and Employee mapping',
    () async {
      await http.runWithClient(
        () async {
          final result = await LoginApi.login('staff.user', 'password');
          expect(result['error'], isNull);
          expect(result['employee_id'], 'EMP-1');
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('email'), user);
          expect(prefs.getString('session_username'), user);
          expect(prefs.getString('session_sid'), 'mobile-sid');
        },
        () => MockClient((request) async {
          if (request.url.path == '$api.login') {
            final body = jsonDecode(request.body) as Map;
            expect(body['usr'], 'staff.user');
            expect(body['pwd'], 'password');
            expect(body['device_key'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
            return loggedIn();
          }
          expect(request.url.path, '/api/method/frappe.auth.get_logged_user');
          expect(request.headers['Cookie'], 'sid=mobile-sid');
          return http.Response(jsonEncode({'message': user}), 200);
        }),
      );
    },
  );

  test(
    'blocked phone displays server message without logout or overwriting credentials',
    () async {
      SharedPreferences.setMockInitialValues({'token': 'existing-local-token'});
      var calls = 0;
      await http.runWithClient(
        () async {
          final result = await LoginApi.login(user, 'password');
          expect(result['error'], 'Log out from your other phone first.');
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('token'), 'existing-local-token');
          expect(prefs.getString('session_sid'), isNull);
        },
        () => MockClient((request) async {
          calls++;
          expect(request.url.path, '$api.login');
          return http.Response(
            jsonEncode({
              'message': {
                'key': 0,
                'message': 'Log out from your other phone first.',
              },
            }),
            409,
          );
        }),
      );
      expect(calls, 1);
    },
  );

  test(
    'installation credential survives preference cleanup and failed login',
    () async {
      final original = await MobileLoginDevice.key();
      await (await SharedPreferences.getInstance()).clear();
      expect(await MobileLoginDevice.key(), original);
      await http.runWithClient(() async {
        await LoginApi.login(user, 'wrong');
        expect(await MobileLoginDevice.key(), original);
      }, () => MockClient((_) async => http.Response('{}', 401)));
    },
  );

  test(
    'old backend and incomplete token responses cannot enter the app',
    () async {
      for (final response in [
        loggedIn(guarded: false),
        loggedIn(token: null),
      ]) {
        await http.runWithClient(() async {
          final result = await LoginApi.login(user, 'password');
          expect(result['error'], isNotNull);
          expect(await SessionAuthApi.getSessionId(), isNull);
        }, () => MockClient((_) async => response));
      }
    },
  );

  test(
    'logout releases remembered binding even after local SID was cleared',
    () async {
      var releases = 0;
      await http.runWithClient(
        () async {
          await LoginApi.login(user, 'password');
          await SessionAuthApi.clearSession();
          await SessionAuthApi.logout();
          expect(await SessionAuthApi.getSessionId(), isNull);
          expect(
            (await SharedPreferences.getInstance()).getString('token'),
            isNull,
          );
        },
        () => MockClient((request) async {
          if (request.url.path == '$api.mobile_logout') {
            releases++;
            expect(request.headers['Cookie'], isNull);
            expect(request.headers['Authorization'], isNull);
            expect((jsonDecode(request.body) as Map)['user'], user);
            return loggedOut();
          }
          return request.method == 'POST'
              ? loggedIn()
              : http.Response(jsonEncode({'message': user}), 200);
        }),
      );
      expect(releases, 1);
    },
  );

  test(
    'failed logout retains recovery across local cleanup and retries before login',
    () async {
      var failLogout = true;
      final paths = <String>[];
      await http.runWithClient(
        () async {
          await LoginApi.login(user, 'password');
          await expectLater(SessionAuthApi.logout(), throwsStateError);
          expect(await SessionAuthApi.getSessionId(), 'mobile-sid');
          // Match face enrollment's emergency local-only sign-out.
          await SessionAuthApi.clearSession();
          await (await SharedPreferences.getInstance()).clear();
          paths.clear();
          final failed = await LoginApi.login(user, 'password');
          expect(failed['error'], isNotNull);
          expect(paths, ['$api.mobile_logout']);
          failLogout = false;
          paths.clear();
          final result = await LoginApi.login(user, 'password');
          expect(result['error'], isNull);
          expect(paths, [
            '$api.mobile_logout',
            '$api.login',
            '/api/method/frappe.auth.get_logged_user',
          ]);
        },
        () => MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '$api.mobile_logout') {
            return failLogout ? http.Response('{}', 503) : loggedOut();
          }
          return request.method == 'POST'
              ? loggedIn()
              : http.Response(jsonEncode({'message': user}), 200);
        }),
      );
    },
  );

  test('same installation retries use the same credential', () async {
    final keys = <String>[];
    await http.runWithClient(
      () async {
        expect((await LoginApi.login(user, 'password'))['error'], isNull);
        expect((await LoginApi.login(user, 'password'))['error'], isNull);
      },
      () => MockClient((request) async {
        if (request.method == 'POST') {
          keys.add((jsonDecode(request.body) as Map)['device_key'] as String);
          return loggedIn();
        }
        return http.Response(jsonEncode({'message': user}), 200);
      }),
    );
    expect(keys.length, 2);
    expect(keys[0], keys[1]);
  });
}
