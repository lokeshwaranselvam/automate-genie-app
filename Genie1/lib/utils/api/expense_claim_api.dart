import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'session_auth.dart';

class ExpenseClaimOption {
  final String value;
  final String label;

  const ExpenseClaimOption({required this.value, required this.label});

  factory ExpenseClaimOption.fromJson(Map<String, dynamic> json) =>
      ExpenseClaimOption(
        value: json['value']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
      );
}

class ExpenseClaimFormOptions {
  final String defaultEmployee;
  final String defaultExpenseApprover;
  final String currency;
  final String csrfToken;
  final List<ExpenseClaimOption> employees;
  final List<ExpenseClaimOption> expenseApprovers;
  final List<ExpenseClaimOption> expenseTypes;

  const ExpenseClaimFormOptions({
    required this.defaultEmployee,
    required this.defaultExpenseApprover,
    required this.currency,
    required this.csrfToken,
    required this.employees,
    required this.expenseApprovers,
    required this.expenseTypes,
  });

  static List<ExpenseClaimOption> _readOptions(dynamic raw, String label) {
    if (raw is! List) {
      throw FormatException('The server did not return $label options.');
    }
    final options =
        raw
            .whereType<Map>()
            .map(
              (value) =>
                  ExpenseClaimOption.fromJson(Map<String, dynamic>.from(value)),
            )
            .where(
              (option) => option.value.isNotEmpty && option.label.isNotEmpty,
            )
            .toList();
    if (options.isEmpty) {
      throw FormatException('No $label options were returned by ERPNext.');
    }
    return options;
  }

  factory ExpenseClaimFormOptions.fromJson(Map<String, dynamic> json) =>
      ExpenseClaimFormOptions(
        defaultEmployee: json['employee']?.toString() ?? '',
        defaultExpenseApprover: json['expense_approver']?.toString() ?? '',
        currency: json['currency']?.toString() ?? '',
        csrfToken: json['csrf_token']?.toString() ?? '',
        employees: _readOptions(json['employee_options'], 'Employee'),
        expenseApprovers: _readOptions(
          json['expense_approver_options'],
          'Expense Approver',
        ),
        expenseTypes: _readOptions(json['expense_types'], 'Expense Type'),
      );
}

class ExpenseClaimCreationResult {
  final String name;
  final String expenseRow;

  const ExpenseClaimCreationResult({
    required this.name,
    required this.expenseRow,
  });
}

class ExpenseClaimApi {
  static const _method = 'create_expense_claim_from_mobile';
  static final http.Client _client = http.Client();

  static Uri _endpoint(String path) {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    return base.resolve(path);
  }

  static Future<String> _sessionId() async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    return sid;
  }

  static Map<String, dynamic> _decodeMessage(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const FormatException('The server returned an invalid response.');
    }
    final message = decoded is Map ? decoded['message'] : null;
    if (response.statusCode != 200) {
      throw StateError(_serverError(decoded, response.statusCode));
    }
    if (message is! Map) {
      throw const FormatException('The server returned an invalid response.');
    }
    return Map<String, dynamic>.from(message);
  }

  static String _serverError(dynamic decoded, int statusCode) {
    if (decoded is Map) {
      final message = decoded['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
      final serverMessages = decoded['_server_messages'];
      if (serverMessages is String && serverMessages.isNotEmpty) {
        try {
          final parsed = jsonDecode(serverMessages);
          if (parsed is List && parsed.isNotEmpty) {
            final first = parsed.first;
            if (first is String) {
              final detail = jsonDecode(first);
              if (detail is Map && detail['message'] != null) {
                return detail['message'].toString();
              }
            }
          }
        } catch (_) {
          // Use Frappe's standard exception field below.
        }
      }
      final exception = decoded['exception']?.toString();
      if (exception != null && exception.isNotEmpty) {
        return exception
            .split('\n')
            .last
            .replaceFirst(RegExp(r'^[\w.]+:\s*'), '');
      }
    }
    return 'Expense Claim request failed ($statusCode).';
  }

  static Future<ExpenseClaimFormOptions> loadFormOptions({
    String? employee,
  }) async {
    final sid = await _sessionId();
    final uri = _endpoint('api/method/$_method');
    final requestUri =
        employee == null || employee.isEmpty
            ? uri
            : uri.replace(queryParameters: {'employee': employee});
    final response = await _client
        .get(
          requestUri,
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 25));
    return ExpenseClaimFormOptions.fromJson(_decodeMessage(response));
  }

  static Future<ExpenseClaimCreationResult> submitClaim({
    required String employee,
    required String expenseApprover,
    required String expenseType,
    required String amount,
    required String expenseDate,
    required String description,
    required String csrfToken,
    required String billPath,
  }) async {
    final sid = await _sessionId();
    final bill = File(billPath);
    if (!await bill.exists()) {
      throw StateError('The selected bill image is missing. Choose it again.');
    }

    final request = http.MultipartRequest(
      'POST',
      _endpoint('api/method/$_method'),
    );
    request.headers.addAll({
      'Accept': 'application/json',
      'Cookie': 'sid=$sid',
      if (csrfToken.isNotEmpty) 'X-Frappe-CSRF-Token': csrfToken,
    });
    request.fields.addAll({
      'employee': employee,
      'expense_approver': expenseApprover,
      'expense_type': expenseType,
      'amount': amount,
      'expense_date': expenseDate,
      'description': description,
    });
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        billPath,
        filename: path.basename(billPath),
      ),
    );

    // Submit the image and claim together. The server stores the image against
    // the newly created claim before returning, so there is no second upload
    // request that can be skipped when the claim response is delayed.
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 90));
    final message = _decodeMessage(response);
    final claimName = message['name']?.toString() ?? '';
    final expenseRow = message['expense_row']?.toString() ?? '';
    if (claimName.isEmpty) {
      throw const FormatException('ERPNext did not return the new claim name.');
    }
    final billUrl = message['bill_file_url']?.toString() ?? '';
    if (billUrl.isEmpty) {
      throw const FormatException(
        'ERPNext created the claim but did not confirm that the bill was attached.',
      );
    }
    return ExpenseClaimCreationResult(name: claimName, expenseRow: expenseRow);
  }
}
