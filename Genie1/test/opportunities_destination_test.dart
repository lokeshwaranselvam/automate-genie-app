import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/home_dashboard_view.dart';
import 'package:homegenie/Screen/lead_creation_page.dart';
import 'package:homegenie/Screen/my_opportunities_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    for (final entry
        in {
          'OpportunitiesPreview': 'C:/Windows/Fonts/arial.ttf',
          'MaterialIcons':
              'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        }.entries) {
      final font = File(entry.value);
      if (await font.exists()) {
        await (FontLoader(entry.key)
          ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  testWidgets(
    'Opportunities replaces the sections and opens the existing New Lead form',
    (tester) async {
      SharedPreferences.setMockInitialValues({'session_sid': 'sid'});
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      tester.view.physicalSize = const Size(393, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var loads = 0;
      final capture = GlobalKey();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  useMaterial3: true,
                  fontFamily: 'OpportunitiesPreview',
                ),
                home: Scaffold(
                  body: const MyOpportunitiesPage(canCreateLead: true),
                  bottomNavigationBar: HomeNavigationBar(
                    currentIndex: 3,
                    onTap: (_) {},
                    showLeads: true,
                    showVisits: true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Opportunities'), findsNWidgets(2));
          expect(find.text('My Leads'), findsNothing);
          expect(find.byType(TabBar), findsNothing);
          expect(find.text('New Lead'), findsOneWidget);
          expect(find.text('Customer One'), findsOneWidget);
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await boundary.toImage(pixelRatio: 2);
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('build/details_preview').create(recursive: true);
            await File(
              'build/details_preview/opportunities_destination.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
          await tester.tap(find.text('New Lead'));
          await tester.pumpAndSettle();
          expect(find.byType(LeadCreationPage), findsOneWidget);
          expect(find.widgetWithText(AppBar, 'Create Lead'), findsOneWidget);
          tester.state<NavigatorState>(find.byType(Navigator)).pop();
          await tester.pumpAndSettle();
          expect(find.text('Customer One'), findsOneWidget);
          expect(loads, 2);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response('{"message":"sales@example.test"}', 200);
          }
          if (request.url.path == '/api/resource/Opportunity') {
            loads++;
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'name': 'ROC-OPP-2026-00477',
                    'customer_name': 'Customer One',
                    'owner': 'creator@example.test',
                    'opportunity_owner': 'sales@example.test',
                    'status': 'Follow-up',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'message': {
                'lead_owner': 'sales@example.test',
                'lead_owner_name': 'Sales',
                'source_options': ['Website'],
                'product_category_options': ['Doors'],
                'customer_category_options': ['B2B'],
                'csrf_token': 'token',
                'location_fields': {
                  'custom_citytown': {
                    'fieldtype': 'Select',
                    'options': ['Chennai'],
                  },
                  'custom_district': {
                    'fieldtype': 'Select',
                    'options': ['Chennai - TN'],
                  },
                },
              },
            }),
            200,
          );
        }),
      );
    },
  );

  testWidgets('New Lead stays hidden without creation access', (tester) async {
    SharedPreferences.setMockInitialValues({'session_sid': 'sid'});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: MyOpportunitiesPage()));
        await tester.pumpAndSettle();
        expect(find.text('New Lead'), findsNothing);
      },
      () => MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('get_logged_user')
              ? '{"message":"sales@example.test"}'
              : '{"data":[]}',
          200,
        ),
      ),
    );
  });
}
