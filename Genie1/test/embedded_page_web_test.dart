@TestOn('browser')
library;

import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/session_webview.dart';
import 'package:homegenie/utils/navigation/home_navigation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

class _ViewRegistry implements ui_web.PlatformViewRegistry {
  final views = <int, web.Element>{};
  @override
  Object getViewById(int viewId) => views[viewId]!;
  @override
  bool registerViewFactory(
    String viewType,
    Function viewFactory, {
    bool isVisible = true,
  }) => false;
}

void main() {
  late _ViewRegistry registry;
  setUp(() {
    registry = _ViewRegistry();
    ui_web.debugOverridePlatformViewRegistry(registry);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
          if (call.method == 'create') {
            final args = call.arguments as Map;
            final params = args['params'] as Map?;
            registry.views[args['id'] as int] = web.document.createElement(
              params?['tagName'] as String? ?? 'div',
            );
          } else if (call.method == 'dispose') {
            registry.views.remove(call.arguments);
          }
          return null;
        });
    dotenv.testLoad(
      fileInput:
          'SITE_URL=${Uri.base.origin}/\nWEB_PROXY_ERP_ORIGIN=https://erp.example.test',
    );
    SharedPreferences.setMockInitialValues({
      'session_sid': 'browser-marker',
      'session_username': 'staff@example.test',
    });
  });
  tearDown(() {
    ui_web.debugOverridePlatformViewRegistry(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });
  testWidgets(
    'invalid page keeps app navigation and offers Retry without opening another tab',
    (tester) async {
      final owner = Object();
      HomeNavigation.register(
        owner: owner,
        route: null,
        selectHome: () {},
        navigationBar: (_) => const Text('App navigation'),
      );
      addTearDown(() => HomeNavigation.unregister(owner));
      await tester.pumpWidget(
        const MaterialApp(
          home: SessionWebView(url: 'invalid', title: 'Report'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('App navigation'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Open page'), findsNothing);
      expect(find.byTooltip('Open page in browser'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'authenticated ERP page is framed through the local origin with no SID in its URL',
    (tester) async {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(
              home: SessionWebView(
                url: 'https://erp.example.test/robots.txt',
                title: 'ERP report',
              ),
            ),
          );
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(find.byType(HtmlElementView), findsOneWidget);
          final frame =
              registry.views.values.whereType<web.HTMLIFrameElement>().single;
          expect(frame.src, '${Uri.base.origin}/robots.txt');
          expect(frame.src, isNot(contains('browser-marker')));
          expect(find.byTooltip('Reload page'), findsOneWidget);
          expect(find.byTooltip('Open page in browser'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
        () => MockClient(
          (_) async => http.Response('{"message":"staff@example.test"}', 200),
        ),
      );
    },
  );
}
