import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/platform/embedded_page_uri.dart';

void main() {
  final app = Uri.parse('http://localhost:8765/genie/');
  Uri? resolve(
    String page, {
    String? site = 'http://localhost:8765/',
    String? proxy = 'https://erp.homegeniegroup.in',
  }) => embeddedPageUri(page, app: app, site: site, proxyErpOrigin: proxy);

  test('local ERP iframe uses its authenticated same-origin proxy', () {
    expect(
      resolve(
        'https://erp.homegeniegroup.in/GOAD?view=month#attendance',
      )?.toString(),
      'http://localhost:8765/GOAD?view=month#attendance',
    );
  });
  test('local fallback dashboard links are allowed only on the app origin', () {
    expect(
      resolve('http://localhost:8765/materialtrack').toString(),
      'http://localhost:8765/materialtrack',
    );
    expect(resolve('http://localhost:8766/materialtrack'), isNull);
    expect(resolve('http://localhost:8765/materialtrack', site: null), isNull);
  });
  test('external Tasks and SVR retain the exact requested URLs', () {
    for (final page in ['TGC', 'SVR']) {
      final value = 'https://16.itgenie.online/$page';
      expect(resolve(value).toString(), value);
    }
  });
  test('production and absent or mismatched proxy settings preserve URLs', () {
    const page = 'https://erp.homegeniegroup.in/Genieone-Canteen';
    expect(
      embeddedPageUri(
        page,
        app: Uri.parse('https://erp.homegeniegroup.in/genie/'),
      ).toString(),
      page,
    );
    expect(resolve(page, proxy: null).toString(), page);
    expect(resolve(page, site: 'http://localhost:9999/').toString(), page);
  });
  test('unsafe schemes and embedded credentials are rejected', () {
    for (final value in [
      'javascript:alert(1)',
      'http://external.test/',
      'https://user:password@erp.homegeniegroup.in/',
      'invalid',
    ]) {
      expect(resolve(value), isNull);
    }
  });
}
