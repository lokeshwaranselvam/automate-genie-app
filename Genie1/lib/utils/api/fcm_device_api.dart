import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Registers this installation's FCM token against the logged-in Frappe user.
class FcmDeviceApi {
  static StreamSubscription<String>? _tokenRefreshSubscription;

  static void initializeTokenRefreshListener() {
    _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh
        .listen(
          (token) {
            // The login flow uploads the final token after rotation completes.
            // Do not race it with an intermediate Firebase refresh event.
            if (_permissionRequest == null) unawaited(registerToken(token));
          },
          onError:
              (Object error) =>
                  debugPrint('FCM token refresh listener error: $error'),
        );
  }

  static Future<void> requestPermissionAndRegister({
    bool rotateToken = false,
  }) async {
    // A restored session can share pending work. An explicit login must still
    // rotate even if a restore registration was already in progress.
    if (rotateToken && _permissionRequest != null) await _permissionRequest;
    final request =
        _permissionRequest ??= _requestPermissionAndRegister(
          rotateToken: rotateToken,
        );
    try {
      await request;
    } finally {
      if (identical(_permissionRequest, request)) _permissionRequest = null;
    }
  }

  static Future<void> _requestPermissionAndRegister({
    required bool rotateToken,
  }) async {
    try {
      final sid = (await SharedPreferences.getInstance()).getString(
        'session_sid',
      );
      if (sid == null || sid.isEmpty) return;
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('FCM permission denied; device token not registered.');
        return;
      }

      await _assertSession(sid);
      String? previousToken;
      if (rotateToken) {
        // Firebase owns token generation; invalidate the previous registration
        // only after successful password authentication, never on app restore.
        previousToken = await FirebaseMessaging.instance.getToken();
      }
      String? token;
      for (var attempt = 0; attempt < (rotateToken ? 2 : 1); attempt++) {
        if (rotateToken) {
          await FirebaseMessaging.instance.deleteToken();
          await _assertSession(sid);
        }
        token = await FirebaseMessaging.instance.getToken();
        if (token == null || token.isEmpty || token != previousToken) break;
      }
      if (token == null || token.isEmpty) {
        debugPrint('FCM did not return a device token.');
        return;
      }
      if (rotateToken && token == previousToken) {
        throw StateError('Firebase did not rotate the FCM token after login.');
      }
      await registerToken(token, expectedSessionId: sid);
    } catch (error) {
      // Push registration must not prevent an otherwise successful login.
      debugPrint('FCM device registration failed: $error');
    }
  }

  static Future<void>? _permissionRequest;

  static Future<void> _assertSession(String sid) async {
    if ((await SharedPreferences.getInstance()).getString('session_sid') !=
        sid) {
      throw StateError('FCM registration session changed.');
    }
  }

  static Future<String> _csrfToken(String sid, Uri endpoint) async {
    var uri = endpoint.resolve('/app');
    final client = http.Client();
    try {
      for (var redirects = 0; redirects <= 3; redirects++) {
        await _assertSession(sid);
        final response = await (() async {
          final result = await client.send(
            http.Request('GET', uri)
              ..followRedirects = false
              ..headers.addAll({
                'Cookie': 'sid=$sid',
                'Accept': 'text/html',
                'Cache-Control': 'no-cache, no-store',
              }),
          );
          return http.Response.fromStream(result);
        })().timeout(const Duration(seconds: 15));
        await _assertSession(sid);
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null) break;
          final next = uri.resolve(location);
          if (next.origin != endpoint.origin || next.userInfo.isNotEmpty) {
            throw StateError('FCM token bootstrap redirected to another site.');
          }
          uri = next;
          continue;
        }
        if (response.statusCode == 200) {
          final token =
              RegExp(
                r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
              ).firstMatch(response.body)?.group(1)?.trim();
          if (token != null && token.isNotEmpty) return token;
        }
        break;
      }
    } finally {
      client.close();
    }
    throw StateError(
      'Could not initialize the FCM registration session token.',
    );
  }

  static bool _csrfRejected(http.Response response) {
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

  static Future<void> registerToken(
    String fcmToken, {
    String? expectedSessionId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // register_device uses frappe.session.user, so authenticate it with
      // the Frappe session created by SessionAuthApi, not Genie1's API token.
      final sessionId = prefs.getString('session_sid');
      if (expectedSessionId != null && sessionId != expectedSessionId) return;
      final siteUrl = dotenv.env['SITE_URL']?.trim();
      if (sessionId == null ||
          sessionId.isEmpty ||
          siteUrl == null ||
          siteUrl.isEmpty) {
        debugPrint(
          'FCM registration skipped: Frappe session or SITE_URL missing.',
        );
        return;
      }

      final endpoint = Uri.parse(
        siteUrl,
      ).resolve('/api/method/itgenie.fcm.devices.register_device');
      if (fcmToken.trim().isEmpty) return;
      final package = await PackageInfo.fromPlatform();
      final metadata = {
        'fcm_token': fcmToken,
        'platform': Platform.isAndroid ? 'android' : 'ios',
        'device_id': fcmToken.split(':').first,
        'app_version': package.version,
        'build_version': package.buildNumber,
      };
      var csrf = await _csrfToken(sessionId, endpoint);
      Future<http.Response> post() async {
        await _assertSession(sessionId);
        final client = http.Client();
        try {
          final request =
              http.Request('POST', endpoint)
                ..followRedirects = false
                ..headers.addAll({
                  'Cookie': 'sid=$sessionId',
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                  'X-Frappe-CSRF-Token': csrf,
                })
                ..body = jsonEncode({...metadata, 'csrf_token': csrf});
          return await client
              .send(request)
              .then(http.Response.fromStream)
              .timeout(const Duration(seconds: 15));
        } finally {
          client.close();
        }
      }

      var response = await post();
      if (_csrfRejected(response)) {
        csrf = await _csrfToken(sessionId, endpoint);
        response = await post();
      }
      await _assertSession(sessionId);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        String errorType = 'UnknownError';
        try {
          final data = jsonDecode(response.body);
          final type = data is Map ? data['exc_type'] : null;
          // Log only an exception type, never response bodies containing
          // registration tokens, cookies or employee data.
          if (type is String && RegExp(r'^[A-Za-z_]{1,80}$').hasMatch(type)) {
            errorType = type;
          }
        } catch (_) {
          // Non-JSON proxy errors still have their HTTP status logged below.
        }
        debugPrint(
          'FCM registration endpoint returned ${response.statusCode} ($errorType): '
          'Registration was not saved.',
        );
      } else {
        dynamic payload;
        try {
          payload = jsonDecode(response.body);
        } on FormatException {
          payload = null;
        }

        final message = payload is Map ? payload['message'] : null;
        if (message is Map && message['status'] == 'success') {
          debugPrint(
            'FCM device token registered for ${message['user'] ?? 'unknown user'}.',
          );
        } else {
          // A 2xx status alone does not prove the Frappe method saved the row.
          debugPrint(
            'FCM registration returned HTTP ${response.statusCode}, '
            'but Frappe did not confirm success.',
          );
        }
      }
    } catch (error) {
      debugPrint('FCM token upload failed: $error');
    }
  }
}
