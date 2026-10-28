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
        visitMethods: Uri.parse('https://erp.example.test/api/method/app.api'),
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
      expect(result, access.$1);
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

  Map<String, dynamic> visit(String id, String scheduled, String completed) => {
    'name': id,
    'starts_on': scheduled,
    'custom_check_out': completed,
    'status': 'Completed',
  };

  http.Client records({
    List<Map<String, dynamic>> scheduled = const [],
    List<Map<String, dynamic>> history = const [],
    int historyStatus = 200,
    int leadCount = 2,
  }) => MockClient((request) async {
    expect(request.headers['Cookie'], 'sid=test-sid');
    expect(request.headers['Cache-Control'], 'no-cache, no-store');
    expect(request.followRedirects, isFalse);
    final path = request.url.path;
    expect(path.contains('mobile_employee_performance'), isFalse);
    expect(path.endsWith('/Employee'), isFalse);
    expect(path.endsWith('/Visit'), isFalse);
    if (path.endsWith('.event_list') || path.endsWith('.history_list')) {
      expect(request.url.queryParameters['user'], 'staff@example.test');
      final isHistory = path.endsWith('.history_list');
      if (isHistory) {
        expect(request.url.queryParameters['from_date'], '2000-01-01');
        expect(
          request.url.queryParameters['to_date'],
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
        );
      }
      return http.Response(
        jsonEncode({'message': isHistory ? history : scheduled}),
        isHistory ? historyStatus : 200,
      );
    }
    final filters = jsonDecode(request.url.queryParameters['filters']!) as List;
    final type = request.url.pathSegments.last;
    expect(
      filters,
      contains(
        equals([
          type == 'Lead' ? 'lead_owner' : 'owner',
          '=',
          'staff@example.test',
        ]),
      ),
    );
    expect(
      filters,
      contains(
        equals([
          type == 'Lead' ? 'creation' : 'transaction_date',
          '>=',
          '2026-05-01',
        ]),
      ),
    );
    expect(
      filters,
      contains(
        equals([
          type == 'Lead' ? 'creation' : 'transaction_date',
          '<',
          '2026-11-01',
        ]),
      ),
    );
    final data = switch (type) {
      'Lead' => List.generate(
        leadCount,
        (i) => {
          'creation': i == 0 ? '2026-10-01 10:00:00' : '2026-09-02 10:00:00',
          'status': i == 0 ? 'Converted' : 'Open',
        },
      ),
      'Quotation' => [
        {'transaction_date': '2026-10-15'},
      ],
      'Sales Order' => <Map<String, dynamic>>[],
      _ => throw StateError('Unexpected request $path'),
    };
    return http.Response(jsonEncode({'data': data}), 200);
  });

  test(
    'loads completed visits without Employee or custom performance API',
    () async {
      final result = await api(
        records(
          history: [
            visit('EV-1', '2026-09-01', '2026-10-08 10:00:00'),
            visit('EV-2', '2026-08-01', '2026-09-30 23:59:00'),
          ],
        ),
      ).load(DateTime(2026, 10));
      expect(result.sales, {
        'leads': 1,
        'site_visits': 1,
        'quotations': 1,
        'orders': 0,
      });
      expect(result.previous['site_visits'], 1);
      expect(result.previous['leads'], 1);
      expect(result.weekly[1]['site_visits'], 1);
      expect(result.weekly[0]['conversions'], 1);
      expect(result.trend.length, 6);
    },
  );

  test('merges duplicate IDs and excludes unfinished events', () async {
    final completed = visit('EV-1', '2026-09-01', '2026-10-31 23:59:59');
    final result = await api(
      records(
        scheduled: [
          completed,
          {'name': 'OPEN', 'status': 'Open', 'starts_on': '2026-10-01'},
        ],
        history: [completed, completed],
      ),
    ).load(DateTime(2026, 10));
    expect(result.sales['site_visits'], 1);
    expect(result.weekly[3]['site_visits'], 1);
  });

  test('matches Completed tab date fallbacks and closed status', () async {
    final result = await api(
      records(
        scheduled: [
          {
            'name': 'CLOSED',
            'status': 'Closed',
            'ends_on': '2026-10-12',
            'starts_on': '2026-09-01',
          },
          {
            'name': 'DONE',
            'status': 'Completed',
            'ends_on': '2026-10-13',
            'starts_on': '2026-09-01',
          },
        ],
        history: [
          {'name': 'HISTORY', 'starts_on': '2026-10-14'},
          visit('NEXT', '2026-10-01', '2026-11-01'),
        ],
      ),
    ).load(DateTime(2026, 10));
    expect(result.sales['site_visits'], 3);
  });

  test('empty completed list is zero; denied history is unavailable', () async {
    final empty = await api(records()).load(DateTime(2026, 10));
    expect(empty.sales['site_visits'], 0);
    final denied = await api(
      records(historyStatus: 403),
    ).load(DateTime(2026, 10));
    expect(denied.sales['site_visits'], isNull);
    expect(denied.sales['leads'], 1);
  });

  test('invalid completed timestamp never becomes a fabricated zero', () async {
    final result = await api(
      records(
        history: [
          {'name': 'BAD'},
        ],
      ),
    ).load(DateTime(2026, 10));
    expect(result.sales['site_visits'], isNull);
    expect(result.sales['leads'], 1);
    expect(PerformanceData.count(null), isNull);
    expect(PerformanceData.count(-1), isNull);
    expect(PerformanceData.count(1.5), isNull);
  });

  test('changed user or expired session stops the request', () async {
    var calls = 0;
    await expectLater(
      api(
        records(),
        user:
            () async =>
                calls++ == 0 ? 'staff@example.test' : 'other@example.test',
      ).load(DateTime(2026, 10)),
      throwsStateError,
    );
    await expectLater(
      api(
        MockClient((_) async => http.Response('{}', 401)),
      ).load(DateTime(2026, 10)),
      throwsStateError,
    );
  });

  test('resource reads remain paginated', () async {
    var pages = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.event_list') ||
          request.url.path.endsWith('.history_list')) {
        return http.Response(jsonEncode({'message': []}), 200);
      }
      if (request.url.pathSegments.last == 'Lead') {
        pages++;
        return http.Response(
          jsonEncode({
            'data': List.generate(
              request.url.queryParameters['limit_start'] == '0' ? 500 : 1,
              (_) => {'creation': '2026-10-02', 'status': 'Open'},
            ),
          }),
          200,
        );
      }
      return http.Response('{}', 403);
    });
    final result = await api(client).load(DateTime(2026, 10));
    expect(pages, 2);
    expect(result.sales['leads'], 501);
    expect(result.sales['site_visits'], 0);
    expect(result.sales['quotations'], isNull);
  });
}
