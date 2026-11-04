import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/opportunity_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const opportunityUser = 'creator@example.test';
Map<String, dynamic> opportunity({
  String owner = 'other.creator@example.test',
  String? opportunityOwner = opportunityUser,
}) => {
  'name': 'OPP-1',
  'owner': owner,
  'opportunity_owner': opportunityOwner,
  'customer_name': 'Customer One',
  'status': 'Open',
  'custom_requirement': 'Office doors',
  'items': [
    {'item_code': 'DOOR-1', 'qty': 2},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': opportunityUser,
    });
  });

  MockClient client(Future<http.Response> Function(http.Request) resource) =>
      MockClient((request) async {
        expect(request.headers['Cookie'], 'sid=sid');
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': opportunityUser}), 200);
        }
        expect(request.followRedirects, isFalse);
        return resource(request);
      });

  test(
    'Home count uses the centralized permitted Opportunity visibility without a page cap',
    () async {
      await http.runWithClient(
        () async {
          expect(await OpportunityApi.getMyOpportunityCount(), 1251);
        },
        () => client((request) async {
          expect(request.url.path, '/api/method/mobile_opportunity_policy');
          expect(request.url.queryParameters['action'], 'count');
          return http.Response(
            jsonEncode({
              'message': {'current_user': opportunityUser, 'count': 1251},
            }),
            200,
          );
        }),
      );
    },
  );

  test(
    'list filters by Opportunity Owner and includes records created by others',
    () async {
      await http.runWithClient(
        () async {
          expect(
            await OpportunityApi.getMyOpportunities(offset: 50),
            hasLength(1),
          );
        },
        () => client((request) async {
          expect(request.url.path, '/api/resource/Opportunity');
          expect(jsonDecode(request.url.queryParameters['filters']!), [
            ['opportunity_owner', '=', opportunityUser],
          ]);
          expect(request.url.queryParameters['limit_start'], '50');
          expect(request.url.queryParameters['limit_page_length'], '50');
          expect(
            jsonDecode(request.url.queryParameters['fields']!),
            isNot(contains('*')),
          );
          return http.Response(
            jsonEncode({
              'data': [opportunity()],
            }),
            200,
          );
        }),
      );
    },
  );

  test('detail retains custom fields and child rows', () async {
    await http.runWithClient(
      () async {
        final result = await OpportunityApi.getDetails('OPP-1');
        expect(result['custom_requirement'], 'Office doors');
        expect(result['items'][0]['qty'], 2);
        expect(result['owner'], 'other.creator@example.test');
        expect(result['opportunity_owner'], opportunityUser);
      },
      () => client((request) async {
        expect(request.url.path, '/api/resource/Opportunity/OPP-1');
        return http.Response(jsonEncode({'data': opportunity()}), 200);
      }),
    );
  });

  test(
    'Lead link lookup uses exact relation and retains owner and pagination',
    () async {
      await http.runWithClient(
        () async => expect(
          await OpportunityApi.getForLead('LEAD-1', offset: 50),
          hasLength(1),
        ),
        () => client((request) async {
          expect(jsonDecode(request.url.queryParameters['filters']!), [
            ['opportunity_owner', '=', opportunityUser],
            ['opportunity_from', '=', 'Lead'],
            ['party_name', '=', 'LEAD-1'],
          ]);
          expect(request.url.queryParameters['limit_start'], '50');
          expect(request.url.queryParameters['limit_page_length'], '50');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  ...opportunity(),
                  'opportunity_from': 'Lead',
                  'party_name': 'LEAD-1',
                },
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  for (final relation in [
    {'opportunity_from': 'Lead', 'party_name': 'OTHER-LEAD'},
    {'opportunity_from': 'Customer', 'party_name': 'LEAD-1'},
  ]) {
    test('Lead lookup rejects mismatched relation $relation', () async {
      await http.runWithClient(
        () async =>
            expectLater(OpportunityApi.getForLead('LEAD-1'), throwsStateError),
        () => client(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {...opportunity(), ...relation},
              ],
            }),
            200,
          ),
        ),
      );
    });
  }

  for (final details in [false, true]) {
    for (final assignedUser in ['other@example.test', '', null]) {
      test(
        'rejects Opportunity Owner $assignedUser in ${details ? 'details' : 'list'} even for the creator',
        () async {
          await http.runWithClient(
            () async {
              await expectLater(
                details
                    ? OpportunityApi.getDetails('OPP-1')
                    : OpportunityApi.getMyOpportunities(),
                throwsStateError,
              );
            },
            () => client((request) async {
              final row = opportunity(
                owner: opportunityUser,
                opportunityOwner: assignedUser,
              );
              return http.Response(
                jsonEncode({
                  'data': details ? row : [row],
                }),
                200,
              );
            }),
          );
        },
      );
    }
  }

  test('account switch during request discards response', () async {
    await http.runWithClient(
      () async {
        await expectLater(
          OpportunityApi.getMyOpportunities(),
          throwsStateError,
        );
      },
      () => client((request) async {
        await (await SharedPreferences.getInstance()).setString(
          'session_username',
          'other@example.test',
        );
        return http.Response(
          jsonEncode({
            'data': [opportunity()],
          }),
          200,
        );
      }),
    );
  });

  for (final status in [302, 401, 403, 404, 500]) {
    test('HTTP $status does not expose records or follow redirects', () async {
      var requests = 0;
      await http.runWithClient(
        () async {
          await expectLater(
            OpportunityApi.getDetails('OPP-1'),
            throwsStateError,
          );
        },
        () => client((request) async {
          requests++;
          return http.Response(
            '',
            status,
            headers: {'location': 'https://other.example.test'},
          );
        }),
      );
      expect(requests, 1);
    });
  }

  test('signed out request never queries opportunities', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await http.runWithClient(
      () async {
        await expectLater(
          OpportunityApi.getMyOpportunities(),
          throwsStateError,
        );
      },
      () => MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(calls, 0);
  });

  test('rejects malformed server data', () async {
    await http.runWithClient(() async {
      await expectLater(
        OpportunityApi.getMyOpportunities(),
        throwsFormatException,
      );
    }, () => client((request) async => http.Response('unexpected HTML', 200)));
  });
}
