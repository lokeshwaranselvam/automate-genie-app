import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api/session_auth.dart';

/// Eligibility for continuous employee tracking, separate from attendance GPS.
class LiveTrackingAccess {
  LiveTrackingAccess._();

  static String? _verifiedSession;
  static DateTime? _verifiedAt;
  static bool _allowed = false;
  static final Map<String, Future<bool?>> _pending = {};

  static Future<bool> canTrack({bool requireCheckIn = true}) async =>
      await trackingDecision(requireCheckIn: requireCheckIn) == true;

  /// `true` allows tracking and `false` is a definitive deny (no attendance,
  /// signed out, another account, or ERP refused). `null` means ERP could not
  /// be reached or understood (timeout, 5xx, bad JSON): callers must keep the
  /// current tracking state instead of stopping the native service.
  static Future<bool?> trackingDecision({bool requireCheckIn = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (requireCheckIn && prefs.getBool('is_employee_checked_in') != true) {
      return false;
    }
    final email = prefs.getString('email')?.trim() ?? '';
    final sid = prefs.getString('session_sid')?.trim() ?? '';
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    if (email.isEmpty || sid.isEmpty || site.isEmpty) return false;
    final session = jsonEncode([site, email, sid]);
    bool? allowed;
    if (_verifiedSession == session &&
        _verifiedAt != null &&
        DateTime.now().difference(_verifiedAt!) < const Duration(minutes: 1)) {
      allowed = _allowed;
    } else {
      final request = _pending.putIfAbsent(
        session,
        () => _verify(site, email, sid, session),
      );
      try {
        allowed = await request;
      } finally {
        if (identical(_pending[session], request)) _pending.remove(session);
      }
    }
    // Never apply a response to another account or a completed shift.
    if (prefs.getString('email')?.trim() != email ||
        prefs.getString('session_sid')?.trim() != sid ||
        (requireCheckIn && prefs.getBool('is_employee_checked_in') != true)) {
      return false;
    }
    return allowed;
  }

  static Future<bool?> _verify(
    String site,
    String email,
    String sid,
    String session,
  ) async {
    try {
      final user = await SessionAuthApi.getActiveSessionUser();
      if (user?.toLowerCase() != email.toLowerCase()) return false;
      final uri = Uri.parse(site.endsWith('/') ? site : '$site/')
          .resolve('api/method/mobile_site_visit')
          .replace(queryParameters: {'action': 'can_create'});
      final response = await http
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Cookie': 'sid=$sid',
              'Cache-Control': 'no-cache, no-store',
            },
          )
          .timeout(const Duration(seconds: 10));
      // 401/403 are definitive; other failures (5xx, proxies) are unknown.
      if (response.statusCode == 401 || response.statusCode == 403) {
        return false;
      }
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      final message =
          decoded is Map && decoded['exc'] == null ? decoded['message'] : null;
      if (message is! Map) return null;
      if (message['current_user']?.toString().trim().toLowerCase() !=
              email.toLowerCase() ||
          message['can_track'] is! bool) {
        return false;
      }
      final allowed = message['can_track'] == true;
      _verifiedSession = session;
      _verifiedAt = DateTime.now();
      _allowed = allowed;
      return allowed;
    } catch (error) {
      // Timeout, offline or invalid JSON: not a deny.
      debugPrint('Could not verify live tracking eligibility: $error');
      return null;
    }
  }
}
