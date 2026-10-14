import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

class LeadFormOptions {
  final String leadOwner;
  final String leadOwnerName;
  final List<String> sourceOptions;
  final List<String> productCategoryOptions;
  final String? csrfToken;

  const LeadFormOptions({
    required this.leadOwner,
    required this.leadOwnerName,
    required this.sourceOptions,
    required this.productCategoryOptions,
    this.csrfToken,
  });
}

class LeadApi {
  static const _method = 'create_lead_from_mobile';
  // Reuse the connection between loading form options and submitting the form.
  static final http.Client _client = http.Client();

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
    final response = await _client
        .get(
          _endpoint(),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 20));
    final message = _message(response);
    final rawSources = message['source_options'];
    final rawCategories = message['product_category_options'];
    if (rawSources is! List || rawCategories is! List) {
      throw const FormatException(
        'The server did not return Lead Source and Product Category options.',
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
        'No Lead Source options were returned. Configure Lead.custom_source in Frappe.',
      );
    }
    if (productCategoryOptions.isEmpty) {
      throw const FormatException(
        'No Product Category options were returned. Configure Lead.custom_product_enquired in Frappe.',
      );
    }

    return LeadFormOptions(
      leadOwner: message['lead_owner']?.toString() ?? '',
      leadOwnerName: message['lead_owner_name']?.toString() ?? '',
      sourceOptions: sourceOptions,
      productCategoryOptions: productCategoryOptions,
      csrfToken: message['csrf_token']?.toString(),
    );
  }

  static Future<List<Map<String, dynamic>>> getMyLeads() async {
    final sid = await _sessionId();
    final response = await _client
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

  static Future<Map<String, dynamic>> createLead({
    required String firstName,
    required String mobileNo,
    required String requirement,
    required String source,
    required String productCategory,
    required String address,
    required String csrfToken,
  }) async {
    // The form already loaded the session and CSRF token. Reuse them instead
    // of making extra validation and form-options requests on every submit.
    final sid = await _sessionId();
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': 'sid=$sid',
    };
    if (csrfToken.isNotEmpty) {
      headers['X-Frappe-CSRF-Token'] = csrfToken;
    }

    final response = await _client
        .post(
          _endpoint(),
          headers: headers,
          body: {
            'first_name': firstName.trim(),
            'mobile_no': mobileNo.trim(),
            'custom_requirement': requirement.trim(),
            'custom_source': source.trim(),
            'custom_product_enquired': productCategory.trim(),
            'custom_address': address.trim(),
          },
        )
        .timeout(const Duration(seconds: 30));

    return _message(response);
  }
}
