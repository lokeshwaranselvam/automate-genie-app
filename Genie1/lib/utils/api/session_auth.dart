import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
    final response = await http.post(
      _methodUri('login'),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'usr': username, 'pwd': password}),
    );
    final data = _decode(response);
    final message = data is Map ? data['message']?.toString() : null;

    if (response.statusCode != 200 || message != 'Logged In') {
      final detail = message;
      throw Exception(
        detail == null || detail.isEmpty
            ? 'Session login failed (${response.statusCode}).'
            : detail,
      );
    }

    final sid = _sidFrom(response);
    if (sid == null || sid.isEmpty) {
      throw Exception(
        'Frappe login succeeded but did not return a session cookie.',
      );
    }

    final loggedInUser = await _fetchLoggedInUser(sid);
    if (loggedInUser == null ||
        loggedInUser.toLowerCase() != username.trim().toLowerCase()) {
      await _endRemoteSession(sid);
      throw Exception(
        'The server session does not match the user who signed in.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final fullName = data is Map ? data['full_name']?.toString() : null;
    await prefs.setString(_sidKey, sid);
    await prefs.setString(_usernameKey, loggedInUser);
    await prefs.setString(
      _fullNameKey,
      (fullName == null || fullName.isEmpty) ? loggedInUser : fullName,
    );

    return {
      'username': loggedInUser,
      'full_name':
          (fullName == null || fullName.isEmpty) ? loggedInUser : fullName,
    };
  }

  static Future<String?> _fetchLoggedInUser(String sid) async {
    final response = await http.get(
      _methodUri('frappe.auth.get_logged_user'),
      headers: {'Accept': 'application/json', 'Cookie': 'sid=$sid'},
    );
    if (response.statusCode != 200) return null;
    final data = _decode(response);
    if (data is! Map) return null;
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
    } catch (_) {
      // Network errors should not erase a valid session; the caller can retry later.
      return null;
    }
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
    final sid = prefs.getString(_sidKey);
    if (sid != null && sid.isNotEmpty) await _endRemoteSession(sid);
    await clearSession();
  }

  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sidKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_fullNameKey);
  }
}
