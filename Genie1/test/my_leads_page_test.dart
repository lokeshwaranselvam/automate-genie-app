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
