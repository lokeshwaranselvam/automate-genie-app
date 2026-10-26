import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/site_visit_report_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final canEdit in [true, false]) {
    testWidgets(
      'API outcomes and can_edit_report=$canEdit control submitted report',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'session_sid': 'sid',
          'session_username': 'user@example.test',
          'token': 'token test',
          'name': 'Test User',
        });
        dotenv.testLoad(
          fileInput:
              'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/example.api',
        );
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              const MaterialApp(
                home: SiteVisitReportPage(
                  visit: {'name': 'EVENT-1', 'subject': 'Test Visit'},
                ),
              ),
            );
            await tester.pumpAndSettle();
            final field = tester.widget<TextField>(
              find.byType(TextField).first,
            );
            expect(field.enabled, canEdit);
            await tester.scrollUntilVisible(
              find.byType(DropdownButtonFormField<String>),
              150,
            scrollable: find.byType(Scrollable).first,
            );
            final dropdown = tester.widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            );
            expect(dropdown.onChanged != null, canEdit);
            if (!canEdit) {
              await tester.scrollUntilVisible(
                find.text('Report submitted. Editing is locked.'),
                100,
              scrollable: find.byType(Scrollable).first,
              );
            }
            expect(
              find.text('Report submitted. Editing is locked.'),
              canEdit ? findsNothing : findsOneWidget,
            );
            if (canEdit) {
              await tester.ensureVisible(
                find.byType(DropdownButtonFormField<String>),
              );
              await tester.tap(find.byType(DropdownButtonFormField<String>));
              await tester.pumpAndSettle();
              expect(find.text('Booked'), findsOneWidget);
              expect(find.text('Interested'), findsNothing);
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
          () => MockClient((request) async {
            if (request.url.path.endsWith('event_visit_report')) {
              return http.Response(
                jsonEncode({
                  'message': {
                    'status': 'success',
                    'observation': 'Visited',
                    'outcome': 'Needs Quote',
                    'outcomes': ['Needs Quote', 'Booked'],
                    'is_submitted': true,
                    'can_edit_report': canEdit,
                    'description':
                        'observation : Visited\nOutcome: Needs Quote',
                  },
                }),
                200,
              );
            }
            return http.Response('{"data":[],"message":{}}', 200);
          }),
        );
      },
    );
  }
}
