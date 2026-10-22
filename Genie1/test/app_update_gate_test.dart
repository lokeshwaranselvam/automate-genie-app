import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/app_update_gate.dart';
import 'package:homegenie/utils/api/app_update_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test/');
    PackageInfo.setMockInitialValues(
      appName: 'Genie',
      packageName: 'test.genie',
      version: '1.0.0',
      buildNumber: '15',
      buildSignature: '',
    );
  });

  http.Response response(bool required) => http.Response(
    jsonEncode({
      'message': {
        'update_required': required,
        'latest_version': '1.0.0',
        'latest_build': 4,
      },
    }),
    200,
  );

  for (final required in [true, false]) {
    test(
      'sends installed values and obeys server update_required=$required',
      () async {
        await http.runWithClient(
          () async {
            final result = await AppUpdateApi.check();
            expect(result.required, required);
          },
          () => MockClient((request) async {
            expect(request.url.origin, 'https://erp.example.test');
            expect(request.url.path, '/api/method/update_required');
            expect(request.url.queryParameters, {
              'app_version': '1.0.0',
              'build_version': '15',
            });
            return response(required);
          }),
        );
      },
    );
  }

  for (final badResponse in [
    http.Response('{}', 200),
    http.Response('{"message":{"update_required":"false"}}', 200),
    http.Response('not JSON', 200),
    http.Response('{}', 403),
    http.Response('{}', 500),
  ]) {
    test(
      'rejects invalid or failed response ${badResponse.statusCode}: ${badResponse.body}',
      () async {
        await http.runWithClient(() async {
          await expectLater(
            AppUpdateApi.check(),
            throwsA(anyOf(isA<Exception>(), isA<StateError>())),
          );
        }, () => MockClient((_) async => badResponse));
      },
    );
  }

  testWidgets(
    'waits before mounting startup; blocks back and allows retry only',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(
              home: AppUpdateGate(
                child: Scaffold(body: Text('Existing startup')),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('Existing startup'), findsNothing);
          pending.complete(response(true));
          await tester.pumpAndSettle();
          expect(find.text('Update required'), findsOneWidget);
          expect(find.text('Existing startup'), findsNothing);
          expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Update required'), findsOneWidget);
          await tester.tap(find.text('Check again'));
          await tester.pumpAndSettle();
          expect(find.text('Existing startup'), findsOneWidget);
          expect(calls, 2);
        },
        () => MockClient(
          (_) async => ++calls == 1 ? pending.future : response(false),
        ),
      );
    },
  );

  testWidgets('check failure blocks startup until a successful retry', (
    tester,
  ) async {
    var calls = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: AppUpdateGate(
              child: Scaffold(body: Text('Existing startup')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Unable to check for updates'), findsOneWidget);
        expect(find.text('Existing startup'), findsNothing);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Existing startup'), findsOneWidget);
      },
      () => MockClient(
        (_) async => ++calls == 1 ? http.Response('{}', 500) : response(false),
      ),
    );
  });

  testWidgets('iOS retains existing startup without the APK check', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AppUpdateGate(child: Scaffold(body: Text('Existing startup'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Existing startup'), findsOneWidget);
    }, () => MockClient((_) async => throw StateError('Must not check')));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
