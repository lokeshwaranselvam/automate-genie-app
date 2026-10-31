import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/lead_creation_page.dart';
import 'package:homegenie/Screen/my_leads_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'phone and exact Lead status filters combine and clear without refetching',
    (tester) async {
      SharedPreferences.setMockInitialValues({'session_sid': 'filter-session'});
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      var loads = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: MyLeadsPage()));
          await tester.pumpAndSettle();
          expect(find.text('My Opportunities'), findsNothing);
          await tester.enterText(find.byType(TextField), '98765');
          await tester.pumpAndSettle();
          expect(find.text('Customer A'), findsOneWidget);
          expect(find.text('Customer B'), findsOneWidget);
          expect(find.text('Customer C'), findsNothing);
          await tester.tap(find.text('Status: All'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widgetList<SimpleDialogOption>(find.byType(SimpleDialogOption))
                .map((option) => (option.child! as Text).data)
                .toList(),
            [
              'Open',
              'Lead',
              'Junk',
              'Followup',
              'RNR',
              'Hot Followup',
              'Not Interested',
              'Duplicate Lead',
            ],
          );
          await tester.tap(find.widgetWithText(SimpleDialogOption, 'Junk'));
          await tester.pumpAndSettle();
          expect(find.text('Customer A'), findsNothing);
          expect(find.text('Customer B'), findsOneWidget);
          await tester.enterText(find.byType(TextField), '00000');
          await tester.pumpAndSettle();
          expect(
            find.text('No leads match the selected filters.'),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('Clear phone search'));
          await tester.pumpAndSettle();
          expect(find.text('Customer B'), findsOneWidget);
          expect(find.text('Customer A'), findsNothing);
          await tester.tap(find.text('Status: Junk'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Clear filter'));
          await tester.pumpAndSettle();
          expect(find.text('Customer A'), findsOneWidget);
          expect(find.text('Customer B'), findsOneWidget);
          expect(find.text('Customer C'), findsOneWidget);
          expect(loads, 1);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient((request) async {
          expect(request.url.queryParameters, {'view': 'list'});
          loads++;
          return http.Response(
            jsonEncode({
              'message': {
                'leads': [
                  {
                    'name': 'A',
                    'lead_name': 'Customer A',
                    'mobile_no': '+91 (98765) 43210',
                    'status': 'Lead',
                  },
                  {
                    'name': 'B',
                    'lead_name': 'Customer B',
                    'phone': '+91-98765-11111',
                    'status': 'Junk',
                  },
                  {
                    'name': 'C',
                    'lead_name': 'Customer C',
                    'mobile_no': '1234567890',
                    'whatsapp_no': '9876543210',
                    'status': 'Lead',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
    },
  );
  testWidgets('lead content stays bounded while pulling at either list edge', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'session_sid': 'scroll-session'});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    var loads = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: MyLeadsPage()));
        await tester.pumpAndSettle();
        final listScrollable = find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        );
        expect(listScrollable, findsOneWidget);
        final scroll = tester.state<ScrollableState>(listScrollable);
        final initialTop = tester.getTopLeft(find.text('Customer 0')).dy;
        final pull = await tester.startGesture(const Offset(150, 320));
        await pull.moveBy(const Offset(0, 40));
        await tester.pump();
        await pull.moveBy(const Offset(0, 450));
        await tester.pump();
        expect(scroll.position.pixels, 0);
        expect(tester.getTopLeft(find.text('Customer 0')).dy, initialTop);
        await pull.up();
        await tester.pumpAndSettle();
        expect(loads, 2); // Pull-to-refresh still fetches the lead list.
        await tester.fling(find.byType(ListView), const Offset(0, -4000), 6000);
        await tester.pumpAndSettle();
        final bottom = scroll.position.maxScrollExtent;
        expect(scroll.position.pixels, closeTo(bottom, 0.01));
        final bottomPull = await tester.startGesture(const Offset(150, 400));
        await bottomPull.moveBy(const Offset(0, -250));
        await tester.pump();
        expect(scroll.position.pixels, closeTo(bottom, 0.01));
        await bottomPull.up();
        await tester.pumpAndSettle();
        expect(loads, 2);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        expect(request.url.queryParameters['view'], 'list');
        loads++;
        return http.Response(
          jsonEncode({
            'message': {
              'leads': List.generate(
                25,
                (i) => {
                  'name': 'LEAD-$i',
                  'first_name': 'Customer $i',
                  'mobile_no': '9876543210',
                },
              ),
            },
          }),
          200,
        );
      }),
    );
  });

  testWidgets(
    'Lead list opens details and existing creation form, then reloads',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_sid': 'test-session',
        'session_username': 'sales@example.test',
        'session_full_name': 'Sales User',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      var listCalls = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: MyLeadsPage()));
          await tester.pumpAndSettle();
          expect(find.text('New Lead'), findsOneWidget);
          expect(find.text('Customer One'), findsOneWidget);
          await tester.tap(find.text('Customer One'));
          await tester.pumpAndSettle();
          expect(find.text('Lead Details'), findsOneWidget);
          expect(find.text('Sales User'), findsOneWidget);
          expect(find.text('sales@example.test'), findsNothing);
          expect(find.text('Document Information'), findsNothing);
          expect(find.text('Creation'), findsNothing);
          expect(find.text('Modified By'), findsNothing);
          expect(find.text('Doors'), findsOneWidget);
          expect(find.text('WhatsApp Number'), findsOneWidget);
          expect(find.text('+919876543210'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Chennai'),
            100,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Chennai'), findsOneWidget);
          await tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh();
          await tester.pumpAndSettle();
          expect(find.text('Updated Customer'), findsOneWidget);
          await tester.tap(find.byTooltip('Back'));
          await tester.pumpAndSettle();
          expect(find.text('My Leads'), findsOneWidget);
          await tester.tap(find.text('New Lead'));
          await tester.pumpAndSettle();
          expect(find.byType(LeadCreationPage), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('My Leads'), findsOneWidget);
          expect(listCalls, 2);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          expect(request.url.path, '/api/method/create_lead_from_mobile');
          expect(request.method, 'GET');
          expect(request.headers['cookie'], 'sid=test-session');
          if (request.url.queryParameters['view'] == 'detail') {
            expect(request.url.queryParameters['lead'], 'LEAD-1');
            return http.Response(
              jsonEncode({
                'message': {
                  'lead': {'name': 'LEAD-1', 'first_name': 'Updated Customer'},
                },
              }),
              200,
            );
          }
          if (request.url.queryParameters['view'] == 'list') {
            listCalls++;
            return http.Response(
              jsonEncode({
                'message': {
                  'leads': [
                    {
                      'name': 'LEAD-1',
                      'owner': 'sales@example.test',
                      'creation': '2026-10-21',
                      'modified_by': 'sales@example.test',
                      'docstatus': 0,
                      'naming_series': 'CRM-LEAD-.YYYY.-',
                      'first_name': 'Customer One',
                      'mobile_no': '9876543210',
                      'whatsapp_no': '+919876543210',
                      'custom_requirement': 'Doors',
                      'custom_address': 'Chennai',
                    },
                  ],
                },
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
                'customer_category_options': ['B2B', 'B2C'],
                'location_fields': {
                  'custom_citytown': {
                    'fieldtype': 'Select',
                    'options': ['Chennai', 'Madurai'],
                  },
                  'custom_district': {
                    'fieldtype': 'Select',
                    'options': ['Chennai - TN', 'Madurai - TN'],
                  },
                },
                'csrf_token': 'csrf-test',
              },
            }),
            200,
          );
        }),
      );
    },
  );
  testWidgets(
    'second section opens Opportunities lazily and preserves Leads filters',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_sid': 'sections-session',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      var leadLoads = 0;
      var opportunityLoads = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(home: MyLeadsPage(showOpportunities: true)),
          );
          await tester.pumpAndSettle();
          expect(find.byType(TabBar), findsOneWidget);
          expect(find.text('My Opportunities'), findsOneWidget);
          expect(opportunityLoads, 0);
          await tester.enterText(find.byType(TextField), '98765');
          await tester.pumpAndSettle();
          await tester.tap(find.text('My Opportunities'));
          await tester.pumpAndSettle();
          expect(opportunityLoads, 1);
          expect(find.text('New Lead'), findsNothing);
          expect(find.byType(AppBar), findsOneWidget);
          await tester.tap(find.widgetWithText(Tab, 'My Leads'));
          await tester.pumpAndSettle();
          expect(find.text('98765'), findsOneWidget);
          expect(find.text('New Lead'), findsOneWidget);
          expect(leadLoads, 1);
          await tester.tap(find.text('My Opportunities'));
          await tester.pumpAndSettle();
          expect(opportunityLoads, 1);
          await tester.pumpWidget(const MaterialApp(home: MyLeadsPage()));
          await tester.pumpAndSettle();
          expect(find.text('My Opportunities'), findsNothing);
          expect(find.text('98765'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response('{"message":"sales@example.test"}', 200);
          }
          if (request.url.path == '/api/resource/Opportunity') {
            opportunityLoads++;
            return http.Response('{"data":[]}', 200);
          }
          if (request.url.path == '/api/method/create_lead_from_mobile') {
            leadLoads++;
            return http.Response('{"message":{"leads":[]}}', 200);
          }
          return http.Response('', 404);
        }),
      );
    },
  );
}
