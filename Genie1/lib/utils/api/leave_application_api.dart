import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'session_auth.dart';

class LeaveTypeOption {
  const LeaveTypeOption({required this.value, required this.label});

  final String value;
  final String label;
}

class LeaveApplicationOptions {
  const LeaveApplicationOptions({
    required this.employee,
    required this.employeeName,
    required this.leaveTypes,
    required this.csrfToken,
  });

  final String employee;
  final String employeeName;
  final List<LeaveTypeOption> leaveTypes;
  final String csrfToken;

  factory LeaveApplicationOptions.fromJson(Map<String, dynamic> message) {
    final rawTypes = message['leave_types'];
    final employee = message['employee']?.toString().trim() ?? '';
    if (employee.isEmpty || rawTypes is! List) {
      throw const FormatException(
        'The server did not return the leave form options.',
      );
    }
    final types = <LeaveTypeOption>[];
    final seen = <String>{};
    for (final row in rawTypes.whereType<Map>()) {
      final value = row['value']?.toString().trim() ?? '';
      final label = row['label']?.toString().trim() ?? '';
      if (value.isEmpty || !seen.add(value)) continue;
      types.add(
        LeaveTypeOption(value: value, label: label.isEmpty ? value : label),
      );
    }
    if (types.isEmpty) {
      throw const FormatException('No Leave Types are configured in ERPNext.');
    }
    return LeaveApplicationOptions(
      employee: employee,
      employeeName: message['employee_name']?.toString() ?? employee,
      leaveTypes: types,
      csrfToken: message['csrf_token']?.toString() ?? '',
    );
  }
}

class LeaveApplicationResult {
  const LeaveApplicationResult({required this.name, this.totalLeaveDays});

  final String name;
  final double? totalLeaveDays;
}

class LeaveApplicationApi {
  LeaveApplicationApi({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  String? _optionsSessionCookie;

  Uri _endpoint() {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    return base.resolve('api/method/create_leave_application_from_mobile');
  }

  Future<Map<String, String>> _headers({String? csrfToken}) async {
    final sid = await SessionAuthApi.getSessionId();
    if (sid == null || sid.isEmpty) {
      throw StateError(
        'Your Frappe session has expired. Please sign in again.',
      );
    }
    return {
      'Accept': 'application/json',
      'Cookie': 'sid=$sid',
      if (csrfToken != null)
        'Content-Type': 'application/x-www-form-urlencoded',
      if (csrfToken != null && csrfToken.isNotEmpty)
        'X-Frappe-CSRF-Token': csrfToken,
    };
  }

  Map<String, dynamic> _message(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const FormatException('The server returned an invalid response.');
    }
    if (response.statusCode != 200) {
      String? error;
      if (decoded is Map) {
        final messages = decoded['_server_messages'];
        if (messages is String) {
          try {
            final rows = jsonDecode(messages);
            if (rows is List && rows.isNotEmpty) {
              final row =
                  rows.first is String ? jsonDecode(rows.first) : rows.first;
              if (row is Map) error = row['message']?.toString();
            }
          } catch (_) {
            // Use the ordinary message or exception when server messages are malformed.
          }
        }
        if (decoded['message'] is String) error ??= decoded['message'];
        error ??= decoded['exception']?.toString().split('\n').first;
      }
      throw StateError(
        error ?? 'Leave Application request failed (${response.statusCode}).',
      );
    }
    final message = decoded is Map ? decoded['message'] : null;
    if (message is! Map) {
      throw const FormatException('The server returned an invalid response.');
    }
    return Map<String, dynamic>.from(message);
  }

  Future<LeaveApplicationOptions> loadOptions() async {
    final headers = await _headers();
    final response = await _client
        .get(
          _endpoint(),
          headers: {...headers, 'Cache-Control': 'no-cache, no-store'},
        )
        .timeout(const Duration(seconds: 25));
    await _assertSameSession(headers);
    final message = _message(response);
    if ((message['csrf_token']?.toString().trim() ?? '').isEmpty) {
      message['csrf_token'] = await _loadDeskCsrf(headers);
    }
    final options = LeaveApplicationOptions.fromJson(message);
    _optionsSessionCookie = headers['Cookie'];
    return options;
  }

  Future<void> _assertSameSession(Map<String, String> headers) async {
    if ((await _headers())['Cookie'] != headers['Cookie']) {
      throw StateError(
        'Your session changed. Reopen the leave form and try again.',
      );
    }
  }

  Future<String> _loadDeskCsrf(Map<String, String> headers) async {
    var uri = _endpoint().resolve('/app');
    for (var redirects = 0; redirects <= 3; redirects++) {
      await _assertSameSession(headers);
      final response = await (() async {
        final streamed = await _client.send(
          http.Request('GET', uri)
            ..headers.addAll({
              ...headers,
              'Cache-Control': 'no-cache, no-store',
            })
            ..followRedirects = false,
        );
        return http.Response.fromStream(streamed);
      })().timeout(const Duration(seconds: 25));
      await _assertSameSession(headers);
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) break;
        final next = uri.resolve(location);
        if (next.origin != uri.origin || next.userInfo.isNotEmpty) {
          throw StateError(
            'ERP redirected to a different site. Check SITE_URL.',
          );
        }
        uri = next;
        continue;
      }
      if (response.statusCode == 200) {
        final match = RegExp(
          r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
        ).firstMatch(response.body);
        final token = match?.group(1)?.trim();
        if (token != null && token.isNotEmpty) return token;
      }
      break;
    }
    throw StateError(
      'ERP could not initialize the leave session token. Sign in again and reopen the leave form.',
    );
  }

  bool _isCsrfFailure(http.Response response) {
    if (response.statusCode == 200) return false;
    try {
      final body = jsonDecode(response.body);
      return body is Map &&
          (body['exc_type'] == 'CSRFTokenError' ||
              body['exception']?.toString().startsWith(
                    'frappe.exceptions.CSRFTokenError:',
                  ) ==
                  true);
    } catch (_) {
      return false;
    }
  }

  Future<LeaveApplicationResult> submitApplication({
    required String leaveType,
    required DateTime fromDate,
    required DateTime toDate,
    required String reason,
    required bool halfDay,
    required String csrfToken,
  }) async {
    final headers = await _headers();
    if (_optionsSessionCookie != null &&
        _optionsSessionCookie != headers['Cookie']) {
      throw StateError(
        'Your session changed. Reopen the leave form and try again.',
      );
    }
    var token = csrfToken.trim();
    if (token.isEmpty) token = await _loadDeskCsrf(headers);
    Future<http.Response> post(String currentToken) async {
      await _assertSameSession(headers);
      return _client
          .post(
            _endpoint(),
            headers: {
              ...headers,
              'Content-Type': 'application/x-www-form-urlencoded',
              'X-Frappe-CSRF-Token': currentToken,
            },
            body: {
              'leave_type': leaveType,
              'from_date': DateFormat('yyyy-MM-dd').format(fromDate),
              'to_date': DateFormat('yyyy-MM-dd').format(toDate),
              'description': reason.trim(),
              'half_day': halfDay ? '1' : '0',
              'csrf_token': currentToken,
            },
          )
          .timeout(const Duration(seconds: 90));
    }

    var response = await post(token);
    // Frappe rejects CSRF before running the leave creation script. Only this
    // explicit rejection is safe to refresh/retry; never retry a timeout or
    // ordinary validation error that could otherwise duplicate an application.
    if (_isCsrfFailure(response)) {
      await _assertSameSession(headers);
      token = await _loadDeskCsrf(headers);
      response = await post(token);
    }
    await _assertSameSession(headers);
    final message = _message(response);
    final name = message['name']?.toString().trim() ?? '';
    if (message['status'] != 'success' || name.isEmpty) {
      throw const FormatException(
        'ERPNext did not confirm the Leave Application.',
      );
    }
    return LeaveApplicationResult(
      name: name,
      totalLeaveDays: double.tryParse(
        message['total_leave_days']?.toString() ?? '',
      ),
    );
  }

  void close() => _client.close();
}
