import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateStatus {
  const AppUpdateStatus({
    required this.required,
    required this.installedVersion,
    required this.installedBuild,
    required this.latestVersion,
    required this.latestBuild,
  });

  final bool required;
  final String installedVersion;
  final String installedBuild;
  final String latestVersion;
  final int latestBuild;
}

abstract final class AppUpdateApi {
  static Future<AppUpdateStatus> check() async {
    final site = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
    if (site == null ||
        site.scheme != 'https' ||
        site.host.isEmpty ||
        site.userInfo.isNotEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }
    final package = await PackageInfo.fromPlatform();
    final uri = site
        .resolve('/api/method/update_required')
        .replace(
          queryParameters: {
            'app_version': package.version,
            'build_version': package.buildNumber,
          },
        );
    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Could not check for app updates.');
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    final build = message is Map ? message['latest_build'] : null;
    if (message is! Map ||
        message['update_required'] is! bool ||
        message['latest_version'] is! String ||
        (message['latest_version'] as String).trim().isEmpty ||
        build is! int ||
        build < 0 ||
        body['exc_type'] != null ||
        body['exception'] != null) {
      throw const FormatException(
        'The update service returned an invalid response.',
      );
    }
    return AppUpdateStatus(
      required: message['update_required'] as bool,
      installedVersion: package.version,
      installedBuild: package.buildNumber,
      latestVersion: message['latest_version'] as String,
      latestBuild: build,
    );
  }
}
