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
}
