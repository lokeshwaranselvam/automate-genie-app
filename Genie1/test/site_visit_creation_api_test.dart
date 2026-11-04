import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/site_visit_creation_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'sales@example.test';
var sessionNumber = 0;

http.Response success(Map<String, dynamic> fields) => http.Response(
  jsonEncode({
    'message': {'status': 'success', 'current_user': user, ...fields},
  }),
  200,
);

http.Response options({String? token}) => success({
  'opportunities': [],
  'product_enquired_options': [],
  'event_categories': ['Installation'],
  'location_types': ['Site'],
  'users': [],
  if (token != null) 'csrf_token': token,
});

Future<Map<String, dynamic>> saveLocation() =>
    SiteVisitCreationApi.saveLocation(
      opportunity: 'OPP-1',
      mapLink: 'https://maps.google.com/?q=13,80',
      latitude: 13,
      longitude: 80,
      locationType: 'Site',
    );

Future<Map<String, dynamic>> createEvent() => SiteVisitCreationApi.createEvent(
  opportunity: 'OPP-1',
  locationRow: 'LOC-1',
  summary: 'Customer visit',
  startsOn: '2026-10-14 10:00:00',
  endsOn: '2026-10-14 10:30:00',
  assignedTo: user,
  category: 'Site Visit',
  productEnquired: "D'sign Doors",
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'session_sid': 'visit-session-${++sessionNumber}',
      'session_username': user,
    });
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });

  test(
    'Opportunity ID search sends authenticated query and preserves Opportunity identity',
    () async {
      await http.runWithClient(
        () async {
          final rows = await SiteVisitCreationApi.searchOpportunities(
            ' 28718 ',
          );
          expect(rows.single['name'], 'CRM-OPP-2026-28718');
          expect(rows.single['contact_mobile'], '9873823617');
        },
        () => MockClient((request) async {
          expect(request.url.path, '/api/method/mobile_site_visit');
          expect(request.url.queryParameters, {
            'action': 'search_opportunities',
            'query': '28718',
          });
          expect(request.headers['cookie'], 'sid=visit-session-$sessionNumber');
          return success({
            'opportunities': [
              {
                'name': 'CRM-OPP-2026-28718',
                'title': 'Ankit',
                'party_name': 'CRM-LEAD-2026-50209',
                'contact_mobile': '9873823617',
              },
            ],
          });
        }),
      );
    },
  );

  test(
    'Opportunity search rejects responses from another session user',
    () async {
      await http.runWithClient(
        () async {
          await expectLater(
            SiteVisitCreationApi.searchOpportunities('28718'),
            throwsA(isA<FormatException>()),
          );
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'message': {
                'status': 'success',
                'current_user': 'another@example.test',
                'opportunities': [],
              },
            }),
            200,
          ),
        ),
      );
    },
  );

  test(
    'creation capability is session-bound and requires explicit server approval',
    () async {
      for (final allowed in [true, false, null, 'true']) {
        await http.runWithClient(
          () async {
            expect(
              await SiteVisitCreationApi.canCreateVisit(),
              allowed == true,
            );
          },
          () => MockClient((request) async {
            expect(request.url.queryParameters['action'], 'can_create');
            expect(
              request.headers['cookie'],
              'sid=visit-session-$sessionNumber',
            );
            return success({'can_create': allowed});
          }),
        );
      }
    },
  );

  test('capability rejects a different signed-in user', () async {
    await http.runWithClient(
      () async {
        await expectLater(
          SiteVisitCreationApi.canCreateVisit(),
          throwsFormatException,
        );
      },
      () => MockClient(
        (_) async =>
            success({'current_user': 'other@example.test', 'can_create': true}),
      ),
    );
  });

  test(
    'missing token is initialized before saving and retained for event',
    () async {
      final posts = <http.Request>[];
      var deskRequests = 0;
      await http.runWithClient(
        () async {
          await SiteVisitCreationApi.loadOptions();
          final location = await saveLocation();
          expect(location['location_row'], 'LOC-1');
          final event = await createEvent();
          expect(event['event'], 'EVENT-1');
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response(jsonEncode({'message': user}), 200);
          }
          if (request.url.path == '/app') {
            deskRequests++;
            return http.Response('frappe.csrf_token = "desk-token";', 200);
          }
          if (request.method == 'GET') return options();
          posts.add(request);
          expect(request.headers['X-Frappe-CSRF-Token'], 'desk-token');
          expect(request.bodyFields['csrf_token'], 'desk-token');
          expect(request.headers['Cookie'], 'sid=visit-session-$sessionNumber');
          return request.bodyFields['action'] == 'save_location'
              ? success({'location_row': 'LOC-1'})
              : success({'event': 'EVENT-1'});
        }),
      );
      expect(deskRequests, 1);
      expect(posts.first.bodyFields, {
        'action': 'save_location',
        'opportunity': 'OPP-1',
        'map_link': 'https://maps.google.com/?q=13,80',
        'latitude': '13.0',
        'longitude': '80.0',
        'location_type': 'Site',
        'csrf_token': 'desk-token',
      });
      expect(posts.last.bodyFields, {
        'action': 'create_event',
        'opportunity': 'OPP-1',
        'location_row': 'LOC-1',
        'summary': 'Customer visit',
        'starts_on': '2026-10-14 10:00:00',
        'ends_on': '2026-10-14 10:30:00',
        'assigned_to': user,
        'category': 'Site Visit',
        'product_enquired': "D'sign Doors",
        'csrf_token': 'desk-token',
      });
    },
  );

  for (final submit in [saveLocation, createEvent]) {
    test(
      '${submit == saveLocation ? 'location' : 'event'} refreshes explicit CSRF rejection once',
      () async {
        final tokens = <String?>[];
        await http.runWithClient(
          () async {
            await SiteVisitCreationApi.loadOptions();
            await submit();
          },
          () => MockClient((request) async {
            if (request.url.path.endsWith('get_logged_user')) {
              return http.Response(jsonEncode({'message': user}), 200);
            }
            if (request.url.path == '/app') {
              return http.Response("frappe.csrf_token = 'fresh-token';", 200);
            }
            if (request.method == 'GET') return options(token: 'old-token');
            tokens.add(request.bodyFields['csrf_token']);
            if (tokens.length == 1) {
              return http.Response(
                jsonEncode({
                  'exc_type': 'CSRFTokenError',
                  'exception':
                      'frappe.exceptions.CSRFTokenError: Invalid Request',
                }),
                400,
              );
            }
            return success({'location_row': 'LOC-1', 'event': 'EVENT-1'});
          }),
        );
        expect(tokens, ['old-token', 'fresh-token']);
      },
    );
  }

  test('mobile search without a token preserves the form token', () async {
    await http.runWithClient(
      () async {
        await SiteVisitCreationApi.loadOptions();
        await SiteVisitCreationApi.searchByMobile('98765');
        await saveLocation();
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': user}), 200);
        }
        if (request.method == 'POST') {
          expect(request.bodyFields['csrf_token'], 'form-token');
          return success({'location_row': 'LOC-1'});
        }
        expect(request.url.path, '/api/method/mobile_site_visit');
        return request.url.queryParameters['action'] == 'search_by_mobile'
            ? success({'opportunities': []})
            : options(token: 'form-token');
      }),
    );
  });

  test('validation errors are displayed without retrying the write', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await SiteVisitCreationApi.loadOptions();
        await expectLater(
          saveLocation(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Choose a valid location type.',
            ),
          ),
        );
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': user}), 200);
        }
        if (request.method == 'GET') return options(token: 'form-token');
        posts++;
        return http.Response(
          jsonEncode({
            '_server_messages': jsonEncode([
              jsonEncode({'message': 'Choose a valid location type.'}),
            ]),
            'exc_type': 'ValidationError',
          }),
          417,
        );
      }),
    );
    expect(posts, 1);
  });

  test('direct Event sends no destination fields', () async {
    await http.runWithClient(
      () async {
        await SiteVisitCreationApi.loadOptions();
        await SiteVisitCreationApi.createEvent(
          opportunity: '',
          locationRow: '',
          summary: 'Bank visit',
          startsOn: '2026-10-24 10:00:00',
          endsOn: '2026-10-24 10:30:00',
          assignedTo: user,
          category: 'Bank',
        );
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': user}), 200);
        }
        if (request.method == 'GET') return options(token: 'form-token');
        expect(request.bodyFields, containsPair('action', 'create_event'));
        expect(request.bodyFields, containsPair('opportunity', ''));
        expect(request.bodyFields, containsPair('location_row', ''));
        expect(request.bodyFields, containsPair('category', 'Bank'));
        for (final key in [
          'latitude',
          'longitude',
          'location_type',
          'map_link',
        ]) {
          expect(request.bodyFields, isNot(contains(key)));
        }
        expect(request.bodyFields, isNot(contains('product_enquired')));
        return success({'event': 'EVENT-1'});
      }),
    );
  });

  test('session change discards the previous session token', () async {
    await http.runWithClient(
      () async {
        await SiteVisitCreationApi.loadOptions();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('session_sid', 'replacement-session');
        await saveLocation();
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': user}), 200);
        }
        if (request.url.path == '/app') {
          expect(request.headers['Cookie'], 'sid=replacement-session');
          return http.Response('frappe.csrf_token = "replacement-token";', 200);
        }
        if (request.method == 'GET') return options(token: 'previous-token');
        expect(request.bodyFields['csrf_token'], 'replacement-token');
        return success({'location_row': 'LOC-1'});
      }),
    );
  });

  test('token bootstrap refuses to send the session to another site', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await SiteVisitCreationApi.loadOptions();
        await expectLater(saveLocation(), throwsA(isA<StateError>()));
      },
      () => MockClient((request) async {
        expect(request.url.host, 'erp.example.test');
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': user}), 200);
        }
        if (request.url.path == '/app') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://other.example.test/app'},
          );
        }
        if (request.method == 'POST') posts++;
        return options();
      }),
    );
    expect(posts, 0);
  });
}
