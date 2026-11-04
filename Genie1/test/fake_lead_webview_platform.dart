import 'dart:convert';
import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class FakeLeadWebPlatform extends WebViewPlatform {
  late FakeLeadWebController controller;
  bool marker = true;
  final cookies = <WebViewCookie>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = FakeLeadWebController(params, this);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakeLeadNavigation(params);
  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => FakeLeadCookies(params, cookies);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWidget(params);
}

class FakeLeadCookies extends PlatformWebViewCookieManager {
  FakeLeadCookies(super.params, this.cookies) : super.implementation();
  final List<WebViewCookie> cookies;
  @override
  Future<void> setCookie(WebViewCookie cookie) async {
    cookies.add(cookie);
  }

  @override
  Future<bool> clearCookies() async {
    throw StateError('Do not clear other ERP cookies.');
  }
}

class FakeLeadWebController extends PlatformWebViewController {
  FakeLeadWebController(super.params, this.owner) : super.implementation();
  final FakeLeadWebPlatform owner;
  LoadRequestParams? request;
  int loads = 0;
  late JavaScriptChannelParams channel;
  late FakeLeadNavigation navigation;
  String? url;
  String? asset;
  final scripts = <String>[];
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setBackgroundColor(Color color) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channel = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    navigation = handler as FakeLeadNavigation;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads++;
    request = params;
    url = params.uri.toString();
    final decision = await navigation.request(
      NavigationRequest(url: url!, isMainFrame: true),
    );
    if (decision == NavigationDecision.navigate) {
      navigation.started(url!);
      navigation.finished(url!);
    }
  }

  @override
  Future<Object> runJavaScriptReturningResult(String script) async =>
      owner.marker;
  void notify(String action, [Map<String, dynamic> extra = const {}]) =>
      channel.onMessageReceived(
        JavaScriptMessage(message: jsonEncode({'action': action, ...extra})),
      );
  @override
  Future<String?> currentUrl() async => url;
  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
  }

  void send(String id, String action, [Map<String, dynamic> args = const {}]) =>
      channel.onMessageReceived(
        JavaScriptMessage(
          message: jsonEncode({'id': id, 'action': action, 'args': args}),
        ),
      );
  Map<String, dynamic> response(String id) {
    for (final script in scripts.reversed) {
      final match = RegExp(
        r'^window.LeadForm.receive\((.*)\);$',
      ).firstMatch(script);
      if (match != null) {
        final data = jsonDecode(match.group(1)!);
        if (data['id'] == id) return Map<String, dynamic>.from(data);
      }
    }
    throw StateError('No response for $id');
  }
}

class FakeLeadNavigation extends PlatformNavigationDelegate {
  FakeLeadNavigation(super.params) : super.implementation();
  late NavigationRequestCallback request;
  late PageEventCallback finished, started;
  @override
  Future<void> setOnPageStarted(PageEventCallback value) async {
    started = value;
  }

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback value) async {
    request = value;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback value) async {
    finished = value;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback value) async {}
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
