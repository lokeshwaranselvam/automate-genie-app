// Mirror Homescreen's existing WillPopScope handling for embedded pages.
// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/navigation/home_navigation.dart';
import 'package:homegenie/utils/widget/home_back_button.dart';

Widget page(String title, {String? next}) => Builder(
  builder:
      (context) => Scaffold(
        appBar: AppBar(title: Text(title), leading: const HomeBackButton()),
        body:
            next == null
                ? null
                : TextButton(
                  onPressed:
                      () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder:
                              (_) => page(
                                next,
                                next: next == 'Visits' ? 'Details' : null,
                              ),
                        ),
                      ),
                  child: Text('Open $next'),
                ),
      ),
);

void main() {
  for (final origin in ['Home', 'More']) {
    for (final phoneBack in [false, true]) {
      testWidgets(
        'Back returns Details to Visits before $origin: phone=$phoneBack',
        (tester) async {
          final owner = Object();
          var homeResets = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) {
                  HomeNavigation.register(
                    owner: owner,
                    route: ModalRoute.of(context),
                    selectHome: () => homeResets++,
                  );
                  return page(origin, next: 'Visits');
                },
              ),
            ),
          );
          addTearDown(() => HomeNavigation.unregister(owner));
          await tester.tap(find.text('Open Visits'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open Details'));
          await tester.pumpAndSettle();
          Future<void> back() async {
            if (phoneBack) {
              await tester.binding.handlePopRoute();
            } else {
              await tester.tap(find.byTooltip('Back'));
            }
            await tester.pumpAndSettle();
          }

          await back();
          expect(find.text('Visits'), findsOneWidget);
          expect(find.text(origin), findsNothing);
          expect(homeResets, 0);
          await back();
          expect(find.text(origin), findsOneWidget);
          expect(homeResets, 0);
        },
      );
    }
  }

  testWidgets('App back honors embedded-page back handling', (tester) async {
    var embeddedOpen = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder:
              (context, setState) => WillPopScope(
                onWillPop: () async {
                  setState(() => embeddedOpen = false);
                  return false;
                },
                child: page(embeddedOpen ? 'Attendance' : 'Home'),
              ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
