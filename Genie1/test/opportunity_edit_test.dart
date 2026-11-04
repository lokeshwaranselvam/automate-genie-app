import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/opportunity_api.dart';
import 'package:homegenie/utils/api_business_policy.dart';
import 'package:homegenie/utils/widget/opportunity_edit_dialog.dart';
import 'package:homegenie/utils/widget/warning.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'creator@example.test';
final original = <String, dynamic>{
  'name': 'OPP-1',
  'owner': 'other.creator@example.test',
  'opportunity_owner': user,
  'modified': '2026-10-21 10:00:00',
  'status': 'Open',
  'custom_next_followup_date': DateTime.now().toIso8601String().substring(
    0,
    10,
  ),
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
  testWidgets('API can allow status changes without notes or Event warnings', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  child: const Text('Edit'),
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => OpportunityEditDialog(
                              document: original,
                              options: OpportunityEditOptions(
                                statuses: const ['Open', 'Demo'],
                                notesType: 'CRM Note',
                                followUpField: 'custom_next_followup_date',
                                businessPolicy: ApiBusinessPolicy.fromApi({
                                  'fields': {
                                    'note': {
                                      'visible': false,
                                      'required': false,
                                    },
                                  },
                                  'rules': {
                                    'note_on_status_change': false,
                                    'note_on_followup_change': false,
                                    'dependencies': [],
                                  },
                                }),
                              ),
                              onSave: (patch) async {
                                saved = patch;
                              },
                            ),
                      ),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Add note'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Create an event first'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, {'status': 'Demo'});
  });

  testWidgets(
    'event-required error uses Create event heading only for this notice',
    (tester) async {
      late BuildContext popupContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              popupContext = context;
              return Scaffold(
                body: TextButton(
                  onPressed:
                      () => Warning.show(
                        context,
                        'You do not have permission.',
                        'Error',
                      ),
                  child: const Text('Other error'),
                ),
              );
            },
          ),
        ),
      );
      Warning.show(
        popupContext,
        Warning.opportunityEventRequiredMessage,
        'Error',
      );
      await tester.pumpAndSettle();
      expect(find.text('Create event'), findsOneWidget);
      expect(find.text('Something went wrong'), findsNothing);
      expect(
        find.text(Warning.opportunityEventRequiredMessage),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other error'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Create event'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    },
  );

  for (final changeStatus in [true, false]) {
    testWidgets(
      '${changeStatus ? 'Status' : 'Follow-up date'} change requires a new nonblank note',
      (tester) async {
        var writes = 0;
        Map<String, dynamic>? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder:
                  (context) => Scaffold(
                    body: TextButton(
                      child: const Text('Edit'),
                      onPressed:
                          () => showDialog<void>(
                            context: context,
                            builder:
                                (_) => OpportunityEditDialog(
                                  document: {
                                    ...original,
                                    'custom_next_followup_date':
                                        changeStatus
                                            ? DateTime.now()
                                                .toIso8601String()
                                                .substring(0, 10)
                                            : '2000-01-01',
                                  },
                                  options: const OpportunityEditOptions(
                                    statuses: ['Open', 'Follow-up'],
                                    followUpField: 'custom_next_followup_date',
                                    notesType: 'CRM Note',
                                  ),
                                  onSave: (patch) async {
                                    writes++;
                                    if (changeStatus && writes <= 4) {
                                      throw OpportunityActionError(
                                        statusCode: 417,
                                        validationMessage: switch (writes) {
                                          1 =>
                                            'Create an Event before selecting Demo.',
                                          2 => null,
                                          3 =>
                                            'Create Events before selecting Demo.',
                                          _ => 'A required field is missing.',
                                        },
                                      );
                                    }
                                    saved = patch;
                                  },
                                ),
                          ),
                    ),
                  ),
            ),
          ),
        );
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        if (changeStatus) {
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Demo').last);
          await tester.pumpAndSettle();
          expect(find.textContaining('Create an event first'), findsOneWidget);
          expect(writes, 0);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Select a next follow-up date on or after'),
            findsOneWidget,
          );
          expect(writes, 0);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(OutlinedButton));
          await tester.pumpAndSettle();
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
        }
        for (final note in ['', '   \n  ']) {
          await tester.enterText(
            find.widgetWithText(TextField, 'Add note'),
            note,
          );
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Note required:'), findsOneWidget);
          expect(writes, 0);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
        }
        await tester.enterText(
          find.widgetWithText(TextField, 'Add note'),
          'Called customer',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        if (changeStatus) {
          for (var attempt = 1; attempt <= 3; attempt++) {
            expect(writes, attempt);
            expect(
              find.textContaining('Create an event first'),
              findsOneWidget,
            );
            expect(find.textContaining('417'), findsNothing);
            expect(find.text('Something went wrong'), findsNothing);
            expect(find.text('Create event'), findsOneWidget);
            expect(find.text('Called customer'), findsOneWidget);
            expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
            await tester.tap(find.text('OK'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Save'));
            await tester.pumpAndSettle();
          }
          // Other ERP validation errors must retain their actual explanation.
          expect(writes, 4);
          expect(find.text('A required field is missing.'), findsOneWidget);
          expect(find.textContaining('Create an event first'), findsNothing);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
        }
        expect(writes, changeStatus ? 5 : 1);
        expect(saved!['notes'][0], (original['notes'] as List)[0]);
        expect(saved!['notes'][1]['note'], '<p>Called customer</p>');
        expect(tester.takeException(), isNull);
      },
    );
  }
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
        find.widgetWithText(TextField, 'Add note'),
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
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(OpportunityEditDialog), findsNothing);
      expect(saved!['custom_next_followup_date'], futureDate);
      expect(saved!.containsKey('custom_next_followup_date'), true);
      expect(saved!['notes'][0]['name'], 'NOTE-1');
      expect(saved!['notes'][0]['note'], '<p>Existing <b>note</b></p>');
      expect(saved!['notes'][1]['note'], '<p>Updated note</p>');
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
  MockClient server(
    Future<http.Response> Function(http.Request) handler, {
    Map<String, Object?> policy = const {},
  }) => MockClient((request) async {
    if (request.url.path.endsWith('get_logged_user')) {
      return http.Response(jsonEncode({'message': user}), 200);
    }
    if (request.url.path.endsWith('getdoctype')) {
      return http.Response(jsonEncode(metadata), 200);
    }
    if (request.url.path.endsWith('mobile_opportunity_policy') &&
        request.method == 'GET') {
      return http.Response(
        jsonEncode({
          'message': {
            'current_user': user,
            'editable_statuses': ['Open', 'Follow-up'],
            'status_transitions': {},
            'followup_policy': {
              'allow_past': false,
              'earliest_date': DateTime.now().toIso8601String().substring(
                0,
                10,
              ),
            },
            ...policy,
          },
        }),
        200,
      );
    }
    return handler(request);
  });

  test(
    'API overrides editable statuses, transitions and past follow-up policy',
    () async {
      await http.runWithClient(
        () async {
          final options = await OpportunityApi.getEditOptions(name: 'OPP-1');
          expect(options.statusesFor('Open'), ['Follow-up']);
          expect(options.firstFollowupDate, DateTime(2000));
          expect(options.isAllowedFollowupDate('2001-01-01'), isTrue);
          expect(options.isAllowedFollowupDate('1999-12-31'), isFalse);
        },
        () => server(
          (_) async => throw StateError('Unexpected request'),
          policy: {
            'editable_statuses': ['Follow-up'],
            'status_transitions': {
              'Open': ['Follow-up'],
            },
            'followup_policy': {
              'allow_past': true,
              'earliest_date': '2000-01-01',
            },
          },
        ),
      );
    },
  );

  testWidgets('dialog uses API status choices and earliest follow-up date', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpportunityEditDialog(
            document: {...original, 'custom_next_followup_date': '2001-01-01'},
            options: OpportunityEditOptions(
              statuses: const ['Open', 'Lost'],
              allowedStatuses: const ['Lost'],
              statusTransitions: const {
                'Open': ['Lost'],
              },
              followUpField: 'custom_next_followup_date',
              notesType: 'CRM Note',
              allowPastFollowup: true,
              earliestDate: DateTime(2000),
            ),
          ),
        ),
      ),
    );
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.items!.map((item) => item.value).toList(), ['Lost']);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DatePickerDialog>(find.byType(DatePickerDialog)).firstDate,
      DateTime(2000),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
    'status filter combines with Opportunity Owner, phone search and pagination',
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
            ['opportunity_owner', '=', user],
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
          expect(updated['sales_stage'], 'Follow-up');
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
          expect(request.method, 'POST');
          expect(request.headers['X-Frappe-CSRF-Token'], 'token$tokens');
          expect(jsonDecode(request.body), {
            'action': 'save',
            'name': 'OPP-1',
            'changes': {'status': 'Follow-up'},
            'modified': original['modified'],
            'csrf_token': 'token$tokens',
          });
          if (csrfRetry && writes == 1) {
            return http.Response('{"exc_type":"CSRFTokenError"}', 400);
          }
          return http.Response(
            jsonEncode({
              'data': {
                ...original,
                'status': 'Follow-up',
                'sales_stage': 'Follow-up',
              },
            }),
            200,
          );
        }),
      );
      expect(writes, csrfRetry ? 2 : 1);
      expect(tokens, writes);
    });
  }

  for (final change in ['notes', 'date', 'unchanged status']) {
    test('$change edit leaves sales stage untouched', () async {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final source = {
        ...original,
        'custom_next_followup_date': today,
        'sales_stage': 'Existing stage',
      };
      final changes = switch (change) {
        'notes' => <String, dynamic>{'notes': original['notes']},
        'date' => <String, dynamic>{'custom_next_followup_date': today},
        _ => <String, dynamic>{'status': 'Open'},
      };
      var writes = 0;
      await http.runWithClient(
        () async {
          final updated = await OpportunityApi.updateDetails(
            original: source,
            changes: changes,
          );
          expect(updated['sales_stage'], 'Existing stage');
          expect(changes.containsKey('sales_stage'), false);
        },
        () => server((request) async {
          if (request.url.path == '/app') {
            return http.Response('frappe.csrf_token = "token";', 200);
          }
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'data': source}), 200);
          }
          writes++;
          expect(jsonDecode(request.body), {
            'action': 'save',
            'name': 'OPP-1',
            'changes': changes,
            'modified': original['modified'],
            'csrf_token': 'token',
          });
          return http.Response(
            jsonEncode({
              'data': {...source, ...changes},
            }),
            200,
          );
        }),
      );
      expect(writes, 1);
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
    'follow-up allows today but rejects cleared, past and invalid dates',
    () async {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      await http.runWithClient(() async {
        expect(OpportunityApi.isFutureFollowUpDate(today), true);
        for (final date in [null, '', '2000-01-01', '2099-02-30']) {
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

  for (final statusCode in [417]) {
    for (final validation in [
      null,
      'An Event is required for Demo.',
      'A required field is missing.',
    ]) {
      test(
        '$statusCode preserves Demo event validation without retry: $validation',
        () async {
          var writes = 0;
          await http.runWithClient(
            () async {
              await expectLater(
                OpportunityApi.updateDetails(
                  original: original,
                  changes: {'status': 'Follow-up'},
                ),
                throwsA(
                  isA<OpportunityActionError>()
                      .having((error) => error.statusCode, 'status', statusCode)
                      .having(
                        (error) => error.validationMessage,
                        'validation',
                        validation,
                      ),
                ),
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
              return http.Response(
                jsonEncode({
                  'exc_type': 'ValidationError',
                  'exc': 'Internal traceback must not be displayed',
                  if (validation != null)
                    '_server_messages': jsonEncode([
                      jsonEncode({'message': '<b>$validation</b>'}),
                    ]),
                }),
                statusCode,
              );
            }),
          );
          expect(writes, 1);
        },
      );
    }
  }

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
    'adding a note hides history and preserves row identity, audit values and HTML',
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
                            (_) => OpportunityEditDialog(
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
      expect(find.text('Existing note'), findsNothing);
      expect(find.text('Note 1'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
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
