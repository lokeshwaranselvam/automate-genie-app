import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

/// Pending-work calls use the authenticated Frappe session, so each endpoint
/// evaluates frappe.session.user on the server.
class PendingWorkApi {
  static String? _csrfToken;
  static String? _taskSession;
  static Uri? _taskEndpoint;
  static const _taskApiMethod = 'my_assigned_tasks';

  static Future<void> _assertTaskSession(String sid, Uri endpoint) async {
    if (await SessionAuthApi.getSessionId() != sid ||
        _endpoint(_taskApiMethod) != endpoint) {
      throw StateError('Your session changed. Refresh My Tasks and try again.');
    }
  }

  static Future<String> _loadTaskCsrf(String sid, Uri endpoint) async {
    var uri = endpoint.resolve('/app');
    final client = http.Client();
    try {
      for (var redirects = 0; redirects <= 3; redirects++) {
        await _assertTaskSession(sid, endpoint);
        final response = await (() async {
          final stream = await client.send(
            http.Request('GET', uri)
              ..headers.addAll({
                'Accept': 'text/html',
                'Cookie': 'sid=$sid',
                'Cache-Control': 'no-cache, no-store',
              })
              ..followRedirects = false,
          );
          return http.Response.fromStream(stream);
        })().timeout(const Duration(seconds: 25));
        await _assertTaskSession(sid, endpoint);
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
      'ERP could not initialize the task session token. Sign in again and retry.',
    );
  }

  static bool _isCsrfFailure(http.Response response) {
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

  static Uri _endpoint(String method, {Map<String, String>? query}) {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    final endpoint = base.resolve('api/method/$method');
    return query == null ? endpoint : endpoint.replace(queryParameters: query);
  }

  static Future<Map<String, dynamic>> _getMessage(String action) async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError(
        'Your Frappe session has expired. Please sign in again.',
      );
    }

    final response = await http
        .get(
          _endpoint('get_pending_work', query: {'action': action}),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
            'Pragma': 'no-cache',
          },
        )
        .timeout(const Duration(seconds: 40));

    if (response.statusCode != 200) {
      throw StateError(
        _serverError(response.body, action, response.statusCode),
      );
    }

    final decoded = jsonDecode(response.body);
    final message = decoded is Map ? decoded['message'] : null;
    if (message is! Map) {
      throw const FormatException('The server returned an invalid response.');
    }
    return Map<String, dynamic>.from(message);
  }

  static String _serverError(String body, String action, int statusCode) {
    String? detail;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final messages = decoded['_server_messages'];
        if (messages is String && messages.isNotEmpty) {
          final parsedMessages = jsonDecode(messages);
          if (parsedMessages is List && parsedMessages.isNotEmpty) {
            final first = parsedMessages.first;
            if (first is String) {
              final parsedFirst = jsonDecode(first);
              if (parsedFirst is Map) {
                detail = parsedFirst['message']?.toString();
              }
            } else if (first is Map) {
              detail = first['message']?.toString();
            }
          }
        }
        detail ??= decoded['exception']?.toString().split('\n').first;
        detail ??= decoded['message']?.toString();
        detail ??= decoded['exc_type']?.toString();
      }
    } catch (_) {
      // Keep the HTTP status if Frappe returned a non-JSON error page.
    }

    final suffix = detail == null || detail.isEmpty ? '' : ': $detail';
    return 'Pending work ($action) failed ($statusCode)$suffix';
  }

  static List<Map<String, dynamic>> _items(Map<String, dynamic> response) {
    final raw = response['items'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static Future<Map<String, dynamic>> getMobileDashboard() =>
      _getMessage('dashboard');

  static Future<List<Map<String, dynamic>>> getPendingTasks() async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError(
        'Your Frappe session has expired. Please sign in again.',
      );
    }

    // This dedicated endpoint always scopes results to frappe.session.user.
    final endpoint = _endpoint(_taskApiMethod);
    final uri = endpoint.replace(queryParameters: {'action': 'get'});
    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
            'Pragma': 'no-cache',
          },
        )
        .timeout(const Duration(seconds: 40));

    if (response.statusCode != 200) {
      throw StateError(
        _serverError(response.body, 'tasks', response.statusCode),
      );
    }

    final decoded = jsonDecode(response.body);
    final message = decoded is Map ? decoded['message'] : null;
    final rawTasks = message is Map ? message['task_data'] : null;
    if (rawTasks is! List) {
      throw const FormatException(
        'The task service returned an invalid response.',
      );
    }
    final tasks =
        rawTasks.whereType<Map>().map((row) {
          return Map<String, dynamic>.from(row);
        }).toList();
    final serverAssignedUser =
        message is Map ? message['assigned_user']?.toString().trim() : null;
    if (message is! Map ||
        message['assigned_to_only'] != true ||
        serverAssignedUser == null ||
        serverAssignedUser.isEmpty ||
        serverAssignedUser.toLowerCase() == 'guest' ||
        serverAssignedUser.toLowerCase() != user.trim().toLowerCase()) {
      throw const FormatException(
        'The task API response does not match the signed-in user or is not restricted to assigned tasks.',
      );
    }
    await _assertTaskSession(sid, endpoint);
    final token = message['csrf_token']?.toString().trim() ?? '';
    if (_taskSession != sid || _taskEndpoint != endpoint) _csrfToken = null;
    _taskSession = sid;
    _taskEndpoint = endpoint;
    if (token.isNotEmpty) _csrfToken = token;
    return tasks;
  }

  /// Completes one task through the dedicated API, which verifies assignment
  /// before updating the Task and its linked ToDo.
  static Future<void> completePendingTask(Map<String, dynamic> task) async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null || sid.isEmpty) {
      throw StateError(
        'Your Frappe session has expired. Please sign in again.',
      );
    }
    final taskId =
        (task['name'] ?? task['task_id'] ?? task['id'] ?? '').toString().trim();
    if (taskId.isEmpty) {
      throw const FormatException('The task is missing its ERP ID.');
    }

    final endpoint = _endpoint(_taskApiMethod);
    if (_taskSession != null &&
        (_taskSession != sid || _taskEndpoint != endpoint)) {
      throw StateError('Your session changed. Refresh My Tasks and try again.');
    }
    var token = _csrfToken ?? '';
    if (token.isEmpty) token = await _loadTaskCsrf(sid, endpoint);
    Future<http.Response> post(String currentToken) async {
      await _assertTaskSession(sid, endpoint);
      return http
          .post(
            endpoint.replace(
              queryParameters: {'action': 'complete', 'task_id': taskId},
            ),
            headers: {
              'Accept': 'application/json',
              'Cookie': 'sid=$sid',
              'Cache-Control': 'no-cache, no-store',
              'X-Frappe-CSRF-Token': currentToken,
            },
            body: {'csrf_token': currentToken},
          )
          .timeout(const Duration(seconds: 40));
    }

    var response = await post(token);
    // CSRF is rejected before the task API executes. Never automatically
    // retry timeouts, permission failures, or ordinary validation errors.
    if (_isCsrfFailure(response)) {
      token = await _loadTaskCsrf(sid, endpoint);
      response = await post(token);
    }
    await _assertTaskSession(sid, endpoint);
    _taskSession = sid;
    _taskEndpoint = endpoint;
    _csrfToken = token;

    if (response.statusCode != 200) {
      throw StateError(
        _serverError(response.body, 'complete task', response.statusCode),
      );
    }
    final decoded = jsonDecode(response.body);
    final message = decoded is Map ? decoded['message'] : null;
    if (message is! Map || message['status'] != 'success') {
      final detail = message is Map ? message['message']?.toString() : null;
      throw StateError(detail ?? 'ERP did not confirm task completion.');
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingWorkOrders() async =>
      _items(await _getMessage('work_orders'));

  static Future<List<Map<String, dynamic>>> getPendingJobCards() async =>
      _items(await _getMessage('job_cards'));

  static Future<List<Map<String, dynamic>>> getPendingProjects() async =>
      _items(await _getMessage('projects'));

  static Future<List<Map<String, dynamic>>> getPendingSectionItems(
    String section,
  ) async {
    switch (section) {
      case 'same_area_city':
        return _items(await _getMessage('same_area_city'));
      case 'stock':
        return _items(await _getMessage('stock'));
      case 'manufacturing':
        return _items(await _getMessage('manufacturing'));
      case 'projects':
        return _items(await _getMessage('projects'));
      case 'opportunities':
        return _items(await _getMessage('opportunities'));
      case 'overdue_followups':
        return _items(await _getMessage('overdue_followups'));
      case 'overdue_closing':
        return _items(await _getMessage('overdue_closing'));
      case 'draft_delivery_plans':
        return _items(await _getMessage('draft_delivery_plans'));
      default:
        throw ArgumentError.value(
          section,
          'section',
          'Unknown pending section',
        );
    }
  }
}
