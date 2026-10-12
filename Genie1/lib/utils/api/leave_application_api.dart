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
    final response = await _client
        .get(
          _endpoint(),
          headers: {...await _headers(), 'Cache-Control': 'no-cache, no-store'},
        )
        .timeout(const Duration(seconds: 25));
    return LeaveApplicationOptions.fromJson(_message(response));
  }

  Future<LeaveApplicationResult> submitApplication({
    required String leaveType,
    required DateTime fromDate,
    required DateTime toDate,
    required String reason,
    required bool halfDay,
    required String csrfToken,
  }) async {
    final response = await _client
        .post(
          _endpoint(),
          headers: await _headers(csrfToken: csrfToken),
          body: {
            'leave_type': leaveType,
            'from_date': DateFormat('yyyy-MM-dd').format(fromDate),
            'to_date': DateFormat('yyyy-MM-dd').format(toDate),
            'description': reason.trim(),
            'half_day': halfDay ? '1' : '0',
          },
        )
        .timeout(const Duration(seconds: 90));
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
