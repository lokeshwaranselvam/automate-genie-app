import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Map<String, bool>> verifyEventBrowserCsrf() async {
  final results = <String, bool>{};
  for (final checkout in [false, true]) {
    for (final scenario in ['success', 'csrf', 'validation', 'timeout', 'session-change']) {
      SharedPreferences.setMockInitialValues({
        'session_sid': 'browser-generation', 'token': 'token key:secret',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/test.api');
      var gets = 0, posts = 0, preparations = 0;
      var valid = true, threw = false;
      await http.runWithClient(() async {
        try {
          if (checkout) {
            await Event.eventCheckout('user@example.test', 'EVENT-1', 13, 80,
              'GPS address', '01:00', '0', '', '[]', _UnusedContext(),
              beforeCheckout: () async { preparations++; return true; });
          } else {
            await Event.eventCheckin('user@example.test', 'EVENT-1', 13, 80,
              'GPS address', _UnusedContext());
          }
        } catch (_) { threw = true; }
      }, () => MockClient((request) async {
        if (request.method == 'GET') {
          gets++;
          valid = valid && request.url.path == '/app';
          if (scenario == 'session-change') {
            await (await SharedPreferences.getInstance()).setString('session_sid', 'new-generation');
          }
          return http.Response('frappe.csrf_token = "csrf$gets";', 200);
        }
        posts++;
        valid = valid && request.url.path.endsWith(checkout ? '.event_checkout' : '.event_checkin') &&
          request.headers['X-Frappe-CSRF-Token'] == 'csrf$gets' &&
          request.headers['Authorization'] == 'token key:secret' &&
          !request.headers.containsKey('Cookie') &&
          request.bodyFields['csrf_token'] == 'csrf$gets' &&
          request.bodyFields['event_id'] == 'EVENT-1' &&
          request.bodyFields['address'] == 'GPS address';
        if (scenario == 'timeout') throw TimeoutException('uncertain response');
        if (posts == 1 && ['csrf', 'validation'].contains(scenario)) {
          return http.Response(jsonEncode({'exc_type': scenario == 'csrf' ? 'CSRFTokenError' : 'ValidationError'}), 400);
        }
        return http.Response('{"message":{"status":"success","message":"Saved"}}', 200);
      }));
      final expectedPosts = scenario == 'csrf' ? 2 : scenario == 'session-change' ? 0 : 1;
      results['${checkout ? "checkout" : "checkin"}:$scenario'] = valid &&
        gets == (scenario == 'csrf' ? 2 : 1) && posts == expectedPosts &&
        preparations == (checkout ? 1 : 0) &&
        threw == ['timeout', 'session-change'].contains(scenario);
    }
  }
  return results;
}
