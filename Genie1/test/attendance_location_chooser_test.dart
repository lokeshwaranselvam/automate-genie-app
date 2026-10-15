import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/widget/action_bottom.dart';

void main() {
  for (final checkingOut in [false, true]) {
    testWidgets(
      'Location chooser opens before validation: checkout=$checkingOut',
      (tester) async {
        final validation = Completer<bool?>();
        var validations = 0;
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
                            options: ['Head Office', 'Operations'],
                            isCheckedIn: checkingOut,
                            resolveAttendanceAction: () {
                              validations++;
                              return validation.future;
                            },
                          ),
                      child: const Text('Attendance action'),
                    ),
                  ),
            ),
          ),
        );
        await tester.tap(find.text('Attendance action'));
        await tester.pumpAndSettle();
        expect(find.text('Choose Location'), findsOneWidget);
        expect(find.text('Head Office'), findsOneWidget);
        expect(validations, 0);
        await tester.tap(find.text('Operations'));
        await tester.pumpAndSettle();
        expect(validations, 1);
        // Failed validation must not continue to office lookup or face capture.
        validation.complete(null);
        await tester.pumpAndSettle();
        expect(find.text('Choose Location'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
