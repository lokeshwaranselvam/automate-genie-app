import 'erp_webview_web.dart';

void setErpPageRefreshHandler(WebViewController? controller, Future<void> Function()? handler) {
  if (controller != null) controller.onPullToRefresh = handler;
}
