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
  for (final type in ['Lead', 'Opportunity']) {
    testWidgets('$type status pill appears below its ID at narrow width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CrmDocumentDetails(
              documentType: type,
              document: const {'name': 'DOC-1', 'status': 'Opportunity'},
              onOpenOpportunity: type == 'Lead' ? () => tapped = true : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final id = find.text('DOC-1');
      final chip = find.byType(RawChip);
      expect(
        tester.getTopLeft(chip).dy,
        greaterThan(tester.getBottomLeft(id).dy),
      );
      expect(find.text('Opportunity'), findsOneWidget);
      if (type == 'Lead') {
        await tester.tap(chip);
        expect(tapped, isTrue);
      } else {
        expect(tester.widget<RawChip>(chip).onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final dated in [true, false]) {
    for (final type in ['Opportunity', 'Lead']) {
      testWidgets(
        '$type notes ${dated ? 'sort by date' : 'use row order'} without changing saved rows',
        (tester) async {
          tester.view.physicalSize = const Size(600, 4000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final notes = [
            for (final day in [2, 5, 1, 4, 3])
              {
                'note': 'Note day $day',
                'name': 'NOTE-ROW-$day',
                'owner': 'note-author@example.test',
                if (dated && day != 4)
                  'added_on':
                      '2026-10-${day.toString().padLeft(2, '0')} 10:00:00',
                if (dated && day == 4) 'creation': '2026-10-04 10:00:00',
              },
          ];
          final snapshot =
              notes.map((row) => Map<String, String>.from(row)).toList();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: CrmDocumentDetails(
                  documentType: type,
                  document: {'name': 'DOC-1', 'notes': notes},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final visible =
              type == 'Lead'
                  ? [2, 5, 1, 4, 3]
                  : dated
                  ? [5, 4, 3]
                  : [3, 4, 1];
          if (type == 'Lead') {
            for (var i = 1; i <= visible.length; i++) {
              await tester.tap(find.text('Row $i'));
              await tester.pumpAndSettle();
            }
          } else {
            for (var i = 1; i <= 3; i++) {
              expect(find.text('Note $i'), findsOneWidget);
              expect(find.text('Row $i'), findsNothing);
            }
            expect(find.text('note-author@example.test'), findsNothing);
            for (var day = 1; day <= 5; day++) {
              expect(find.text('NOTE-ROW-$day'), findsNothing);
            }
          }
          for (var day = 1; day <= 5; day++) {
            expect(
              find.text('Note day $day'),
              visible.contains(day) ? findsOneWidget : findsNothing,
            );
          }
          final rendered =
              tester
                  .widgetList<SelectableText>(find.byType(SelectableText))
                  .map((widget) => widget.data)
                  .where((text) => text?.startsWith('Note day') == true)
                  .toList();
          expect(rendered, visible.map((day) => 'Note day $day').toList());
          expect(notes, snapshot);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Opportunity audit and additional sections show only requested fields',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CrmDocumentDetails(
              documentType: 'Opportunity',
              creatorFullName: 'Arun Digital',
              document: const {
                'name': 'OPP-1',
                'owner': 'arun@example.test',
                'creation': '2026-08-18',
                'modified': '2026-10-21',
                'modified_by': 'editor@example.test',
                'custom_next_followup_date': '2026-10-25',
                'custom_customer_type': 'Consumer',
                'custom_citytown': 'Chennai',
                'custom_district': 'Chennai - TN',
                'transaction_date': '2026-08-18',
                'language': 'en',
                'approve': 0,
                'custom_agent_status': 'Not Sent',
                'custom_extra_detail': 'Hidden additional value',
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Arun Digital'), findsOneWidget);
      expect(find.text('arun@example.test'), findsNothing);
      for (final label in [
        'Creation',
        'Modified',
        'Modified By',
        'Transaction Date',
        'Language',
        'Approve',
        'Agent Status',
        'Hidden additional value',
      ]) {
        expect(find.text(label), findsNothing);
      }
      final opportunitySection = find.ancestor(
        of: find.text('2026-10-25'),
        matching: find.byType(ExpansionTile),
      );
      expect(
        (tester.widget<ExpansionTile>(opportunitySection).title as Text).data,
        'Opportunity Information',
      );
      for (final value in ['Consumer', 'Chennai', 'Chennai - TN']) {
        final section = find.ancestor(
          of: find.text(value),
          matching: find.byType(ExpansionTile),
        );
        expect(
          (tester.widget<ExpansionTile>(section).title as Text).data,
          'Additional Information',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final type in ['Opportunity', 'Lead']) {
    testWidgets('$type keeps the requested Value & Company fields', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CrmDocumentDetails(
              documentType: type,
              document: const {
                'name': 'DOC-1',
                'company': 'Test Company',
                'currency': 'INR',
                'conversion_rate': 1,
                'opportunity_amount': 100,
                'base_opportunity_amount': 100,
                'base_total': 100,
                'total': 100,
                'annual_revenue': 100,
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test Company'), findsOneWidget);
      expect(find.text('INR'), findsOneWidget);
      for (final label in [
        'Conversion Rate',
        'Opportunity Amount',
        'Base Opportunity Amount',
        'Base Total',
        'Total',
        'Annual Revenue',
      ]) {
        expect(
          find.text(label),
          type == 'Opportunity' ? findsNothing : findsOneWidget,
        );
      }
    });
  }
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
  for (final width in [320.0, 393.0]) {
    testWidgets(
      'Opportunity note author and time appear on the right at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                useMaterial3: true,
                fontFamily: 'DetailsPreview',
              ),
              builder:
                  (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(width == 320 ? 1.5 : 1),
                    ),
                    child: child!,
                  ),
              home: Scaffold(
                backgroundColor: CrmDocumentDetails.background,
                appBar: brandAppBar(title: const Text('Opportunity Details')),
                body: const CrmDocumentDetails(
                  documentType: 'Opportunity',
                  document: {
                    'name': 'ROC-OPP-2026-00477',
                    'status': 'Follow-up',
                    'customer_name': 'Customer One',
                    'notes': [
                      {
                        'note': '<p>Customer requested a follow-up call.</p>',
                        'added_by': 'sales@example.test',
                        'added_on': '2026-10-31 12:37:00',
                      },
                      {'note': '<p>Older note without audit details.</p>'},
                    ],
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('sales@example.test'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('31 Oct 2026, 12:37 PM'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('sales@example.test')).dx,
          greaterThan(
            tester
                .getTopLeft(find.text('Customer requested a follow-up call.'))
                .dx,
          ),
        );
        expect(find.text('Author unavailable'), findsOneWidget);
        expect(find.text('Time unavailable'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (width == 393) {
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
              'build/details_preview/opportunity_note_audit.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }
      },
    );
  }

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
        expect(find.text('Document Information'), findsNothing);
        expect(find.text('Naming Series'), findsNothing);
        expect(find.text('Creation'), findsNothing);
        expect(find.text('Modified By'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('$type Information'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Office doors'), findsOneWidget);
        if (type == 'Lead') {
          await tester.scrollUntilVisible(
            find.text('Real custom value'),
            180,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Real custom value'), findsOneWidget);
        } else {
          expect(find.text('Real custom value'), findsNothing);
          expect(find.text('Creation'), findsNothing);
          expect(find.text('Modified By'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
