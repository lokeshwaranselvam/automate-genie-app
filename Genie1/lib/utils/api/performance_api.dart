import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

class PerformanceData {
  const PerformanceData({
    required this.month,
    required this.user,
    required this.sales,
    required this.activity,
    required this.attendance,
    required this.previous,
    required this.weekly,
    required this.trend,
  });

  final String month;
  final String user;
  final Map<String, dynamic> sales, activity, attendance, previous;
  final List<Map<String, dynamic>> weekly, trend;

  factory PerformanceData.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> section(String key) {
      if (json[key] is! Map) {
        throw const FormatException('Update the My Performance API on ERP.');
      }
      return Map<String, dynamic>.from(json[key] as Map);
    }

    List<Map<String, dynamic>> rows(String key) {
      if (json[key] is! List || (json[key] as List).any((row) => row is! Map)) {
        throw const FormatException('Invalid performance chart data.');
      }
      return (json[key] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    }

    final month = json['month'];
    final user = json['current_user'];
    if (month is! String || user is! String || user.isEmpty) {
      throw const FormatException('Invalid performance response.');
    }
    return PerformanceData(
      month: month,
      user: user,
      sales: section('sales'),
      activity: section('activity'),
      attendance: section('attendance'),
      previous: section('previous'),
      weekly: rows('weekly'),
      trend: rows('trend'),
    );
  }

  static int? count(dynamic value) =>
      value is num &&
              value.isFinite &&
              value >= 0 &&
              value == value.roundToDouble()
          ? value.toInt()
          : null;
}

class PerformanceApi {
  PerformanceApi({
    http.Client? client,
    Uri? site,
    Future<String?> Function()? sessionId,
    Future<String?> Function()? savedUser,
  }) : _client = client ?? http.Client(),
       _site = site,
       _sessionId = sessionId ?? SessionAuthApi.getSessionId,
       _savedUser = savedUser ?? SessionAuthApi.getSavedSessionUser;

  static final instance = PerformanceApi();
  final http.Client _client;
  final Uri? _site;
  final Future<String?> Function() _sessionId, _savedUser;

  /// Checks the roles of the authenticated ERP session, never locally saved roles.
  Future<bool> canViewSales() async {
    final sid = await _sessionId();
    final user = await _savedUser();
    if (sid == null || sid.isEmpty || user == null || user.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    final value = _site == null ? dotenv.env['SITE_URL']?.trim() ?? '' : '';
    if (_site == null && value.isEmpty) {
      throw StateError('SITE_URL is not configured.');
    }
    final base = _site ?? Uri.parse(value.endsWith('/') ? value : '$value/');
    final request = http.Request(
      'GET',
      base
          .resolve('api/method/mobile_employee_performance')
          .replace(queryParameters: {'action': 'can_view_sales'}),
    )..followRedirects = false;
    request.headers.addAll({
      'Accept': 'application/json',
      'Cookie': 'sid=$sid',
      'Cache-Control': 'no-cache, no-store',
    });
    final response = await (() async {
      return http.Response.fromStream(await _client.send(request));
    })().timeout(const Duration(seconds: 10));
    await _assertSession(user, sid);
    if (response.statusCode != 200) {
      throw StateError('Could not verify sales performance access.');
    }
    final decoded = jsonDecode(response.body);
    final message = decoded is Map ? decoded['message'] : null;
    if (message is! Map ||
        message['current_user'] != user ||
        message['can_view_sales'] is! bool) {
      throw const FormatException(
        'Invalid sales performance permission response.',
      );
    }
    return message['can_view_sales'] == true;
  }

  Future<PerformanceData> load(DateTime month) async {
    final sid = await _sessionId();
    final user = await _savedUser();
    if (sid == null || sid.isEmpty || user == null || user.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    final value = _site == null ? dotenv.env['SITE_URL']?.trim() ?? '' : '';
    if (_site == null && value.isEmpty) {
      throw StateError('SITE_URL is not configured.');
    }
    final base = _site ?? Uri.parse(value.endsWith('/') ? value : '$value/');
    final key =
        '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}';
    final request = http.Request(
      'GET',
      base
          .resolve('api/method/mobile_employee_performance')
          .replace(queryParameters: {'month': key}),
    )..followRedirects = false;
    request.headers.addAll({
      'Accept': 'application/json',
      'Cookie': 'sid=$sid',
      'Cache-Control': 'no-cache, no-store',
    });
    final response = await (() async {
      return http.Response.fromStream(await _client.send(request));
    })().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError('Your ERP session expired. Please sign in again.');
      }
      if (response.statusCode == 404 || response.statusCode == 417) {
        // Older sites may not have the aggregation script installed, or may
        // reject its restricted execution. Read real, permission-filtered ERP
        // records instead; never substitute preview/sample data.
        return _loadResources(base, month, user, sid);
      }
      throw StateError(
        'Could not load My Performance (${response.statusCode}). '
        'Confirm the mobile_employee_performance API is installed, then retry.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['message'] is! Map) {
      throw const FormatException('ERP returned invalid performance data.');
    }
    final result = PerformanceData.fromJson(
      Map<String, dynamic>.from(decoded['message'] as Map),
    );
    if (result.user != user ||
        result.month != key ||
        await _savedUser() != user ||
        await _sessionId() != sid) {
      throw StateError('Your account or month changed. Reload My Performance.');
    }
    return result;
  }

  Future<void> _assertSession(String user, String sid) async {
    if (await _savedUser() != user || await _sessionId() != sid) {
      throw StateError('Your account changed. Reopen My Performance.');
    }
  }

  Future<List<Map<String, dynamic>>?> _records(
    Uri base,
    String user,
    String sid,
    String doctype,
    List<String> fields,
    List<List<dynamic>> filters,
  ) async {
    final rows = <Map<String, dynamic>>[];
    // Limit each stream and never report a partial stream as a complete total.
    for (var page = 0; page < 20; page++) {
      await _assertSession(user, sid);
      final request = http.Request(
        'GET',
        base
            .resolve('api/resource/${Uri.encodeComponent(doctype)}')
            .replace(
              queryParameters: {
                'fields': jsonEncode(fields),
                'filters': jsonEncode(filters),
                'order_by': 'name asc',
                'limit_page_length': '500',
                'limit_start': '${page * 500}',
              },
            ),
      )..followRedirects = false;
      request.headers.addAll({
        'Accept': 'application/json',
        'Cookie': 'sid=$sid',
        'Cache-Control': 'no-cache, no-store',
      });
      final response = await (() async {
        return http.Response.fromStream(await _client.send(request));
      })().timeout(const Duration(seconds: 20));
      await _assertSession(user, sid);
      if (response.statusCode == 401) {
        throw StateError('Your ERP session expired. Please sign in again.');
      }
      // No permission/schema means unavailable, not zero. Other streams can
      // still supply their own genuine totals.
      if ({403, 404, 417}.contains(response.statusCode)) return null;
      if (response.statusCode != 200) {
        throw StateError('Could not load performance records. Please retry.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['data'] is! List) {
        throw const FormatException(
          'ERP returned invalid performance records.',
        );
      }
      final batch = decoded['data'] as List;
      if (batch.any((row) => row is! Map)) {
        throw const FormatException(
          'ERP returned invalid performance records.',
        );
      }
      rows.addAll(batch.map((row) => Map<String, dynamic>.from(row as Map)));
      if (batch.length < 500) return rows;
    }
    return null;
  }

  Future<PerformanceData> _loadResources(
    Uri base,
    DateTime month,
    String user,
    String sid,
  ) async {
    String key(DateTime date) =>
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
    final start = '${key(DateTime(month.year, month.month - 5))}-01';
    final end = '${key(DateTime(month.year, month.month + 1))}-01';
    List<List<dynamic>> filters(String owner, String date, int docstatus) => [
      [owner, '=', user],
      [date, '>=', start],
      [date, '<', end],
      ['docstatus', docstatus == 2 ? '!=' : '=', docstatus],
    ];
    final streams = await Future.wait([
      _records(base, user, sid, 'Lead', [
        'creation',
        'status',
      ], filters('lead_owner', 'creation', 2)),
      _records(base, user, sid, 'Quotation', [
        'transaction_date',
      ], filters('owner', 'transaction_date', 1)),
      _records(base, user, sid, 'Sales Order', [
        'transaction_date',
      ], filters('owner', 'transaction_date', 1)),
      _records(
        base,
        user,
        sid,
        'Employee',
        ['name'],
        [
          ['user_id', '=', user],
          ['status', '=', 'Active'],
        ],
      ),
    ]);
    final employees = streams[3];
    final employee =
        employees != null && employees.length == 1
            ? employees.first['name']
            : null;
    final visits =
        employee is String && employee.isNotEmpty
            ? await _records(
              base,
              user,
              sid,
              'Visit',
              ['custom_check_in_time'],
              [
                ['employee', '=', employee],
                [
                  'event_id',
                  'not in',
                  ['', 'Employee Checked In', 'Employee Checked Out'],
                ],
                ['custom_check_in_time', '>=', start],
                ['custom_check_in_time', '<', end],
                ['docstatus', '!=', 2],
              ],
            )
            : null;
    final sources = [streams[0], visits, streams[1], streams[2]];
    if (sources.every((rows) => rows == null)) {
      throw StateError(
        'Performance data is unavailable for this account. Ask your administrator to update mobile_employee_performance or allow access to your sales records.',
      );
    }
    const metrics = ['leads', 'site_visits', 'quotations', 'orders'];
    final trend = List.generate(
      6,
      (i) => <String, dynamic>{
        'month': key(DateTime(month.year, month.month - 5 + i)),
        for (var j = 0; j < metrics.length; j++)
          metrics[j]: sources[j] == null ? null : 0,
        'conversions': sources[0] == null ? null : 0,
      },
    );
    final weekly = List.generate(
      4,
      (i) => <String, dynamic>{
        'label': 'W${i + 1}',
        for (var j = 0; j < metrics.length; j++)
          metrics[j]: sources[j] == null ? null : 0,
        'conversions': sources[0] == null ? null : 0,
      },
    );
    for (var i = 0; i < metrics.length; i++) {
      for (final row in sources[i] ?? <Map<String, dynamic>>[]) {
        final raw =
            row[i == 0
                ? 'creation'
                : i == 1
                ? 'custom_check_in_time'
                : 'transaction_date'];
        final date = DateTime.tryParse(raw?.toString() ?? '');
        if (date == null) {
          throw const FormatException(
            'ERP returned an invalid performance date.',
          );
        }
        final buckets = trend.where((bucket) => bucket['month'] == key(date));
        if (buckets.isEmpty) continue;
        final bucket = buckets.first;
        bucket[metrics[i]] = (bucket[metrics[i]] as int) + 1;
        final converted = i == 0 && row['status'] == 'Converted';
        if (converted) {
          bucket['conversions'] = (bucket['conversions'] as int) + 1;
        }
        if (key(date) == key(month)) {
          final week = weekly[((date.day - 1) ~/ 7).clamp(0, 3)];
          week[metrics[i]] = (week[metrics[i]] as int) + 1;
          if (converted) week['conversions'] = (week['conversions'] as int) + 1;
        }
      }
    }
    await _assertSession(user, sid);
    return PerformanceData(
      month: key(month),
      user: user,
      sales: {for (final metric in metrics) metric: trend.last[metric]},
      activity: const {},
      attendance: const {},
      previous: trend[4],
      weekly: weekly,
      trend: trend,
    );
  }
}
