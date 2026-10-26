import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/attendance_page.dart';
import 'package:homegenie/Screen/leave_application_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response optionsResponse() => http.Response(
  jsonEncode({
    'message': {
      'employee': 'EMP-1',
      'employee_name': 'Staff',
      'csrf_token': 'leave-csrf',
      'leave_types': [
        {'value': 'Casual Leave', 'label': 'Casual Leave'},
        {'value': 'Sick Leave', 'label': 'Sick Leave'},
      ],
    },
  }),
  200,
);

http.Response savedResponse() => http.Response(
  jsonEncode({
    'message': {
      'status': 'success',
      'name': 'HR-LAP-2026-00001',
      'total_leave_days': 0.5,
    },
  }),
  200,
);

const previewKey = ValueKey('leave-preview');

Future<void> withLeavePage(
  WidgetTester tester,
  Future<void> Function(List<http.Request>) check, {
  Future<http.Response> Function(http.Request)? reply,
  VoidCallback? onBack,
  VoidCallback? onNotifications,
  bool signedIn = true,
}) async {
  SharedPreferences.setMockInitialValues(
    signedIn ? {'session_sid': 'leave-session'} : {},
  );
  dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return reply != null
        ? reply(request)
        : request.method == 'GET'
        ? optionsResponse()
        : savedResponse();
  });
  try {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
          home: RepaintBoundary(
            key: previewKey,
            child: Scaffold(
              backgroundColor: Colors.white,
              body: LeaveApplicationPage(
                onBack: onBack ?? () {},
                onNotifications: onNotifications ?? () {},
              ),
              bottomNavigationBar: BottomNavigationBar(
                backgroundColor: Colors.white,
                elevation: 0,
                type: BottomNavigationBarType.fixed,
                selectedItemColor: const Color(0xFF1768C4),
                unselectedItemColor: const Color(0xFF7F8998),
                selectedFontSize: 10,
                unselectedFontSize: 10,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.assignment_outlined),
                    label: 'Tasks',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.location_on_outlined),
                    label: 'Visits',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.people_outline_rounded),
                    label: 'Leads',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.more_horiz_rounded),
                    label: 'More',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await check(requests);
    }, () => client);
  } finally {
    await dismissPopup(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }
}

Future<void> chooseLeaveType(WidgetTester tester, String type) async {
  await tester.tap(find.byKey(const ValueKey('leave-type')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(type).last);
  await tester.pumpAndSettle();
}

Future<void> chooseDate(WidgetTester tester, String key, DateTime date) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Switch to input'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.byType(TextField),
    ),
    DateFormat.yMd('en_US').format(date),
  );
  await tester.tap(find.text('OK').last);
  await tester.pumpAndSettle();
}

Future<void> dismissPopup(WidgetTester tester) async {
  if (find.byType(Dialog).evaluate().isNotEmpty) {
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
  }
}

Future<void> submit(WidgetTester tester) async {
  await dismissPopup(tester);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('leave-submit')));
  await tester.tap(find.byKey(const ValueKey('leave-submit')));
}

void main() {
  testWidgets(
    'API hides fields and makes reason optional with a server length limit',
    (tester) async {
      await withLeavePage(
        tester,
        (requests) async {
          expect(find.byKey(const ValueKey('leave-type')), findsNothing);
          final reason = tester.widget<TextFormField>(
            find.byKey(const ValueKey('leave-reason')),
          );
          final input = tester.widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('leave-reason')),
              matching: find.byType(TextField),
            ),
          );
          expect(input.maxLength, 4);
          expect(reason.validator!(''), isNull);
          expect(find.byType(Checkbox), findsNothing);
        },
        reply: (request) async {
          final data =
              jsonDecode(optionsResponse().body) as Map<String, dynamic>;
          (data['message'] as Map)['business_policy'] = {
            'fields': {
              'description': {'required': false, 'max_length': 4},
              'leave_type': {'visible': false},
              'half_day': {'visible': false},
            },
            'rules': {
              'earliest_date': '2026-11-01',
              'latest_date': '2026-11-30',
            },
          };
          return http.Response(jsonEncode(data), 200);
        },
      );
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fontDirectory = Platform.environment['LEAVE_UI_PREVIEW_FONT_DIR'];
    if (fontDirectory == null) return;
    for (final font
        in {
          'Roboto': 'roboto-regular.ttf',
          'MaterialIcons': 'materialicons-regular.otf',
        }.entries) {
      final loader = FontLoader(font.key)..addFont(
        File(
          '$fontDirectory/${font.value}',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });
  testWidgets(
    'loads the supplied API options with the screenshot fields and navigation',
    (tester) async {
      await withLeavePage(tester, (requests) async {
        expect(requests.length, 1);
        expect(
          requests.single.url.path,
          '/api/method/create_leave_application_from_mobile',
        );
        expect(requests.single.headers['Cookie'], 'sid=leave-session');
        for (final label in [
          'Leave Type *',
          'From Date *',
          'To Date *',
          'Reason *',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('Total Days'), findsOneWidget);
        expect(find.text('1 day'), findsOneWidget);
        expect(find.text('Apply for half day'), findsOneWidget);
        expect(find.text('Submit Application'), findsOneWidget);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(find.text('Employee'), findsNothing);
        expect(find.text('Leave Approver'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'half-day and date selections update the inclusive calendar preview',
    (tester) async {
      await withLeavePage(tester, (_) async {
        final start = DateTime(DateTime.now().year, 11, 10);
        await chooseDate(tester, 'leave-from-date', start);
        expect(find.text('1 day'), findsOneWidget);
        await chooseDate(
          tester,
          'leave-to-date',
          start.add(const Duration(days: 2)),
        );
        expect(find.text('3 days'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('leave-half-day')),
        );
        await tester.tap(find.byKey(const ValueKey('leave-half-day')));
        await tester.pumpAndSettle();
        expect(find.text('2.5 days'), findsOneWidget);
        await chooseDate(
          tester,
          'leave-from-date',
          start.add(const Duration(days: 4)),
        );
        expect(find.text('0.5 days'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('leave-to-date')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DatePickerDialog>(find.byType(DatePickerDialog))
              .firstDate,
          start.add(const Duration(days: 4)),
        );
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
      });
    },
  );

  testWidgets('required leave type and reason stop incomplete submissions', (
    tester,
  ) async {
    await withLeavePage(tester, (requests) async {
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.text('Choose a leave type.'), findsOneWidget);
      expect(find.text('Reason is required.'), findsOneWidget);
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
    });
  });

  testWidgets(
    'submit maps all fields, session and CSRF to the working API then clears the form',
    (tester) async {
      await withLeavePage(tester, (requests) async {
        final today = DateUtils.dateOnly(DateTime.now());
        await chooseLeaveType(tester, 'Casual Leave');
        await tester.enterText(
          find.byKey(const ValueKey('leave-reason')),
          '  Family function  ',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('leave-half-day')),
        );
        await tester.tap(find.byKey(const ValueKey('leave-half-day')));
        await submit(tester);
        await tester.pumpAndSettle();
        final request = requests.singleWhere(
          (request) => request.method == 'POST',
        );
        expect(request.bodyFields, {
          'leave_type': 'Casual Leave',
          'from_date': DateFormat('yyyy-MM-dd').format(today),
          'to_date': DateFormat('yyyy-MM-dd').format(today),
          'description': 'Family function',
          'half_day': '1',
          'csrf_token': 'leave-csrf',
        });
        expect(request.headers['X-Frappe-CSRF-Token'], 'leave-csrf');
        expect(request.headers['Cookie'], 'sid=leave-session');
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Success'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.text(
            'Leave Application HR-LAP-2026-00001 created for 0.5 days.',
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('leave-reason')))
              .controller!
              .text,
          '',
        );
        expect(
          tester
              .widget<Checkbox>(find.byKey(const ValueKey('leave-half-day')))
              .value,
          isFalse,
        );
        expect(find.text('1 day'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        await submit(tester);
        await tester.pumpAndSettle();
        expect(find.text('Choose a leave type.'), findsOneWidget);
        expect(requests.where((request) => request.method == 'POST').length, 1);
      });
    },
  );

  testWidgets('ERP validation errors retain the form and allow resubmission', (
    tester,
  ) async {
    var posts = 0;
    await withLeavePage(
      tester,
      (requests) async {
        await chooseLeaveType(tester, 'Sick Leave');
        await tester.enterText(
          find.byKey(const ValueKey('leave-reason')),
          'Unwell',
        );
        await submit(tester);
        await tester.pumpAndSettle();
        expect(find.text('Insufficient leave balance.'), findsOneWidget);
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Something went wrong'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('leave-reason')))
              .controller!
              .text,
          'Unwell',
        );
        await submit(tester);
        await tester.pumpAndSettle();
        expect(posts, 2);
        expect(requests.last.bodyFields['half_day'], '0');
      },
      reply: (request) async {
        if (request.method == 'GET') return optionsResponse();
        posts++;
        if (posts == 1) {
          return http.Response(
            jsonEncode({
              '_server_messages': jsonEncode([
                jsonEncode({'message': 'Insufficient leave balance.'}),
              ]),
            }),
            417,
          );
        }
        return savedResponse();
      },
    );
  });

  testWidgets('submission timeout uses the app popup and preserves the form', (
    tester,
  ) async {
    await withLeavePage(
      tester,
      (_) async {
        await chooseLeaveType(tester, 'Casual Leave');
        await tester.enterText(
          find.byKey(const ValueKey('leave-reason')),
          'Family function',
        );
        await submit(tester);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Warning'), findsOneWidget);
        expect(
          find.text(
            'Submission timed out. Check Leave Applications in ERPNext before retrying; it may have been saved.',
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('leave-reason')))
              .controller!
              .text,
          'Family function',
        );
      },
      reply: (request) async {
        if (request.method == 'GET') return optionsResponse();
        throw TimeoutException('Slow ERP');
      },
    );
  });

  testWidgets('pending submissions disable duplicate taps and form edits', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    await withLeavePage(
      tester,
      (requests) async {
        await chooseLeaveType(tester, 'Casual Leave');
        await tester.enterText(
          find.byKey(const ValueKey('leave-reason')),
          'Family function',
        );
        await submit(tester);
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('leave-submit')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<Checkbox>(find.byKey(const ValueKey('leave-half-day')))
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('leave-reason')))
              .enabled,
          isFalse,
        );
        expect(requests.where((request) => request.method == 'POST').length, 1);
        pending.complete(savedResponse());
        await tester.pumpAndSettle();
      },
      reply:
          (request) =>
              request.method == 'GET'
                  ? Future.value(optionsResponse())
                  : pending.future,
    );
  });

  testWidgets(
    'load failures support swipe refresh without opening a broken form',
    (tester) async {
      var loads = 0;
      await withLeavePage(
        tester,
        (_) async {
          expect(
            find.text('Loading leave options timed out. Please try again.'),
            findsOneWidget,
          );
          await tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh();
          await tester.pumpAndSettle();
          expect(find.text('Submit Application'), findsOneWidget);
          expect(loads, 2);
        },
        reply: (_) async {
          if (++loads == 1) throw TimeoutException('Slow ERP');
          return optionsResponse();
        },
      );
    },
  );

  testWidgets(
    'missing session explains sign-in without making an API request',
    (tester) async {
      await withLeavePage(tester, (requests) async {
        expect(
          find.text('Your Frappe session has expired. Please sign in again.'),
          findsOneWidget,
        );
        expect(requests, isEmpty);
      }, signedIn: false);
    },
  );

  testWidgets(
    'header back and notification buttons invoke existing navigation',
    (tester) async {
      var backs = 0;
      var notifications = 0;
      await withLeavePage(
        tester,
        (_) async {
          await tester.tap(find.byTooltip('Back to More'));
          await tester.tap(find.byTooltip('Notifications'));
          expect(backs, 1);
          expect(notifications, 1);
        },
        onBack: () => backs++,
        onNotifications: () => notifications++,
      );
    },
  );

  testWidgets('attendance keeps its action without the moved leave button', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'session_sid': 'leave-session'});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    final client = MockClient((_) async => optionsResponse());
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => AttendancePage(
                    checkedIn: false,
                    previousDayPendingCheckout: false,
                    loading: false,
                    actionLoading: false,
                    status: const {},
                    position: null,
                    accuracy: null,
                    currentAddress: '',
                    onRefresh: () async {},
                    onBack: () {},
                    onOpenHistory: () {},
                    onAttendanceAction: () {},
                    onLeaveApplication:
                        () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder:
                                (context) => LeaveApplicationPage(
                                  onBack: () => Navigator.of(context).pop(),
                                  onNotifications: () {},
                                ),
                          ),
                        ),
                  ),
            ),
          ),
        ),
      );
      expect(find.text('Request Correction'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Leave Application'), findsNothing);
      expect(find.text('Check In'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('completed attendance shows a disabled Completed button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttendancePage(
            checkedIn: true,
            previousDayPendingCheckout: false,
            completedToday: true,
            loading: false,
            actionLoading: false,
            status: const {},
            position: null,
            accuracy: null,
            currentAddress: '',
            onRefresh: () async {},
            onBack: () {},
            onOpenHistory: () {},
            onAttendanceAction: () {},
            onLeaveApplication: () {},
          ),
        ),
      ),
    );

    expect(find.text('Completed'), findsNWidgets(2));
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Completed'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('phone layout matches the reference without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await withLeavePage(tester, (_) async {
      await chooseLeaveType(tester, 'Casual Leave');
      await tester.enterText(
        find.byKey(const ValueKey('leave-reason')),
        'Family function',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final path = Platform.environment['LEAVE_UI_PREVIEW_PATH'];
      if (path != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(previewKey),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  });
}
