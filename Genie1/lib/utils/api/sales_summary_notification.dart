import 'package:flutter_dotenv/flutter_dotenv.dart';

const salesSummaryRoute = '/genie-sales-summary';

String salesSummaryPageRoute(Object? value) =>
    value == salesSummaryRoute ? salesSummaryRoute : '';

bool isSalesSummaryPush(Map<String, dynamic> data) =>
    data['type'] == 'DOCUMENT_NOTIFICATION' &&
    data['notification_kind'] == 'SALES_SUMMARY' &&
    data['doctype'] == 'Notification Log' &&
    data['docname'] is String &&
    (data['docname'] as String).startsWith('sales-summary-') &&
    data['notification_log'] == data['docname'] &&
    data['page_route'] == salesSummaryRoute;

Uri? salesSummaryPageUri() {
  final site = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
  if (site == null ||
      site.scheme != 'https' ||
      site.host.isEmpty ||
      site.userInfo.isNotEmpty) {
    return null;
  }
  return site.resolve(salesSummaryRoute);
}
