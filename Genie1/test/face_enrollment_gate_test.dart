import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/face_enrollment_gate.dart';
import 'package:homegenie/utils/api/face_auth_api.dart';
import 'package:homegenie/utils/widget/ag_path_loading_indicator.dart';

FaceEnrollmentStatus enrollment({bool enrolled = false}) =>
    FaceEnrollmentStatus(
      currentUser: 'staff@example.test',
      csrfToken: 'face-csrf',
      minimumSimilarity: 0.5,
      referenceName: enrolled ? 'FACE-REFERENCE-1' : null,
      referenceUrl: enrolled ? '/private/files/reference.jpg' : null,
      referenceVersion: enrolled ? 'reference-version-1' : null,
    );

const protectedChild = Scaffold(body: Text('Protected home'));

void main() {
  testWidgets(
    'enrolled login never displays selfie setup while checking status',
    (tester) async {
      final reply = Completer<FaceEnrollmentStatus>();
      var cameraCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () => reply.future,
            enrollSelfie: (_, _) async {
              cameraCalls++;
              return null;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(AgPathLoadingIndicator), findsOneWidget);
      expect(find.text('Your attendance face photo'), findsNothing);
      expect(find.text('Set up your selfie'), findsNothing);
      expect(find.textContaining('Look at the front camera'), findsNothing);
      expect(find.text('Protected home'), findsNothing);
      reply.complete(enrollment(enrolled: true));
      await tester.pumpAndSettle();
      expect(find.text('Protected home'), findsOneWidget);
      expect(find.text('Your attendance face photo'), findsNothing);
      expect(cameraCalls, 0);
    },
  );

  testWidgets('existing enrollment opens home without opening the camera', (
    tester,
  ) async {
    var statusCalls = 0;
    var cameraCalls = 0;
    var readyCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FaceEnrollmentGate(
          child: protectedChild,
          loadStatus: () async {
            statusCalls++;
            return enrollment(enrolled: true);
          },
          enrollSelfie: (_, _) async {
            cameraCalls++;
            throw StateError('The camera must not open for an enrolled user.');
          },
          onReady: () => readyCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Protected home'), findsOneWidget);
    expect(statusCalls, 1);
    expect(cameraCalls, 0);
    expect(readyCalls, 1);
  });

  testWidgets('first missing enrollment automatically opens selfie setup', (
    tester,
  ) async {
    var cameraCalls = 0;
    var readyCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FaceEnrollmentGate(
          child: protectedChild,
          loadStatus: () async => enrollment(),
          enrollSelfie: (context, status) async {
            cameraCalls++;
            expect(context.mounted, isTrue);
            expect(status.currentUser, 'staff@example.test');
            expect(status.enrolled, isFalse);
            return enrollment(enrolled: true);
          },
          onReady: () => readyCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cameraCalls, 1);
    expect(readyCalls, 1);
    expect(find.text('Protected home'), findsOneWidget);
  });

  testWidgets(
    'cancelled setup blocks home and offers another selfie or sign out',
    (tester) async {
      var signedOut = false;
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () async => enrollment(),
            enrollSelfie: (_, _) async => null,
            onSignOut: () async => signedOut = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Protected home'), findsNothing);
      expect(
        find.text('Take your first-login selfie to finish setup.'),
        findsOneWidget,
      );
      expect(find.text('Take selfie'), findsOneWidget);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
      await tester.tap(find.text('Sign out'));
      await tester.pump();
      expect(signedOut, isTrue);
    },
  );

  testWidgets(
    'failed enrollment retry refreshes server status before another capture',
    (tester) async {
      final order = <String>[];
      var cameraCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () async {
              order.add('status');
              return enrollment();
            },
            enrollSelfie: (_, _) async {
              order.add('camera');
              if (++cameraCalls == 1) throw StateError('Upload interrupted.');
              return enrollment(enrolled: true);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Upload interrupted.'), findsOneWidget);
      expect(find.text('Protected home'), findsNothing);
      await tester.tap(find.text('Take selfie'));
      await tester.pumpAndSettle();
      expect(order, ['status', 'camera', 'status', 'camera']);
      expect(find.text('Protected home'), findsOneWidget);
    },
  );

  testWidgets(
    'interrupted response recovers an existing server photo without replacing it',
    (tester) async {
      var statusCalls = 0;
      var cameraCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () async => enrollment(enrolled: ++statusCalls > 1),
            enrollSelfie: (_, _) async {
              cameraCalls++;
              throw TimeoutException(
                'The photo may have saved, but its reply was lost.',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Protected home'), findsNothing);
      await tester.tap(find.text('Take selfie'));
      await tester.pumpAndSettle();
      expect(statusCalls, 2);
      expect(cameraCalls, 1);
      expect(find.text('Protected home'), findsOneWidget);
    },
  );

  testWidgets(
    'status network failure keeps home blocked and retry does not overwrite enrollment',
    (tester) async {
      var statusCalls = 0;
      var cameraCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () async {
              if (++statusCalls == 1) throw StateError('Network unavailable.');
              return enrollment(enrolled: true);
            },
            enrollSelfie: (_, _) async {
              cameraCalls++;
              return null;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Protected home'), findsNothing);
      expect(find.textContaining('Network unavailable.'), findsOneWidget);
      expect(find.text('Your attendance face photo'), findsNothing);
      expect(find.text('Set up your selfie'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(statusCalls, 2);
      expect(cameraCalls, 0);
      expect(find.text('Protected home'), findsOneWidget);
    },
  );

  testWidgets(
    'pending status and capture cannot start duplicate enrollment attempts',
    (tester) async {
      final statusReply = Completer<FaceEnrollmentStatus>();
      final cameraReply = Completer<FaceEnrollmentStatus?>();
      var statusCalls = 0;
      var cameraCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () {
              statusCalls++;
              return statusReply.future;
            },
            enrollSelfie: (_, _) {
              cameraCalls++;
              return cameraReply.future;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.text('Protected home'), findsNothing);
      statusReply.complete(enrollment());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(FilledButton), findsNothing);
      expect(cameraCalls, 1);
      expect(statusCalls, 1);
      expect(find.text('Your attendance face photo'), findsOneWidget);
      expect(find.text('Set up your selfie'), findsOneWidget);
      cameraReply.complete(enrollment(enrolled: true));
      await tester.pumpAndSettle();
      expect(find.text('Protected home'), findsOneWidget);
    },
  );

  testWidgets(
    'completion after gate is disposed does not navigate or set state',
    (tester) async {
      final reply = Completer<FaceEnrollmentStatus>();
      await tester.pumpWidget(
        MaterialApp(
          home: FaceEnrollmentGate(
            child: protectedChild,
            loadStatus: () => reply.future,
            enrollSelfie:
                (_, _) async =>
                    throw StateError('Disposed gate must not open camera.'),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Text('Signed out')));
      reply.complete(enrollment());
      await tester.pumpAndSettle();
      expect(find.text('Signed out'), findsOneWidget);
      expect(find.text('Protected home'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
