import 'dart:convert';
import '../api_business_policy.dart';
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
  final bool supportsMultipleExpenses;
  final ApiBusinessPolicy businessPolicy;

  const ExpenseClaimFormOptions({
    required this.defaultEmployee,
    required this.defaultExpenseApprover,
    required this.currency,
    required this.csrfToken,
    required this.employees,
    required this.expenseApprovers,
    required this.expenseTypes,
    this.supportsMultipleExpenses = false,
    this.businessPolicy = ApiBusinessPolicy.empty,
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

  factory ExpenseClaimFormOptions.fromJson(Map<String, dynamic> json) {
    final policy = ApiBusinessPolicy.fromApi(json['business_policy']);
    final types = _readOptions(json['expense_types'], 'Expense Type');
    final allowed = policy.options(
      'expense_type',
      types.map((row) => row.value).toList(),
    );
    return ExpenseClaimFormOptions(
      businessPolicy: policy,
      defaultEmployee: json['employee']?.toString() ?? '',
      defaultExpenseApprover: json['expense_approver']?.toString() ?? '',
      currency: json['currency']?.toString() ?? '',
      csrfToken: json['csrf_token']?.toString() ?? '',
      supportsMultipleExpenses: json['supports_multiple_expenses'] == true,
      employees: _readOptions(json['employee_options'], 'Employee'),
      expenseApprovers: _readOptions(
        json['expense_approver_options'],
        'Expense Approver',
      ),
      expenseTypes: types.where((row) => allowed.contains(row.value)).toList(),
    );
  }
}

class ExpenseClaimLine {
  final String expenseType;
  final String amount;
  final String expenseDate;
  final String description;

  const ExpenseClaimLine({
    required this.expenseType,
    required this.amount,
    required this.expenseDate,
    required this.description,
  });

  Map<String, String> toJson() => {
    'expense_type': expenseType.trim(),
    'amount': amount.trim().replaceAll(',', ''),
    'expense_date': expenseDate,
    'description': description.trim(),
  };
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
  static String? _formSession;
  static Uri? _formEndpoint;
  static String? _csrfToken;

  static Future<void> _assertSession(String sid) async {
    if (await SessionAuthApi.getSessionId() != sid ||
        (_formEndpoint != null &&
            _formEndpoint != _endpoint('api/method/$_method'))) {
      throw StateError(
        'Your session changed. Reopen the Expense Claim form and try again.',
      );
    }
  }

  static Future<String> _loadCsrfToken(String sid) async {
    var uri = _endpoint('api/method/$_method').resolve('/app');
    final client = http.Client();
    try {
      for (var redirects = 0; redirects <= 3; redirects++) {
        await _assertSession(sid);
        final response = await (() async {
          final streamed = await client.send(
            http.Request('GET', uri)
              ..headers.addAll({
                'Accept': 'text/html',
                'Cookie': 'sid=$sid',
                'Cache-Control': 'no-cache, no-store',
              })
              ..followRedirects = false,
          );
          return http.Response.fromStream(streamed);
        })().timeout(const Duration(seconds: 20));
        await _assertSession(sid);
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
          final token =
              RegExp(
                r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
              ).firstMatch(response.body)?.group(1)?.trim() ??
              '';
          if (token.isNotEmpty) return token;
        }
        break;
      }
    } finally {
      client.close();
    }
    throw StateError(
      'Could not initialize the Expense Claim session token. Sign in again and reopen the form.',
    );
  }

  static bool _isCsrfFailure(http.Response response) {
    if (response.statusCode == 200) return false;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map &&
          (decoded['exc_type'] == 'CSRFTokenError' ||
              decoded['exception']?.toString().startsWith(
                    'frappe.exceptions.CSRFTokenError:',
                  ) ==
                  true);
    } catch (_) {
      return false;
    }
  }

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
      final rawMessage = decoded['message'];
      final message =
          rawMessage is Map
              ? rawMessage['message']?.toString()
              : rawMessage?.toString();
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
      if (message != null && message.isNotEmpty) return message;
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
    final response = await http
        .get(
          requestUri,
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 25));
    if (await SessionAuthApi.getSessionId() != sid ||
        uri != _endpoint('api/method/$_method')) {
      throw StateError('Your session changed. Reopen the Expense Claim form.');
    }
    final options = ExpenseClaimFormOptions.fromJson(_decodeMessage(response));
    _formSession = sid;
    _formEndpoint = uri;
    _csrfToken = options.csrfToken.trim();
    return options;
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
  }) => submitExpenses(
    employee: employee,
    expenseApprover: expenseApprover,
    expenses: [
      ExpenseClaimLine(
        expenseType: expenseType,
        amount: amount,
        expenseDate: expenseDate,
        description: description,
      ),
    ],
    csrfToken: csrfToken,
    billPaths: [billPath],
  );

  static Future<ExpenseClaimCreationResult> submitExpenses({
    required String employee,
    required String expenseApprover,
    required List<ExpenseClaimLine> expenses,
    required String csrfToken,
    required List<String> billPaths,
    bool supportsMultipleExpenses = false,
    ApiBusinessPolicy businessPolicy = ApiBusinessPolicy.empty,
  }) async {
    if (employee.trim().isEmpty || expenseApprover.trim().isEmpty) {
      throw StateError('Choose an Employee and Expense Approver.');
    }
    if (expenses.isEmpty) {
      throw StateError('Add at least one expense.');
    }
    if (billPaths.length <
        (businessPolicy.data.isEmpty ? 1 : businessPolicy.minimumUploads)) {
      throw StateError('Attach a bill photo before submitting.');
    }
    if (!supportsMultipleExpenses &&
        (expenses.length > 1 || billPaths.length > 1)) {
      throw StateError(
        'Update the Expense Claim Server Script to submit multiple expenses or bills.',
      );
    }
    for (var index = 0; index < expenses.length; index++) {
      final row = expenses[index].toJson();
      final amount = double.tryParse(row['amount']!);
      if (businessPolicy.validate(
                'expense_type',
                row['expense_type'],
                legacyRequired: true,
              ) !=
              null ||
          row['expense_date']!.isEmpty ||
          businessPolicy.validate(
                'description',
                row['description'],
                legacyRequired: true,
              ) !=
              null ||
          amount == null ||
          !amount.isFinite ||
          (businessPolicy.hasField('amount')
              ? businessPolicy.validate('amount', row['amount']) != null
              : amount <= 0)) {
        throw StateError(
          'Complete the required fields in expense ${index + 1}.',
        );
      }
    }
    final sid = await _sessionId();
    final uploadError = await businessPolicy.validateUploads(billPaths);
    if (uploadError != null) throw StateError(uploadError);
    final maxRows = businessPolicy.rules['max_expense_rows'] as int? ?? 0;
    if (maxRows > 0 && expenses.length > maxRows)
      throw StateError('The permitted expense row count has been exceeded.');
    for (final billPath in billPaths) {
      if (!await File(billPath).exists()) {
        throw StateError(
          'The selected bill image is missing. Choose it again.',
        );
      }
    }

    final endpoint = _endpoint('api/method/$_method');
    if (_formSession != null &&
        (_formSession != sid || _formEndpoint != endpoint)) {
      throw StateError('Your session changed. Reopen the Expense Claim form.');
    }
    var token = (_csrfToken ?? csrfToken).trim();
    if (token.isEmpty) token = await _loadCsrfToken(sid);

    Future<http.Response> post(String currentToken) async {
      await _assertSession(sid);
      // Multipart streams are consumed once. Rebuild every file for the
      // single retry that is safe after Frappe rejects CSRF before execution.
      final request = http.MultipartRequest('POST', endpoint)
        ..followRedirects = false;
      request.headers.addAll({
        'Accept': 'application/json',
        'Cookie': 'sid=$sid',
        'X-Frappe-CSRF-Token': currentToken,
      });
      request.fields.addAll({
        'employee': employee.trim(),
        'expense_approver': expenseApprover.trim(),
        ...expenses.first.toJson(),
        if (supportsMultipleExpenses)
          'expenses': jsonEncode(expenses.map((row) => row.toJson()).toList()),
        'csrf_token': currentToken,
      });
      for (final billPath in billPaths) {
        request.files.add(
          await http.MultipartFile.fromPath(
            'file',
            billPath,
            filename: path.basename(billPath),
          ),
        );
      }
      await _assertSession(sid);
      final client = http.Client();
      try {
        return await client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 90));
      } finally {
        client.close();
      }
    }

    var response = await post(token);
    // Never repeat timeouts, validation errors or ambiguous server failures:
    // the claim and bills may already have been saved.
    if (_isCsrfFailure(response)) {
      token = await _loadCsrfToken(sid);
      response = await post(token);
    }
    await _assertSession(sid);
    _formSession = sid;
    _formEndpoint = endpoint;
    _csrfToken = token;
    final message = _decodeMessage(response);
    final claimName = message['name']?.toString() ?? '';
    final expenseRow = message['expense_row']?.toString() ?? '';
    if (claimName.isEmpty) {
      throw const FormatException('ERPNext did not return the new claim name.');
    }
    final billUrl = message['bill_file_url']?.toString() ?? '';
    if (billUrl.isEmpty && billPaths.isNotEmpty) {
      throw const FormatException(
        'ERPNext created the claim but did not confirm that the bill was attached.',
      );
    }
    if (supportsMultipleExpenses) {
      final savedExpenses = message['expenses'];
      final savedBills = message['bill_files'];
      if (savedExpenses is! List ||
          savedExpenses.length != expenses.length ||
          savedBills is! List ||
          savedBills.length != billPaths.length ||
          savedBills.any(
            (bill) =>
                bill is! Map || (bill['file_url']?.toString() ?? '').isEmpty,
          )) {
        throw FormatException(
          'ERPNext returned claim $claimName without confirming every expense and bill. Check this claim before retrying.',
        );
      }
    }
    return ExpenseClaimCreationResult(name: claimName, expenseRow: expenseRow);
  }
}
