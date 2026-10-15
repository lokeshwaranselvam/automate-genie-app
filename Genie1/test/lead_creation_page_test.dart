import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/lead_creation_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
          await tester.enterText(fields.at(2), 'Chennai');
          await tester.enterText(fields.at(3), 'New doors');
          final dropdowns = find.byType(DropdownButtonFormField<String>);
          await tester.tap(dropdowns.at(0));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Doors').last);
          await tester.pumpAndSettle();
          await tester.tap(dropdowns.at(1));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Website').last);
          await tester.pumpAndSettle();

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
          expect(submittedFields?['custom_source'], 'Website');
          expect(gets, 1);
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
