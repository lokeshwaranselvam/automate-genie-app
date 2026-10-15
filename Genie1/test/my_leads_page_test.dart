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
        expect(find.byType(Scrollable), findsOneWidget);
        final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
        final initialTop = tester.getTopLeft(find.text('Customer 0')).dy;
        final pull = await tester.startGesture(const Offset(150, 200));
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
      SharedPreferences.setMockInitialValues({'session_sid': 'test-session'});
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
          expect(find.text('Doors'), findsOneWidget);
          expect(find.text('Chennai'), findsOneWidget);
          expect(find.text('WhatsApp Number'), findsOneWidget);
          expect(find.text('+919876543210'), findsOneWidget);
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
                'csrf_token': 'csrf-test',
              },
            }),
            200,
          );
        }),
      );
    },
  );
}
