import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/lead_details_page.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:homegenie/utils/widget/crm_document_details.dart';

const fixture = <String, dynamic>{
  'name': 'CRM-OPP-2026-32105',
  'status': 'Open',
  'owner': 'lokeshwaran.trainee@homegeniegroups.com',
  'creation': '2026-10-16 11:19:14.962389',
  'modified': '2026-10-16 11:19:14.962389',
  'modified_by': 'lokeshwaran.trainee@homegeniegroups.com',
  'docstatus': 0,
  'naming_series': 'CRM-OPP-.YYYY.-',
  'opportunity_from': 'Lead',
  'party_name': 'CRM-LEAD-2026-5559',
  'custom_requirement': 'Office doors',
  'custom_extra_detail': 'Real custom value',
  'items': [
    {'item_code': 'DOOR-1', 'qty': 2},
  ],
};

Widget screen(String type, {GlobalKey? previewKey, double scale = 1}) {
  final doc = {...fixture};
  if (type == 'Lead') {
    doc.addAll({
      'name': 'CRM-LEAD-2026-5559',
      'naming_series': 'CRM-LEAD-.YYYY.-',
      'lead_name': 'Customer One',
      'mobile_no': '9876543210',
    });
    doc.remove('opportunity_from');
    doc.remove('party_name');
  }
  return RepaintBoundary(
    key: previewKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: 'DetailsPreview'),
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
      home:
          type == 'Lead'
              ? LeadDetailsPage(lead: doc)
              : Scaffold(
                backgroundColor: CrmDocumentDetails.background,
                appBar: brandAppBar(
                  leading: const Icon(Icons.arrow_back_rounded),
                  title: const Text(
                    'Opportunity Details',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  actions: const [
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Icon(Icons.more_vert, color: Colors.white),
                    ),
                  ],
                ),
                body: CrmDocumentDetails(document: doc, documentType: type),
              ),
    ),
  );
}

void main() {
  testWidgets('WhatsApp displays a chat icon without a call action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrmDocumentDetails(
            document: const {'name': 'OPP-1', 'whatsapp_no': '9876543210'},
            documentType: 'Opportunity',
            onCallContact: (_) => fail('WhatsApp must not initiate a call'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.call_rounded), findsNothing);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    expect(find.text('9876543210'), findsOneWidget);
  });
  testWidgets('Opportunity contact call button passes the displayed number', (
    tester,
  ) async {
    String? calledNumber;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrmDocumentDetails(
            document: const {'name': 'OPP-1', 'contact_mobile': '9876543210'},
            documentType: 'Opportunity',
            onCallContact: (number) => calledNumber = number,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Call 9876543210'));
    expect(calledNumber, '9876543210');
  });

  testWidgets('contact call button is disabled while a call is starting', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrmDocumentDetails(
            document: const {'name': 'OPP-1', 'contact_mobile': '9876543210'},
            documentType: 'Opportunity',
            callInProgress: true,
            onCallContact: (_) => fail('Call must not be submitted twice'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Call 9876543210',
            ),
          )
          .onPressed,
      isNull,
    );
  });
  setUpAll(() async {
    for (final entry
        in {
          'DetailsPreview': 'C:/Windows/Fonts/arial.ttf',
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

  for (final type in ['Opportunity', 'Lead']) {
    for (final width in [320.0, 393.0, 600.0]) {
      testWidgets('$type details remain readable at width $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        await tester.pumpWidget(
          screen(type, previewKey: key, scale: width == 320 ? 1.5 : 1),
        );
        await tester.pumpAndSettle();
        expect(find.text('$type Details'), findsOneWidget);
        expect(find.text('${type.toUpperCase()} ID'), findsOneWidget);
        expect(find.text('Audit Information'), findsOneWidget);
        expect(find.text('Created By'), findsOneWidget);
        expect(tester.takeException(), isNull);

        if (width == 393) {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('build/details_preview').create(recursive: true);
            await File(
              'build/details_preview/${type.toLowerCase()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.tap(find.text('Audit Information'));
        await tester.pumpAndSettle();
        expect(find.text('Created By'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Document Information'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Naming Series'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('$type Information'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Office doors'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Real custom value'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Real custom value'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
