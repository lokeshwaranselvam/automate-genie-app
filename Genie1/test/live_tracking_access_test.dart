import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/live_tracking_access.dart';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'package:homegenie/utils/widget/location_permission_helper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var session = 0;
  final nativeCalls = <String>[];
  final permissionCalls = <String>[];
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    session++;
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
    SharedPreferences.setMockInitialValues({
      'email': 'role-test@example.test',
      'session_sid': 'role-session-$session',
      'token': 'token key:secret',
      'is_employee_checked_in': true,
    });
    nativeCalls.clear();
    permissionCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveLocationService.platform, (call) async {
          nativeCalls.add(call.method);
          if (call.method == 'isLocationTracking') return true;
          return 'ok';
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (call) async {
          permissionCalls.add(call.method);
          return 1;
        });
  });

  tearDown(() {
    for (final channel in [LiveLocationService.platform, permissions]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  MockClient client({List<String>? roles, int status = 200, bool? decision}) =>
      MockClient((request) async {
        expect(request.headers['Cookie'], 'sid=role-session-$session');
        expect(request.url.queryParameters.containsKey('user'), isFalse);
        if (request.url.path.endsWith('frappe.auth.get_logged_user')) {
          return http.Response(
            jsonEncode({'message': 'role-test@example.test'}),
            200,
          );
        }
        expect(request.url.path, endsWith('/mobile_site_visit'));
        return http.Response(
          jsonEncode({
            'message': {
              'current_user': 'role-test@example.test',
              'can_track':
                  decision ??
                  (roles == null
                      ? null
                      : roles.any(
                        (role) => const {
                          'sales user',
                          'designer',
                        }.contains(role.trim().toLowerCase()),
                      )),
            },
          }),
          status,
        );
      });

  test(
    'API decision permits tracking without a client-side role allowlist',
    () async {
      await http.runWithClient(() async {
        expect(await LiveTrackingAccess.canTrack(), isTrue);
      }, () => client(roles: ['Employee'], decision: true));
    },
  );

  for (final role in ['Sales User', 'Designer', ' designer ', 'sales user']) {
    test('$role can start and resume tracking during attendance', () async {
      await http.runWithClient(() async {
        await LiveLocationService().startTracking();
        expect(nativeCalls, ['startLocationTracking', 'isLocationTracking']);
        nativeCalls.clear();
        await LiveLocationService().ensureTracking();
        expect(nativeCalls, ['isLocationTracking']);
      }, () => client(roles: ['Employee', role]));
    });
  }

  for (final roles in [
    <String>[],
    ['Employee'],
    ['System Manager'],
    ['Sales'],
    ['Sales Manager'],
    ['Desginer'],
    ['site engineer'],
    ['Sales Manager', 'Employee', 'Site Engineer'],
  ]) {
    test(
      '$roles cannot start or resume tracking or request background access',
      () async {
        await http.runWithClient(() async {
          await LiveLocationService().startTracking();
          await LiveLocationService().ensureTracking();
          await LocationPermissionHelper.requestBackgroundOnce();
          expect(nativeCalls, ['stopLocationTracking', 'stopLocationTracking']);
          expect(permissionCalls, isEmpty);
          expect(LiveLocationService().isTracking, isFalse);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getBool('is_employee_checked_in'), isTrue);
        }, () => client(roles: roles));
      },
    );
  }

  test(
    'an eligible role without attendance cannot request background access',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_employee_checked_in', false);
      await http.runWithClient(() async {
        expect(
          await LiveTrackingAccess.canTrack(requireCheckIn: false),
          isTrue,
        );
        await LiveLocationService().startTracking();
        await LocationPermissionHelper.requestBackgroundOnce();
        expect(nativeCalls, ['stopLocationTracking']);
        expect(permissionCalls, isEmpty);
      }, () => client(roles: ['Sales User']));
    },
  );

  for (final status in [200, 401, 403, 500]) {
    test(
      'missing roles or HTTP $status stops tracking without blocking attendance',
      () async {
        await http.runWithClient(() async {
          await LiveLocationService().ensureTracking();
          expect(nativeCalls, ['stopLocationTracking']);
          expect(permissionCalls, isEmpty);
          expect(
            (await SharedPreferences.getInstance()).getBool(
              'is_employee_checked_in',
            ),
            isTrue,
          );
        }, () => client(status: status));
      },
    );
  }

  test('an account switch discards the previous account role result', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    await http.runWithClient(
      () async {
        final allowed = LiveTrackingAccess.canTrack();
        await started.future;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('email', 'other@example.test');
        await prefs.setString('session_sid', 'other-session');
        response.complete(
          http.Response(
            jsonEncode({
              'message': {
                'current_user': 'role-test@example.test',
                'can_track': true,
              },
            }),
            200,
          ),
        );
        expect(await allowed, isFalse);
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('mobile_site_visit')) {
          started.complete();
          return response.future;
        }
        return http.Response(
          jsonEncode({'message': 'role-test@example.test'}),
          200,
        );
      }),
    );
  });

  test('a different authenticated user cannot authorize tracking', () async {
    await http.runWithClient(
      () async {
        await LiveLocationService().ensureTracking();
        expect(nativeCalls, ['stopLocationTracking']);
        expect(permissionCalls, isEmpty);
      },
      () => MockClient((request) async {
        expect(request.url.path, endsWith('frappe.auth.get_logged_user'));
        return http.Response(
          jsonEncode({'message': 'other@example.test'}),
          200,
        );
      }),
    );
  });

  test(
    'an account switch during permission setup cannot start the old account',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissions, (call) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('email', 'other@example.test');
            await prefs.setString('session_sid', 'other-session');
            return 1;
          });
      await http.runWithClient(
        () async {
          await LiveLocationService().startTracking();
          expect(nativeCalls, ['stopLocationTracking']);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('frappe.auth.get_logged_user')) {
            final prefs = await SharedPreferences.getInstance();
            return http.Response(
              jsonEncode({'message': prefs.getString('email')}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'message': {
                'current_user': 'role-test@example.test',
                'can_track': true,
              },
            }),
            200,
          );
        }),
      );
    },
  );

  test('simultaneous checks share one authenticated roles request', () async {
    var roleRequests = 0;
    await http.runWithClient(
      () async {
        expect(
          await Future.wait(
            List.generate(5, (_) => LiveTrackingAccess.canTrack()),
          ),
          everyElement(isTrue),
        );
        expect(roleRequests, 1);
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('mobile_site_visit')) {
          roleRequests++;
          return http.Response(
            jsonEncode({
              'message': {
                'current_user': 'role-test@example.test',
                'can_track': true,
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'message': 'role-test@example.test'}),
          200,
        );
      }),
    );
  });
}
