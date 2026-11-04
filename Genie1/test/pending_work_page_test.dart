import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/pending_work_page.dart';
import 'package:homegenie/Screen/session_webview.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'My Tasks embeds the existing New Task web page without native task requests',
    (tester) async {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: PendingWorkPage()));
          await tester.pumpAndSettle();
          final webview = tester.widget<SessionWebView>(
            find.byType(SessionWebView),
          );
          expect(webview.url, 'https://erp.homegeniegroup.in/TG');
          expect(webview.embedded, isTrue);
          expect(find.text('My Tasks'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(find.text('New Task'), findsNothing);
          expect(
            find.text('Your session has expired. Please sign in again.'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
        () => MockClient((_) async {
          fail('The WebView screen must not fetch or submit native task data.');
        }),
      );
    },
  );

  testWidgets(
    'pending-work updates retain the WebView state instead of resetting a form',
    (tester) async {
      final key = GlobalKey<PendingWorkPageState>();
      await tester.pumpWidget(MaterialApp(home: PendingWorkPage(key: key)));
      await tester.pumpAndSettle();
      final webviewState = tester.state(find.byType(SessionWebView));
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SessionWebView)), same(webviewState));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Tasks ignores phone Back while its visible Back returns Home', (
    tester,
  ) async {
    var tasksOpen = true;
    var visibleBackCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder:
              (context, update) =>
                  tasksOpen
                      ? PendingWorkPage(
                        onBack: () {
                          visibleBackCalls++;
                          update(() => tasksOpen = false);
                        },
                      )
                      : const Scaffold(body: Text('Home')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final webviewState = tester.state(find.byType(SessionWebView));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('My Tasks'), findsOneWidget);
    expect(tester.state(find.byType(SessionWebView)), same(webviewState));
    expect(visibleBackCalls, 0);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(PendingWorkPage), findsNothing);
    expect(visibleBackCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
