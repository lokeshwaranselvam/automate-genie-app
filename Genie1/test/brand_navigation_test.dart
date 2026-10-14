import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';

void main() {
  for (final width in [320.0, 360.0, 600.0]) {
    testWidgets('gradient navigation retains actions at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selectedTab = -1;
      var refreshes = 0;
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewKey,
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: BrandColors.indigo),
            ),
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.18)),
                  child: child!,
                ),
            home: Scaffold(
              appBar: brandAppBar(
                title: const Text('Site Visits'),
                actions: [
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () => refreshes++,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Your schedule', style: TextStyle(fontSize: 22)),
                    const SizedBox(height: 12),
                    const Text('Larger text with clear, readable navigation.'),
                    const SizedBox(height: 24),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        foregroundColor: Colors.white,
                      ).copyWith(
                        backgroundBuilder: BrandColors.buttonBackground,
                      ),
                      onPressed: () {},
                      child: const Text('New Visit'),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: brandBottomNavigationBar(
                currentIndex: 0,
                onTap: (index) => selectedTab = index,
                type: BottomNavigationBarType.fixed,
                showUnselectedLabels: true,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.assignment),
                    label: 'Tasks',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.place),
                    label: 'Visits',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.people),
                    label: 'Leads',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.more_horiz),
                    label: 'More',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(selectedTab, 1);
      expect(tester.takeException(), isNull);
      if (width == 360) {
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build').create(recursive: true);
          await File(
            'build/brand_navigation_preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
