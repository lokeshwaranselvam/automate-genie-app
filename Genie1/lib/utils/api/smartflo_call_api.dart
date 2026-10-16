import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';
import '../opportunity_contact.dart';

/// Calls the existing whitelisted Frappe method. Provider secrets stay on ERP.
class SmartfloCallApi {
  static Future<void> initiateCall({
    required Map<String, dynamic> opportunity,
    required String number,
  }) async {
    final phone = number.trim();
    final digits = phone.replaceAll(RegExp(r'[+\s().-]'), '');
    if (!RegExp(r'^[+0-9\s().-]+$').hasMatch(phone) ||
        !RegExp(r'^\d{7,15}$').hasMatch(digits)) {
      throw StateError(
        'This contact number is invalid. Update it in ERP first.',
      );
    }
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    final base = Uri.tryParse(site);
    if (base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }
    final sid = await SessionAuthApi.getSessionId();
    final user = await SessionAuthApi.getActiveSessionUser();
    if (sid == null || sid.isEmpty || user == null || user == 'Guest') {
      throw StateError('Sign in before calling a contact.');
    }
    if (opportunity['owner'] != user ||
        (opportunity['name']?.toString().trim() ?? '').isEmpty ||
        (opportunity['doctype'] != null &&
            opportunity['doctype'] != 'Opportunity') ||
        !opportunity.entries.any(
          (field) =>
              OpportunityContact.isPhoneField(field.key) &&
              OpportunityContact.number(field.value) == phone,
        )) {
      throw StateError('Reopen your Opportunity before calling its contact.');
    }
    Future<void> assertSession() async {
      if (await SessionAuthApi.getSessionId() != sid ||
          await SessionAuthApi.getSavedSessionUser() != user ||
          dotenv.env['SITE_URL']?.trim() != site) {
        throw StateError('Your account changed. Reopen Opportunities.');
      }
    }

    final client = http.Client();
    try {
      var desk = base.resolve('/app');
      String? csrf;
      for (var redirects = 0; redirects <= 3; redirects++) {
        await assertSession();
        final response = await client
            .send(
              http.Request('GET', desk)
                ..followRedirects = false
                ..headers.addAll({
                  'Cookie': 'sid=$sid',
                  'Accept': 'text/html',
                  'Cache-Control': 'no-cache, no-store',
                }),
            )
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 20));
        await assertSession();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null) break;
          final next = desk.resolve(location);
          if (next.origin != base.origin || next.userInfo.isNotEmpty) break;
          desk = next;
          continue;
        }
        if (response.statusCode == 200) {
          csrf =
              RegExp(
                r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
              ).firstMatch(response.body)?.group(1)?.trim();
        }
        break;
      }
      if (csrf == null || csrf.isEmpty) {
        throw StateError(
          'Could not initialize your call session. Sign in again and retry.',
        );
      }
      await assertSession();
      final response = await client
          .send(
            http.Request(
                'POST',
                base.resolve('/api/method/smartflo.api.initiate_call'),
              )
              ..followRedirects = false
              ..headers.addAll({
                'Cookie': 'sid=$sid',
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                'X-Frappe-CSRF-Token': csrf,
              })
              ..body = jsonEncode({
                'doc': {...opportunity, 'doctype': 'Opportunity'},
                'number': phone,
                'csrf_token': csrf,
              }),
          )
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 30));
      // Never retry POST: the provider may have placed the call already.
      await assertSession();
      dynamic body;
      try {
        body = jsonDecode(response.body);
      } catch (_) {
        throw const FormatException(
          'ERP did not confirm the call request. Check your phone before trying again.',
        );
      }
      if (response.statusCode != 200 ||
          body is! Map ||
          body['exception'] != null ||
          body['exc_type'] != null) {
        throw StateError(_error(body, response.statusCode));
      }
      final result = body['message'];
      if (result == null || result == false) {
        throw StateError(
          'ERP did not confirm the call request. Check your phone before trying again.',
        );
      }
      if (result is Map &&
          (result['success'] == false ||
              result['success'] == 0 ||
              [
                'error',
                'failed',
                'failure',
              ].contains(result['status']?.toString().toLowerCase()) ||
              result['error'] != null)) {
        throw StateError(
          result['message'] is String
              ? result['message'] as String
              : 'The call could not be started. Contact your administrator.',
        );
      }
    } finally {
      client.close();
    }
  }

  static String _error(dynamic body, int status) {
    if (body is Map && body['_server_messages'] is String) {
      try {
        final messages = jsonDecode(body['_server_messages'] as String);
        if (messages is List && messages.isNotEmpty) {
          final last =
              messages.last is String
                  ? jsonDecode(messages.last as String)
                  : messages.last;
          if (last is Map && last['message'] is String) {
            return (last['message'] as String)
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim();
          }
        }
      } catch (_) {
        /* Use the safe status message below. */
      }
    }
    return switch (status) {
      401 => 'Your session expired. Sign in again before calling.',
      403 => 'You do not have permission to initiate this call.',
      404 => 'Smartflo calling is not available on this ERP site.',
      _ =>
        'The call could not be confirmed ($status). Check your phone before trying again.',
    };
  }
}
