import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/opportunities_webview_page.dart';
import 'package:homegenie/Screen/pending_section_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'selected Opportunity is encoded within the existing ERP page fragment',
    () {
      final base = Uri.parse('https://erp.example.test/app?old=1#old');
      expect(
        opportunitiesWebPageUri(base).toString(),
        'https://erp.example.test/genie-opportunities',
      );
      for (final id in [
        'OPP-1',
        'OPP/2 &status=Open#test',
        'https://outside.test',
      ]) {
        final page = opportunitiesWebPageUri(base, opportunityId: id);
        expect(page.origin, base.origin);
        expect(page.path, '/genie-opportunities');
        expect(page.query, isEmpty);
        expect(Uri.splitQueryString(page.fragment), {'opportunity': id});
        expect(isOpportunitiesWebPageLocation(page, page.toString()), isTrue);
      }
    },
  );

  testWidgets(
    'Pending Opportunity ID and name fallback open the selected WebView record',
    (tester) async {
      for (final useFallback in [false, true]) {
        const user = 'pending@example.test';
        dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
        SharedPreferences.setMockInitialValues({
          'session_sid': 'pending-${useFallback.toString()}',
          'session_username': user,
        });
        FlutterSecureStorage.setMockInitialValues({});
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              const MaterialApp(
                home: PendingSectionPage(
                  title: 'Open Opportunities',
                  icon: Icons.business,
                  section: 'opportunities',
                  isActive: true,
                ),
              ),
            );
            await tester.pumpAndSettle();
            // Avoid platform WebView creation while checking the real tap/navigation path.
            dotenv.testLoad(fileInput: 'SITE_URL=http://erp.example.test');
            await tester.tap(find.text('Selected Customer'));
            await tester.pumpAndSettle();
            final page = tester.widget<OpportunitiesWebViewPage>(
              find.byType(OpportunitiesWebViewPage),
            );
            expect(
              page.initialOpportunityId,
              useFallback ? 'FALLBACK-1' : 'OPP-SELECTED',
            );
            expect(page.canCreateLead, isFalse);
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byType(OpportunitiesWebViewPage), findsNothing);
            expect(find.text('Selected Customer'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
          () => MockClient((request) async {
            if (request.url.path.endsWith('get_logged_user')) {
              return http.Response(jsonEncode({'message': user}), 200);
            }
            expect(request.url.path, '/api/method/get_pending_work');
            return http.Response(
              jsonEncode({
                'message': {
                  'items': [
                    {
                      'name': 'FALLBACK-1',
                      if (!useFallback) 'opportunity_id': 'OPP-SELECTED',
                      'customer_name': 'Selected Customer',
                      'status': 'Open',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );
      }
    },
  );

  test(
    'Opportunity bridge accepts only the configured HTTPS origin and page',
    () {
      final page = Uri.parse('https://erp.example.test/genie-opportunities');
      for (final value in [
        page.toString(),
        '${page.toString()}/',
        '${page.toString()}#opportunity=OPP-1',
        '${page.toString()}?v=2',
      ]) {
        expect(isOpportunitiesWebPageLocation(page, value), isTrue);
      }
      for (final value in [
        'http://erp.example.test/genie-opportunities',
        'https://outside.example/genie-opportunities',
        'https://erp.example.test.outside.example/genie-opportunities',
        'https://user@erp.example.test/genie-opportunities',
        'https://erp.example.test:444/genie-opportunities',
        'https://erp.example.test/app',
        'https://erp.example.test/login',
        'javascript:alert(1)',
        'file:///genie-opportunities',
        'about:blank',
      ]) {
        expect(
          isOpportunitiesWebPageLocation(page, value),
          isFalse,
          reason: value,
        );
      }
    },
  );

  testWidgets(
    'invalid ERP site does not show native New Lead and Back uses its caller',
    (tester) async {
      dotenv.testLoad(fileInput: 'SITE_URL=http://erp.example.test');
      var exits = 0;
      final key = GlobalKey<OpportunitiesWebViewPageState>();
      await tester.pumpWidget(
        MaterialApp(
          home: WillPopScope(
            onWillPop: () async {
              await key.currentState!.handleBack();
              return false;
            },
            child: OpportunitiesWebViewPage(
              key: key,
              canCreateLead: true,
              onExit: () => exits++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The ERP site URL is not configured.'), findsOneWidget);
      expect(find.text('New Lead'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
