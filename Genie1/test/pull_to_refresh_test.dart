import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/pull_to_refresh.dart';

void main() {
  for (final layout in ['empty', 'short', 'long', 'form', 'safe-area form']) {
    testWidgets('swipe refresh works for $layout content', (tester) async {
      var calls = 0;
      final Widget child = switch (layout) {
        'empty' => const Center(child: Text('No items')),
        'short' => ListView(children: const [Text('One item')]),
        'long' => Column(
          children: [
            const Text('Search'),
            Expanded(
              child: ListView(
                children: List.generate(40, (i) => Text('Row $i')),
              ),
            ),
          ],
        ),
        'form' => SingleChildScrollView(
          child: Column(children: const [TextField(), SizedBox(height: 1200)]),
        ),
        _ => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: const [TextField(), SizedBox(height: 1200)],
            ),
          ),
        ),
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: PullToRefresh(
              onRefresh: () async {
                calls++;
              },
              child: child,
            ),
          ),
        ),
      );
      final pull = await tester.startGesture(const Offset(150, 150));
      await pull.moveBy(const Offset(0, 40));
      await tester.pump();
      await pull.moveBy(const Offset(0, 450));
      await tester.pump();
      void expectBounded() {
        for (final state in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        )) {
          final position = state.position;
          expect(
            position.pixels,
            greaterThanOrEqualTo(position.minScrollExtent),
          );
          expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent));
        }
      }

      // Check during the drag, not only after a bounce animation settles.
      expectBounded();
      await pull.up();
      await tester.pumpAndSettle();
      expectBounded();
      expect(calls, 1);
      await tester.flingFrom(
        const Offset(150, 400),
        const Offset(0, -4000),
        6000,
      );
      await tester.pumpAndSettle();
      expectBounded();
      final bottomPull = await tester.startGesture(const Offset(150, 400));
      await bottomPull.moveBy(const Offset(0, -40));
      await tester.pump();
      await bottomPull.moveBy(const Offset(0, -450));
      await tester.pump();
      expectBounded();
      await bottomPull.up();
      await tester.pumpAndSettle();
      expectBounded();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
