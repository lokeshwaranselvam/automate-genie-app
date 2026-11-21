import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// All selection rules remain in the event_visit_report Server Script.
class VisitVerificationApi {
  static Future<Map<String, dynamic>> request(
    String action, [
    Map<String, String> values = const {},
  ]) async {
    final prefs = await SharedPreferences.getInstance();
    final user =
        prefs.getString('session_username') ?? prefs.getString('email');
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) {
      throw StateError('Sign in to verify visits.');
    }
    final site = Uri.tryParse(dotenv.env['SITE_URL'] ?? '');
    if (site == null || !site.hasAuthority) {
      throw StateError('ERP URL is missing.');
    }
    final response = await http
        .post(
          site.resolve('/api/method/event_visit_report'),
          headers: {'Authorization': token, 'Accept': 'application/json'},
          body: {'action': action, ...values},
        )
        .timeout(const Duration(seconds: 20));
    if ((prefs.getString('session_username') ?? prefs.getString('email')) !=
            user ||
        prefs.getString('token') != token) {
      throw StateError('Your session changed. Refresh and try again.');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw StateError('Verification API returned an invalid response.');
    }
    final message = decoded is Map ? decoded['message'] : null;
    if (response.statusCode != 200 ||
        decoded is! Map ||
        decoded['exc'] != null ||
        message is! Map) {
      throw StateError(
        'Could not load or submit verification. Refresh and try again.',
      );
    }
    return Map<String, dynamic>.from(message);
  }

  static Future<Map<String, dynamic>> policy() async {
    final data = await request('verification_policy');
    final policy = data['verification_policy'];
    if (policy is! Map) throw StateError('Verification policy is unavailable.');
    final prefs = await SharedPreferences.getInstance();
    if (policy['current_user'] !=
        (prefs.getString('session_username') ?? prefs.getString('email'))) {
      throw StateError('Verification policy belongs to another session.');
    }
    return Map<String, dynamic>.from(policy);
  }

  static Future<Map<String, Map<String, dynamic>>> states(
    List<String> ids,
  ) async {
    final states = <String, Map<String, dynamic>>{};
    // Keep each server request bounded, with at most three in flight.
    for (var start = 0; start < ids.length; start += 150) {
      final batches = <List<String>>[];
      for (
        var offset = start;
        offset < ids.length && offset < start + 150;
        offset += 50
      ) {
        batches.add(ids.skip(offset).take(50).toList());
      }
      final responses = await Future.wait(
        batches.map(
          (batch) =>
              request('verification_states', {'event_ids': jsonEncode(batch)}),
        ),
      );
      for (var index = 0; index < responses.length; index++) {
        final data = responses[index];
        final batch = batches[index];
        if (data['events'] is! List) {
          throw StateError('Verification states are unavailable.');
        }
        for (final row in (data['events'] as List).whereType<Map>()) {
          final id = row['event_id']?.toString();
          if (id != null && batch.contains(id)) {
            states[id] = Map<String, dynamic>.from(row);
          }
        }
      }
    }
    return states;
  }

  static Future<Map<String, dynamic>> verify(String id, String entered) =>
      request('verify', {'event_id': id, 'custom_validate': entered.trim()});
}
