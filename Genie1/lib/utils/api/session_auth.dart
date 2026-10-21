import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../face/face_template_cache.dart';
import 'mobile_login_device.dart';

/// Thrown when the ERP server could not be reached to verify a session.
class SessionUnreachableException implements Exception {
  const SessionUnreachableException(this.message);
  final String message;

  @override
  String toString() => 'SessionUnreachableException: $message';
}

/// Manages the Frappe browser-style session separately from Genie1's API token.
class SessionAuthApi {
  static const _sidKey = 'session_sid';
  static const _usernameKey = 'session_username';
  static const _fullNameKey = 'session_full_name';
  static final Map<String, String> _userFullNameCache = {};

  static Uri _methodUri(String method) {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    return base.resolve('api/method/$method');
  }

  static String? _sidFrom(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return null;
    final match = RegExp(r'(?:^|[,;]\s*)sid=([^;,]+)').firstMatch(setCookie);
    return match?.group(1);
  }

  static dynamic _decode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } catch (_) {
      return null;
    }
  }

  /// Starts a Frappe session and verifies which user the server authenticated.
  static Future<Map<String, String>> login(
    String username,
    String password,
  ) async {
    await MobileLoginDevice.completePendingLogout();
    final apiBase = dotenv.env['URL']?.trim() ?? '';
    if (apiBase.isEmpty) throw StateError('URL is not configured in .env');
    final response = await http
        .post(
          Uri.parse('$apiBase.login'),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'usr': username,
            'pwd': password,
            'device_key': await MobileLoginDevice.key(),
            if (defaultTargetPlatform == TargetPlatform.android)
              'platform': 'android'
            else if (defaultTargetPlatform == TargetPlatform.iOS)
              'platform': 'ios',
          }),
        )
        .timeout(const Duration(seconds: 30));
    final data = _decode(response);
    final rawMessage = data is Map ? data['message'] : null;
    String? message =
        rawMessage is Map
            ? rawMessage['message']?.toString()
            : rawMessage?.toString();
    if (data is Map && data['_server_messages'] is String) {
      try {
        final messages = jsonDecode(data['_server_messages'] as String) as List;
        if (messages.isNotEmpty) {
          final first =
              messages.first is String
                  ? jsonDecode(messages.first)
                  : messages.first;
          if (first is Map) message = first['message']?.toString() ?? message;
        }
      } catch (_) {
        /* Preserve the ordinary response message. */
      }
    }

    if (response.statusCode != 200 || message != 'Logged In') {
      final detail = message;
      throw Exception(
        detail == null || detail.isEmpty
            ? 'Session login failed (${response.statusCode}).'
            : detail,
      );
    }

    if (data is! Map || data['single_device_login'] != true) {
      throw StateError(
        'The ERP mobile login update is required. Contact your administrator.',
      );
    }
    final token = data['token']?.toString().trim() ?? '';
    final expectedUser = data['email']?.toString().trim() ?? '';
    if (token.isEmpty || expectedUser.isEmpty) {
      throw StateError('ERP did not return complete mobile login credentials.');
    }

    final sid = _sidFrom(response);
    if (sid == null || sid.isEmpty) {
      throw Exception(
        'Frappe login succeeded but did not return a session cookie.',
      );
    }

    final loggedInUser = await _fetchLoggedInUser(sid);
    if (loggedInUser == null ||
        loggedInUser.toLowerCase() != expectedUser.toLowerCase()) {
      throw Exception(
        'The server session does not match the user who signed in.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final fullName = data['full_name']?.toString();
    await MobileLoginDevice.rememberSession(
      Uri.parse('$apiBase.mobile_logout'),
      loggedInUser,
    );
    await prefs.setString(_sidKey, sid);
    await prefs.setString(_usernameKey, loggedInUser);
    await prefs.setString(
      _fullNameKey,
      (fullName == null || fullName.isEmpty) ? loggedInUser : fullName,
    );
    await prefs.setString('token', token);
    await prefs.setBool('single_device_login', true);
    await prefs.setString('mobile_logout_endpoint', '$apiBase.mobile_logout');

    return {
      'username': loggedInUser,
      'full_name':
          (fullName == null || fullName.isEmpty) ? loggedInUser : fullName,
      'token': token,
      'employee_id': data['employee_id']?.toString() ?? '',
    };
  }

  /// Returns the session's user, or null when the server says the session is
  /// no longer valid. Throws [SessionUnreachableException] when the server
  /// could not answer (offline, timeout, 5xx), so callers do not mistake a
  /// network problem for an expired session.
  static Future<String?> _fetchLoggedInUser(String sid) async {
    final http.Response response;
    try {
      response = await http
          .get(
            _methodUri('frappe.auth.get_logged_user'),
            headers: {'Accept': 'application/json', 'Cookie': 'sid=$sid'},
          )
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      throw SessionUnreachableException('$error');
    }
    if (response.statusCode == 401 || response.statusCode == 403) return null;
    if (response.statusCode != 200) {
      throw SessionUnreachableException(
        'Session check returned ${response.statusCode}',
      );
    }
    final data = _decode(response);
    if (data is! Map) {
      throw const SessionUnreachableException(
        'Session check returned an invalid response',
      );
    }
    final user = data['message']?.toString();
    if (user == null || user.isEmpty || user.toLowerCase() == 'guest') {
      return null;
    }
    return user;
  }

  /// Returns the currently authenticated Frappe user, or null for an expired session.
  static Future<String?> getActiveSessionUser() async {
    final prefs = await SharedPreferences.getInstance();
    final sid = prefs.getString(_sidKey);
    if (sid == null || sid.isEmpty) return null;

    try {
      final user = await _fetchLoggedInUser(sid);
      if (user == null) {
        await clearSession();
        return null;
      }
      await prefs.setString(_usernameKey, user);
      return user;
    } on SessionUnreachableException {
      // The server could not confirm either way. Keep the saved session so a
      // network blip does not sign the user out; later requests will retry.
      final savedUser = prefs.getString(_usernameKey)?.trim();
      return (savedUser == null || savedUser.isEmpty) ? null : savedUser;
    } catch (_) {
      return null;
    }
  }

  /// Returns the signed-in username saved on this device, without contacting
  /// the server.
  static Future<String?> getSavedSessionUser() async {
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getString(_usernameKey)?.trim();
    return (user == null || user.isEmpty) ? null : user;
  }

  static Future<bool> isSessionActive(String expectedUsername) async {
    final user = await getActiveSessionUser();
    return user != null &&
        user.toLowerCase() == expectedUsername.trim().toLowerCase();
  }

  static Future<String?> getSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_sidKey);
  }

  /// Returns the current user's ERP full name saved during sign-in.
  static Future<String?> getCurrentUserFullName() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(_usernameKey)?.trim() ?? '';
    final fullName = prefs.getString(_fullNameKey)?.trim() ?? '';
    if (_isFullName(fullName, username)) return fullName;

    final savedName = prefs.getString('name')?.trim() ?? '';
    if (_isFullName(savedName, username)) return savedName;

    final sid = prefs.getString(_sidKey);
    if (username.isNotEmpty && sid != null && sid.isNotEmpty) {
      final resolved = await _fetchUserFullName(username, sid);
      if (resolved != null) {
        _userFullNameCache[username.toLowerCase()] = resolved;
        return resolved;
      }
    }
    return null;
  }

  static bool _isFullName(String value, String username) {
    return value.isNotEmpty &&
        value.toLowerCase() != username.toLowerCase() &&
        !value.contains('@');
  }

  static Future<String?> _fetchUserFullName(String username, String sid) async {
    try {
      final uri = _methodUri('frappe.client.get_value').replace(
        queryParameters: {
          'doctype': 'User',
          'filters': jsonEncode({'name': username}),
          'fieldname': 'full_name',
        },
      );
      final response = await http
          .get(
            uri,
            headers: {'Accept': 'application/json', 'Cookie': 'sid=$sid'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final data = _decode(response);
      final message = data is Map ? data['message'] : null;
      final fullName =
          message is Map ? message['full_name']?.toString().trim() : null;
      if (fullName == null || !_isFullName(fullName, username)) return null;
      return fullName;
    } catch (_) {
      return null;
    }
  }

  /// Resolves a Frappe User ID to its full name for display purposes.
  static Future<String?> getUserFullName(String userId) async {
    final username = userId.trim();
    if (username.isEmpty || username.toLowerCase() == 'null') return null;

    final cacheKey = username.toLowerCase();
    final cached = _userFullNameCache[cacheKey];
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final sessionUser = prefs.getString(_usernameKey)?.trim() ?? '';
    if (sessionUser.isNotEmpty && sessionUser.toLowerCase() == cacheKey) {
      final localName = prefs.getString(_fullNameKey)?.trim() ?? '';
      if (_isFullName(localName, sessionUser)) {
        _userFullNameCache[cacheKey] = localName;
        return localName;
      }
      final savedName = prefs.getString('name')?.trim() ?? '';
      if (_isFullName(savedName, sessionUser)) {
        _userFullNameCache[cacheKey] = savedName;
        return savedName;
      }
    }

    final sid = prefs.getString(_sidKey);
    if (sid == null || sid.isEmpty) return null;
    final fullName = await _fetchUserFullName(username, sid);
    if (fullName != null) _userFullNameCache[cacheKey] = fullName;
    return fullName;
  }

  /// Gets the ERP profile image for the currently authenticated Frappe user.
  static Future<String?> getCurrentUserAvatarUrl() async {
    final username = await getActiveSessionUser();
    final sid = await getSessionId();
    if (username == null || sid == null || sid.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final cacheKey =
        'session_avatar_${username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

    try {
      final uri = _methodUri('frappe.client.get_value').replace(
        queryParameters: {
          'doctype': 'User',
          'filters': jsonEncode({'name': username}),
          'fieldname': 'user_image',
        },
      );
      final response = await http
          .get(
            uri,
            headers: {'Accept': 'application/json', 'Cookie': 'sid=$sid'},
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = _decode(response);
        final message = data is Map ? data['message'] : null;
        final imagePath =
            message is Map ? message['user_image']?.toString().trim() : null;
        if (imagePath == null || imagePath.isEmpty || imagePath == 'null') {
          await prefs.remove(cacheKey);
          return null;
        }

        final imageUri = Uri.tryParse(imagePath);
        final resolvedUri =
            imageUri != null && imageUri.hasScheme
                ? imageUri
                : _siteUri().resolve(
                  imagePath.startsWith('/') ? imagePath : '/$imagePath',
                );
        if (resolvedUri.scheme != 'https' || resolvedUri.host.isEmpty) {
          return null;
        }
        await prefs.setString(cacheKey, resolvedUri.toString());
        return resolvedUri.toString();
      }
    } catch (_) {
      // If the ERP is temporarily unavailable, use the last saved avatar URL.
    }

    return prefs.getString(cacheKey);
  }

  static Uri _siteUri() {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    return Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
  }

  static Future<void> _endRemoteSession(String sid) async {
    try {
      await http.post(
        _methodUri('logout'),
        headers: {'Accept': 'application/json', 'Cookie': 'sid=$sid'},
      );
    } catch (_) {
      // Local credentials are still cleared by the caller.
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    if (await MobileLoginDevice.logoutRememberedSession()) {
      await clearSession();
      await prefs.remove('token');
      return;
    }
    if (prefs.getBool('single_device_login') == true) {
      final user = prefs.getString(_usernameKey) ?? prefs.getString('email');
      final endpoint = prefs.getString('mobile_logout_endpoint');
      if (user == null || endpoint == null) {
        throw StateError(
          'Could not identify the ERP mobile session. Please retry sign-out.',
        );
      }
      await MobileLoginDevice.logout(Uri.parse(endpoint), user);
      await clearSession();
      await prefs.remove('token');
      return;
    }
    final sid = prefs.getString(_sidKey);
    if (sid != null && sid.isNotEmpty) await _endRemoteSession(sid);
    await clearSession();
  }

  static Future<void> clearSession() async {
    await FaceTemplateCache.instance.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sidKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_fullNameKey);
    await prefs.remove('single_device_login');
    await prefs.remove('mobile_logout_endpoint');
  }
}
