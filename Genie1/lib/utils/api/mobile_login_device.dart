import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// An installation credential, not a hardware ID. Kept across prefs.clear().
class MobileLoginDevice {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'genie_mobile_installation_key';
  static const _pendingName = 'genie_pending_mobile_logout';
  static const _activeName = 'genie_active_mobile_binding';
  static Future<String>? _keyRequest;
  static Future<void>? _logoutRequest;

  static Future<String> key() async {
    final request = _keyRequest ??= _loadKey();
    try {
      return await request;
    } finally {
      if (identical(_keyRequest, request)) _keyRequest = null;
    }
  }

  static Future<String> _loadKey() async {
    final saved = await _storage.read(key: _keyName);
    if (saved != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(saved)) {
      return saved;
    }
    final random = Random.secure();
    final value = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    await _storage.write(key: _keyName, value: value);
    return value;
  }

  static Future<void> logout(Uri endpoint, String user) async {
    // Persist before the network call. Enrollment's emergency local cleanup
    // must not lose the ability to release the server binding after an outage.
    await _storage.write(
      key: _pendingName,
      value: jsonEncode({'endpoint': endpoint.toString(), 'user': user}),
    );
    await completePendingLogout();
  }

  static Future<void> rememberSession(Uri endpoint, String user) async {
    final previous = await _storage.read(key: _activeName);
    final value = jsonEncode({'endpoint': endpoint.toString(), 'user': user});
    if (previous != null && previous != value) {
      final old = jsonDecode(previous) as Map;
      await logout(Uri.parse(old['endpoint'] as String), old['user'] as String);
    }
    await _storage.write(key: _activeName, value: value);
  }

  static Future<bool> logoutRememberedSession() async {
    final active = await _storage.read(key: _activeName);
    if (active == null) return false;
    final data = jsonDecode(active) as Map;
    await logout(Uri.parse(data['endpoint'] as String), data['user'] as String);
    return true;
  }

  static Future<void> completePendingLogout() async {
    final request = _logoutRequest ??= _completePendingLogout();
    try {
      await request;
    } finally {
      if (identical(_logoutRequest, request)) _logoutRequest = null;
    }
  }

  static Future<void> _completePendingLogout() async {
    final pending = await _storage.read(key: _pendingName);
    if (pending == null) return;
    final data = jsonDecode(pending) as Map;
    final endpoint = Uri.parse(data['endpoint'] as String);
    final fields = {'user': data['user'], 'device_key': await key()};
    final client = http.Client();
    try {
      Future<http.Response> post([String? csrf]) async {
        if (await _storage.read(key: _pendingName) != pending) {
          throw StateError('Your sign-out request changed. Please retry.');
        }
        final request =
            http.Request('POST', endpoint)
              ..followRedirects = !kIsWeb
              ..headers.addAll({
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                if (csrf != null) 'X-Frappe-CSRF-Token': csrf,
              })
              // Native clients omit cookies. Browsers attach their own ERP cookie,
              // so a live browser session can additionally require a CSRF token.
              // The installation credential still authenticates the release.
              ..body = jsonEncode({
                ...fields,
                if (csrf != null) 'csrf_token': csrf,
              });
        return client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 15));
      }

      var response = await post();
      if (kIsWeb && _isCsrfFailure(response)) {
        // CSRF fails before the release executes. Retry this rejection once;
        // never automatically retry timeouts or other failed release requests.
        final csrf = await _logoutCsrf(client, endpoint);
        response = await post(csrf);
      }
      final body = _decode(response);
      if (response.statusCode != 200 ||
          body is! Map ||
          body['message'] is! Map ||
          body['message']['status'] != 'success') {
        throw StateError(
          kIsWeb
              ? _logoutFailure(response)
              : 'Could not complete sign-out on ERP. Check your connection and retry.',
        );
      }
      // Do not remove a newer pending release written while this one ran.
      if (await _storage.read(key: _pendingName) == pending) {
        await _storage.delete(key: _pendingName);
      }
      if (await _storage.read(key: _activeName) == pending) {
        await _storage.delete(key: _activeName);
      }
    } finally {
      client.close();
    }
  }

  static dynamic _decode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } catch (_) {
      return null;
    }
  }

  static bool _isCsrfFailure(http.Response response) {
    final body = _decode(response);
    return response.statusCode != 200 &&
        body is Map &&
        (body['exc_type'] == 'CSRFTokenError' ||
            body['exception']?.toString().startsWith(
                  'frappe.exceptions.CSRFTokenError:',
                ) ==
                true);
  }

  static Future<String> _logoutCsrf(http.Client client, Uri endpoint) async {
    final request = http.Request('GET', endpoint.resolve('/app'))
      ..headers.addAll({
        'Accept': 'text/html',
        'Cache-Control': 'no-cache, no-store',
      });
    final response = await (() async {
      final stream = await client.send(request);
      if (stream case http.BaseResponseWithUrl(
        :final url,
      ) when url.origin != endpoint.origin) {
        await stream.stream.listen(null).cancel();
        throw StateError(
          'ERP redirected sign-out to another site. Check the ERP site configuration.',
        );
      }
      return http.Response.fromStream(stream);
    })().timeout(const Duration(seconds: 15));
    final token =
        response.statusCode == 200
            ? RegExp(
              r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
            ).firstMatch(response.body)?.group(1)?.trim()
            : null;
    if (token == null || token.isEmpty) {
      throw StateError(
        'Could not initialize ERP sign-out security. Reload the web app and retry.',
      );
    }
    return token;
  }

  static String _logoutFailure(http.Response response) {
    if (_isCsrfFailure(response)) {
      return 'ERP rejected the sign-out security token. Reload the web app and retry.';
    }
    if (response.statusCode == 404) {
      return 'ERP sign-out endpoint was not found (HTTP 404). Ask your administrator to check api_utils.mobile_logout.';
    }
    if (response.statusCode == 403) {
      return 'ERP refused sign-out (HTTP 403). Ask your administrator to check this browser installation binding.';
    }
    return 'ERP did not confirm sign-out (HTTP ${response.statusCode}). Please retry; if it persists, contact your administrator.';
  }
}
