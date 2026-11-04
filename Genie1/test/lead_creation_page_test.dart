import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/lead_creation_page.dart';
import 'package:homegenie/utils/widget/webview_pull_to_refresh.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'fake_lead_webview_platform.dart';

void main() {
  late FakeLeadWebPlatform platform;
  late List<http.Request> requests;
  setUp(() {
    platform = FakeLeadWebPlatform();
    WebViewPlatform.instance = platform;
    requests = [];
    SharedPreferences.setMockInitialValues({
      'session_sid': 'private-lead-cookie-value',
      'session_username': 'sales@example.test',
    });
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });
  MockClient client() => MockClient((request) async {
    requests.add(request);
    expectSync(request.url.path, '/api/method/frappe.auth.get_logged_user');
    return http.Response(jsonEncode({'message': 'sales@example.test'}), 200);
  });
  Future<void> open(WidgetTester tester, Future<void> Function() checks) =>
      http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: LeadCreationPage()));
        await tester.pumpAndSettle();
        await checks();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, client);

  test('Lead bridge accepts only the exact configured ERP webpage', () {
    final page = Uri.parse('https://erp.example.test/create_lead_from_mobile');
    for (final value in [page.toString(), '$page/', '$page?v=1']) {
      expectSync(isLeadCreationWebPageLocation(page, value), isTrue);
    }
    for (final value in [
      'file:///android_asset/flutter_assets/assets/web/lead_creation.html',
      'https://outside.test/create_lead_from_mobile',
      'http://erp.example.test/create_lead_from_mobile',
      'https://erp.example.test/api/method/create_lead_from_mobile',
      'https://erp.example.test/login',
      'https://user@erp.example.test/create_lead_from_mobile',
      'https://erp.example.test:444/create_lead_from_mobile',
    ]) {
      expectSync(isLeadCreationWebPageLocation(page, value), isFalse);
    }
  });
  testWidgets('loads hosted page with ERP cookie and binds only the username', (
    tester,
  ) async {
    await open(tester, () async {
      expectSync(find.text('Create Lead'), findsOneWidget);
      expectSync(find.byTooltip('Back'), findsOneWidget);
      expectSync(
        platform.controller.request!.uri.toString(),
        'https://erp.example.test/create_lead_from_mobile',
      );
      expectSync(
        platform.controller.request!.headers['Cookie'],
        'sid=private-lead-cookie-value',
      );
      expectSync(platform.cookies.single.name, 'sid');
      expectSync(platform.cookies.single.value, 'private-lead-cookie-value');
      expectSync(
        platform.controller.scripts.join(),
        contains('genie-lead-session'),
      );
      expectSync(
        platform.controller.scripts.join(),
        contains('sales@example.test'),
      );
      expectSync(
        platform.controller.scripts.join(),
        isNot(contains('private-lead-cookie-value')),
      );
      expectSync(tester.takeException(), isNull);
    });
  });
  testWidgets('blocks outside navigation and navigation during submission', (
    tester,
  ) async {
    await open(tester, () async {
      expectSync(
        await platform.controller.navigation.request(
          NavigationRequest(url: 'https://outside.test', isMainFrame: true),
        ),
        NavigationDecision.prevent,
      );
      platform.controller.notify('busy', {'value': true});
      await tester.pumpAndSettle();
      expectSync(
        await platform.controller.navigation.request(
          NavigationRequest(url: platform.controller.url!, isMainFrame: true),
        ),
        NavigationDecision.prevent,
      );
      platform.controller.notify('busy', {'value': false});
      await tester.pumpAndSettle();
      expectSync(
        await platform.controller.navigation.request(
          NavigationRequest(url: platform.controller.url!, isMainFrame: true),
        ),
        NavigationDecision.navigate,
      );
    });
  });
  testWidgets(
    'old bridge-only webpage gives a publication error instead of spinning',
    (tester) async {
      platform.marker = false;
      await open(tester, () async {
        expectSync(
          find.text(
            'Publish the updated create_lead_from_mobile Web Page in ERP, then retry.',
          ),
          findsOneWidget,
        );
        expectSync(find.text('Retry'), findsOneWidget);
      });
    },
  );
  testWidgets(
    'session changes fail closed and the page cannot call native Lead APIs',
    (tester) async {
      await open(tester, () async {
        platform.controller.send('1', 'options');
        await tester.pumpAndSettle();
        expectSync(requests.length, 1);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('session_sid', 'another-session');
        platform.controller.notify('busy', {'value': true});
        await tester.pumpAndSettle();
        expectSync(
          find.text(
            'Your ERP session or site changed. Sign in again and reopen Create Lead.',
          ),
          findsOneWidget,
        );
        expectSync(requests.length, 1);
      });
    },
  );
  testWidgets(
    'missing session shows a sign-in error without opening the webpage',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await open(tester, () async {
        expectSync(
          find.text('Your Frappe session has expired. Please sign in again.'),
          findsOneWidget,
        );
      });
    },
  );
  testWidgets('Back returns to the existing caller', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed:
                        () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const LeadCreationPage(),
                          ),
                        ),
                    child: const Text('Caller'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Caller'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expectSync(find.text('Caller'), findsOneWidget);
    }, client);
  });
  testWidgets('swipe refresh recreates the Lead form but never interrupts submission', (tester) async {
    await open(tester, () async {
      final old = platform.controller;
      Future<void> swipe() async {
        final bounds = tester.getRect(find.byType(WebViewPullToRefresh));
        final gesture = await tester.startGesture(bounds.topLeft + const Offset(40, 40));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 150));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }
      platform.controller.notify('busy', {'value': true});
      await tester.pumpAndSettle();
      await swipe();
      expectSync(platform.controller, same(old));
      platform.controller.notify('busy', {'value': false});
      await tester.pumpAndSettle();
      await swipe();
      expectSync(platform.controller, isNot(same(old)));
      expectSync(platform.controller.request!.uri.path, '/create_lead_from_mobile');
      expectSync(platform.controller.scripts.join(), contains('genie-lead-session'));
      expectSync(requests.every((request) => request.method == 'GET'), isTrue);
      expectSync(tester.takeException(), isNull);
    });
  });

}
