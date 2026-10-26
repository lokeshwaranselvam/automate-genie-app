import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

class SiteVisitCreationApi {
  static const _method = 'mobile_site_visit';
  static String? _csrfToken;
  static String? _csrfSession;
  static Uri? _csrfEndpoint;

  static void _useSession(String sid) {
    final endpoint = _endpoint();
    if (_csrfSession != sid || _csrfEndpoint != endpoint) {
      _csrfToken = null;
      _csrfSession = sid;
      _csrfEndpoint = endpoint;
    }
  }

  static Future<void> _assertSession(String sid) async {
    if (await SessionAuthApi.getSessionId() != sid) {
      throw StateError(
        'Your session changed. Reopen the visit form and try again.',
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
        })().timeout(const Duration(seconds: 40));
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
          final match = RegExp(
            r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
          ).firstMatch(response.body);
          final token = match?.group(1)?.trim() ?? '';
          if (token.isNotEmpty) return token;
        }
        break;
      }
    } finally {
      client.close();
    }
    throw StateError(
      'ERP could not initialize the visit session token. Sign in again and reopen the visit form.',
    );
  }

  static bool _isCsrfFailure(http.Response response) {
    if (response.statusCode == 200) return false;
    try {
      final data = jsonDecode(response.body);
      return data is Map &&
          (data['exc_type'] == 'CSRFTokenError' ||
              data['exception']?.toString().startsWith(
                    'frappe.exceptions.CSRFTokenError:',
                  ) ==
                  true);
    } catch (_) {
      return false;
    }
  }

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

    _useSession(sid);
    var token = _csrfToken ?? '';
    if (token.isEmpty) token = await _loadCsrfToken(sid);
    Future<http.Response> post(String currentToken) async {
      await _assertSession(sid);
      return http
          .post(
            _endpoint(),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/x-www-form-urlencoded',
              'Cookie': 'sid=$sid',
              'X-Frappe-CSRF-Token': currentToken,
            },
            body: {...fields, 'csrf_token': currentToken},
          )
          .timeout(const Duration(seconds: 40));
    }

    var response = await post(token);
    // CSRF rejection happens before the script runs. Retry only this failure;
    // retrying timeouts or validation errors could duplicate a location/event.
    if (_isCsrfFailure(response)) {
      token = await _loadCsrfToken(sid);
      response = await post(token);
    }
    await _assertSession(sid);
    _csrfToken = token;

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
    final token = result['csrf_token']?.toString().trim() ?? '';
    if (token.isNotEmpty) _csrfToken = token;
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

  /// Server-side role decision for the signed-in session; no local role cache.
  static Future<bool> canCreateVisit() async {
    return (await homeQuickActionAccess()).canCreateVisit;
  }

  static Future<
    ({
      bool canAddLead,
      bool canCreateVisit,
      bool canViewOpportunities,
      bool canViewVisits,
      bool canViewPending,
      Map<String, bool> featureVisibility,
    })
  >
  homeQuickActionAccess() async {
    final user = await SessionAuthApi.getSavedSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      return (
        canAddLead: false,
        canCreateVisit: false,
        canViewOpportunities: false,
        canViewVisits: false,
        canViewPending: false,
        featureVisibility: <String, bool>{},
      );
    }
    final response = await http
        .get(
          _endpoint(query: const {'action': 'can_create'}),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 15));
    await _assertSession(sid);
    final permission = _decodeResponse(response, user);
    if (permission['current_user']?.toString().trim().toLowerCase() !=
        user.trim().toLowerCase()) {
      throw const FormatException(
        'The ERP permission response did not verify the signed-in user.',
      );
    }
    final canCreateVisit = permission['can_create'] == true;
    final canAddLead = permission['can_create_lead'] == true;
    final visibility = permission['feature_visibility'];
    if (visibility != null &&
        (visibility is! Map ||
            visibility.values.any((value) => value is! bool))) {
      throw const FormatException(
        'ERP returned invalid feature visibility rules.',
      );
    }
    return (
      canAddLead: canAddLead,
      canCreateVisit: canCreateVisit,
      canViewOpportunities:
          permission.containsKey('can_view_opportunities')
              ? permission['can_view_opportunities'] == true
              : canCreateVisit,
      canViewVisits: permission['can_view_visits'] != false,
      canViewPending: permission['can_view_pending'] == true,
      featureVisibility:
          visibility is Map
              ? Map<String, bool>.from(visibility)
              : <String, bool>{},
    );
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
    _useSession(sid);
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
    await _assertSession(sid);
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
    _useSession(sid);
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
    await _assertSession(sid);
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

  /// Search Opportunity IDs and names beyond the initial dropdown page.
  static Future<List<Map<String, dynamic>>> searchOpportunities(
    String query,
  ) async {
    final text = query.trim();
    if (text.length < 2 || text.length > 140) {
      throw ArgumentError(
        'Enter between 2 and 140 characters of the Opportunity ID or name.',
      );
    }
    final user =
        await SessionAuthApi.getSavedSessionUser() ??
        await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    _useSession(sid);
    final response = await http
        .get(
          _endpoint(query: {'action': 'search_opportunities', 'query': text}),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 40));
    await _assertSession(sid);
    final result = _decodeResponse(response, user);
    final rows = result['opportunities'];
    if (rows is! List || rows.any((row) => row is! Map)) {
      throw const FormatException(
        'The site visit service returned an invalid Opportunity search response.',
      );
    }
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  static Future<List<Map<String, dynamic>>> loadReferences({
    required String category,
    String mobile = '',
  }) async {
    final user =
        await SessionAuthApi.getSavedSessionUser() ??
        await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    _useSession(sid);
    final response = await http
        .get(
          _endpoint(
            query: {
              'action': 'get_references',
              'category': category,
              if (mobile.isNotEmpty) 'mobile': mobile,
            },
          ),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 40));
    await _assertSession(sid);
    final result = _decodeResponse(response, user);
    final expectedDoctype =
        category.trim().toLowerCase() == 'measurement'
            ? 'Measurement'
            : 'Installation Note';
    if (result['reference_doctype'] != expectedDoctype ||
        result['references'] is! List) {
      throw const FormatException(
        'The visit service returned invalid reference documents.',
      );
    }
    return (result['references'] as List)
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
    String mapLink = '',
    String referenceDoctype = '',
    String referenceName = '',
    double? latitude,
    double? longitude,
    String locationType = '',
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
    if (referenceDoctype.isNotEmpty) 'reference_doctype': referenceDoctype,
    if (referenceName.isNotEmpty) 'reference_name': referenceName,
    if (mapLink.isNotEmpty) 'map_link': mapLink,
    if (latitude != null) 'latitude': latitude.toString(),
    if (longitude != null) 'longitude': longitude.toString(),
    if (locationType.isNotEmpty) 'location_type': locationType,
  });
}
