import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// Keep every existing API service in the same HTTP zone, including multipart.
/// Browsers own HttpOnly cookies; a saved session marker is never a credential.
void runBrowserApp(Future<void> Function() start) {
  http.runWithClient(() => unawaited(start()), () => _BrowserSessionClient());
}

class _BrowserSessionClient extends http.BaseClient {
  final BrowserClient _client = BrowserClient();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final site = Uri.tryParse(dotenv.env['SITE_URL'] ?? '');
    final isErp =
        site != null && site.hasAuthority && (request.url.scheme == 'https' || request.url.scheme == 'http') && request.url.origin == site.origin;
    request.headers.removeWhere((key, _) => key.toLowerCase() == 'cookie');
    // Use same-origin hosting for ERP sessions. Explicitly send cookies only
    // to ERP; never opt external mapping or media requests into credentials.
    _client.withCredentials = isErp;
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}
