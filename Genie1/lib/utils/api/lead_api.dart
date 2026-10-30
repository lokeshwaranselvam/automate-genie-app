import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';
import '../lead_phone_number.dart';
import '../api_business_policy.dart';

class LeadFormOptions {
  final String leadOwner;
  final String leadOwnerName;
  final List<String> sourceOptions;
  final List<String> productCategoryOptions;
  final List<String> customerCategoryOptions;
  final String? csrfToken;
  final ApiBusinessPolicy businessPolicy;

  const LeadFormOptions({
    required this.leadOwner,
    required this.leadOwnerName,
    required this.sourceOptions,
    required this.productCategoryOptions,
    this.customerCategoryOptions = const [],
    this.csrfToken,
    this.businessPolicy = ApiBusinessPolicy.empty,
  });
}

class LeadApi {
  static const _method = 'create_lead_from_mobile';
  static String? _formSession;
  static Uri? _formEndpoint;
  static String? _csrfToken;

  static Future<void> _assertSession(String sid) async {
    if (await _sessionId() != sid) {
      throw StateError(
        'Your session changed. Reopen the Lead form and try again.',
      );
    }
  }

  static Future<String> _loadCsrfToken(String sid) async {
    var uri = _endpoint().resolve('/app');
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
      'Could not initialize the Lead session token. Sign in again and reopen the form.',
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

  static Uri _endpoint() {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    return base.resolve('api/method/$_method');
  }

  static Future<String> _sessionId() async {
    final sid = await SessionAuthApi.getSessionId();
    if (sid == null || sid.isEmpty) {
      throw StateError(
        'Your Frappe session has expired. Please sign in again.',
      );
    }
    return sid;
  }

  static Map<String, dynamic> _message(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw FormatException('The server returned an invalid response.');
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
    String? detail;
    if (decoded is Map) {
      detail = decoded['message']?.toString();
      final serverMessages = decoded['_server_messages'];
      if (serverMessages is String && serverMessages.isNotEmpty) {
        try {
          final parsed = jsonDecode(serverMessages);
          if (parsed is List && parsed.isNotEmpty) {
            final first = parsed.first;
            if (first is String) {
              final firstMessage = jsonDecode(first);
              if (firstMessage is Map) {
                detail = firstMessage['message']?.toString() ?? detail;
              }
            } else if (first is Map) {
              detail = first['message']?.toString() ?? detail;
            }
          }
        } catch (_) {
          // Fall through to Frappe's exception/message fields.
        }
      }
      detail ??= decoded['exception']?.toString().split('\n').first;
    }

    return detail == null || detail.isEmpty
        ? 'Lead request failed ($statusCode).'
        : detail;
  }

  static Future<LeadFormOptions> getFormOptions() async {
    // This authenticated endpoint verifies the session itself and returns the
    // owner, so a separate get_logged_user request is unnecessary.
    final sid = await _sessionId();
    final endpoint = _endpoint();
    final response = await http
        .get(
          endpoint,
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 20));
    final message = _message(response);
    await _assertSession(sid);
    final rawSources = message['source_options'];
    final rawCategories = message['product_category_options'];
    final rawCustomerCategories = message['customer_category_options'];
    if (rawSources is! List || rawCategories is! List) {
      throw const FormatException(
        'The server did not return Lead Source and Product Enquired options.',
      );
    }
    if (rawCustomerCategories is! List ||
        rawCustomerCategories.any((value) => value is! String)) {
      throw const FormatException(
        'Update create_lead_from_mobile on ERP to return Customer Category options.',
      );
    }

    final sourceOptions =
        rawSources
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList();
    final productCategoryOptions =
        rawCategories
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList();
    if (sourceOptions.isEmpty) {
      throw const FormatException(
        'No Lead Source options were returned. Configure Lead.source in Frappe.',
      );
    }
    if (productCategoryOptions.isEmpty) {
      throw const FormatException(
        'No Product Enquired options were returned. Configure Lead.custom_product_enquired in Frappe.',
      );
    }

    _formSession = sid;
    _formEndpoint = endpoint;
    _csrfToken = message['csrf_token']?.toString().trim();
    final policy = ApiBusinessPolicy.fromApi(message['business_policy']);
    return LeadFormOptions(
      businessPolicy: policy,
      leadOwner: message['lead_owner']?.toString() ?? '',
      leadOwnerName: message['lead_owner_name']?.toString() ?? '',
      sourceOptions: policy.options('source', sourceOptions),
      productCategoryOptions: policy.options(
        'custom_product_enquired',
        productCategoryOptions,
      ),
      customerCategoryOptions: policy.options(
        'custom_customer_category',
        rawCustomerCategories
            .cast<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList(),
      ),
      csrfToken: _csrfToken,
    );
  }

  static Future<List<Map<String, dynamic>>> getMyLeads() async {
    final sid = await _sessionId();
    final response = await http
        .get(
          _endpoint().replace(queryParameters: {'view': 'list'}),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 20));
    final message = _message(response);
    final rawLeads = message['leads'];
    if (rawLeads is! List) {
      throw const FormatException(
        "The server did not return the signed-in user's Leads.",
      );
    }

    return rawLeads.map((lead) {
      if (lead is! Map) {
        throw const FormatException(
          'The server returned an invalid Lead record.',
        );
      }
      return Map<String, dynamic>.from(lead);
    }).toList();
  }

  static Future<Map<String, dynamic>> getLeadDetails(String name) async {
    final sid = await _sessionId();
    final response = await http
        .get(
          _endpoint().replace(
            queryParameters: {'view': 'detail', 'lead': name},
          ),
          headers: {'Accept': 'application/json', 'Cookie': 'sid=$sid'},
        )
        .timeout(const Duration(seconds: 25));
    await _assertSession(sid);
    final lead = _message(response)['lead'];
    if (lead is! Map) {
      throw const FormatException('The server did not return Lead details.');
    }
    return Map<String, dynamic>.from(lead);
  }

  static Future<Map<String, dynamic>> createLead({
    required String firstName,
    required String mobileNo,
    required String requirement,
    required String source,
    required String productCategory,
    required String address,
    required String csrfToken,
    String whatsappNo = '',
    String customerCategory = '',
    ApiBusinessPolicy businessPolicy = ApiBusinessPolicy.empty,
  }) async {
    final whatsappError =
        whatsappNo.trim().isEmpty &&
                !businessPolicy.required('whatsapp_no', true)
            ? null
            : LeadPhoneNumber.validateWhatsApp(whatsappNo);
    if (whatsappError != null) throw FormatException(whatsappError);
    final sid = await _sessionId();
    final endpoint = _endpoint();
    if (_formSession != null &&
        (_formSession != sid || _formEndpoint != endpoint)) {
      throw StateError(
        'Your session changed. Reopen the Lead form and try again.',
      );
    }
    var token = (_csrfToken ?? csrfToken).trim();
    if (token.isEmpty) token = await _loadCsrfToken(sid);
    Future<http.Response> post(String currentToken) async {
      await _assertSession(sid);
      return http
          .post(
            endpoint,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/x-www-form-urlencoded',
              'Cookie': 'sid=$sid',
              'X-Frappe-CSRF-Token': currentToken,
            },
            body: {
              'first_name': firstName.trim(),
              'mobile_no': mobileNo.trim(),
              if (whatsappNo.trim().isNotEmpty)
                'whatsapp_no': LeadPhoneNumber.normalize(whatsappNo),
              'custom_requirement': requirement.trim(),
              'source': source.trim(),
              'custom_product_enquired': productCategory.trim(),
              if (customerCategory.trim().isNotEmpty)
                'custom_customer_category': customerCategory.trim(),
              'custom_address': address.trim(),
              'csrf_token': currentToken,
            },
          )
          .timeout(const Duration(seconds: 30));
    }

    var response = await post(token);
    // Frappe rejects CSRF before executing the API. Never retry ambiguous
    // network failures or validation errors: the Lead may already exist.
    if (_isCsrfFailure(response)) {
      token = await _loadCsrfToken(sid);
      response = await post(token);
    }
    await _assertSession(sid);
    _csrfToken = token;
    final message = _message(response);
    if (message['status'] != 'success' ||
        (message['name']?.toString().trim() ?? '').isEmpty) {
      throw StateError(
        message['message']?.toString() ??
            'The server did not confirm Lead creation.',
      );
    }
    return message;
  }
}
