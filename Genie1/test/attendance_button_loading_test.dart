import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/attendance_page.dart';

void main() {
  for (final verifying in [false, true]) {
    testWidgets('Attendance verification gates the button: $verifying', (
      tester,
    ) async {
      var actions = 0;
      await tester.pumpWidget(MaterialApp(
        home: AttendancePage(
          checkedIn: false,
          previousDayPendingCheckout: false,
          // Unrelated dashboard initialization must not block attendance.
          loading: true,
          statusLoading: verifying,
          actionLoading: false,
          status: const {},
          position: null,
          accuracy: null,
          currentAddress: '',
          onRefresh: () async {},
          onBack: () {},
          onOpenHistory: () {},
          onAttendanceAction: () => actions++,
          onLeaveApplication: () {},
        ),
      ));
      final label = verifying ? 'Checking attendance...' : 'Check In';
      final button = find.widgetWithText(ElevatedButton, label);
      await tester.scrollUntilVisible(button, 200);
      expect(tester.widget<ElevatedButton>(button).onPressed,
          verifying ? isNull : isNotNull);
      if (!verifying) {
        await tester.tap(button);
        expect(actions, 1);
      }
    });
  }
}
