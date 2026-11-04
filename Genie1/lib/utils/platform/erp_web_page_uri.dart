import 'package:flutter/foundation.dart';

const _pages = {
  '/create_lead_from_mobile': 'lead-creation.html',
  '/genie-expense-claim': 'expense-claim.html',
  '/genie-leave-application': 'leave-application.html',
  '/genie-opportunities': 'opportunities.html',
  '/genie-pending-work': 'pending-work.html',
  '/genie-sales-summary': 'sales-summary.html',
};

/// Browser pages share the app's origin and ERP session. Native routes stay intact.
Uri erpWebPageUri(Uri site, String route) {
  final target = site.resolve(route);
  final asset = _pages[target.path];
  if (!kIsWeb || asset == null) return target;
  return Uri.base.resolve('pages/$asset').replace(query: target.hasQuery ? target.query : null);
}

bool isTrustedErpPageUri(Uri uri) {
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  if (uri.scheme == 'https') return !kIsWeb || uri.origin == Uri.base.origin;
  return kIsWeb && uri.scheme == 'http' &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1') &&
      uri.origin == Uri.base.origin;
}

String erpPageLoadMessage(String nativeMessage) => kIsWeb
    ? 'This page did not finish loading. Refresh or reopen it and try again.'
    : nativeMessage;
