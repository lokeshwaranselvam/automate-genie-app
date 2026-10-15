import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:homegenie/utils/widget/action_bottom.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final checkout in [false, true]) {
    testWidgets(
      'Office names open before attendance validation: checkout=$checkout',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'token': 'office-test-$checkout',
        });
        dotenv.testLoad(
          fileInput: 'URL=https://erp.example.test/api/method/hrms.api',
        );
        final validation = Completer<bool?>();
        var detailCalls = 0;
        var validations = 0;
        var listCalls = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder:
                      (context) => Scaffold(
                        body: TextButton(
                          onPressed:
                              () => Action_Bottom.show(
                                context: context,
                                title: 'Choose Location',
                                options: ['Head Office'],
                                isCheckedIn: checkout,
                                resolveAttendanceAction: () async {
                                  validations++;
                                  return validation.future;
                                },
                              ),
                          child: const Text('Attendance'),
                        ),
                      ),
                ),
              ),
            );
            await tester.tap(find.text('Attendance'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Head Office'));
            await tester.pumpAndSettle();
            expect(find.text('Office Chennai'), findsOneWidget);
            expect(validations, 0);
            expect(listCalls, 1);
            await tester.tap(find.text('Office Chennai'));
            await tester.pumpAndSettle();
            expect(validations, 1);
            expect(listCalls, 1);
            expect(
              detailCalls,
              1,
            ); // Office lookup runs while status is pending.
            validation.complete(null);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
          () => MockClient((request) async {
            if (request.url.path.endsWith('.head_office_details')) {
              detailCalls++;
              expect(
                request.url.queryParameters['head_office'],
                'Office Chennai',
              );
              return http.Response(
                jsonEncode({
                  'message': {
                    'allowd_distance_meters': 100.0,
                    'latitude': '13',
                    'longitude': '80',
                  },
                }),
                200,
              );
            }
            expect(request.url.path, '/api/method/hrms.api.head_office_list');
            listCalls++;
            return http.Response(
              jsonEncode({
                'message': ['Office Chennai'],
              }),
              200,
            );
          }),
        );
      },
    );
  }

  testWidgets('Office preload deduplicates requests and cache follows login', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'token': 'first-office-user'});
    dotenv.testLoad(
      fileInput: 'URL=https://erp.example.test/api/method/hrms.api',
    );
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold();
          },
        ),
      ),
    );
    var calls = 0;
    await http.runWithClient(
      () async {
        final results = await Future.wait([
          Event.head_office_list(pageContext),
          Event.head_office_list(pageContext),
        ]);
        expect(results.first, ['Office Chennai']);
        await Event.head_office_list(pageContext);
        expect(calls, 1);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', 'second-office-user');
        await Event.head_office_list(pageContext);
        expect(calls, 2);
      },
      () => MockClient((request) async {
        expect(request.url.path, '/api/method/hrms.api.head_office_list');
        calls++;
        return http.Response(
          jsonEncode({
            'message': ['Office Chennai'],
          }),
          200,
        );
      }),
    );
  });
}
