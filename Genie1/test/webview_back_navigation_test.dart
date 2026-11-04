import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/session_webview.dart';

void main() {
  testWidgets('WebView blocks phone Back but app Back returns to its caller', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder:
                              (_) => const SessionWebView(
                                url: 'invalid',
                                title: 'Dashboard',
                              ),
                        ),
                      ),
                  child: const Text('More'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WebView without blocked Back lets phone Back close the page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder:
                              (_) => const SessionWebView(
                                url: 'invalid',
                                title: 'Dashboard',
                                blockSystemBack: false,
                              ),
                        ),
                      ),
                  child: const Text('More'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
