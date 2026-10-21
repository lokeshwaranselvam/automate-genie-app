import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/site_visits_page.dart';
import 'package:homegenie/utils/site_visit_distance.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/arial.ttf');
    if (await font.exists()) {
      await (FontLoader('VisitPreview')
        ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  test(
    'recorded metric distances retain units and missing values stay unknown',
    () {
      expect(SiteVisitDistance.meters('1.25 km'), 1250);
      expect(SiteVisitDistance.meters(' 500 M '), 500);
      expect(SiteVisitDistance.meters('1,250.5 m'), 1250.5);
      expect(SiteVisitDistance.meters('0 km'), 0);
      for (final value in [
        null,
        '',
        'Not recorded',
        'NaN km',
        '-5 m',
        '12',
        12,
        '5 miles',
        '1.2.3 km',
        '1,2 km',
      ]) {
        expect(SiteVisitDistance.meters(value), isNull);
      }
      expect(SiteVisitDistance.format(500), '500.00 m');
      expect(SiteVisitDistance.format(1250), '1.25 km');
    },
  );

  for (final width in [320.0, 393.0]) {
    testWidgets(
      'total and per-visit distances remain correct across tabs and filters at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'email': 'sales@example.test',
          'token': 'test-token',
          'session_username': 'sales@example.test',
          'session_sid': 'test-session',
        });
        dotenv.testLoad(
          fileInput:
              'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/hrms.api',
        );
        final date =
            DateTime.now().add(const Duration(days: 1)).toIso8601String();
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(fontFamily: 'VisitPreview'),
                builder:
                    (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(width == 320 ? 1.3 : 1),
                      ),
                      child: child!,
                    ),
                home: const SiteVisitsPage(),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('Total travelled'), findsOneWidget);
            expect(find.text('1.75 km'), findsOneWidget);
            expect(find.text('Travelled: 1.25 km'), findsOneWidget);
            expect(find.text('Travelled: Not recorded'), findsOneWidget);
            expect(
              tester.getTopLeft(find.text('Travelled: 1.25 km')).dy,
              greaterThanOrEqualTo(
                tester
                    .getBottomLeft(
                      find.widgetWithText(TextButton, 'Navigate').first,
                    )
                    .dy,
              ),
            );
            await tester.enterText(find.byType(TextField), 'Scheduled One');
            await tester.pumpAndSettle();
            expect(find.text('1.75 km'), findsOneWidget);
            expect(find.text('Travelled: Not recorded'), findsNothing);
            await tester.enterText(find.byType(TextField), '');
            await tester.tap(find.text('Completed (1)'));
            await tester.pumpAndSettle();
            expect(find.text('Travelled: 500.00 m'), findsOneWidget);
            expect(find.text('1.75 km'), findsOneWidget);
            expect(find.text('Travelled: 99.00 km'), findsNothing);
            expect(find.text('Navigate'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          () => MockClient((request) async {
            if (request.url.queryParameters['action'] == 'can_create') {
              return http.Response(
                jsonEncode({
                  'message': {
                    'status': 'success',
                    'current_user': 'sales@example.test',
                    'can_create': false,
                  },
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/ping')) {
              return http.Response('{"message":"pong"}', 200);
            }
            if (request.url.path.endsWith('.event_list')) {
              return http.Response(
                jsonEncode({
                  'message': [
                    {
                      'name': 'S1',
                      'subject': 'Scheduled One',
                      'starts_on': date,
                      'custom_location': 'Chennai',
                      'custom_distance': '1.25 km',
                    },
                    {
                      'name': 'S2',
                      'subject': 'Scheduled Two',
                      'starts_on': date,
                      'custom_location': 'Chennai',
                    },
                    {
                      'name': 'D1',
                      'subject': 'Completed One',
                      'starts_on': date,
                      'custom_distance': '99 km',
                    },
                  ],
                }),
                200,
              );
            }
            expect(request.url.path, endsWith('.history_list'));
            return http.Response(
              jsonEncode({
                'message': [
                  {
                    'name': 'D1',
                    'subject': 'Completed One',
                    'starts_on': date,
                    'custom_distance': '500 m',
                  },
                ],
              }),
              200,
            );
          }),
        );
      },
    );
  }
}
