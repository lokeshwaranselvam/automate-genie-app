import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Registers this installation's FCM token against the logged-in Frappe user.
class FcmDeviceApi {
  static StreamSubscription<String>? _tokenRefreshSubscription;

  static void initializeTokenRefreshListener() {
    _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh
        .listen(
          (token) => unawaited(_registerToken(token)),
          onError: (Object error) =>
              debugPrint('FCM token refresh listener error: $error'),
        );
  }

  static Future<void> requestPermissionAndRegister() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('FCM permission denied; device token not registered.');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('FCM did not return a device token.');
        return;
      }
      await _registerToken(token);
    } catch (error) {
      // Push registration must not prevent an otherwise successful login.
      debugPrint('FCM device registration failed: $error');
    }
  }

  static Future<void> _registerToken(String fcmToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // register_device uses frappe.session.user, so authenticate it with
      // the Frappe session created by SessionAuthApi, not Genie1's API token.
      final sessionId = prefs.getString('session_sid');
      final siteUrl = dotenv.env['SITE_URL']?.trim();
      if (sessionId == null || sessionId.isEmpty ||
          siteUrl == null || siteUrl.isEmpty) {
        debugPrint('FCM registration skipped: Frappe session or SITE_URL missing.');
        return;
      }

      final endpoint = Uri.parse(siteUrl).resolve(
        '/api/method/itgenie.fcm.devices.register_device',
      );
      final response = await http
          .post(
            endpoint,
            headers: {
              'Cookie': 'sid=$sessionId',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'fcm_token': fcmToken,
              'platform': Platform.isAndroid ? 'android' : 'ios',
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          'FCM registration endpoint returned ${response.statusCode}: '
          '${response.body}',
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
            'but Frappe did not confirm success: ${response.body}',
          );
        }
      }
    } catch (error) {
      debugPrint('FCM token upload failed: $error');
    }
  }
}
