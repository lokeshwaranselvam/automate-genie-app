import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/my_opportunities_page.dart';
import 'package:homegenie/Screen/opportunity_details_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': 'creator@example.test',
    });
  });
  MockClient server({bool empty = false, int status = 200}) => MockClient((
    request,
  ) async {
    if (request.url.path.endsWith('get_logged_user')) {
      return http.Response('{"message":"creator@example.test"}', 200);
    }
    final doc = {
      'name': 'OPP-1',
      'owner': 'creator@example.test',
      'customer_name': 'Customer One',
      'status': 'Open',
      'custom_requirement': 'Office doors',
      'items': [
        {'item_code': 'DOOR-1', 'qty': 2},
      ],
    };
    return http.Response(
      jsonEncode({
        'data':
            request.url.path.endsWith('/OPP-1') ? doc : (empty ? [] : [doc]),
      }),
      status,
    );
  });

  testWidgets(
    'owned list opens full details including custom fields and child rows',
    (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: MyOpportunitiesPage()));
        await tester.pumpAndSettle();
        expect(find.text('My Opportunities'), findsOneWidget);
        await tester.tap(find.text('Customer One'));
        await tester.pumpAndSettle();
        expect(find.byType(OpportunityDetailsPage), findsOneWidget);
        expect(find.text('Office doors'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Row 1'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Row 1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Row 1'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('DOOR-1'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('DOOR-1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => server());
    },
  );

  testWidgets('empty list offers pull to refresh', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: MyOpportunitiesPage()));
      await tester.pumpAndSettle();
      expect(
        find.text('You have not created any opportunities yet.'),
        findsOneWidget,
      );
      expect(find.byType(RefreshIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => server(empty: true));
  });

  testWidgets('phone search is debounced, reaches ERP and can be cleared', (
    tester,
  ) async {
    final searches = <String?>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: MyOpportunitiesPage()));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '987');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.enterText(find.byType(TextField), '98765');
        await tester.pump(const Duration(milliseconds: 460));
        await tester.pumpAndSettle();
        expect(searches.length, 2);
        expect(jsonDecode(searches.last!), [
          ['contact_mobile', 'like', '%9%8%7%6%5%'],
          ['phone', 'like', '%9%8%7%6%5%'],
        ]);
        expect(
          find.text('No opportunities match this phone number.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Clear phone search'));
        await tester.pump(const Duration(milliseconds: 460));
        await tester.pumpAndSettle();
        expect(searches.last, isNull);
        expect(
          find.text('You have not created any opportunities yet.'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response('{"message":"creator@example.test"}', 200);
        }
        searches.add(request.url.queryParameters['or_filters']);
        expect(jsonDecode(request.url.queryParameters['filters']!), [
          ['owner', '=', 'creator@example.test'],
        ]);
        return http.Response('{"data":[]}', 200);
      }),
    );
  });

  testWidgets('permission error is readable and retryable', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: MyOpportunitiesPage()));
      await tester.pumpAndSettle();
      expect(
        find.text('You do not have permission to view these opportunities.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => server(status: 403));
  });
}
