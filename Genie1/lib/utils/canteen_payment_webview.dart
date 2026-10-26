/// Payment support is restricted to the existing Canteen entry point.
bool isCanteenPaymentPage(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'erp.homegeniegroup.in' &&
    (uri.path == '/Genieone-Canteen' || uri.path == '/Genieone-Canteen/');

/// Convert browser intent URLs to payment app URLs. Never execute arbitrary
/// Android intent extras, components, fallback URLs, or non-payment schemes.
Uri? canteenUpiUri(String url) {
  var uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme == 'intent') {
    final match = RegExp(
      r'^Intent;(?:[^;]*;)*scheme=([a-zA-Z][a-zA-Z0-9+.-]*);',
    ).firstMatch(uri.fragment);
    if (match == null || !uri.fragment.endsWith(';end')) return null;
    uri = uri.replace(scheme: match.group(1)!, fragment: '');
  }
  const schemes = {
    'upi',
    'tez',
    'gpay',
    'phonepe',
    'paytmmp',
    'credpay',
    'bhim',
  };
  if (!schemes.contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      !(uri.host == 'pay' || (uri.host == 'upi' && uri.path == '/pay')) ||
      (uri.queryParameters['pa'] ?? '').trim().isEmpty) {
    return null;
  }
  return uri;
}

/// The Canteen page loads checkout.js only when Pay is tapped. Intercept its
/// constructor assignment before that load, retaining every existing option,
/// callback, static property, and prototype. Also handles an already loaded SDK.
const canteenRazorpaySupportScript = r'''
(() => {
  if (window.__genieCanteenUpiInstalled) return;
  const descriptor = Object.getOwnPropertyDescriptor(window, 'Razorpay');
  if (descriptor && !descriptor.configurable) {
    throw new Error('Cannot configure Canteen UPI checkout');
  }
  const wrap = value => typeof value !== 'function' ? value : new Proxy(value, {
    construct(target, args, newTarget) {
      const paymentArgs = args.slice();
      paymentArgs[0] = Object.assign({}, paymentArgs[0], {webview_intent: true});
      return Reflect.construct(target, paymentArgs, newTarget);
    }
  });
  let checkout = wrap(window.Razorpay);
  Object.defineProperty(window, 'Razorpay', {
    configurable: true,
    enumerable: descriptor ? descriptor.enumerable : true,
    get() { return checkout; },
    set(value) { checkout = wrap(value); }
  });
  window.__genieCanteenUpiInstalled = true;
})();
''';
