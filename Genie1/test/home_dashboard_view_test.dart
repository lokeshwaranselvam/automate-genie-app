import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/home_dashboard_view.dart';

void main() {
  setUpAll(() async {
    // Optional real fonts for the local visual preview; tests run without them.
    for (final entry
        in {
          'HomePreview': 'C:/Windows/Fonts/arial.ttf',
          'MaterialIcons':
              'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        }.entries) {
      final font = File(entry.value);
      if (await font.exists()) {
        final loader = FontLoader(entry.key)
          ..addFont(font.readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    }
  });

  for (final width in [320.0, 360.0, 430.0, 600.0]) {
    testWidgets('Home preserves live content and actions at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      final previewKey = GlobalKey();
      Widget screen({
        String name = 'Lokeshwaran S',
        Widget? avatar,
        List<Widget> schedule = const [],
      }) => RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'HomePreview'),
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.18)),
                child: child!,
              ),
          home: Scaffold(
            body: HomeDashboardView(
              avatar:
                  avatar ??
                  const Icon(Icons.person, key: ValueKey('first-avatar')),
              name: name,
              greeting: 'Good Morning',
              date: DateTime(2024, 6, 24),
              taskCount: '00',
              visitCount: '00',
              leadCount: '22',
              pendingCount: '24',
              loading: false,
              attendanceBusy: false,
              schedule: schedule,
              onRefresh: () async => calls.add('refresh'),
              onMenu: () => calls.add('menu'),
              onNotifications: () => calls.add('notifications'),
              onTasks: () => calls.add('tasks'),
              onVisits: () => calls.add('visits'),
              onLeads: () => calls.add('leads'),
              onPending: () => calls.add('pending'),
              onAttendance: () => calls.add('attendance'),
              onAddLead: () => calls.add('add-lead'),
            ),
            bottomNavigationBar: HomeNavigationBar(
              currentIndex: 0,
              onTap: (index) => calls.add('nav-$index'),
            ),
          ),
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Add Task'), findsNothing);
      expect(find.text('Lokeshwaran S'), findsOneWidget);
      expect(find.text('22'), findsOneWidget);
      expect(find.text('Mon, 24 Jun'), findsOneWidget);
      if (width == 360) {
        await tester.runAsync(() async {
          final boundary =
              previewKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build').create(recursive: true);
          await File(
            'build/home_dashboard_preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      for (final entry
          in {
            'Tasks Today': 'tasks',
            'Site Visits': 'visits',
            'My Leads': 'leads',
            'Pending': 'pending',
            'View All': 'visits',
            'Attendance': 'attendance',
            'Add Lead': 'add-lead',
            'Site Visit': 'visits',
            'New Task': 'tasks',
          }.entries) {
        await tester.ensureVisible(find.text(entry.key));
        await tester.tap(find.text(entry.key));
        expect(calls.last, entry.value);
      }
      await tester.tap(find.text('Tasks'));
      expect(calls.last, 'nav-1');
      await tester.pumpWidget(
        screen(
          name: 'Another Employee',
          avatar: const Icon(Icons.face, key: ValueKey('updated-avatar')),
          schedule: const [Text('Live ERP visit')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Another Employee'), findsOneWidget);
      expect(find.byKey(const ValueKey('updated-avatar')), findsOneWidget);
      expect(find.byKey(const ValueKey('first-avatar')), findsNothing);
      expect(find.text('Live ERP visit'), findsOneWidget);
      expect(find.text('No events scheduled for today.'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
