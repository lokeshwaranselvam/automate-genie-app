import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/face_auth_api.dart';
import 'package:homegenie/utils/face/face_auth_flow.dart';
import 'package:homegenie/utils/face/face_template_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const account = 'staff@example.test';
final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

Map<String, dynamic> statusMessage({bool enrolled = true}) => {
  'current_user': account,
  'model_version': FaceAuthApi.modelVersion,
  'minimum_similarity': 0.5,
  'verification_receipt_version': 2,
  'csrf_token': 'face-csrf',
  'enrolled': enrolled,
  if (enrolled)
    'reference_file': {
      'name': 'FACE-REFERENCE-1',
      'file_url': '/private/files/reference.jpg',
      'version': 'reference-version-1',
    },
};

http.Response response(Map<String, dynamic> message) =>
    http.Response(jsonEncode({'message': message}), 200);

FaceEnrollmentStatus enrolledStatus({String? url}) => FaceEnrollmentStatus(
  currentUser: account,
  csrfToken: 'face-csrf',
  minimumSimilarity: 0.5,
  referenceName: 'FACE-REFERENCE-1',
  referenceUrl: url ?? '/private/files/reference.jpg',
  referenceVersion: 'reference-version-1',
);

FaceAuthApi apiWith(
  http.Client client, {
  Future<String?> Function()? user,
  Future<String?> Function()? sid,
}) => FaceAuthApi(
  client: client,
  savedUser: user ?? () async => account,
  sessionId: sid ?? () async => 'face-session',
  site: Uri.parse('https://erp.example.test/'),
);

Future<FaceVerificationReceipt> verify(
  FaceAuthApi api, {
  String action = 'attendance_in',
}) => api.recordVerification(
  status: enrolledStatus(),
  action: action,
  similarity: 0.87,
  latitude: 13.0827,
  longitude: 80.2707,
  capturedOn: DateTime.utc(2026, 10, 12, 8, 30),
);

class MemoryFaceStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  final events = <String>[];
  Completer<void>? holdWrite;
  Completer<void>? writeStarted;
  Completer<void>? holdRead;
  Completer<void>? readStarted;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final result = values[key];
    events.add('read');
    if (readStarted != null && !readStarted!.isCompleted)
      readStarted!.complete();
    if (holdRead != null) await holdRead!.future;
    return result;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    events.add('write-start');
    if (writeStarted != null && !writeStarted!.isCompleted)
      writeStarted!.complete();
    if (holdWrite != null) await holdWrite!.future;
    if (value != null) values[key] = value;
    events.add('write-finish');
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
    events.add('delete');
  }
}

List<double> embedding({int axis = 0}) =>
    List<double>.generate(128, (index) => index == axis ? 1 : 0);

void main() {
  group('private template cache logout races', () {
    test(
      'stale derivation after logout cannot restore the previous account template',
      () async {
        final storage = MemoryFaceStorage();
        final cache = FaceTemplateCache(storage: storage);
        final oldGeneration = cache.generation;
        await cache.clear();
        await cache.write(
          'old-account',
          embedding(),
          expectedGeneration: oldGeneration,
        );
        expect(storage.values, isEmpty);
        expect(await cache.read('old-account'), isNull);
      },
    );

    test(
      'logout queued during an active write deletes the completed old write',
      () async {
        final storage =
            MemoryFaceStorage()
              ..holdWrite = Completer<void>()
              ..writeStarted = Completer<void>();
        final cache = FaceTemplateCache(storage: storage);
        final write = cache.write(
          'old-account',
          embedding(),
          expectedGeneration: cache.generation,
        );
        await storage.writeStarted!.future;
        final oldGeneration = cache.generation;
        final clear = cache.clear();
        expect(cache.generation, greaterThan(oldGeneration));
        storage.holdWrite!.complete();
        await write;
        await clear;
        expect(storage.events, ['write-start', 'write-finish', 'delete']);
        expect(storage.values, isEmpty);
      },
    );

    test('logout while reading does not return a stale template', () async {
      final storage = MemoryFaceStorage();
      final cache = FaceTemplateCache(storage: storage);
      await cache.write('old-account', embedding());
      storage.holdRead = Completer<void>();
      storage.readStarted = Completer<void>();
      final read = cache.read('old-account');
      await storage.readStarted!.future;
      final clear = cache.clear();
      storage.holdRead!.complete();
      expect(await read, isNull);
      await clear;
      expect(storage.values, isEmpty);
    });

    test(
      'different account or model identity cannot reuse a cached template',
      () async {
        final storage = MemoryFaceStorage();
        final cache = FaceTemplateCache(storage: storage);
        await cache.write('account-model-version-A', embedding());
        expect(await cache.read('account-model-version-A'), embedding());
        expect(await cache.read('account-model-version-B'), isNull);
        expect(storage.values, isEmpty);
      },
    );
  });

  for (final failLocation in [false, true]) {
    testWidgets(
      failLocation
          ? 'fresh GPS restriction blocks evidence after successful face matching'
          : 'wrong face cannot submit evidence or attendance',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.runAsync(() async {
          final requests = <String>[];
          final api = apiWith(
            MockClient((request) async {
              requests.add(request.method);
              if (request.url.path.startsWith('/private/files/')) {
                return http.Response.bytes(jpeg, 200);
              }
              return response(statusMessage());
            }),
          );
          final directory = await Directory.systemTemp.createTemp(
            'genie-face-flow-test-',
          );
          final selfie = await File(
            '${directory.path}/selfie.jpg',
          ).writeAsBytes(jpeg);
          var gpsCalls = 0;
          String? rejection;
          final flow = FaceAuthFlow(
            api: api,
            cache: FaceTemplateCache(storage: MemoryFaceStorage()),
            embed:
                (file) async => embedding(
                  axis:
                      file.path.endsWith('reference.jpg') || failLocation
                          ? 0
                          : 1,
                ),
            capture: (_, _, validate) async {
              rejection = await validate(selfie);
              return rejection == null ? selfie : null;
            },
          );
          try {
            final result = flow.verify(
              context: context,
              action: 'attendance_in',
              refreshLocation: () async {
                gpsCalls++;
                throw StateError(
                  'You moved outside the existing 200 m boundary.',
                );
              },
            );
            if (failLocation) {
              await expectLater(
                result,
                throwsA(
                  isA<StateError>().having(
                    (error) => error.message,
                    'message',
                    contains('200 m boundary'),
                  ),
                ),
              );
              expect(rejection, isNull);
              expect(gpsCalls, 1);
              expect(await selfie.exists(), isFalse);
            } else {
              expect(await result, isNull);
              expect(rejection, contains('does not match'));
              expect(gpsCalls, 0);
            }
            expect(requests, ['GET', 'GET']);
          } finally {
            if (await selfie.exists()) await selfie.delete();
            await directory.delete();
          }
        });
      },
    );
  }

  test(
    'asserting the account is read-only and rejects changed sessions',
    () async {
      var requests = 0;
      var currentUser = account;
      final api = apiWith(
        MockClient((_) async {
          requests++;
          return response(statusMessage());
        }),
        user: () async => currentUser,
      );
      await api.assertSessionUser(account);
      currentUser = 'another@example.test';
      await expectLater(
        api.assertSessionUser(account),
        throwsA(isA<StateError>()),
      );
      expect(requests, 0);
    },
  );

  for (final operation in ['status', 'enroll', 'record', 'download']) {
    test(
      'an account switch during $operation cannot return another account result',
      () async {
        var currentUser = account;
        final api = apiWith(
          MockClient((request) async {
            currentUser = 'another@example.test';
            if (operation == 'download') return http.Response.bytes(jpeg, 200);
            if (operation == 'record') {
              return response({
                'current_user': account,
                'record_id': 'FACE-LOG-1',
                'receipt_version': 2,
              });
            }
            return response(statusMessage());
          }),
          user: () async => currentUser,
        );
        final Future<Object?> result = switch (operation) {
          'status' => api.status(),
          'enroll' => api.enroll(enrolledStatus(), jpeg),
          'record' => verify(api),
          _ => api.downloadReference(enrolledStatus()),
        };
        await expectLater(
          result,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('account changed'),
            ),
          ),
        );
      },
    );
  }

  test(
    'status authenticates the saved session and reads complete enrollment',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/method/mobile_face_auth');
        expect(request.url.queryParameters, {
          'action': 'status',
          'model_version': FaceAuthApi.modelVersion,
        });
        expect(request.headers['cookie'], 'sid=face-session');
        expect(request.headers['cache-control'], 'no-cache, no-store');
        return response(statusMessage());
      });
      final status = await apiWith(client).status();
      expect(status.currentUser, account);
      expect(status.enrolled, isTrue);
      expect(status.referenceName, 'FACE-REFERENCE-1');
      expect(status.referenceUrl, '/private/files/reference.jpg');
      expect(status.referenceVersion, 'reference-version-1');
      expect(status.minimumSimilarity, 0.5);
    },
  );

  test(
    'status follows a same-site Desk redirect and retrieves its CSRF token',
    () async {
      var statusRequests = 0;
      var deskRequests = 0;
      final client = MockClient((request) async {
        expect(request.headers['cookie'], 'sid=face-session');
        expect(request.followRedirects, isFalse);
        if (request.url.path == '/app' || request.url.path == '/app/') {
          expect(request.method, 'GET');
          expect(request.headers['cache-control'], 'no-cache, no-store');
          deskRequests++;
          if (request.url.path == '/app') {
            return http.Response('', 301, headers: {'location': '/app/'});
          }
          return http.Response(
            '<script>frappe.csrf_token = "desk-session-token";</script>',
            200,
            headers: {'content-type': 'text/html'},
          );
        }

        expect(request.url.path, '/api/method/mobile_face_auth');
        statusRequests++;
        return response(statusMessage()..['csrf_token'] = '');
      });

      final status = await apiWith(client).status();
      expect(status.csrfToken, 'desk-session-token');
      expect(statusRequests, 1);
      expect(deskRequests, 2);
    },
  );

  test(
    'status never forwards the ERP session cookie to another site',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/app') {
          return http.Response(
            '',
            301,
            headers: {'location': 'https://other.example.test/app'},
          );
        }
        return response(statusMessage()..['csrf_token'] = '');
      });

      await expectLater(
        apiWith(client).status(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('redirected to a different site'),
          ),
        ),
      );
    },
  );

  test('status fails safely when Desk does not provide a CSRF token', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/app') {
        return http.Response('<html>Desk</html>', 200);
      }
      return response(statusMessage()..['csrf_token'] = '');
    });

    await expectLater(
      apiWith(client).status(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('did not provide a CSRF token'),
        ),
      ),
    );
  });

  test(
    'missing enrollment does not invent a reference from unrelated response fields',
    () async {
      final message = statusMessage(enrolled: false)
        ..['reference_file'] = {
          'name': 'STALE-PHOTO',
          'file_url': '/private/files/stale.jpg',
          'version': 'old',
        };
      final status =
          await apiWith(MockClient((_) async => response(message))).status();
      expect(status.enrolled, isFalse);
      expect(status.referenceName, isNull);
      expect(status.referenceUrl, isNull);
    },
  );

  for (final field in ['name', 'file_url', 'version']) {
    test('incomplete enrolled reference missing $field is rejected', () async {
      final message = statusMessage();
      (message['reference_file'] as Map).remove(field);
      final api = apiWith(MockClient((_) async => response(message)));
      await expectLater(
        api.status(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('incomplete'),
          ),
        ),
      );
    });
  }

  final invalidStatus = <String, Map<String, dynamic>>{
    'wrong identity':
        statusMessage()..['current_user'] = 'someoneelse@example.test',
    'wrong model': statusMessage()..['model_version'] = 'different-model',
    'missing token': statusMessage()..remove('csrf_token'),
    'empty token': statusMessage()..['csrf_token'] = '',
    'missing threshold': statusMessage()..remove('minimum_similarity'),
    'zero threshold': statusMessage()..['minimum_similarity'] = 0,
    'negative threshold': statusMessage()..['minimum_similarity'] = -0.1,
    'too high threshold': statusMessage()..['minimum_similarity'] = 1.01,
    'nonfinite threshold': statusMessage()..['minimum_similarity'] = 'NaN',
  };
  for (final entry in invalidStatus.entries) {
    test('rejects ${entry.key} in server status', () async {
      final api = apiWith(MockClient((_) async => response(entry.value)));
      await expectLater(api.status(), throwsA(isA<StateError>()));
    });
  }

  test('invalid JSON and non-map message are rejected', () async {
    for (final body in ['<html>Proxy error</html>', '{"message":[]}', '{}']) {
      final api = apiWith(MockClient((_) async => http.Response(body, 200)));
      await expectLater(api.status(), throwsA(isA<StateError>()));
    }
  });

  test('expired session prevents any network request', () async {
    var requests = 0;
    final api = apiWith(
      MockClient((_) async {
        requests++;
        return response(statusMessage());
      }),
      sid: () async => null,
    );
    await expectLater(api.status(), throwsA(isA<StateError>()));
    expect(requests, 0);
  });

  test(
    'private reference download sends only same-origin session and disables redirects',
    () async {
      final api = apiWith(
        MockClient((request) async {
          expect(
            request.url,
            Uri.parse('https://erp.example.test/private/files/reference.jpg'),
          );
          expect(request.headers['cookie'], 'sid=face-session');
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(jpeg, 200);
        }),
      );
      expect(await api.downloadReference(enrolledStatus()), jpeg);
    },
  );

  for (final url in [
    'https://other.example.test/private/files/reference.jpg',
    'http://erp.example.test/private/files/reference.jpg',
    '//other.example.test/private/files/reference.jpg',
    '/files/public-reference.jpg',
    '/private/files/../../api/method/other',
  ]) {
    test(
      'rejects invalid private reference $url before sending credentials',
      () async {
        var requests = 0;
        final api = apiWith(
          MockClient((_) async {
            requests++;
            return http.Response.bytes(jpeg, 200);
          }),
        );
        await expectLater(
          api.downloadReference(enrolledStatus(url: url)),
          throwsA(isA<StateError>()),
        );
        expect(requests, 0);
      },
    );
  }

  test(
    'private download rejects redirects, error pages, and oversized images',
    () async {
      final tooLarge =
          Uint8List(2 * 1024 * 1024 + 1)
            ..[0] = 0xff
            ..[1] = 0xd8;
      for (final reply in [
        http.Response(
          '',
          302,
          headers: {'location': 'https://other.example.test/stolen.jpg'},
        ),
        http.Response('Access denied', 403),
        http.Response('Not a JPEG', 200),
        http.Response.bytes([0xff, 0xd8], 200),
        http.Response.bytes(tooLarge, 200),
      ]) {
        final api = apiWith(MockClient((_) async => reply));
        await expectLater(
          api.downloadReference(enrolledStatus()),
          throwsA(isA<StateError>()),
        );
      }
    },
  );

  test(
    'account switch prevents enrollment, evidence submission, and reference download',
    () async {
      var requests = 0;
      final api = apiWith(
        MockClient((_) async {
          requests++;
          return response(statusMessage());
        }),
        user: () async => 'changed@example.test',
      );
      for (final operation in <Future<Object?> Function()>[
        () => api.enroll(enrolledStatus(), jpeg),
        () => verify(api),
        () => api.downloadReference(enrolledStatus()),
      ]) {
        await expectLater(
          operation(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('account changed'),
            ),
          ),
        );
      }
      expect(requests, 0);
    },
  );

  test(
    'enrollment posts a session-bound JPEG and returns the saved reference',
    () async {
      final api = apiWith(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['cookie'], 'sid=face-session');
          expect(request.headers['x-frappe-csrf-token'], 'face-csrf');
          expect(
            request.headers['content-type'],
            startsWith('application/json'),
          );
          final body = jsonDecode(request.body) as Map;
          expect(body, {
            'action': 'enroll',
            'image_base64': base64Encode(jpeg),
            'model_version': FaceAuthApi.modelVersion,
            'blink_completed': true,
            'csrf_token': 'face-csrf',
          });
          return response(statusMessage());
        }),
      );
      final missing = FaceEnrollmentStatus(
        currentUser: account,
        csrfToken: 'face-csrf',
        minimumSimilarity: 0.5,
      );
      expect((await api.enroll(missing, jpeg)).enrolled, isTrue);
    },
  );

  test(
    'event actions are rejected before creating face-verification requests',
    () async {
      var requests = 0;
      final api = apiWith(
        MockClient((_) async {
          requests++;
          return response({});
        }),
      );

      await expectLater(
        verify(api, action: 'event_in'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        verify(api, action: 'event_out'),
        throwsA(isA<ArgumentError>()),
      );
      expect(requests, 0);
    },
  );

  test(
    'attendance sends no image and requires a versioned ERP receipt',
    () async {
      for (final missing in ['record_id', 'receipt_version']) {
        final api = apiWith(
          MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            expect(body['verification_action'], 'attendance_in');
            expect(body['include_timings'], isTrue);
            expect(body.containsKey('event'), isFalse);
            expect(body.containsKey('image_base64'), isFalse);
            final message = {
              'current_user': account,
              'record_id': 'FACE-LOG-1',
              'receipt_version': 2,
            }..remove(missing);
            return response(message);
          }),
        );
        await expectLater(
          verify(api),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('ERP did not'),
            ),
          ),
        );
      }
    },
  );

  test(
    'old server capability blocks metadata submission without uploading',
    () async {
      var posts = 0;
      final api = apiWith(
        MockClient((request) async {
          if (request.method == 'POST') posts++;
          return response(
            statusMessage()..remove('verification_receipt_version'),
          );
        }),
      );
      final status = await api.status();
      await expectLater(
        api.recordVerification(
          status: status,
          action: 'attendance_in',
          similarity: 0.87,
          latitude: 13,
          longitude: 80,
          capturedOn: DateTime.now(),
        ),
        throwsStateError,
      );
      expect(posts, 0);
    },
  );

  test('Frappe server messages produce plain useful popup text', () async {
    final api = apiWith(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            '_server_messages': jsonEncode([
              jsonEncode({'message': '<b>Face enrollment is locked.</b>'}),
            ]),
          }),
          403,
        ),
      ),
    );
    await expectLater(
      api.status(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Face enrollment is locked.',
        ),
      ),
    );
  });

  test(
    'plain server errors and unknown errors retain useful fallback messages',
    () async {
      for (final entry in [
        ({'message': '<p>Try again later.</p>'}, 'Try again later.'),
        (<String, dynamic>{}, 'Face verification request failed (503).'),
        (
          {
            'exc_type': 'TypeError',
            'exception':
                'Traceback (most recent call last):\n'
                '  File "private/path.py", line 10\n'
                "TypeError: 'NoneType' object is not callable",
          },
          'ERP server error (TypeError): '
              "TypeError: 'NoneType' object is not callable. "
              'Check the Frappe server logs for this request.',
        ),
        (
          {'_server_messages': 'malformed'},
          'Face verification request failed (503).',
        ),
      ]) {
        final api = apiWith(
          MockClient((_) async => http.Response(jsonEncode(entry.$1), 503)),
        );
        await expectLater(
          api.status(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              entry.$2,
            ),
          ),
        );
      }
    },
  );
}
