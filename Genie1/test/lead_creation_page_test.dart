import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/lead_creation_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    for (final entry
        in {
          'Roboto': 'C:/Windows/Fonts/arial.ttf',
          'MaterialIcons':
              'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        }.entries) {
      final file = File(entry.value);
      if (await file.exists()) {
        await (FontLoader(entry.key)
          ..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  testWidgets('searchable Lead form fits a narrow phone', (tester) async {
    SharedPreferences.setMockInitialValues({'session_sid': 'preview-session'});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    tester.view.physicalSize = const Size(360, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture = GlobalKey();
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: const MaterialApp(
              debugShowCheckedModeBanner: false,
              home: LeadCreationPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RawAutocomplete<String>), findsNWidgets(3));
        expect(
          find.text('Phone and WhatsApp numbers are the same'),
          findsOneWidget,
        );
        expect(
          find.text('Customer Category', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(
            'build/lead_creation_preview',
          ).create(recursive: true);
          await File(
            'build/lead_creation_preview/form.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'message': {
              'lead_owner': 'sales@example.test',
              'lead_owner_name': 'Sales',
              'source_options': ['Website', 'Referral'],
              'product_category_options': ['Doors', 'Windows'],
              'customer_category_options': ['B2B', 'B2C'],
              'csrf_token': 'preview-token',
            },
          }),
          200,
        ),
      ),
    );
  });

  testWidgets(
    'creates from the form and blocks duplicate submission and reload',
    (tester) async {
      SharedPreferences.setMockInitialValues({'session_sid': 'form-session'});
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = Completer<http.Response>();
      var posts = 0;
      var gets = 0;
      Map<String, String>? submittedFields;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: LeadCreationPage()));
          await tester.pumpAndSettle();
          final fields = find.byType(TextFormField);
          await tester.enterText(fields.at(0), 'Customer One');
          await tester.enterText(fields.at(1), '9876543210');
          await tester.enterText(fields.at(2), '+91 98765 43210');
          await tester.enterText(
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText == 'Chennai',
            ),
            'Chennai',
          );
          await tester.enterText(
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText ==
                      '200 KLD STP for residential project',
            ),
            'New doors',
          );
          expect(find.byIcon(Icons.search_rounded), findsNothing);
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextFormField>(fields.at(2)).controller!.text,
            '9876543210',
          );
          expect(
            tester
                .widget<TextField>(
                  find.descendant(
                    of: fields.at(2),
                    matching: find.byType(TextField),
                  ),
                )
                .readOnly,
            isTrue,
          );
          await tester.enterText(fields.at(1), '+91 98765 43211');
          expect(
            tester.widget<TextFormField>(fields.at(2)).controller!.text,
            '+91 98765 43211',
          );
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextFormField>(fields.at(2)).controller!.text,
            '+91 98765 43210',
          );
          expect(
            tester
                .widget<TextField>(
                  find.descendant(
                    of: fields.at(2),
                    matching: find.byType(TextField),
                  ),
                )
                .readOnly,
            isFalse,
          );
          expect(
            find.text('Product Enquired *', findRichText: true),
            findsOneWidget,
          );
          expect(find.text('Product Category'), findsNothing);
          Finder choice(String name) => find.descendant(
            of: find.byKey(ValueKey(name)),
            matching: find.byType(TextFormField),
          );
          await tester.enterText(
            choice('custom_product_enquired'),
            'invalid product',
          );
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
          await tester.pumpAndSettle();
          expect(posts, 0);
          expect(
            find.text('Choose Product Enquired from the configured options.'),
            findsOneWidget,
          );
          await tester.enterText(choice('custom_product_enquired'), 'doo');
          await tester.pumpAndSettle();
          await tester.tap(find.text('Doors').last);
          await tester.pumpAndSettle();
          await tester.enterText(choice('source'), 'web');
          await tester.pumpAndSettle();
          await tester.tap(find.text('Website').last);
          await tester.pumpAndSettle();
          await tester.enterText(choice('custom_customer_category'), 'b2b');
          await tester.pumpAndSettle();
          expect(find.text('B2C'), findsNothing);
          await tester.tap(find.text('B2B').last);
          await tester.pumpAndSettle();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh();
          await tester.pumpAndSettle();
          expect(find.text('Customer One'), findsOneWidget);
          expect(
            tester
                .widget<TextFormField>(choice('custom_product_enquired'))
                .controller!
                .text,
            'Doors',
          );
          expect(
            tester.widget<TextFormField>(choice('source')).controller!.text,
            'Website',
          );
          expect(
            tester
                .widget<TextFormField>(choice('custom_customer_category'))
                .controller!
                .text,
            'B2B',
          );

          final button = tester.widget<FilledButton>(find.byType(FilledButton));
          button.onPressed!();
          button.onPressed!();
          await tester.pump();
          await tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh();
          await tester.pump();
          expect(posts, 1);
          expect(submittedFields?['first_name'], 'Customer One');
          expect(submittedFields?['custom_product_enquired'], 'Doors');
          expect(submittedFields?['source'], 'Website');
          expect(submittedFields?['custom_customer_category'], 'B2B');
          expect(submittedFields?['whatsapp_no'], '+919876543210');
          expect(gets, 2);
          pending.complete(
            http.Response(
              jsonEncode({
                'message': {'status': 'success', 'name': 'LEAD-1'},
              }),
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Lead created successfully!'), findsOneWidget);
          expect(find.text('Customer One'), findsNothing);
          expect(
            tester.widget<TextFormField>(fields.at(2)).controller!.text,
            isEmpty,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            submittedFields = request.bodyFields;
            return pending.future;
          }
          if (request.url.path != '/api/method/create_lead_from_mobile') {
            return http.Response('', 404);
          }
          gets++;
          return http.Response(
            jsonEncode({
              'message': {
                'lead_owner': 'sales@example.test',
                'lead_owner_name': 'Sales',
                'source_options': ['Website'],
                'product_category_options': ['Doors'],
                'customer_category_options': ['B2B', 'B2C'],
                'csrf_token': 'form-token',
              },
            }),
            200,
          );
        }),
      );
    },
  );
}
