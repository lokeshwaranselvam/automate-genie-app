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

  test('sales access comes from the current authenticated session', () async {
    // Neither role, Sales User, Sales Manager, and both roles.
    for (final access in [
      (false, false),
      (true, false),
      (false, true),
      (true, true),
    ]) {
      final result =
          await api(
            MockClient((request) async {
              expect(request.url.path, '/api/method/mobile_site_visit');
              expect(request.url.queryParameters, {'action': 'can_create'});
              expect(request.headers['Cookie'], 'sid=test-sid');
              expect(request.headers['Cache-Control'], 'no-cache, no-store');
              expect(request.followRedirects, isFalse);
              return http.Response(
                jsonEncode({
                  'message': {
                    'current_user': 'staff@example.test',
                    'can_create_lead': access.$1,
                    'can_create': access.$2,
                  },
                }),
                200,
              );
            }),
          ).canViewSales();
      expect(result, access.$1 || access.$2);
    }
  });

  test(
    'sales access rejects unknown permissions and another account',
    () async {
      for (final message in [
        {
          'current_user': 'other@example.test',
          'can_create_lead': true,
          'can_create': true,
        },
        {'current_user': 'staff@example.test'},
        {
          'current_user': 'staff@example.test',
          'can_create_lead': 'true',
          'can_create': false,
        },
      ]) {
        await expectLater(
          api(
            MockClient(
              (_) async => http.Response(jsonEncode({'message': message}), 200),
            ),
          ).canViewSales(),
          throwsFormatException,
        );
      }
      var calls = 0;
      await expectLater(
        api(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'message': {
                  'current_user': 'staff@example.test',
                  'can_create_lead': true,
                  'can_create': false,
                },
              }),
              200,
            ),
          ),
          user:
              () async =>
                  calls++ == 0 ? 'staff@example.test' : 'other@example.test',
        ).canViewSales(),
        throwsStateError,
      );
    },
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

  test(
    '417 uses real scoped records, conversions and previous month totals',
    () async {
      final result = await api(
        MockClient((request) async {
          expect(request.headers['Cookie'], 'sid=test-sid');
          expect(request.followRedirects, isFalse);
          if (request.url.path.endsWith('mobile_employee_performance')) {
            return http.Response('{}', 417);
          }
          final doctype = request.url.pathSegments.last;
          final filters =
              jsonDecode(request.url.queryParameters['filters']!) as List;
          expect(
            filters,
            contains(
              equals([
                doctype == 'Lead'
                    ? 'lead_owner'
                    : doctype == 'Employee'
                    ? 'user_id'
                    : doctype == 'Visit'
                    ? 'employee'
                    : 'owner',
                '=',
                doctype == 'Visit' ? 'EMP-1' : 'staff@example.test',
              ]),
            ),
          );
          final data = switch (doctype) {
            'Lead' => [
              {'creation': '2026-10-01 10:00:00', 'status': 'Converted'},
              {'creation': '2026-10-31 12:00:00', 'status': 'Open'},
              {'creation': '2026-09-01 10:00:00', 'status': 'Open'},
            ],
            'Employee' => [
              {'name': 'EMP-1'},
            ],
            'Visit' => [
              {'custom_check_in_time': '2026-10-08 10:00:00'},
            ],
            'Quotation' => [
              {'transaction_date': '2026-10-15'},
            ],
            'Sales Order' => <Map<String, dynamic>>[],
            _ => throw StateError('Unexpected request'),
          };
          return http.Response(jsonEncode({'data': data}), 200);
        }),
      ).load(DateTime(2026, 10));
      expect(result.sales, {
        'leads': 2,
        'site_visits': 1,
        'quotations': 1,
        'orders': 0,
      });
      expect(result.previous['leads'], 1);
      expect(result.weekly[0]['conversions'], 1);
      expect(result.weekly[1]['site_visits'], 1);
      expect(result.weekly[3]['leads'], 1);
      expect(result.trend.length, 6);
    },
  );

  test(
    'fallback paginates and preserves unavailable as distinct from zero',
    () async {
      var leadPages = 0;
      final result = await api(
        MockClient((request) async {
          if (request.url.path.endsWith('mobile_employee_performance')) {
            return http.Response('{}', 417);
          }
          switch (request.url.pathSegments.last) {
            case 'Lead':
              leadPages++;
              final start = request.url.queryParameters['limit_start'];
              return http.Response(
                jsonEncode({
                  'data': List.generate(
                    start == '0' ? 500 : 1,
                    (_) => {'creation': '2026-10-02', 'status': 'Open'},
                  ),
                }),
                200,
              );
            case 'Employee':
              return http.Response(jsonEncode({'data': []}), 200);
            default:
              return http.Response('{}', 403);
          }
        }),
      ).load(DateTime(2026, 10));
      expect(leadPages, 2);
      expect(result.sales['leads'], 501);
      expect(result.sales['site_visits'], isNull);
      expect(result.sales['quotations'], isNull);
      expect(result.weekly[0]['leads'], 501);
    },
  );
}
