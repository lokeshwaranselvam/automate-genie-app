import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedContext extends Fake implements BuildContext {}

Future<Map<String, dynamic>> checkout({
  Future<bool> Function()? beforeCheckout,
  String? legacyOtp,
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
  customOtp: legacyOtp,
  beforeCheckout: beforeCheckout,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(
      fileInput:
          'URL=https://erp.example.test/api/method/company.api\nSITE_URL=https://erp.example.test',
    );
    SharedPreferences.setMockInitialValues({
      'token': 'test-token',
      'session_sid': 'sid',
    });
  });
  test(
    'checkout sends only the normal request without any OTP call or field',
    () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          expect((await checkout())['message']['status'], 'success');
        },
        () => MockClient((request) async {
          calls++;
          expect(request.url.path, '/api/method/company.api.event_checkout');
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'test-token');
          expect(request.bodyFields, {
            'user': 'sales@example.test',
            'event_id': 'EVENT-1',
            'lat': '13.0',
            'lng': '80.0',
            'address': 'Site & office',
            'working_hrs': '01:00',
            'distance': '10 m',
            'last_lat_lng': '13,80',
            'location_logs': '[]',
          });
          return http.Response(
            jsonEncode({
              'message': {'status': 'success'},
            }),
            200,
          );
        }),
      );
      expect(calls, 1);
    },
  );
  for (final uploaded in [true, false]) {
    test(
      'attachment upload success=$uploaded gates the checkout request',
      () async {
        final stages = <String>[];
        await http.runWithClient(
          () async {
            final result = await checkout(
              beforeCheckout: () async {
                stages.add('upload');
                return uploaded;
              },
            );
            if (!uploaded) expect(result['cancelled'], isTrue);
          },
          () => MockClient((request) async {
            expect(request.url.path, endsWith('.event_checkout'));
            stages.add('checkout');
            return http.Response(
              jsonEncode({
                'message': {'status': 'success'},
              }),
              200,
            );
          }),
        );
        expect(stages, uploaded ? ['upload', 'checkout'] : ['upload']);
      },
    );
  }
  test('attachment upload exception prevents checkout', () async {
    await http.runWithClient(
      () async {
        await expectLater(
          checkout(
            beforeCheckout: () async {
              throw StateError('Upload failed');
            },
          ),
          throwsStateError,
        );
      },
      () => MockClient((_) async {
        fail('Checkout must not be sent when attachment upload fails.');
      }),
    );
  });
  test('legacy optional OTP is ignored and never sent', () async {
    await http.runWithClient(
      () => checkout(legacyOtp: 'wrong'),
      () => MockClient((request) async {
        expect(request.bodyFields.containsKey('custom_otp'), isFalse);
        expect(request.url.path, endsWith('.event_checkout'));
        return http.Response(
          jsonEncode({
            'message': {'status': 'success'},
          }),
          200,
        );
      }),
    );
  });
  test('report save preserves fields and does not send legacy OTP', () async {
    await http.runWithClient(
      () => Event.saveVisitReport(
        eventId: 'EVENT-1',
        observation: 'Visited',
        outcome: 'Interested',
        customOtp: 'wrong',
      ),
      () => MockClient((request) async {
        expect(request.bodyFields, {
          'action': 'save',
          'event_id': 'EVENT-1',
          'observation': 'Visited',
          'outcome': 'Interested',
        });
        return http.Response(
          jsonEncode({
            'message': {
              'status': 'success',
              'is_submitted': true,
              'observation': 'Visited',
              'outcome': 'Interested',
            },
          }),
          200,
        );
      }),
    );
  });
}
