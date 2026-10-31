import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:homegenie/utils/widget/crm_document_details.dart';
import 'package:homegenie/utils/widget/opportunity_owner_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const document = {
  'name': 'OPP-1',
  'customer_name': 'Customer One',
  'status': 'Open',
  'opportunity_owner': 'sales@example.test',
  'modified': '2026-10-31 12:00:00',
};

void main() {
  setUpAll(() async {
    final icons = File(
      'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      await (FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
    }
    final font = File('C:/Windows/Fonts/arial.ttf');
    if (await font.exists()) {
      await (FontLoader('OwnerPreview')
        ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  testWidgets(
    'owner pencil opens searchable picker and saves only the owner once',
    (tester) async {
      SharedPreferences.setMockInitialValues({'session_sid': 'sid'});
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      tester.view.physicalSize = const Size(393, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final pending = Completer<http.Response>();
      var writes = 0;
      final searches = <String>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  useMaterial3: true,
                  fontFamily: 'OwnerPreview',
                ),
                home: Builder(
                  builder:
                      (context) => Scaffold(
                        appBar: brandAppBar(
                          title: const Text('Opportunity Details'),
                        ),
                        backgroundColor: CrmDocumentDetails.background,
                        body: CrmDocumentDetails(
                          document: document,
                          documentType: 'Opportunity',
                          onEditOpportunityOwner:
                              () => showDialog<bool>(
                                context: context,
                                builder:
                                    (_) => const OpportunityOwnerDialog(
                                      document: document,
                                    ),
                              ),
                        ),
                      ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Edit Opportunity Owner'));
          await tester.pumpAndSettle();
          expect(find.text('Next Sales User'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
                .onPressed,
            isNull,
          );
          await tester.enterText(find.byType(TextField), 'next');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(searches.last, 'next');
          await tester.tap(find.text('Next Sales User'));
          await tester.pumpAndSettle();
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
              'build/details_preview/opportunity_owner.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
          final save =
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Save'),
                  )
                  .onPressed!;
          save();
          save();
          await tester.pump();
          expect(writes, 1);
          pending.complete(
            http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  'current_user': 'sales@example.test',
                  'name': 'OPP-1',
                  'opportunity_owner': 'next@example.test',
                },
              }),
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(OpportunityOwnerDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response('{"message":"sales@example.test"}', 200);
          }
          if (request.url.path == '/app')
            return http.Response('frappe.csrf_token = "csrf";', 200);
          if (request.method == 'POST') {
            writes++;
            expectSync(request.headers['X-Frappe-CSRF-Token'], 'csrf');
            expectSync(jsonDecode(request.body), {
              'action': 'change_owner',
              'name': 'OPP-1',
              'new_owner': 'next@example.test',
              'modified': document['modified'],
              'csrf_token': 'csrf',
            });
            return pending.future;
          }
          expectSync(request.url.queryParameters['action'], 'owner_options');
          searches.add(request.url.queryParameters['txt']!);
          return http.Response(
            jsonEncode({
              'message': {
                'current_user': 'sales@example.test',
                'options': [
                  {'value': 'next@example.test', 'label': 'Next Sales User'},
                ],
              },
            }),
            200,
          );
        }),
      );
    },
  );
}
