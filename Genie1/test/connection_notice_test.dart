import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/connection_notice.dart';
import 'package:homegenie/utils/widget/warning.dart';

void main() {
  test(
    'offline transport errors get clear instructions; ERP errors stay unchanged',
    () {
      for (final error in [
        'ClientException with SocketException: Failed host lookup: private.example',
        'No Internet Connection! Please check your network.',
        'net::ERR_INTERNET_DISCONNECTED',
        'ClientException: Failed to fetch',
      ]) {
        final notice = ConnectionNotice.fromError(error)!;
        expect(notice.title, 'No internet connection');
        expect(notice.message, contains('mobile data'));
        expect(notice.message, isNot(contains('private.example')));
      }
      expect(ConnectionNotice.fromError('Server error: 500'), isNull);
      expect(ConnectionNotice.fromError('Wrong OTP'), isNull);
      expect(ConnectionNotice.fromError('Not permitted'), isNull);
      expect(
        ConnectionNotice.fromError('TimeoutException after 0:00:30')!.title,
        'Connection timed out',
      );
    },
  );

  testWidgets('shared popup hides socket details and retains dismiss action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => Warning.show(
                        context,
                        'SocketException: Failed host lookup: private.example',
                        'Error',
                      ),
                  child: const Text('Open'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('No internet connection'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
    expect(find.textContaining('private.example'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });
}
