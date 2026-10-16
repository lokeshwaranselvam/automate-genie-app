import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

/// Read-only Opportunity access using Frappe's normal document permissions.
class OpportunityApi {
  static const pageSize = 50;

  static Future<dynamic> _read({
    String? name,
    int offset = 0,
    String phone = '',
  }) async {
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    final base = Uri.tryParse(site);
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }
    final sid = await SessionAuthApi.getSessionId();
    final user = await SessionAuthApi.getActiveSessionUser();
    if (sid == null || sid.isEmpty || user == null) {
      throw StateError('Your session expired. Please sign in again.');
    }
    Future<void> assertSession() async {
      if (await SessionAuthApi.getSessionId() != sid ||
          await SessionAuthApi.getSavedSessionUser() != user ||
          dotenv.env['SITE_URL']?.trim() != site) {
        throw StateError('Your account changed. Reopen Opportunities.');
      }
    }

    await assertSession();
    final resource = base.resolve('/api/resource/Opportunity');
    final uri =
        name == null
            ? resource.replace(
              queryParameters: {
                'fields': jsonEncode([
                  'name',
                  'owner',
                  'customer_name',
                  'party_name',
                  'status',
                  'creation',
                ]),
                'filters': jsonEncode([
                  ['owner', '=', user],
                ]),
                if (phone.isNotEmpty)
                  'or_filters': jsonEncode([
                    [
                      'contact_mobile',
                      'like',
                      '%${phone.split('').join('%')}%',
                    ],
                    ['phone', 'like', '%${phone.split('').join('%')}%'],
                  ]),
                'order_by': 'creation desc, name desc',
                'limit_start': '$offset',
                'limit_page_length': '$pageSize',
              },
            )
            : Uri.parse('${resource.toString()}/${Uri.encodeComponent(name)}');
    final client = http.Client();
    late http.Response response;
    try {
      final request =
          http.Request('GET', uri)
            ..followRedirects = false
            ..headers.addAll({
              'Cookie': 'sid=$sid',
              'Accept': 'application/json',
              'Cache-Control': 'no-cache, no-store',
            });
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 25));
    } finally {
      client.close();
    }
    await assertSession();
    if (response.statusCode != 200) {
      throw StateError(switch (response.statusCode) {
        401 => 'Your session expired. Please sign in again.',
        403 => 'You do not have permission to view these opportunities.',
        404 => 'This opportunity is no longer available.',
        _ =>
          'Could not load opportunities (${response.statusCode}). Please retry.',
      });
    }
    final body = jsonDecode(response.body);
    final data = body is Map ? body['data'] : null;
    final rows = name == null ? data : [data];
    if (rows is! List || rows.any((row) => row is! Map)) {
      throw const FormatException(
        'The ERP returned an invalid Opportunity response.',
      );
    }
    for (final row in rows) {
      if (row['owner'] != user || (name != null && row['name'] != name)) {
        throw StateError(
          'Only opportunities created by your user can be displayed here.',
        );
      }
    }
    return data;
  }

  static Future<List<Map<String, dynamic>>> getMyOpportunities({
    int offset = 0,
    String phone = '',
  }) async {
    if (offset < 0) throw ArgumentError('Invalid page offset.');
    final digits = phone.replaceAll(RegExp(r'[+\s().-]'), '');
    if (digits.isNotEmpty && !RegExp(r'^\d{1,15}$').hasMatch(digits)) {
      throw ArgumentError('Enter a valid phone number.');
    }
    final rows = await _read(offset: offset, phone: digits) as List;
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  static Future<Map<String, dynamic>> getDetails(String name) async {
    if (name.trim().isEmpty) throw ArgumentError('Opportunity ID is required.');
    return Map<String, dynamic>.from(await _read(name: name));
  }
}
