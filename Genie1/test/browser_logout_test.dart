@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/mobile_login_device.dart';
import 'package:homegenie/utils/api/session_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = 'staff@example.test';
const _pending = 'genie_pending_mobile_logout';
const _active = 'genie_active_mobile_binding';
const _storage = FlutterSecureStorage();
final _endpoint = Uri.parse(
  'https://erp.example.test/api/method/itgenie.api_utils.mobile_logout',
);
http.Response _success() =>
    http.Response('{"message":{"status":"success"}}', 200);
http.Response _csrf() => http.Response('{"exc_type":"CSRFTokenError"}', 400);

class _RedirectResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _RedirectResponse()
    : super(
        Stream.value(utf8.encode('frappe.csrf_token = "foreign-token";')),
        200,
      );
  @override
  final url = Uri.parse('https://other.example.test/app');
}

class _ForeignBootstrapClient extends http.BaseClient {
  final _client = MockClient((_) async => _csrf());
  int posts = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET') return _RedirectResponse();
    posts++;
    return _client.send(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'session_sid': 'browser-marker',
      'session_username': _user,
      'single_device_login': true,
      'token': 'token test:secret',
    });
    FlutterSecureStorage.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test/');
    await MobileLoginDevice.rememberSession(_endpoint, _user);
  });

  Future<void> expectRetained() async {
    expect(await _storage.read(key: _pending), isNotNull);
    expect(await _storage.read(key: _active), isNotNull);
    expect(await SessionAuthApi.getSessionId(), 'browser-marker');
    expect(
      (await SharedPreferences.getInstance()).getString('token'),
      'token test:secret',
    );
  }

  test(
    'browser CSRF rejection bootstraps the session and retries once before clearing credentials',
    () async {
      var posts = 0;
      var bootstraps = 0;
      final key = await MobileLoginDevice.key();
      await http.runWithClient(
        () => SessionAuthApi.logout(),
        () => MockClient((request) async {
          if (request.method == 'GET') {
            bootstraps++;
            expect(request.url.toString(), 'https://erp.example.test/app');
            expect(request.headers['Accept'], 'text/html');
            expect(request.url.toString(), isNot(contains(key)));
            return http.Response('frappe.csrf_token = "logout-csrf";', 200);
          }
          posts++;
          expect(request.url, _endpoint);
          expect(request.followRedirects, false);
          final data = jsonDecode(request.body);
          expect(data['user'], _user);
          expect(data['device_key'], key);
          expect(request.headers['Cookie'], isNull);
          expect(request.headers['Authorization'], isNull);
          if (posts == 1) {
            expect(data.containsKey('csrf_token'), false);
            return _csrf();
          }
          expect(data['csrf_token'], 'logout-csrf');
          expect(request.headers['X-Frappe-CSRF-Token'], 'logout-csrf');
          expect(await SessionAuthApi.getSessionId(), 'browser-marker');
          return _success();
        }),
      );
      expect(posts, 2);
      expect(bootstraps, 1);
      expect(await SessionAuthApi.getSessionId(), isNull);
      expect(
        (await SharedPreferences.getInstance()).getString('token'),
        isNull,
      );
      expect(await _storage.read(key: _pending), isNull);
      expect(await _storage.read(key: _active), isNull);
      expect(await MobileLoginDevice.key(), key);
    },
  );

  test(
    'expired-session device release succeeds without requiring a CSRF bootstrap',
    () async {
      var calls = 0;
      await http.runWithClient(
        () => SessionAuthApi.logout(),
        () => MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          return _success();
        }),
      );
      expect(calls, 1);
    },
  );

  for (final status in [403, 404, 500]) {
    test(
      'HTTP $status retains credentials and pending recovery without automatic retry',
      () async {
        var calls = 0;
        await http.runWithClient(
          () async {
            await expectLater(
              SessionAuthApi.logout(),
              throwsA(
                isA<StateError>().having(
                  (error) => error.message,
                  'safe status detail',
                  contains('HTTP $status'),
                ),
              ),
            );
          },
          () => MockClient((request) async {
            calls++;
            expect(request.method, 'POST');
            return http.Response('{"exc_type":"OtherError"}', status);
          }),
        );
        expect(calls, 1);
        await expectRetained();
      },
    );
  }

  test('a second CSRF rejection is not retried and retains recovery', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await expectLater(SessionAuthApi.logout(), throwsStateError);
      },
      () => MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response('frappe.csrf_token = "new-token";', 200);
        }
        posts++;
        return _csrf();
      }),
    );
    expect(posts, 2);
    await expectRetained();
  });

  test(
    'bootstrap without a token prevents the second release request',
    () async {
      var posts = 0;
      await http.runWithClient(
        () async {
          await expectLater(SessionAuthApi.logout(), throwsStateError);
        },
        () => MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response('<html>Sign in</html>', 200);
          }
          posts++;
          return _csrf();
        }),
      );
      expect(posts, 1);
      await expectRetained();
    },
  );

  test(
    'foreign-origin CSRF bootstrap is rejected before another release',
    () async {
      final client = _ForeignBootstrapClient();
      await http.runWithClient(() async {
        await expectLater(SessionAuthApi.logout(), throwsStateError);
      }, () => client);
      expect(client.posts, 1);
      await expectRetained();
    },
  );

  test(
    'network timeout does not automatically retry or remove credentials',
    () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await expectLater(
            SessionAuthApi.logout(),
            throwsA(isA<TimeoutException>()),
          );
        },
        () => MockClient((_) async {
          calls++;
          throw TimeoutException('Test timeout');
        }),
      );
      expect(calls, 1);
      await expectRetained();
    },
  );
}
