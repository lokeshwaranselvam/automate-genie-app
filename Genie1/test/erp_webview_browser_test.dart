@TestOn('browser')
library;
import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:homegenie/utils/platform/erp_webview_web.dart';
import 'package:homegenie/utils/platform/erp_web_page_uri.dart';

void main() {
  test('browser ERP routes stay on the app origin and preserve deep links', () {
    final site = Uri.base.resolve('/');
    final page = erpWebPageUri(site, '/genie-opportunities?view=open');
    expect(page.origin, Uri.base.origin);
    expect(page.path, endsWith('/pages/opportunities.html'));
    expect(page.queryParameters['view'], 'open');
    expect(isTrustedErpPageUri(site), isTrue);
    expect(isTrustedErpPageUri(Uri.parse('https://outside.example/')), isFalse);
    expect(isTrustedErpPageUri(Uri.parse('http://user@localhost/')), isFalse);
  });
  testWidgets('iframe channels deliver only trusted messages and reject cross-origin loads', (tester) async {
    final controller = WebViewController();
    final loaded = Completer<void>();
    final received = Completer<String>();
    var count = 0;
    await controller.addJavaScriptChannel('GenieProbe', onMessageReceived: (message) {
      count++;
      if (!received.isCompleted) received.complete(message.message);
    });
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (_) => NavigationDecision.navigate,
      onPageFinished: (_) async {
        final ready = await controller.runJavaScriptReturningResult("document.body.dataset.probe === 'ready'");
        if (ready == true && !loaded.isCompleted) loaded.complete();
      },
    ));
    await controller.loadRequest(Uri.base.resolve('/bridge-fixture'));
    await tester.pumpWidget(MaterialApp(home: WebViewWidget(controller: controller)));
    await tester.runAsync(() async {
      web.HTMLIFrameElement? frame;
      for (var i = 0; i < 40; i++) {
        frame = web.document.querySelector('iframe') as web.HTMLIFrameElement?;
        if (frame != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(frame, isNotNull);
      frame!.srcdoc = '<!doctype html><html><body data-probe="ready">Bridge fixture</body></html>'.toJS;
      await loaded.future.timeout(const Duration(seconds: 10));
      await controller.runJavaScript("GenieProbe.postMessage('verified');");
      expect(await received.future.timeout(const Duration(seconds: 5)), 'verified');
      web.window.postMessage(<String, Object>{'token': 'forged', 'channel': 'GenieProbe', 'message': 'bad'}.jsify(), Uri.base.origin.toJS);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(count, 1);
      await expectLater(controller.loadRequest(Uri.parse('https://outside.example/')), throwsStateError);
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
