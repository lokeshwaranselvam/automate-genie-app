import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedContext extends Fake implements BuildContext {}

Future<Map<String, dynamic>> checkout(
  String otp, {
  Future<bool> Function()? beforeCheckout,
}) => Event.eventCheckout(
  'sales@example.test',
  'EVENT-1',
  13,
  80,
  'Site & office',
  '01:00',
  '10 m',
  '13,80',
  '[]',
  _UnusedContext(),
  customOtp: otp,
  beforeCheckout: beforeCheckout,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(
      fileInput:
          'URL=https://erp.example.test/api/method/company.api\nSITE_URL=https://erp.example.test',
    );
    SharedPreferences.setMockInitialValues({'token': 'test-token'});
  });

  test('blank OTP blocks checkout without a network request', () async {
    var calls = 0;
    await http.runWithClient(
      () async {
        await expectLater(checkout('  '), throwsArgumentError);
      },
      () => MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(calls, 0);
  });

  for (final otp in ['1', '123', '12345', '123456', '12a4', '12 4', '１２３４']) {
    test('invalid OTP $otp is rejected before any write request', () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await expectLater(checkout(otp), throwsArgumentError);
          await expectLater(
            Event.saveVisitOtp(eventId: 'EVENT-1', customOtp: otp),
            throwsArgumentError,
          );
          await expectLater(
            Event.saveVisitReport(
              eventId: 'EVENT-1',
              observation: 'Visited',
              outcome: 'Interested',
              customOtp: otp,
            ),
            throwsArgumentError,
          );
          expect(await Event.verifyOtp(otp, 'EVENT-1'), isFalse);
        },
        () => MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      expect(calls, 0);
    });
  }

  test(
    'OTP is confirmed saved before checkout with location fields intact',
    () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          final result = await checkout(' 0123 ');
          expect(result['message']['status'], 'success');
        },
        () => MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/event_visit_report')) {
            expect(calls, 1);
            expect(request.bodyFields['action'], 'save_otp');
            expect(request.bodyFields['custom_otp'], '0123');
            expect(request.bodyFields['event_id'], 'EVENT-1');
            return http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  'action': 'save_otp',
                  'event_id': 'EVENT-1',
                  'custom_otp': '0123',
                  'otp_saved': true,
                },
              }),
              200,
            );
          }
          expect(calls, 2);
          expect(request.url.path, endsWith('.event_checkout'));
          expect(request.bodyFields['custom_otp'], '0123');
          expect(request.bodyFields['address'], 'Site & office');
          expect(request.bodyFields['location_logs'], '[]');
          expect(request.bodyFields['event_id'], 'EVENT-1');
          expect(request.headers['Authorization'], 'test-token');
          return http.Response(
            jsonEncode({
              'message': {'status': 'success'},
            }),
            200,
          );
        }),
      );
      expect(calls, 2);
    },
  );

  for (final failure in ['rejected', 'missing_confirmation', 'different_otp']) {
    test('OTP $failure prevents checkout', () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await expectLater(checkout('0123'), throwsStateError);
        },
        () => MockClient((request) async {
          calls++;
          expect(request.url.path, endsWith('/event_visit_report'));
          return http.Response(
            jsonEncode({
              'message': {
                'status': failure == 'rejected' ? 'error' : 'success',
                'action': 'save_otp',
                'event_id': 'EVENT-1',
                'custom_otp': failure == 'different_otp' ? '9999' : '0123',
                if (failure != 'missing_confirmation') 'otp_saved': true,
              },
            }),
            failure == 'rejected' ? 403 : 200,
          );
        }),
      );
      expect(calls, 1);
    });
  }

  test(
    'Frappe Wrong OTP validation is shown and checkout is never sent',
    () async {
      var calls = 0;
      var uploads = 0;
      await http.runWithClient(
        () async {
          await expectLater(
            checkout(
              '9999',
              beforeCheckout: () async {
                uploads++;
                return true;
              },
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Wrong OTP',
              ),
            ),
          );
        },
        () => MockClient((request) async {
          calls++;
          expect(request.url.path, endsWith('/event_visit_report'));
          return http.Response(
            jsonEncode({
              'exc_type': 'ValidationError',
              '_server_messages': jsonEncode([
                jsonEncode({'message': 'Wrong OTP', 'raise_exception': 1}),
              ]),
            }),
            417,
          );
        }),
      );
      expect(calls, 1);
      expect(uploads, 0);
    },
  );

  for (final uploadSucceeded in [true, false]) {
    test(
      'OTP is validated before upload; upload success=$uploadSucceeded controls checkout',
      () async {
        final stages = <String>[];
        await http.runWithClient(
          () async {
            final result = await checkout(
              '0123',
              beforeCheckout: () async {
                stages.add('upload');
                return uploadSucceeded;
              },
            );
            if (!uploadSucceeded) expect(result['cancelled'], isTrue);
          },
          () => MockClient((request) async {
            if (request.url.path.endsWith('/event_visit_report')) {
              stages.add('otp');
              return http.Response(
                jsonEncode({
                  'message': {
                    'status': 'success',
                    'action': 'save_otp',
                    'event_id': 'EVENT-1',
                    'otp_saved': true,
                    'custom_otp': '0123',
                  },
                }),
                200,
              );
            }
            stages.add('checkout');
            return http.Response(
              jsonEncode({
                'message': {'status': 'success'},
              }),
              200,
            );
          }),
        );
        expect(
          stages,
          uploadSucceeded ? ['otp', 'upload', 'checkout'] : ['otp', 'upload'],
        );
      },
    );
  }
}
