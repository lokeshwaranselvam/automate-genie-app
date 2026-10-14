import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/performance_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> performancePayload({
  String month = '2026-10',
  String user = 'staff@example.test',
}) => {
  'current_user': user,
  'month': month,
  'sales': {'leads': 18, 'site_visits': 12, 'quotations': 8, 'orders': 5},
  'activity': {
    'site_visits': 12,
    'completed_visits': 9,
    'ongoing_visits': 3,
    'visit_days': 7,
  },
  'attendance': {
    'checkin_days': 20,
    'checkins': 22,
    'checkouts': 21,
    'present_days': 19,
  },
  'previous': {
    'leads': 15,
    'site_visits': 9,
    'quotations': 7,
    'orders': 4,
    'checkin_days': 18,
    'checkins': 20,
    'checkouts': 20,
    'present_days': 18,
    'completed_visits': 6,
    'ongoing_visits': 3,
    'visit_days': 6,
  },
  'weekly': List.generate(
    4,
    (index) => {
      'label': 'W${index + 1}',
      'leads': index + 1,
      'conversions': index,
      'site_visits': 3,
      'completed_visits': 2,
      'checkins': 5,
      'checkouts': 4,
    },
  ),
  'trend': [
    {
      'month': '2026-09',
      'leads': 15,
      'conversions': 4,
      'site_visits': 9,
      'completed_visits': 6,
      'checkins': 20,
      'checkouts': 20,
    },
    {
      'month': month,
      'leads': 18,
      'conversions': 5,
      'site_visits': 12,
      'completed_visits': 9,
      'checkins': 22,
      'checkouts': 21,
    },
  ],
};

void main() {
  PerformanceApi api(http.Client client, {Future<String?> Function()? user}) =>
      PerformanceApi(
        client: client,
        site: Uri.parse('https://erp.example.test/'),
        sessionId: () async => 'test-sid',
        savedUser: user ?? () async => 'staff@example.test',
      );

  test(
    'loads the selected month with session identity and no redirects',
    () async {
      final result = await api(
        MockClient((request) async {
          expect(request.url.path, '/api/method/mobile_employee_performance');
          expect(request.url.queryParameters, {'month': '2026-10'});
          expect(request.headers['Cookie'], 'sid=test-sid');
          expect(request.headers['Cache-Control'], 'no-cache, no-store');
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode({'message': performancePayload()}),
            200,
          );
        }),
      ).load(DateTime(2026, 10));
      expect(result.sales['leads'], 18);
      expect(result.weekly.length, 4);
    },
  );

  test(
    'rejects another account, mismatched month and changed session user',
    () async {
      for (final payload in [
        performancePayload(user: 'other@example.test'),
        performancePayload(month: '2026-09'),
      ]) {
        await expectLater(
          api(
            MockClient(
              (_) async => http.Response(jsonEncode({'message': payload}), 200),
            ),
          ).load(DateTime(2026, 10)),
          throwsStateError,
        );
      }
      var calls = 0;
      await expectLater(
        api(
          MockClient(
            (_) async => http.Response(
              jsonEncode({'message': performancePayload()}),
              200,
            ),
          ),
          user:
              () async =>
                  calls++ == 0 ? 'staff@example.test' : 'other@example.test',
        ).load(DateTime(2026, 10)),
        throwsStateError,
      );
    },
  );

  test(
    'missing API and malformed payload never become sample numbers',
    () async {
      await expectLater(
        api(
          MockClient((_) async => http.Response('{}', 404)),
        ).load(DateTime(2026, 10)),
        throwsStateError,
      );
      final legacy = performancePayload()..remove('weekly');
      await expectLater(
        api(
          MockClient(
            (_) async => http.Response(jsonEncode({'message': legacy}), 200),
          ),
        ).load(DateTime(2026, 10)),
        throwsFormatException,
      );
      expect(PerformanceData.count(null), isNull);
      expect(PerformanceData.count(-1), isNull);
      expect(PerformanceData.count(1.5), isNull);
      expect(PerformanceData.count(0), 0);
    },
  );
}
