import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/lead_details_page.dart';
import 'package:homegenie/Screen/opportunity_details_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const user = 'linked@example.test';
  var session = 0;
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'linked-${++session}',
      'session_username': user,
    });
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final count in [0, 1, 2]) {
    testWidgets('Lead Opportunity pill handles $count linked records', (
      tester,
    ) async {
      final detailRequests = <String>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: LeadDetailsPage(
                lead: const {'name': 'LEAD-1', 'status': 'Opportunity'},
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byType(RawChip));
          await tester.pumpAndSettle();
          if (count == 0) {
            expect(
              find.text('No linked Opportunity is available for your account.'),
              findsOneWidget,
            );
            expect(find.byType(OpportunityDetailsPage), findsNothing);
          } else {
            if (count == 2) {
              expect(find.text('Choose Opportunity'), findsOneWidget);
              await tester.tap(find.text('OPP-2'));
              await tester.pumpAndSettle();
            }
            final details = tester.widget<OpportunityDetailsPage>(
              find.byType(OpportunityDetailsPage),
            );
            expect(details.opportunityId, 'OPP-$count');
            expect(detailRequests, ['OPP-$count']);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response(jsonEncode({'message': user}), 200);
          }
          if (request.url.path == '/api/resource/Opportunity') {
            return http.Response(
              jsonEncode({
                'data': [
                  for (var i = 1; i <= count; i++)
                    {
                      'name': 'OPP-$i',
                      'opportunity_owner': user,
                      'opportunity_from': 'Lead',
                      'party_name': 'LEAD-1',
                    },
                ],
              }),
              200,
            );
          }
          final id = request.url.pathSegments.last;
          detailRequests.add(id);
          return http.Response(
            jsonEncode({
              'data': {
                'name': id,
                'opportunity_owner': user,
                'owner': '',
                'status': 'Open',
              },
            }),
            200,
          );
        }),
      );
    });
  }
}
