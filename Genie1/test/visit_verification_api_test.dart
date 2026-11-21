import 'dart:convert';
import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/visit_verification_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'email': 'fe@test',
      'token': 'token test',
    });
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });
  test('policy is authenticated and belongs to current user', () async {
    await http.runWithClient(
      () async {
        expect((await VisitVerificationApi.policy())['visible'], true);
      },
      () => MockClient((request) async {
        expect(request.headers['Authorization'], 'token test');
        expect(request.bodyFields, {'action': 'verification_policy'});
        return http.Response(
          jsonEncode({
            'message': {
              'verification_policy': {
                'current_user': 'fe@test',
                'visible': true,
              },
            },
          }),
          200,
        );
      }),
    );
  });
  test(
    'state batches run concurrently with at most three requests in flight',
    () async {
      final responses = <Completer<http.Response>>[];
      var active = 0;
      var maximum = 0;
      await http.runWithClient(
        () async {
          final future = VisitVerificationApi.states(
            List.generate(151, (i) => 'E$i'),
          );
          await Future<void>.delayed(Duration.zero);
          expect(responses.length, 3);
          for (final response in responses.toList()) {
            response.complete(http.Response('{"message":{"events":[]}}', 200));
          }
          await Future<void>.delayed(Duration.zero);
          expect(responses.length, 4);
          responses.last.complete(
            http.Response('{"message":{"events":[]}}', 200),
          );
          await future;
          expect(maximum, 3);
        },
        () => MockClient((request) async {
          final response = Completer<http.Response>();
          responses.add(response);
          active++;
          if (active > maximum) maximum = active;
          final result = await response.future;
          active--;
          return result;
        }),
      );
    },
  );
  test('reject policy for another account', () async {
    await http.runWithClient(
      () async {
        await expectLater(VisitVerificationApi.policy(), throwsStateError);
      },
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'message': {
              'verification_policy': {
                'current_user': 'other@test',
                'visible': true,
              },
            },
          }),
          200,
        ),
      ),
    );
  });
  test('states uses bounded batches and ignores unrequested events', () async {
    var requests = 0;
    await http.runWithClient(
      () async {
        final states = await VisitVerificationApi.states(
          List.generate(51, (i) => 'E$i'),
        );
        expect(requests, 2);
        expect(states.keys, containsAll(['E0', 'E50']));
        expect(states.containsKey('OTHER'), false);
      },
      () => MockClient((request) async {
        requests++;
        final ids = jsonDecode(request.bodyFields['event_ids']!) as List;
        expect(ids.length, lessThanOrEqualTo(50));
        return http.Response(
          jsonEncode({
            'message': {
              'events': [
                {'event_id': ids.first},
                {'event_id': 'OTHER'},
              ],
            },
          }),
          200,
        );
      }),
    );
  });
  test('verify sends only entered value, preserving leading zeroes', () async {
    await http.runWithClient(
      () async {
        expect(
          (await VisitVerificationApi.verify('E1', ' 012345 '))['is_verified'],
          true,
        );
      },
      () => MockClient((request) async {
        expect(request.bodyFields, {
          'action': 'verify',
          'event_id': 'E1',
          'custom_validate': '012345',
        });
        return http.Response(
          '{"message":{"event_id":"E1","status":"success","is_verified":true}}',
          200,
        );
      }),
    );
  });
  test('reject result if session changes while request is running', () async {
    await http.runWithClient(
      () async {
        await expectLater(
          VisitVerificationApi.verify('E1', '123456'),
          throwsStateError,
        );
      },
      () => MockClient((request) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', 'new token');
        return http.Response('{"message":{"status":"success"}}', 200);
      }),
    );
  });
  for (final response in [
    http.Response('bad', 200),
    http.Response('{}', 403),
    http.Response('{"exc":"trace","message":{}}', 200),
  ]) {
    test(
      'reject invalid, unauthorized or exception response ${response.statusCode}/${response.body}',
      () async {
        await http.runWithClient(() async {
          await expectLater(VisitVerificationApi.policy(), throwsStateError);
        }, () => MockClient((_) async => response));
      },
    );
  }
}
