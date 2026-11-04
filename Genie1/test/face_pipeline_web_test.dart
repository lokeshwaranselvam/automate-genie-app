@TestOn('browser')
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:homegenie/utils/api/face_auth_api.dart';
import 'package:homegenie/utils/face/face_auth_flow.dart';
import 'package:homegenie/utils/face/face_embedding_service_web.dart';
import 'package:homegenie/utils/face/face_template_cache.dart';
import 'package:homegenie/utils/platform/platform_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;

const user = 'employee@example.test';
List<double> vector(int axis) => List.generate(128, (i) => i == axis ? 1 : 0);
Map<String, dynamic> status() => {
  'current_user': user,
  'model_version': FaceAuthApi.modelVersion,
  'minimum_similarity': .5,
  'verification_receipt_version': 2,
  'csrf_token': 'csrf',
  'enrolled': true,
  'reference_file': {
    'name': 'FACE-1',
    'file_url': '/private/files/face.jpg',
    'version': 'v1',
  },
};
Map<String, dynamic> geometry() => {
  'faceCount': 1,
  'left': 100,
  'right': 300,
  'top': 100,
  'bottom': 350,
  'yaw': 0,
  'pitch': 0,
  'roll': 0,
  'leftEyeOpen': .8,
  'rightEyeOpen': .8,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'capture rejects missing/extra faces, clipped faces, pose and closed eyes',
    () {
      for (final change in [
        {'faceCount': 0},
        {'faceCount': 2},
        {'left': -1},
        {'right': 150},
        {'yaw': 21},
        {'pitch': double.nan},
        {'roll': null},
        {'leftEyeOpen': .64},
        {'rightEyeOpen': null},
      ]) {
        expect(
          () => FaceEmbeddingService.validateFace(
            {...geometry(), ...change},
            640,
            480,
            capture: true,
          ),
          throwsA(isA<FaceEmbeddingException>()),
        );
      }
      expect(
        () => FaceEmbeddingService.validateFace(
          geometry(),
          640,
          480,
          capture: true,
        ),
        returnsNormally,
      );
      expect(
        () => FaceEmbeddingService.validateFace(
          {...geometry(), 'leftEyeOpen': .6},
          640,
          480,
          capture: false,
        ),
        returnsNormally,
      );
    },
  );
  test('blur and poor lighting never produce a usable template', () {
    for (final brightness in [0, 127, 255]) {
      final flat = image.Image(width: 112, height: 112);
      image.fill(
        flat,
        color: image.ColorRgb8(brightness, brightness, brightness),
      );
      expect(
        () => FaceEmbeddingService.checkImageQuality(flat),
        throwsA(isA<FaceEmbeddingException>()),
      );
    }
  });
  test(
    'browser templates stay in memory, are account-bound and invalidated on clear',
    () async {
      final cache = FaceTemplateCache();
      final generation = cache.generation;
      await cache.write('account-a', vector(0), expectedGeneration: generation);
      expect(await cache.read('account-a'), vector(0));
      expect(
        await const FlutterSecureStorage().read(
          key: 'genie_private_face_template_v1',
        ),
        isNull,
      );
      expect(await FaceTemplateCache().read('account-a'), isNull);
      expect(await cache.read('account-b'), isNull);
      await cache.clear();
      await cache.write('account-a', vector(0), expectedGeneration: generation);
      expect(await cache.read('account-a'), isNull);
    },
  );
  for (final redirected in [false, true]) {
    test(
      'browser Desk bootstrap validates final origin: $redirected',
      () async {
        final api = FaceAuthApi(
          site: Uri.parse('https://erp.example.test/'),
          savedUser: () async => user,
          sessionId: () async => 'browser-session',
          client: _DeskClient(redirected),
        );
        if (redirected) {
          await expectLater(api.status(), throwsStateError);
        } else {
          expect((await api.status()).csrfToken, 'desk-csrf');
        }
      },
    );
  }
  testWidgets(
    'browser enrollment uploads a private reference using the existing contract',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        var captures = 0, posts = 0;
        final api = FaceAuthApi(
          site: Uri.parse('https://erp.example.test/'),
          savedUser: () async => user,
          sessionId: () async => 'browser-session',
          client: MockClient((request) async {
            posts++;
            final body = jsonDecode(request.body) as Map;
            expect(body['action'], 'enroll');
            expect(body['blink_completed'], isTrue);
            expect(body['model_version'], FaceAuthApi.modelVersion);
            expect(body['csrf_token'], 'csrf');
            expect(
              image.decodeJpg(base64Decode(body['image_base64'] as String)),
              isNotNull,
            );
            return http.Response(jsonEncode({'message': status()}), 200);
          }),
        );
        final photo = await File(
          '/memory/enrollment.jpg',
        ).writeAsBytes(image.encodeJpg(image.Image(width: 160, height: 160)));
        final flow = FaceAuthFlow(
          api: api,
          cache: FaceTemplateCache(),
          embed: (_) async {
            captures++;
            return vector(0);
          },
          capture: (_, _, validate) async {
            expect(await validate(photo), isNull);
            return photo;
          },
        );
        final result = await flow.enroll(
          context,
          const FaceEnrollmentStatus(
            currentUser: user,
            csrfToken: 'csrf',
            minimumSimilarity: .5,
          ),
        );
        expect(result!.enrolled, isTrue);
        expect(captures, 1);
        expect(posts, 1);
        expect(await photo.exists(), isFalse);
      });
    },
  );
  for (final scenario in [
    'attendance_in',
    'attendance_out',
    'mismatch',
    'cancel',
    'gps-failure',
    'account-change',
  ]) {
    testWidgets('browser face flow preserves ERP contract: $scenario', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        final posts = <Map<String, dynamic>>[];
        var activeUser = user, locationReads = 0;
        final api = FaceAuthApi(
          site: Uri.parse('https://erp.example.test/'),
          savedUser: () async => activeUser,
          sessionId: () async => 'browser-session',
          client: MockClient((request) async {
            expect(request.headers.containsKey('cookie'), isFalse);
            if (request.url.path.startsWith('/private/')) {
              return http.Response.bytes([255, 216, 255, 217], 200);
            }
            if (request.method == 'POST') {
              expect(request.headers['X-Frappe-CSRF-Token'], 'csrf');
              posts.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response(
                jsonEncode({
                  'message': {
                    'current_user': user,
                    'receipt_version': 2,
                    'record_id': 'RECEIPT-1',
                  },
                }),
                200,
              );
            }
            return http.Response(jsonEncode({'message': status()}), 200);
          }),
        );
        final photo = await File(
          '/memory/test/selfie-$scenario.jpg',
        ).writeAsBytes([255, 216, 255, 217]);
        final flow = FaceAuthFlow(
          api: api,
          cache: FaceTemplateCache(),
          embed: (_) async => vector(0),
          captureEmbed: (_) async => vector(scenario == 'mismatch' ? 1 : 0),
          warmUp: () async {},
          capture: (_, _, validate) async {
            if (scenario == 'cancel') return null;
            if (scenario == 'account-change') {
              activeUser = 'another@example.test';
            }
            final error = await validate(photo);
            if (scenario == 'mismatch' || scenario == 'account-change') {
              expect(error, isNotNull);
              return null;
            }
            expect(error, isNull);
            return photo;
          },
        );
        final result = flow.verify(
          context: context,
          action:
              scenario == 'attendance_out' ? 'attendance_out' : 'attendance_in',
          refreshLocation: () async {
            locationReads++;
            if (scenario == 'gps-failure') {
              throw StateError('Outside allowed geofence');
            }
            return (
              position: Position(
                latitude: 13,
                longitude: 80,
                timestamp: DateTime.now(),
                accuracy: 5,
                altitude: 0,
                altitudeAccuracy: 0,
                heading: 0,
                headingAccuracy: 0,
                speed: 0,
                speedAccuracy: 0,
              ),
              address: 'Fresh GPS',
            );
          },
        );
        if (scenario == 'gps-failure') {
          await expectLater(result, throwsStateError);
          expect(posts, isEmpty);
        } else if ([
          'mismatch',
          'cancel',
          'account-change',
        ].contains(scenario)) {
          expect(await result, isNull);
          expect(posts, isEmpty);
          expect(locationReads, 0);
        } else {
          expect((await result)!.recordId, 'RECEIPT-1');
          expect(locationReads, 1);
          expect(posts, hasLength(1));
          final body = posts.single;
          expect(body['action'], 'record_verification');
          expect(body['verification_action'], scenario);
          expect(body['model_version'], FaceAuthApi.modelVersion);
          expect(body['blink_completed'], isTrue);
          expect(body['reference_file'], 'FACE-1');
          expect(body['reference_version'], 'v1');
          expect(body['similarity'], 1);
          expect(body['latitude'], 13);
          expect(body['longitude'], 80);
          expect(body.containsKey('image_base64'), isFalse);
        }
        if (await photo.exists()) await photo.delete();
      });
    });
  }
}

class _DeskClient extends http.BaseClient {
  _DeskClient(this.redirected);
  final bool redirected;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.headers.containsKey('cookie'), isFalse);
    if (request.url.path == '/app') {
      expect(request.followRedirects, isTrue);
      return _FinalResponse(
        'frappe.csrf_token = "desk-csrf";',
        request,
        Uri.parse(
          redirected
              ? 'https://other.example.test/app'
              : 'https://erp.example.test/app/home',
        ),
      );
    }
    expect(request.followRedirects, isFalse);
    return _FinalResponse(
      jsonEncode({
        'message': {...status(), 'csrf_token': ''},
      }),
      request,
      request.url,
    );
  }
}

class _FinalResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _FinalResponse(String body, http.BaseRequest request, this.url)
    : super(Stream.value(utf8.encode(body)), 200, request: request);
  @override
  final Uri url;
}
