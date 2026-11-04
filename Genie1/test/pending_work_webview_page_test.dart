import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/pending_work_webview_page.dart';
import 'package:homegenie/Screen/pending_section_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _WebPlatform extends WebViewPlatform {
  late _Controller controller;
  final cookies = <WebViewCookie>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = _Controller(params);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Navigation(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebWidget(params);
  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => _Cookies(params, cookies);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();
  late JavaScriptChannelParams channel;
  late _Navigation navigation;
  String? url;
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
    navigation = handler as _Navigation;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    url = params.uri.toString();
    navigation.started(url!);
    navigation.finished(url!);
  }

  @override
  Future<String?> currentUrl() async => url;
  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String script) async => true;
  void send(String id, String action, [Map<String, dynamic> args = const {}]) =>
      channel.onMessageReceived(
        JavaScriptMessage(
          message: jsonEncode({'id': id, 'action': action, ...args}),
        ),
      );
  Map<String, dynamic> response(String id) {
    for (final script in scripts.reversed) {
      final match = RegExp(r'\{detail: (.*)\}\)\);$').firstMatch(script);
      if (match != null) {
        final value = jsonDecode(match.group(1)!);
        if (value is Map<String, dynamic> && value['id'] == id) return value;
      }
    }
    throw StateError('No response for $id');
  }
}

class _Navigation extends PlatformNavigationDelegate {
  _Navigation(super.params) : super.implementation();
  late PageEventCallback started, finished;
  late NavigationRequestCallback request;
  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback value) async {
    request = value;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback value) async {
    started = value;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback value) async {
    finished = value;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback value) async {}
}

class _WebWidget extends PlatformWebViewWidget {
  _WebWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Cookies extends PlatformWebViewCookieManager {
  _Cookies(super.params, this.cookies) : super.implementation();
  final List<WebViewCookie> cookies;
  @override
  Future<void> setCookie(WebViewCookie cookie) async {
    cookies.add(cookie);
  }

  @override
  Future<bool> clearCookies() async {
    fail('Pending Work must preserve other cookies');
  }
}

void main() {
  testWidgets(
    'native bridge retains API permissions, snapshots, detail route and session isolation',
    (tester) async {
      const user = 'pending-web@example.test';
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      SharedPreferences.setMockInitialValues({
        'session_sid': 'test-pending-sid',
        'session_username': user,
      });
      final platform = _WebPlatform();
      WebViewPlatform.instance = platform;
      final calls = <String>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(home: PendingWorkWebViewPage()),
          );
          await tester.pumpAndSettle();
          final controller = platform.controller;
          expect(
            controller.url,
            'https://erp.example.test$pendingWorkWebRoute',
          );
          expect(platform.cookies.single.domain, 'erp.example.test');
          expect(
            controller.scripts.join(),
            isNot(contains('test-pending-sid')),
          );
          expect(
            await controller.navigation.request(
              NavigationRequest(
                url: 'https://outside.test$pendingWorkWebRoute',
                isMainFrame: true,
              ),
            ),
            NavigationDecision.prevent,
          );
          controller.send('dashboard', 'dashboard');
          await tester.pumpAndSettle();
          expect(controller.response('dashboard')['error'], isNull);
          expect(
            controller.response('dashboard')['value']['available_sections'],
            ['stock'],
          );
          controller.send('denied', 'section', {'section': 'opportunities'});
          await tester.pumpAndSettle();
          expect(
            controller.response('denied')['error'],
            contains('not available'),
          );
          expect(calls, ['dashboard']);
          controller.send('stock', 'section', {'section': 'stock'});
          await tester.pumpAndSettle();
          expect(
            controller.response('stock')['value']['items'][0]['name'],
            'STE-1',
          );
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getStringList('pending_work_seen_${user}_stock'), [
            'STE-1',
          ]);
          controller.send('bad-index', 'open', {
            'section': 'stock',
            'index': 20,
          });
          await tester.pumpAndSettle();
          expect(
            controller.response('bad-index')['error'],
            contains('Refresh the list'),
          );
          controller.send('open', 'open', {'section': 'stock', 'index': 0});
          await tester.pumpAndSettle();
          final detail = tester.widget<PendingDetailPage>(
            find.byType(PendingDetailPage),
          );
          expect(detail.item['name'], 'STE-1');
          expect(detail.section, 'stock');
          expect(await detail.loadItem!(), containsPair('name', 'STE-1'));
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(controller.response('open')['error'], isNull);
          await prefs.setString('session_sid', 'different-session');
          controller.send('changed', 'dashboard');
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Your ERP session changed. Sign in again and reopen Pending Work.',
            ),
            findsOneWidget,
          );
          expect(calls, ['dashboard', 'stock', 'stock']);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response(jsonEncode({'message': user}), 200);
          }
          expectSync(request.url.path, '/api/method/get_pending_work');
          expectSync(request.headers['cookie'], 'sid=test-pending-sid');
          final action = request.url.queryParameters['action']!;
          calls.add(action);
          return http.Response(
            jsonEncode({
              'message':
                  action == 'dashboard'
                      ? {
                        'available_sections': ['stock'],
                        'stock': {'count': 1},
                      }
                      : {
                        'items': [
                          {
                            'name': 'STE-1',
                            'stock_entry': 'STE-1',
                            'item_name': 'Production item',
                          },
                        ],
                      },
            }),
            200,
          );
        }),
      );
    },
  );
  test('bridge accepts only the configured HTTPS Pending Work route', () {
    final page = Uri.parse('https://erp.example.test$pendingWorkWebRoute');
    for (final value in ['$page', '$page/', '$page?v=1', '$page#section']) {
      expect(isPendingWorkWebPageLocation(page, value), isTrue);
    }
    for (final value in [
      'http://erp.example.test$pendingWorkWebRoute',
      'https://outside.test$pendingWorkWebRoute',
      'https://erp.example.test.outside.test$pendingWorkWebRoute',
      'https://user@erp.example.test$pendingWorkWebRoute',
      'https://erp.example.test:444$pendingWorkWebRoute',
      'https://erp.example.test/app',
      'https://erp.example.test/genie-opportunities',
      'https://erp.example.test$pendingWorkWebRoute/extra',
      'javascript:alert(1)',
      'about:blank',
    ]) {
      expect(isPendingWorkWebPageLocation(page, value), isFalse, reason: value);
    }
  });

  testWidgets('invalid site fails safely and Back returns to the caller', (
    tester,
  ) async {
    dotenv.testLoad(fileInput: 'SITE_URL=http://erp.example.test');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const PendingWorkWebViewPage(),
                        ),
                      ),
                  child: const Text('Open Pending Work'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open Pending Work'));
    await tester.pumpAndSettle();
    expect(
      find.text('The ERP site URL is not configured with HTTPS.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PendingWorkWebViewPage), findsNothing);
    expect(find.text('Open Pending Work'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
