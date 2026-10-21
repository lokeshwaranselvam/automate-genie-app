import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/navigation/home_navigation.dart';

void main() {
  testWidgets(
    'embedded page navigation returns to Home and selects its requested tab',
    (tester) async {
      final owner = Object();
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              HomeNavigation.register(
                owner: owner,
                route: ModalRoute.of(context),
                selectHome: () => selected = 0,
                selectTab: (index) => selected = index,
                navigationBar:
                    (pageContext) => TextButton(
                      onPressed: () => HomeNavigation.goToTab(pageContext, 4),
                      child: const Text('More navigation'),
                    ),
              );
              return Scaffold(
                body: TextButton(
                  child: const Text('Open webpage'),
                  onPressed:
                      () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder:
                              (pageContext) => Scaffold(
                                body: const Text('Embedded webpage'),
                                bottomNavigationBar:
                                    HomeNavigation.navigationBar(pageContext),
                              ),
                        ),
                      ),
                ),
              );
            },
          ),
        ),
      );
      addTearDown(() => HomeNavigation.unregister(owner));
      await tester.tap(find.text('Open webpage'));
      await tester.pumpAndSettle();
      expect(find.text('Embedded webpage'), findsOneWidget);
      await tester.tap(find.text('More navigation'));
      await tester.pumpAndSettle();
      expect(selected, 4);
      expect(find.text('Embedded webpage'), findsNothing);
      expect(find.text('Open webpage'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
