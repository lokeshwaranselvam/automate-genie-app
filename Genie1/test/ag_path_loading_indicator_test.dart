import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/ag_path_loading_indicator.dart';

void main() {
  testWidgets(
    'loading completion removes the animation without waiting for a cycle',
    (tester) async {
      var loading = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: Center(
                  child:
                      loading
                          ? const AgPathLoadingIndicator()
                          : const Text('API result'),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(AgPathLoadingIndicator), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      update(() => loading = false);
      await tester.pump();
      expect(find.text('API result'), findsOneWidget);
      expect(find.byType(AgPathLoadingIndicator), findsNothing);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion and hidden ticker mode stop and resume cleanly', (
    tester,
  ) async {
    var reduced = true;
    var tickerEnabled = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: TickerMode(
                enabled: tickerEnabled,
                child: const Center(
                  child: AgPathLoadingIndicator(showBackground: true),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    update(() => reduced = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    update(() => tickerEnabled = false);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    update(() => tickerEnabled = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sizes and duration updates paint on light and dark surfaces', (
    tester,
  ) async {
    for (final size in [24.0, 64.0, 120.0, 180.0]) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: Center(
                child: AgPathLoadingIndicator(
                  size: size,
                  showBackground: true,
                  animationDuration: Duration(
                    milliseconds: size == 64 ? 2500 : 3000,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getSize(find.byType(AgPathLoadingIndicator)),
          Size.square(size),
        );
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('AG path frames paint throughout a full loop', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: const AgPathLoadingIndicator(size: 320),
            ),
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 7; frame++) {
      await tester.pump(Duration(milliseconds: frame == 0 ? 0 : 500));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/ag_loader_preview').create(recursive: true);
        await File(
          'build/ag_loader_preview/frame_$frame.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });
}
