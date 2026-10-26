import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/canteen_payment_webview.dart';

void main() {
  test('payment support is limited to the HTTPS Canteen page', () {
    expect(
      isCanteenPaymentPage(
        Uri.parse('https://erp.homegeniegroup.in/Genieone-Canteen'),
      ),
      isTrue,
    );
    for (final url in [
      'http://erp.homegeniegroup.in/Genieone-Canteen',
      'https://other.example/Genieone-Canteen',
      'https://erp.homegeniegroup.in/GOAD',
      'https://erp.homegeniegroup.in/Genieone-Canteen-extra',
    ]) {
      expect(isCanteenPaymentPage(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('UPI links retain the original payment parameters', () {
    const link = 'upi://pay?pa=merchant%40bank&pn=Canteen&am=5&tr=order123';
    expect(canteenUpiUri(link).toString(), link);
    expect(canteenUpiUri('tez://upi/pay?pa=merchant%40bank'), isNotNull);
    expect(canteenUpiUri('phonepe://pay?pa=merchant%40bank'), isNotNull);
  });

  test('intent URLs retain payment data but discard Android extras', () {
    final uri = canteenUpiUri(
      'intent://pay?pa=merchant%40bank&am=5&tr=order123'
      '#Intent;scheme=upi;package=com.example.app;'
      'S.browser_fallback_url=https%3A%2F%2Fother.example;end',
    );
    expect(uri?.scheme, 'upi');
    expect(uri?.queryParameters['tr'], 'order123');
    expect(uri?.queryParameters['pa'], 'merchant@bank');
    expect(uri?.fragment, isEmpty);
  });

  test('unrelated and malformed deep links cannot launch applications', () {
    for (final link in [
      'intent://pay?pa=merchant@bank#Intent;scheme=evil;end',
      'intent://pay?pa=merchant@bank#Intent;scheme=upi;',
      'intent://pay?pa=merchant@bank#Intent;package=evil;end',
      'javascript:alert(1)',
      'tel:123456',
      'file:///private',
      'upi://settings?pa=merchant@bank',
      'upi://pay?am=5',
      'upi://user@pay?pa=merchant@bank',
      'upi://pay:123?pa=merchant@bank',
    ]) {
      expect(canteenUpiUri(link), isNull, reason: link);
    }
  });
}
