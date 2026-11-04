import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/platform/attendance_action_sheet_web.dart';

void main() {
  testWidgets('Browser chooser opens and invokes the selected location', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showAdaptiveActionSheet<void>(
                        context: context,
                        title: const Text('Choose Location'),
                        actions: [
                          for (final location in ['Head Office', 'Operations'])
                            BottomSheetAction(
                              title: Text(location),
                              onPressed: (sheetContext) {
                                selected = location;
                                Navigator.pop(sheetContext);
                              },
                            ),
                        ],
                      ),
                  child: const Text('Check In'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Check In'));
    await tester.pumpAndSettle();
    expect(find.text('Choose Location'), findsOneWidget);
    expect(find.text('Head Office'), findsOneWidget);
    await tester.tap(find.text('Operations'));
    await tester.pumpAndSettle();
    expect(selected, 'Operations');
    expect(find.text('Choose Location'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
