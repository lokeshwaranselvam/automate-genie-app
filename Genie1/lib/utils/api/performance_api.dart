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
    Uri? visitMethods,
    Future<String?> Function()? sessionId,
    Future<String?> Function()? savedUser,
  }) : _client = client ?? http.Client(),
       _site = site,
       _visitMethods = visitMethods,
       _sessionId = sessionId ?? SessionAuthApi.getSessionId,
       _savedUser = savedUser ?? SessionAuthApi.getSavedSessionUser;

  static final instance = PerformanceApi();
  final http.Client _client;
  final Uri? _site, _visitMethods;
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
          .resolve('api/method/mobile_site_visit')
          .replace(queryParameters: {'action': 'can_create'}),
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
        message['can_create_lead'] is! bool ||
        message['can_create'] is! bool) {
      throw const FormatException(
        'Invalid sales performance permission response.',
      );
    }
    // Share Home's server-verified Sales User OR Sales Manager capability.
    // Record reads still enforce the authenticated ERP permissions.
    return message['can_create_lead'] == true;
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
    return _loadResources(base, month, user, sid);
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

  // Use the same sources, ID merge, completion rules and date fallback as
  // SiteVisitsPage's Completed tab. Do not require a readable Employee record.
  Future<List<Map<String, dynamic>>?> _completedVisitRecords(
    Uri base,
    String user,
    String sid,
  ) async {
    final methods =
        _visitMethods ?? Uri.tryParse(dotenv.env['URL']?.trim() ?? '');
    if (methods == null ||
        methods.scheme != base.scheme ||
        methods.host != base.host ||
        methods.port != base.port ||
        methods.hasQuery ||
        methods.hasFragment) {
      return null;
    }
    Future<List<Map<String, dynamic>>?> read(
      String method,
      Map<String, String> query,
    ) async {
      await _assertSession(user, sid);
      final request = http.Request(
        'GET',
        methods.replace(
          path: '${methods.path}.$method',
          queryParameters: {'user': user, ...query},
        ),
      )..followRedirects = false;
      request.headers.addAll({
        'Accept': 'application/json',
        'Cookie': 'sid=$sid',
        'Cache-Control': 'no-cache, no-store',
      });
      final response = await (() async =>
              http.Response.fromStream(await _client.send(request)))()
          .timeout(const Duration(seconds: 20));
      await _assertSession(user, sid);
      if (response.statusCode == 401) {
        throw StateError('Your ERP session expired. Please sign in again.');
      }
      if ({403, 404, 417}.contains(response.statusCode)) return null;
      if (response.statusCode != 200) {
        throw StateError('Could not load completed visits. Please retry.');
      }
      final body = jsonDecode(response.body);
      final message = body is Map ? body['message'] : null;
      if (message is! List || message.any((row) => row is! Map)) return null;
      final rows =
          message.map((row) => Map<String, dynamic>.from(row as Map)).toList();
      if (rows.any((row) => row['status'] == 'Error')) return null;
      return rows;
    }

    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    // Match the Visits page's full history window so a visit created/scheduled
    // in an earlier month still counts in the month it actually completed.
    final results = await Future.wait([
      read('event_list', {}),
      read('history_list', {'from_date': '2000-01-01', 'to_date': today}),
    ]);
    if (results.any((rows) => rows == null)) return null;
    final byId = <String, Map<String, dynamic>>{};
    for (var source = 0; source < results.length; source++) {
      for (final row in results[source]!) {
        final id = (row['name'] ?? row['event_id'] ?? '').toString().trim();
        if (id.isEmpty) return null;
        byId[id] = {
          ...?byId[id],
          ...row,
          if (source == 1) '_visit_completed_history': true,
        };
      }
    }
    final completed = <Map<String, dynamic>>[];
    for (final row in byId.values) {
      final checkout = row['custom_check_out']?.toString().trim() ?? '';
      final end = row['ends_on']?.toString().trim() ?? '';
      final status = row['status']?.toString().toLowerCase() ?? '';
      final isCompleted =
          row['_visit_completed_history'] == true ||
          checkout.isNotEmpty ||
          (end.isNotEmpty && status == 'completed') ||
          status == 'closed';
      if (!isCompleted) continue;
      final date =
          DateTime.tryParse(
            (row['custom_check_out'] ?? row['ends_on'])?.toString() ?? '',
          )?.toLocal() ??
          DateTime.tryParse(row['starts_on']?.toString() ?? '')?.toLocal();
      if (date == null) return null;
      completed.add({'completed_at': date.toIso8601String()});
    }
    return completed;
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
      _completedVisitRecords(base, user, sid),
    ]);
    final visits = streams[3];
    final sources = [streams[0], visits, streams[1], streams[2]];
    if (sources.every((rows) => rows == null)) {
      throw StateError(
        'Performance data is unavailable for this account. Ask your administrator to check access to your sales records.',
      );
    }
    const metrics = ['leads', 'site_visits', 'quotations', 'orders'];
    final trend = List.generate(
      6,
      (i) => <String, dynamic>{
        'month': key(DateTime(month.year, month.month - 5 + i)),
        for (var j = 0; j < metrics.length; j++)
          metrics[j]: sources[j] == null ? null : 0,
        'conversions': visits == null ? null : 0,
      },
    );
    final weekly = List.generate(
      4,
      (i) => <String, dynamic>{
        'label': 'W${i + 1}',
        for (var j = 0; j < metrics.length; j++)
          metrics[j]: sources[j] == null ? null : 0,
        'conversions': visits == null ? null : 0,
      },
    );
    for (var i = 0; i < metrics.length; i++) {
      for (final row in sources[i] ?? <Map<String, dynamic>>[]) {
        final raw =
            row[i == 0
                ? 'creation'
                : i == 1
                ? 'completed_at'
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
        // Conversions are completed site visits, grouped by completion date.
        final converted = i == 1;
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
