import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/my_performance_page.dart';
import 'package:homegenie/Screen/session_webview.dart';
import 'package:homegenie/utils/api/performance_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'performance_api_test.dart' show performancePayload;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    final fontPath = Platform.environment['PERFORMANCE_PREVIEW_FONT'];
    if (fontPath != null) {
      final loader = FontLoader('Roboto')..addFont(
        File(
          fontPath,
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    }
    final iconPath = Platform.environment['PERFORMANCE_PREVIEW_ICONS'];
    if (iconPath != null) {
      final loader = FontLoader('MaterialIcons')..addFont(
        File(
          iconPath,
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    }
  });
  Widget page({
    Future<PerformanceData> Function(DateTime)? load,
    ValueChanged<int>? onNavigate,
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
    home: MyPerformancePage(
      initialMonth: DateTime(2026, 10),
      load: load ?? (_) async => PerformanceData.fromJson(performancePayload()),
      onNavigate: onNavigate,
    ),
  );

  testWidgets('real metrics, monthly comparison, tabs and chart switch', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('My Performance'), findsOneWidget);
    expect(find.text('18'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('Leads vs Conversions'), findsOneWidget);
    expect(find.text('Activity'), findsNothing);
    expect(find.byType(SessionWebView), findsNothing);
    await tester.tap(find.text('Attendance'));
    await tester.pumpAndSettle();
    final attendance = tester.widget<SessionWebView>(
      find.byType(SessionWebView),
    );
    expect(attendance.url, 'https://erp.homegeniegroup.in/GOAD');
    expect(attendance.embedded, isTrue);
    expect(find.text('Leads vs Conversions'), findsNothing);
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Show monthly trend'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Show monthly trend'));
    await tester.pumpAndSettle();
    final chart = tester.widget<PerformanceBarChart>(
      find.byType(PerformanceBarChart),
    );
    expect(chart.points.map((point) => point.label), ['Sep', 'Oct']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late month responses cannot replace the selected month', (
    tester,
  ) async {
    final requests = <String, Completer<PerformanceData>>{};
    await tester.pumpWidget(
      page(
        load: (month) {
          final key = '${month.year}-${month.month.toString().padLeft(2, '0')}';
          return (requests[key] = Completer<PerformanceData>()).future;
        },
      ),
    );
    await tester.tap(find.byTooltip('Previous month'));
    requests['2026-09']!.complete(
      PerformanceData.fromJson(
        performancePayload(month: '2026-09')..['sales']['leads'] = 7,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sep 2026'), findsOneWidget);
    expect(find.text('07'), findsOneWidget);
    requests['2026-10']!.complete(
      PerformanceData.fromJson(performancePayload()),
    );
    await tester.pumpAndSettle();
    expect(find.text('07'), findsOneWidget);
    expect(find.text('18'), findsNothing);
  });

  testWidgets('offline popup offers a successful user-triggered retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      page(
        load: (_) async {
          if (attempts++ == 0) {
            throw StateError(
              'SocketException: Failed host lookup: erp.private',
            );
          }
          return PerformanceData.fromJson(performancePayload());
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No internet connection'), findsOneWidget);
    expect(find.textContaining('erp.private'), findsNothing);
    expect(attempts, 1);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('18'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  for (final systemBack in [false, true]) {
    testWidgets('Back returns after visiting Attendance, system=$systemBack', (
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
                                (_) => MyPerformancePage(
                                  load:
                                      (_) async =>
                                          throw StateError('ERP unavailable'),
                                ),
                          ),
                        ),
                    child: const Text('Open performance'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Open performance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attendance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sales'));
      await tester.pumpAndSettle();
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('Back'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Open performance'), findsOneWidget);
      expect(find.byType(MyPerformancePage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed request shows retry; unavailable data is a dash', (
    tester,
  ) async {
    var fail = true;
    await tester.pumpWidget(
      page(
        load: (_) async {
          if (fail) throw StateError('ERP unavailable');
          final payload = performancePayload();
          payload['sales'] = Map<String, dynamic>.from(payload['sales'] as Map)
            ..['site_visits'] = null;
          return PerformanceData.fromJson(payload);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ERP unavailable'), findsOneWidget);
    expect(find.text('18'), findsNothing);
    fail = false;
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('reference layout fits a narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: page(onNavigate: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('render dashboard preview and verify bottom navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const captureKey = Key('preview');
    int? destination;
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: page(onNavigate: (index) => destination = index),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (Platform.environment['PERFORMANCE_PREVIEW'] == '1') {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/performance_preview').create(recursive: true);
        await File(
          'build/performance_preview/sales.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('Home'));
    expect(destination, 0);
  });
}
