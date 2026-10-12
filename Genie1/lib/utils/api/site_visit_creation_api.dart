import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

class SiteVisitCreationApi {
  static const _method = 'mobile_site_visit';
  static String? _csrfToken;

  static Uri _endpoint({Map<String, String>? query}) {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    final uri = base.resolve('api/method/$_method');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  static Future<Map<String, dynamic>> _post(Map<String, String> fields) async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }

    final response = await http
        .post(
          _endpoint(),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Cookie': 'sid=$sid',
            if (_csrfToken != null && _csrfToken!.isNotEmpty)
              'X-Frappe-CSRF-Token': _csrfToken!,
          },
          body: fields,
        )
        .timeout(const Duration(seconds: 40));

    return _decodeResponse(response, user);
  }

  static Map<String, dynamic> _decodeResponse(
    http.Response response,
    String expectedUser,
  ) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw StateError('The site visit service returned an invalid response.');
    }
    final message = decoded is Map ? decoded['message'] : null;
    if (response.statusCode != 200 || message is! Map) {
      throw StateError(_errorMessage(decoded, response.statusCode));
    }
    final result = Map<String, dynamic>.from(message);
    _csrfToken = result['csrf_token']?.toString();
    final serverUser = result['current_user']?.toString().trim();
    if (serverUser != null &&
        serverUser.isNotEmpty &&
        serverUser.toLowerCase() != expectedUser.trim().toLowerCase()) {
      throw const FormatException(
        'The ERP response belongs to a different signed-in user.',
      );
    }
    if (result['status'] == 'error') {
      throw StateError(result['message']?.toString() ?? 'Site visit failed.');
    }
    return result;
  }

  static String _errorMessage(dynamic decoded, int statusCode) {
    if (decoded is Map) {
      final message = decoded['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
      final serverMessages = decoded['_server_messages'];
      if (serverMessages is String) {
        try {
          final messages = jsonDecode(serverMessages);
          if (messages is List && messages.isNotEmpty) {
            final first = messages.first;
            if (first is String) {
              final detail = jsonDecode(first);
              if (detail is Map && detail['message'] != null) {
                return detail['message'].toString();
              }
            }
          }
        } catch (_) {
          // Fall back to the HTTP status below.
        }
      }
      final exception = decoded['exception']?.toString();
      if (exception != null && exception.isNotEmpty) {
        final lines =
            exception
                .split('\n')
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty)
                .toList();
        if (lines.isNotEmpty) {
          return lines.last.replaceFirst(RegExp(r'^[\w.]+:\s*'), '');
        }
      }
    }
    return 'Site visit request failed ($statusCode).';
  }

  static Future<Map<String, dynamic>> loadOptions() async {
    // This endpoint authenticates the session and returns current_user, which
    // _decodeResponse checks. Avoid an extra session-check HTTP request.
    final user =
        await SessionAuthApi.getSavedSessionUser() ??
        await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    final response = await http
        .get(
          _endpoint(query: const {'action': 'get'}),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 40));
    final result = _decodeResponse(response, user);
    if (result['opportunities'] is! List ||
        result['product_enquired_options'] is! List ||
        result['event_categories'] is! List ||
        result['location_types'] is! List ||
        result['users'] is! List) {
      throw const FormatException(
        'The site visit service returned incomplete form options.',
      );
    }
    return result;
  }

  /// Opportunities whose Opportunity or linked
  /// Lead has a mobile number containing [mobile].
  static Future<List<Map<String, dynamic>>> searchByMobile(
    String mobile,
  ) async {
    final user =
        await SessionAuthApi.getSavedSessionUser() ??
        await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    final response = await http
        .get(
          _endpoint(query: {'action': 'search_by_mobile', 'mobile': mobile}),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 40));
    final result = _decodeResponse(response, user);
    final opportunities = result['opportunities'];
    if (opportunities is! List) {
      throw const FormatException(
        'The site visit service returned an invalid mobile search response.',
      );
    }
    return opportunities
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static Future<Map<String, dynamic>> saveLocation({
    required String opportunity,
    required String mapLink,
    required double latitude,
    required double longitude,
    required String locationType,
  }) => _post({
    'action': 'save_location',
    'opportunity': opportunity,
    'map_link': mapLink,
    'latitude': latitude.toString(),
    'longitude': longitude.toString(),
    'location_type': locationType,
  });

  static Future<Map<String, dynamic>> createEvent({
    required String opportunity,
    required String locationRow,
    required String summary,
    required String startsOn,
    required String endsOn,
    required String assignedTo,
    required String category,
    String productEnquired = '',
  }) => _post({
    'action': 'create_event',
    'opportunity': opportunity,
    'location_row': locationRow,
    'summary': summary,
    'starts_on': startsOn,
    'ends_on': endsOn,
    'assigned_to': assignedTo,
    'category': category,
    if (productEnquired.isNotEmpty) 'product_enquired': productEnquired,
  });
}
