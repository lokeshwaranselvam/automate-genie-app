import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/webview_pull_to_refresh.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class RefreshWebPlatform extends WebViewPlatform {
  late RefreshWebController controller;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = RefreshWebController(params);
}

class RefreshWebController extends PlatformWebViewController {
  RefreshWebController(super.params) : super.implementation();
  Future<Object> Function() probe = () async => true;
  final scripts = <String>[];
  @override
  Future<Object> runJavaScriptReturningResult(String script) {
    scripts.add(script);
    return probe();
  }
}

void main() {
  late RefreshWebPlatform platform;
  WebViewPlatform? previous;
  setUp(() {
    previous = WebViewPlatform.instance;
    WebViewPlatform.instance = platform = RefreshWebPlatform();
  });
  tearDown(() {
    if (previous != null) WebViewPlatform.instance = previous;
  });

  Future<void> mount(
    WidgetTester tester, {
    required Future<void> Function() refresh,
    bool enabled = true,
    WebViewController? controller,
    Widget? child,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WebViewPullToRefresh(
            controller: controller,
            enabled: enabled,
            onRefresh: refresh,
            child: child ?? const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pull(
    WidgetTester tester, [
    Offset delta = const Offset(0, 140),
  ]) async {
    final gesture = await tester.startGesture(
      const Offset(150, 100),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await gesture.moveBy(delta);
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  testWidgets('top-of-page pull refreshes once without taking tap gestures', (
    tester,
  ) async {
    final controller = WebViewController();
    var refreshes = 0, taps = 0;
    await mount(
      tester,
      controller: controller,
      refresh: () async => refreshes++,
      child: Center(
        child: TextButton(onPressed: () => taps++, child: const Text('Action')),
      ),
    );
    await tester.tap(find.text('Action'));
    await tester.pump();
    expect(taps, 1);
    expect(refreshes, 0);
    await pull(tester);
    expect(refreshes, 1);
    expect(platform.controller.scripts.last, contains('parentElement'));
    expect(platform.controller.scripts.last, contains('elementFromPoint'));
  });

  testWidgets('scrolled HTML or focused control cannot trigger refresh', (
    tester,
  ) async {
    final controller = WebViewController();
    platform.controller.probe = () async => false;
    var calls = 0;
    await mount(tester, controller: controller, refresh: () async => calls++);
    await pull(tester);
    expect(calls, 0);
  });

  testWidgets('short upward and horizontal swipes do not reload', (
    tester,
  ) async {
    final controller = WebViewController();
    var calls = 0;
    await mount(tester, controller: controller, refresh: () async => calls++);
    for (final delta in [
      const Offset(0, 30),
      const Offset(0, -120),
      const Offset(160, 100),
    ]) {
      await pull(tester, delta);
    }
    expect(calls, 0);
  });

  testWidgets(
    'disabled forms cannot refresh and concurrent refreshes are coalesced',
    (tester) async {
      final controller = WebViewController();
      var calls = 0;
      await mount(
        tester,
        enabled: false,
        controller: controller,
        refresh: () async => calls++,
      );
      await pull(tester);
      expect(calls, 0);
      final pending = Completer<void>();
      await mount(
        tester,
        controller: controller,
        refresh: () {
          calls++;
          return pending.future;
        },
      );
      await pull(tester);
      await pull(tester);
      expect(calls, 1);
      pending.complete();
      await tester.pump();
    },
  );

  testWidgets('multi-touch and a cancelled drag cannot refresh', (
    tester,
  ) async {
    final controller = WebViewController();
    var calls = 0;
    await mount(tester, controller: controller, refresh: () async => calls++);
    final first = await tester.startGesture(const Offset(150, 100), pointer: 1);
    await tester.pump();
    final second = await tester.startGesture(
      const Offset(170, 100),
      pointer: 2,
    );
    await first.moveBy(const Offset(0, 150));
    await second.up();
    await first.up();
    await tester.pump();
    final cancel = await tester.startGesture(const Offset(150, 100));
    await cancel.moveBy(const Offset(0, 150));
    await cancel.cancel();
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('late scroll probes cannot refresh disposed or replaced pages', (
    tester,
  ) async {
    final controller = WebViewController();
    final probe = Completer<Object>();
    platform.controller.probe = () => probe.future;
    var calls = 0;
    await mount(tester, controller: controller, refresh: () async => calls++);
    final gesture = await tester.startGesture(const Offset(150, 100));
    await gesture.moveBy(const Offset(0, 150));
    await gesture.up();
    await tester.pumpWidget(const SizedBox.shrink());
    probe.complete(true);
    await tester.pump();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error layout can be retried by swiping without a controller', (
    tester,
  ) async {
    var calls = 0;
    await mount(tester, refresh: () async => calls++);
    await pull(tester);
    expect(calls, 1);
  });

  testWidgets('failed DOM inspection leaves page untouched', (tester) async {
    final controller = WebViewController();
    platform.controller.probe =
        () async => throw StateError('WebView unavailable');
    var calls = 0;
    await mount(tester, controller: controller, refresh: () async => calls++);
    await pull(tester);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
