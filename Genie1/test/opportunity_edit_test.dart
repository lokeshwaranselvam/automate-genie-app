import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/opportunity_api.dart';
import 'package:homegenie/utils/widget/opportunity_edit_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'creator@example.test';
const original = <String, dynamic>{
  'name': 'OPP-1',
  'owner': user,
  'modified': '2026-10-21 10:00:00',
  'status': 'Open',
  'custom_next_followup_date': '2026-10-22',
  'notes': [
    {
      'name': 'NOTE-1',
      'doctype': 'CRM Note',
      'note': '<p>Existing <b>note</b></p>',
      'added_by': user,
      'added_on': '2026-10-20 09:00:00',
    },
  ],
};
const metadata = {
  'docs': [
    {
      'name': 'Opportunity',
      'fields': [
        {
          'fieldname': 'status',
          'fieldtype': 'Select',
          'options': 'Open\nFollow-up\nLost',
        },
        {
          'fieldname': 'custom_next_followup_date',
          'fieldtype': 'Date',
          'label': 'Next Followup Date',
        },
        {'fieldname': 'notes', 'fieldtype': 'Table', 'options': 'CRM Note'},
      ],
    },
    {
      'name': 'CRM Note',
      'fields': [
        {'fieldname': 'note', 'fieldtype': 'Text Editor'},
      ],
    },
  ],
};

void main() {
  testWidgets(
    'failed save retains draft notes and follow-up change for retry',
    (tester) async {
      var attempts = 0;
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed:
                        () => showDialog<void>(
                          context: context,
                          builder:
                              (_) => OpportunityEditDialog(
                                document: {
                                  ...original,
                                  'custom_next_followup_date': '2000-01-01',
                                },
                                options: const OpportunityEditOptions(
                                  statuses: ['Open', 'Follow-up'],
                                  followUpField: 'custom_next_followup_date',
                                  notesType: 'CRM Note',
                                ),
                                onSave: (patch) async {
                                  attempts++;
                                  if (attempts == 1) {
                                    throw StateError('Please retry');
                                  }
                                  saved = patch;
                                },
                              ),
                        ),
                    child: const Text('Edit'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Note 1'),
        'Updated note',
      );
      expect(find.byTooltip('Clear follow-up date'), findsNothing);
      expect(find.byIcon(Icons.clear), findsNothing);
      final statusField = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(statusField.items!.map((item) => item.value).toList(), [
        'Open',
        'Follow-up',
        'Demo',
        'VC',
        'Duplicate Lead',
        'Junk',
        'Not Interested',
        'Hot Followup',
        'RNR',
        'B2B Database',
      ]);
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Next follow-up date: 2000-01-01'),
      );
      await tester.pumpAndSettle();
      final picker = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(picker.firstDate, OpportunityApi.earliestFollowUpDate);
      expect(picker.initialDate, picker.firstDate);
      final futureDate = picker.initialDate!.toIso8601String().substring(0, 10);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Please retry'), findsOneWidget);
      expect(find.text('Updated note'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(OpportunityEditDialog), findsNothing);
      expect(saved!['custom_next_followup_date'], futureDate);
      expect(saved!.containsKey('custom_next_followup_date'), true);
      expect(saved!['notes'][0]['name'], 'NOTE-1');
      expect(saved!['notes'][0]['note'], '<p>Updated note</p>');
      expect(saved!['notes'][0]['added_by'], user);
      expect(saved!.containsKey('status'), false);
    },
  );
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'session_sid': 'sid',
      'session_username': user,
    });
  });
  MockClient server(Future<http.Response> Function(http.Request) handler) =>
      MockClient((request) async {
        if (request.url.path.endsWith('get_logged_user')) {
          return http.Response(jsonEncode({'message': user}), 200);
        }
        if (request.url.path.endsWith('getdoctype')) {
          return http.Response(jsonEncode(metadata), 200);
        }
        return handler(request);
      });

  test('reads customized status, follow-up and notes metadata', () async {
    await http.runWithClient(() async {
      final options = await OpportunityApi.getEditOptions();
      expect(options.statuses, ['Open', 'Follow-up', 'Lost']);
      expect(options.followUpField, 'custom_next_followup_date');
      expect(options.notesType, 'CRM Note');
    }, () => server((_) async => throw StateError('Unexpected request')));
  });

  test(
    'status filter combines with owner, phone search and pagination',
    () async {
      await http.runWithClient(
        () async {
          await OpportunityApi.getMyOpportunities(
            status: 'Follow-up',
            phone: '987',
            offset: 50,
          );
        },
        () => server((request) async {
          expect(jsonDecode(request.url.queryParameters['filters']!), [
            ['owner', '=', user],
            ['status', '=', 'Follow-up'],
          ]);
          expect(request.url.queryParameters['limit_start'], '50');
          expect(
            request.url.queryParameters['or_filters'],
            contains('contact_mobile'),
          );
          return http.Response('{"data":[]}', 200);
        }),
      );
    },
  );

  for (final csrfRetry in [false, true]) {
    test('saves only requested changes with CSRF; retry=$csrfRetry', () async {
      var writes = 0;
      var tokens = 0;
      await http.runWithClient(
        () async {
          final updated = await OpportunityApi.updateDetails(
            original: original,
            changes: {'status': 'Follow-up'},
          );
          expect(updated['status'], 'Follow-up');
        },
        () => server((request) async {
          expect(request.followRedirects, false);
          expect(request.headers['Cookie'], 'sid=sid');
          if (request.url.path == '/app') {
            tokens++;
            return http.Response('frappe.csrf_token = "token$tokens";', 200);
          }
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'data': original}), 200);
          }
          writes++;
          expect(request.method, 'PUT');
          expect(request.headers['X-Frappe-CSRF-Token'], 'token$tokens');
          expect(jsonDecode(request.body), {
            'status': 'Follow-up',
            'modified': original['modified'],
            'csrf_token': 'token$tokens',
          });
          if (csrfRetry && writes == 1) {
            return http.Response('{"exc_type":"CSRFTokenError"}', 400);
          }
          return http.Response(
            jsonEncode({
              'data': {...original, 'status': 'Follow-up'},
            }),
            200,
          );
        }),
      );
      expect(writes, csrfRetry ? 2 : 1);
      expect(tokens, writes);
    });
  }

  test('changed document is rejected before writing', () async {
    await http.runWithClient(
      () async {
        await expectLater(
          OpportunityApi.updateDetails(
            original: original,
            changes: {'status': 'Follow-up'},
          ),
          throwsStateError,
        );
      },
      () => server((request) async {
        expect(request.method, 'GET');
        return http.Response(
          jsonEncode({
            'data': {...original, 'modified': 'later'},
          }),
          200,
        );
      }),
    );
  });

  test('unrelated field changes are rejected before writing', () async {
    await http.runWithClient(() async {
      await expectLater(
        OpportunityApi.updateDetails(
          original: original,
          changes: {'company': 'Other Company'},
        ),
        throwsArgumentError,
      );
    }, () => server((_) async => throw StateError('Must not write')));
  });

  test(
    'status outside the requested options is rejected before writing',
    () async {
      await http.runWithClient(() async {
        await expectLater(
          OpportunityApi.updateDetails(
            original: original,
            changes: {'status': 'Lost'},
          ),
          throwsArgumentError,
        );
      }, () => server((_) async => throw StateError('Must not write')));
    },
  );

  test(
    'follow-up cannot be cleared or changed to today, a past or invalid date',
    () async {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      await http.runWithClient(() async {
        for (final date in [null, '', today, '2000-01-01', '2099-02-30']) {
          await expectLater(
            OpportunityApi.updateDetails(
              original: original,
              changes: {'custom_next_followup_date': date},
            ),
            throwsArgumentError,
          );
        }
        final tomorrow = OpportunityApi.earliestFollowUpDate
            .toIso8601String()
            .substring(0, 10);
        expect(OpportunityApi.isFutureFollowUpDate(tomorrow), true);
      }, () => server((_) async => throw StateError('Must not write')));
    },
  );

  test('permission failure is not retried', () async {
    var writes = 0;
    await http.runWithClient(
      () async {
        await expectLater(
          OpportunityApi.updateDetails(
            original: original,
            changes: {'status': 'Follow-up'},
          ),
          throwsStateError,
        );
      },
      () => server((request) async {
        if (request.url.path == '/app') {
          return http.Response('frappe.csrf_token = "token";', 200);
        }
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'data': original}), 200);
        }
        writes++;
        return http.Response('{"exc_type":"PermissionError"}', 403);
      }),
    );
    expect(writes, 1);
  });

  testWidgets(
    'editing notes preserves row identity, audit values and untouched HTML',
    (tester) async {
      Map<String, dynamic>? patch;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      patch = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder:
                            (_) => const OpportunityEditDialog(
                              document: original,
                              options: OpportunityEditOptions(
                                statuses: ['Open', 'Follow-up'],
                                followUpField: 'custom_next_followup_date',
                                notesType: 'CRM Note',
                              ),
                            ),
                      );
                    },
                    child: const Text('Edit'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Existing note'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Add note'),
        'Call <tomorrow>',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(patch!.keys, ['notes']);
      expect(
        patch!['notes'][0],
        original['notes'] is List ? (original['notes'] as List)[0] : null,
      );
      expect(patch!['notes'][1]['note'], '<p>Call &lt;tomorrow&gt;</p>');
      expect(tester.takeException(), isNull);
    },
  );
}
