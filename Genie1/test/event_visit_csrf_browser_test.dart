@TestOn('browser')
library;
import 'package:flutter_test/flutter_test.dart';
import 'support/event_visit_csrf_scenarios.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('PWA visit writes preserve fields, include CSRF and safely bound retries', () async {
    final results = await verifyEventBrowserCsrf();
    expect(results, hasLength(10));
    for (final result in results.entries) {
      expect(result.value, isTrue, reason: result.key);
    }
  });
}
