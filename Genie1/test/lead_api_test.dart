import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/lead_api.dart';
import 'package:homegenie/utils/lead_phone_number.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response options({String? token}) => http.Response(
  jsonEncode({
    'message': {
      'lead_owner': 'sales@example.test',
      'lead_owner_name': 'Sales',
      'source_options': ['Website'],
      'product_category_options': ['Doors'],
      'csrf_token': token,
    },
  }),
  200,
);

http.Response created() => http.Response(
  jsonEncode({
    'message': {'status': 'success', 'name': 'LEAD-1'},
  }),
  200,
);

Future<Map<String, dynamic>> submit({String token = ''}) => LeadApi.createLead(
  firstName: ' Customer & Co ',
  mobileNo: ' +91 9876543210 ',
  whatsappNo: '+91 9876543210',
  requirement: ' Doors & windows ',
  source: ' Website ',
  productCategory: ' Doors ',
  address: ' Chennai ',
  csrfToken: token,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'session_sid': 'lead-session'});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });

  test('WhatsApp validation accepts formatted phone numbers', () {
    for (final value in [
      '9876543210',
      '+91 (98765) 43210',
      '1234567',
      '+123456789012345',
    ]) {
      expect(LeadPhoneNumber.validateWhatsApp(value), isNull);
    }
    expect(LeadPhoneNumber.normalize('+91 (98765) 43210'), '+919876543210');
  });

  test('invalid WhatsApp is rejected before any request', () async {
    var calls = 0;
    await http.runWithClient(
      () async {
        for (final value in [
          '',
          '   ',
          '123',
          '987abc6543210',
          '++919876543210',
          '+0123456789',
          '+1234567890123456',
        ]) {
          expect(LeadPhoneNumber.validateWhatsApp(value), isNotNull);
          await expectLater(
            LeadApi.createLead(
              firstName: 'Customer',
              mobileNo: '9876543210',
              requirement: 'Doors',
              source: 'Website',
              productCategory: 'Doors',
              address: 'Chennai',
              csrfToken: 'token',
              whatsappNo: value,
            ),
            throwsFormatException,
          );
        }
      },
      () => MockClient((_) async {
        calls++;
        return created();
      }),
    );
    expect(calls, 0);
  });

  test('uses form token and the exact API field names and encoding', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        final form = await LeadApi.getFormOptions();
        expect(form.sourceOptions, ['Website']);
        expect(form.productCategoryOptions, ['Doors']);
        expect((await submit(token: form.csrfToken!))['name'], 'LEAD-1');
      },
      () => MockClient((request) async {
        expect(request.url.path, '/api/method/create_lead_from_mobile');
        expect(request.headers['Cookie'], 'sid=lead-session');
        if (request.method == 'GET') return options(token: 'form-token');
        posts++;
        expect(request.headers['X-Frappe-CSRF-Token'], 'form-token');
        expect(request.bodyFields, {
          'first_name': 'Customer & Co',
          'mobile_no': '+91 9876543210',
          'whatsapp_no': '+919876543210',
          'custom_requirement': 'Doors & windows',
          'custom_source': 'Website',
          'custom_product_enquired': 'Doors',
          'custom_address': 'Chennai',
          'csrf_token': 'form-token',
        });
        return created();
      }),
    );
    expect(posts, 1);
  });

  test(
    'initializes a missing token with the same authenticated session',
    () async {
      final paths = <String>[];
      await http.runWithClient(
        () async {
          await LeadApi.getFormOptions();
          await submit();
        },
        () => MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['Cookie'], 'sid=lead-session');
          if (request.url.path == '/app') {
            expect(request.followRedirects, isFalse);
            return http.Response(
              "frappe.csrf_token = 'initialized-token';",
              200,
            );
          }
          if (request.method == 'GET') return options();
          expect(request.headers['X-Frappe-CSRF-Token'], 'initialized-token');
          return created();
        }),
      );
      expect(paths, [
        '/api/method/create_lead_from_mobile',
        '/app',
        '/api/method/create_lead_from_mobile',
      ]);
    },
  );

  test(
    'refreshes explicit CSRF rejection once and reuses the fresh token',
    () async {
      final tokens = <String?>[];
      var deskCalls = 0;
      await http.runWithClient(
        () async {
          await LeadApi.getFormOptions();
          await submit(token: 'old-token');
          await submit(token: 'old-token');
        },
        () => MockClient((request) async {
          if (request.url.path == '/app') {
            deskCalls++;
            return http.Response('frappe.csrf_token = "fresh-token";', 200);
          }
          if (request.method == 'GET') return options(token: 'old-token');
          tokens.add(request.bodyFields['csrf_token']);
          if (tokens.length == 1) {
            return http.Response(
              jsonEncode({'exc_type': 'CSRFTokenError'}),
              400,
            );
          }
          return created();
        }),
      );
      expect(tokens, ['old-token', 'fresh-token', 'fresh-token']);
      expect(deskCalls, 1);
    },
  );

  for (final failure in ['validation', 'timeout', 'csrf']) {
    test('does not repeatedly submit after $failure failure', () async {
      var posts = 0;
      await http.runWithClient(
        () async {
          await LeadApi.getFormOptions();
          await expectLater(
            submit(token: 'form-token'),
            throwsA(
              failure == 'timeout'
                  ? isA<TimeoutException>()
                  : isA<StateError>(),
            ),
          );
        },
        () => MockClient((request) async {
          if (request.url.path == '/app') {
            return http.Response('frappe.csrf_token = "fresh-token";', 200);
          }
          if (request.method == 'GET') return options(token: 'form-token');
          posts++;
          if (failure == 'timeout') throw TimeoutException('Connection lost');
          if (failure == 'csrf') {
            return http.Response(
              jsonEncode({'exc_type': 'CSRFTokenError'}),
              400,
            );
          }
          return http.Response(
            jsonEncode({
              '_server_messages': jsonEncode([
                jsonEncode({'message': 'Phone Number is required.'}),
              ]),
            }),
            417,
          );
        }),
      );
      expect(posts, failure == 'csrf' ? 2 : 1);
    });
  }

  test('rejects a different session after the form was loaded', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await LeadApi.getFormOptions();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('session_sid', 'other-session');
        await expectLater(submit(token: 'form-token'), throwsStateError);
      },
      () => MockClient((request) async {
        if (request.method == 'POST') posts++;
        return options(token: 'form-token');
      }),
    );
    expect(posts, 0);
  });

  test(
    'does not send session cookies to a different origin on redirect',
    () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await LeadApi.getFormOptions();
          await expectLater(submit(), throwsStateError);
        },
        () => MockClient((request) async {
          calls++;
          expect(request.url.host, 'erp.example.test');
          if (request.url.path == '/app') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://other.example.test/app'},
            );
          }
          return options();
        }),
      );
      expect(calls, 2);
    },
  );

  test('requires confirmation before reporting creation success', () async {
    await http.runWithClient(
      () async {
        await LeadApi.getFormOptions();
        await expectLater(submit(token: 'form-token'), throwsStateError);
      },
      () => MockClient(
        (request) async =>
            request.method == 'GET'
                ? options(token: 'form-token')
                : http.Response(
                  jsonEncode({
                    'message': {'status': 'error'},
                  }),
                  200,
                ),
      ),
    );
  });
}
