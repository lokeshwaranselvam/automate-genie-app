import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/smartflo_call_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const opportunity = {
  'name': 'OPP-1',
  'doctype': 'Opportunity',
  'owner': 'creator@example.test',
  'contact_mobile': '9876543210',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': 'creator@example.test',
    });
  });

  Future<void> call(
    Future<http.Response> Function(http.Request) post, {
    Map<String, dynamic> doc = opportunity,
    String number = '9876543210',
    String? redirect,
  }) => http.runWithClient(
    () => SmartfloCallApi.initiateCall(opportunity: doc, number: number),
    () => MockClient((request) async {
      if (request.url.path.endsWith('get_logged_user')) {
        return http.Response('{"message":"creator@example.test"}', 200);
      }
      if (request.url.path == '/app') {
        if (redirect != null) {
          return http.Response('', 302, headers: {'location': redirect});
        }
        return http.Response('frappe.csrf_token = "csrf";', 200);
      }
      return post(request);
    }),
  );

  test(
    'posts exact doc and number arguments under the current session',
    () async {
      var posts = 0;
      await call((request) async {
        posts++;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/method/smartflo.api.initiate_call');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Cookie'], 'sid=sid');
        expect(request.headers['X-Frappe-CSRF-Token'], 'csrf');
        final body = jsonDecode(request.body) as Map;
        expect(body['doc'], opportunity);
        expect(body['number'], '9876543210');
        return http.Response('{"message":{"success":true}}', 200);
      });
      expect(posts, 1);
    },
  );

  test(
    'provider failure and Frappe permission failure do not report success',
    () async {
      await expectLater(
        call(
          (_) async => http.Response(
            '{"message":{"success":false,"message":"Agent unavailable"}}',
            200,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Agent unavailable',
          ),
        ),
      );
      await expectLater(
        call((_) async => http.Response('{}', 403)),
        throwsStateError,
      );
      await expectLater(
        call((_) async => http.Response('{"message":null}', 200)),
        throwsStateError,
      );
    },
  );

  test('timeout submits once and never automatically repeats a call', () async {
    var posts = 0;
    await expectLater(
      call((_) async {
        posts++;
        throw TimeoutException('Call response timed out');
      }),
      throwsA(isA<TimeoutException>()),
    );
    expect(posts, 1);
  });

  test(
    'different owner, unrelated phone and invalid number never submit',
    () async {
      for (final doc in [
        {...opportunity, 'owner': 'other@example.test'},
        {...opportunity, 'contact_mobile': '1234567890'},
      ]) {
        await expectLater(
          call((_) async => throw StateError('Must not POST'), doc: doc),
          throwsStateError,
        );
      }
      await expectLater(
        call((_) async => throw StateError('Must not POST'), number: 'invalid'),
        throwsStateError,
      );
    },
  );

  test(
    'CSRF bootstrap never sends credentials or calls to another site',
    () async {
      var posts = 0;
      await expectLater(
        call((_) async {
          posts++;
          return http.Response('{}', 200);
        }, redirect: 'https://other.example/app'),
        throwsStateError,
      );
      expect(posts, 0);
    },
  );
}
