import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/pending_work_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  String date(DateTime value) => value.toIso8601String().split('T').first;
  testWidgets(
    'priority then deadline determines order and submission keeps the correct task ID',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_sid': 'ordering-session',
        'session_username': 'staff@example.test',
      });
      FlutterSecureStorage.setMockInitialValues({});
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [
        {
          'name': 'LOW',
          'subject': 'Low overdue',
          'task_priority': 'Low',
          'todo_date': date(today.subtract(const Duration(days: 1))),
        },
        {
          'name': 'HIGH',
          'subject': 'High later',
          'task_priority': 'High',
          'todo_date': date(today.add(const Duration(days: 30))),
        },
        {
          'name': 'URGENT-NONE',
          'subject': 'Urgent no date',
          'task_priority': 'Urgent',
        },
        {
          'name': 'URGENT-TODAY',
          'subject': 'Urgent today',
          'task_priority': 'Urgent',
          'todo_date': date(today),
        },
        {
          'name': 'MEDIUM',
          'subject': 'Medium today',
          'task_priority': 'Medium',
          'todo_date': date(today),
        },
        {
          'name': 'URGENT-LATER',
          'subject': 'Urgent later',
          'task_priority': 'Urgent',
          'todo_date': date(today.add(const Duration(days: 1))),
        },
      ];
      final completed = <String>{};
      final submitted = <String>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: PendingWorkPage()));
          await tester.pumpAndSettle();
          final expected = [
            'Urgent today',
            'Urgent later',
            'Urgent no date',
            'High later',
            'Medium today',
            'Low overdue',
          ];
          for (var i = 1; i < expected.length; i++) {
            expect(
              tester.getTopLeft(find.text(expected[i - 1])).dy,
              lessThan(tester.getTopLeft(find.text(expected[i])).dy),
            );
          }
          await tester.tap(find.byType(Checkbox).first);
          await tester.pump();
          await tester.tap(find.text('Submit (1)'));
          await tester.pumpAndSettle();
          expect(submitted, ['URGENT-TODAY']);
          expect(find.text('Pending (5)'), findsOneWidget);
          expect(find.text('Completed (1)'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response(
              jsonEncode({'message': 'staff@example.test'}),
              200,
            );
          }
          if (request.method == 'POST') {
            final id = request.url.queryParameters['task_id']!;
            submitted.add(id);
            completed.add(id);
            return http.Response(
              jsonEncode({
                'message': {'status': 'success'},
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'message': {
                'assigned_to_only': true,
                'assigned_user': 'staff@example.test',
                'csrf_token': 'ordering-token',
                'task_data': [
                  for (final row in rows)
                    {
                      ...row,
                      'task_status':
                          completed.contains(row['name'])
                              ? 'Completed'
                              : 'Open',
                    },
                ],
              },
            }),
            200,
          );
        }),
      );
    },
  );

  for (final example in [
    (
      name: 'saved low remains low when overdue',
      fields: <String, dynamic>{
        'task_priority': 'Low',
        'todo_date': date(today.subtract(const Duration(days: 1))),
      },
      priority: 'Low',
      due: 'Overdue',
    ),
    (
      name: 'saved medium remains medium when due today',
      fields: <String, dynamic>{
        'task_priority': 'Medium',
        'todo_date': date(today),
      },
      priority: 'Medium',
      due: 'Due Today',
    ),
    (
      name: 'saved high remains high with a distant deadline',
      fields: <String, dynamic>{
        'task_priority': ' HIGH ',
        'todo_date': date(today.add(const Duration(days: 30))),
      },
      priority: 'High',
      due: 'Due ',
    ),
    (
      name: 'urgent without a deadline is still urgent',
      fields: <String, dynamic>{'task_priority': 'Urgent'},
      priority: 'Urgent',
      due: 'No due date',
    ),
    (
      name: 'due date takes precedence over start date',
      fields: <String, dynamic>{
        'priority': 'urgent',
        'todo_date': 'invalid',
        'due_date': date(today.add(const Duration(days: 1))),
        'start_date': date(today.subtract(const Duration(days: 7))),
      },
      priority: 'Urgent',
      due: 'Due Tomorrow',
    ),
    (
      name: 'completed task is not labelled overdue',
      fields: <String, dynamic>{
        'task_priority': 'Low',
        'task_status': 'Completed',
        'todo_date': date(today.subtract(const Duration(days: 1))),
      },
      priority: 'Low',
      due: 'Due ',
    ),
    (
      name: 'legacy record retains due-date fallback',
      fields: <String, dynamic>{'todo_date': date(today)},
      priority: 'High',
      due: 'Due Today',
    ),
  ]) {
    testWidgets(example.name, (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_sid': 'priority-session',
        'session_username': 'staff@example.test',
      });
      dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: PendingWorkPage()));
          await tester.pumpAndSettle();
          expect(find.text(example.priority), findsOneWidget);
          expect(find.textContaining(example.due), findsOneWidget);
          if (example.priority == 'Urgent') {
            expect(
              tester.widget<Text>(find.text('Urgent')).style?.color,
              const Color(0xFFB3261E),
            );
          }
          if (example.fields['task_status'] == 'Completed') {
            expect(find.textContaining('Overdue'), findsNothing);
            expect(
              tester.widget<Checkbox>(find.byType(Checkbox)).onChanged,
              isNull,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response(
              jsonEncode({'message': 'staff@example.test'}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'message': {
                'assigned_to_only': true,
                'assigned_user': 'staff@example.test',
                'task_data': [
                  {
                    'name': 'TASK-PRIORITY',
                    'subject': 'Priority example',
                    'task_status': 'Open',
                    ...example.fields,
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
    });
  }

  for (final partialFailure in [false, true]) {
    testWidgets(
      'task submission preserves counts and selections: partial=$partialFailure',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'session_sid': 'task-page-session-$partialFailure',
          'session_username': 'staff@example.test',
        });
        FlutterSecureStorage.setMockInitialValues({});
        dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
        final completed = <String>{'TASK-DONE'};
        final submitted = <String>[];
        var bootstraps = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(const MaterialApp(home: PendingWorkPage()));
            await tester.pumpAndSettle();
            expect(find.text('All (3)'), findsOneWidget);
            expect(find.text('Pending (2)'), findsOneWidget);
            expect(find.text('Completed (1)'), findsOneWidget);
            await tester.tap(find.byType(Checkbox).at(0));
            if (partialFailure) await tester.tap(find.byType(Checkbox).at(1));
            await tester.pump();
            final submit = tester.widget<TextButton>(
              find.widgetWithText(
                TextButton,
                partialFailure ? 'Submit (2)' : 'Submit (1)',
              ),
            );
            submit.onPressed!();
            submit
                .onPressed!(); // The existing UI guard must block a double tap.
            await tester.pumpAndSettle();
            expect(
              submitted,
              partialFailure ? ['TASK-1', 'TASK-2'] : ['TASK-1'],
            );
            expect(bootstraps, 1);
            expect(find.text('Pending (1)'), findsOneWidget);
            expect(find.text('Completed (2)'), findsOneWidget);
            expect(
              find.text(partialFailure ? 'Submit (1)' : 'Submit (0)'),
              findsOneWidget,
            );
            expect(
              find.textContaining(
                partialFailure ? '1 completed; 1 failed.' : '1 task submitted',
              ),
              findsOneWidget,
            );
            // Searching and switching tabs must still work after submitting.
            await tester.enterText(find.byType(TextField), 'Task Two');
            await tester.pumpAndSettle();
            expect(
              find.text('Task Two', findRichText: false, skipOffstage: true),
              findsNWidgets(2),
            );
            expect(find.text('Task One'), findsNothing);
            await tester.tap(find.text('Completed (2)'));
            await tester.pumpAndSettle();
            expect(find.text('No tasks found'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          () => MockClient((request) async {
            if (request.url.path.endsWith('get_logged_user')) {
              return http.Response(
                jsonEncode({'message': 'staff@example.test'}),
                200,
              );
            }
            if (request.url.path == '/app') {
              bootstraps++;
              return http.Response('frappe.csrf_token="page-token";', 200);
            }
            if (request.method == 'POST') {
              final id = request.url.queryParameters['task_id']!;
              submitted.add(id);
              if (partialFailure && id == 'TASK-2') {
                return http.Response(
                  jsonEncode({'message': 'Task validation failed.'}),
                  417,
                );
              }
              completed.add(id);
              return http.Response(
                jsonEncode({
                  'message': {'status': 'success'},
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'message': {
                  'assigned_to_only': true,
                  'assigned_user': 'staff@example.test',
                  'task_data': [
                    for (final entry
                        in {
                          'TASK-1': 'Task One',
                          'TASK-2': 'Task Two',
                          'TASK-DONE': 'Finished Task',
                        }.entries)
                      {
                        'name': entry.key,
                        'subject': entry.value,
                        'task_status':
                            completed.contains(entry.key)
                                ? 'Completed'
                                : 'Open',
                      },
                  ],
                },
              }),
              200,
            );
          }),
        );
      },
    );
  }
}
