import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';

/// Loads the WebView shortcuts permitted for the current Frappe session user.
class SessionWebLinksApi {
  static Uri _methodUri() {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) {
      throw StateError('SITE_URL is not configured in .env');
    }
    final base = Uri.parse(siteUrl.endsWith('/') ? siteUrl : '$siteUrl/');
    return base.resolve('api/method/get_user_roles');
  }

  static List<Map<String, String>> _parseLinks(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) {
          return <String, String>{
            'title': item['title']?.toString().trim() ?? '',
            'url': item['url']?.toString().trim() ?? '',
            'icon': item['icon']?.toString().trim() ?? '',
          };
        })
        .where((link) {
          final uri = Uri.tryParse(link['url']!);
          return link['title']!.isNotEmpty &&
              uri != null &&
              uri.scheme == 'https' &&
              uri.host.isNotEmpty;
        })
        .toList();
  }

  static List<Map<String, String>> _fallbackLinks(List<dynamic> roles) {
    final siteUrl = dotenv.env['SITE_URL']?.trim();
    if (siteUrl == null || siteUrl.isEmpty) return [];
    final baseUrl =
        siteUrl.endsWith('/')
            ? siteUrl.substring(0, siteUrl.length - 1)
            : siteUrl;
    final links = <Map<String, String>>[
      {
        'title': 'PBF Stage Tracker',
        'url': '$baseUrl/pbf-stage-tracker',
        'icon': 'timeline',
      },
      {
        'title': 'Material Track',
        'url': '$baseUrl/materialtrack',
        'icon': 'inventory',
      },
    ];

    if (roles.map((role) => role.toString()).contains('Employee')) {
      links.addAll([
        {
          'title': 'PBF Report',
          'url': '$baseUrl/app/web-page/pbf-reportcopy',
          'icon': 'description',
        },
        {
          'title': 'Item Group Summary',
          'url': '$baseUrl/item-group-summary',
          'icon': 'summarize',
        },
      ]);
    }
    return links;
  }

  static Future<List<Map<String, String>>> getLinksForCurrentUser() async {
    final username = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (username == null || sid == null || sid.isEmpty) {
      throw StateError('The Frappe session is unavailable.');
    }

    final response = await http
        .get(
          _methodUri().replace(
            queryParameters: {
              '_refresh': DateTime.now().microsecondsSinceEpoch.toString(),
            },
          ),
          headers: {
            'Accept': 'application/json',
            'Cookie': 'sid=$sid',
            'Cache-Control': 'no-cache, no-store',
            'Pragma': 'no-cache',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError(
        'Could not load the current user permissions (${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body);
    final message = decoded is Map ? decoded['message'] : null;
    if (message is Map) {
      final rawLinks = message['links'];
      if (rawLinks is List) return _parseLinks(rawLinks);

      final roles = message['role'];
      if (roles is List) return _fallbackLinks(roles);
    }

    throw const FormatException('The server returned no web page permissions.');
  }
}
