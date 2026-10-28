import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:homegenie/Screen/face_capture_page.dart';
import 'package:homegenie/utils/api/face_auth_api.dart';
import 'package:homegenie/utils/face/face_auth_flow.dart';
import 'package:homegenie/utils/face/face_embedding_service.dart';
import 'package:homegenie/utils/face/face_image_quality.dart';
import 'package:homegenie/utils/face/face_template_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;

import 'face_auth_api_test.dart' as fixture;

Position position(double latitude, double longitude) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: DateTime.now(),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

FaceLocation location() => (
  position: position(13.0827, 80.2707),
  address: 'Fresh address',
);

class FakeFaceGps extends GeolocatorPlatform {
  Position current;
  var reads = 0;
  FakeFaceGps(this.current);

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    expect(locationSettings!.accuracy, LocationAccuracy.high);
    expect(locationSettings.timeLimit, const Duration(seconds: 15));
    reads++;
    return current;
  }
}

class FlowHarness {
  final requests = <http.Request>[];
  final cache = FaceTemplateCache(storage: fixture.MemoryFaceStorage());
  late final FaceAuthApi api;
  Future<http.Response> Function()? onReference;
  Map<String, dynamic> status = fixture.statusMessage();

  FlowHarness() {
    api = fixture.apiWith(
      MockClient((request) async {
        requests.add(request);
        if (request.url.path.startsWith('/private/files/')) {
          return onReference == null
              ? http.Response.bytes(fixture.jpeg, 200)
              : onReference!();
        }
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map;
          expect(body['action'], 'record_verification');
          expect(body['blink_completed'], isTrue);
          expect(body.containsKey('image_base64'), isFalse);
          expect(body.containsKey('photo_url'), isFalse);
          expect(body['model_version'], FaceAuthApi.modelVersion);
          return fixture.response({
            'current_user': fixture.account,
            'record_id': 'RECEIPT-1',
            'receipt_version': 2,
          });
        }
        return fixture.response(status);
      }),
    );
  }

  Iterable<http.Request> get posts =>
      requests.where((request) => request.method == 'POST');

  Future<void> primeTemplate() => cache.write(
    jsonEncode([
      api.site.toString(),
      fixture.account,
      'FACE-REFERENCE-1',
      'reference-version-1',
      FaceAuthApi.modelVersion,
    ]),
    fixture.embedding(),
  );
}

Future<void> withPhoto(
  WidgetTester tester,
  Future<void> Function(BuildContext, File) check,
) async {
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
  try {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'genie-face-performance-',
      );
      final photo = await File(
        '${directory.path}/selfie.jpg',
      ).writeAsBytes(fixture.jpeg);
      try {
        await check(context, photo);
      } finally {
        if (await photo.exists()) await photo.delete();
        // Only remove this test's now-empty, individually created directory.
        await directory.delete();
      }
    });
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
  }
}

void main() {
  for (final action in ['enroll', 'attendance_in', 'attendance_out']) {
    testWidgets(
      '$action camera retains main-person selection and raw-photo validation',
      (tester) async {
        const channel = MethodChannel('google_mlkit_face_detector');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final harness = FlowHarness();
        await harness.primeTemplate();
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
        final flow = FaceAuthFlow(
          api: harness.api,
          cache: harness.cache,
          embed: (_) async => fixture.embedding(),
          warmUp: () async {},
        );
        final pending =
            action == 'enroll'
                ? flow.enroll(
                  context,
                  const FaceEnrollmentStatus(
                    currentUser: fixture.account,
                    csrfToken: 'face-csrf',
                    minimumSimilarity: .5,
                  ),
                )
                : flow.verify(
                  context: context,
                  action: action,
                  refreshLocation: () async => location(),
                );
        await tester.pumpAndSettle();
        final page = tester.widget<FaceCapturePage>(
          find.byType(FaceCapturePage),
        );
        expect(page.usePrimaryFaceSelection, isTrue);
        expect(page.validatePhotoInCallback, isTrue);
        expect(page.validateCapture, isNotNull);
        Navigator.of(tester.element(find.byType(FaceCapturePage))).pop();
        await tester.pumpAndSettle();
        expect(await pending, isNull);
        expect(harness.posts, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('camera opens while the cold reference is still being prepared', (
    tester,
  ) async {
    await withPhoto(tester, (context, photo) async {
      final harness = FlowHarness();
      final reference = Completer<http.Response>();
      final cameraOpened = Completer<void>();
      harness.onReference = () => reference.future;
      var modelPreparation = 0;
      final flow = FaceAuthFlow(
        api: harness.api,
        cache: harness.cache,
        warmUp: () async {
          modelPreparation++;
        },
        embed: (_) async => fixture.embedding(),
        capture: (_, _, validate) async {
          cameraOpened.complete();
          expect(reference.isCompleted, isFalse);
          expect(await validate(photo), isNull);
          return null;
        },
      );
      final result = flow.verify(
        context: context,
        action: 'attendance_in',
        refreshLocation: () async => location(),
      );
      await cameraOpened.future;
      expect(modelPreparation, 1);
      reference.complete(http.Response.bytes(fixture.jpeg, 200));
      expect(await result, isNull);
      expect(harness.posts, isEmpty);
    });
  });

  testWidgets(
    'outside Head Office matching and GPS overlap; receipt waits for both',
    (tester) async {
      await withPhoto(tester, (context, photo) async {
        final harness = FlowHarness();
        await harness.primeTemplate();
        final matching = Completer<List<double>>();
        final gps = Completer<FaceLocation>();
        final matchStarted = Completer<void>();
        final gpsStarted = Completer<void>();
        final flow = FaceAuthFlow(
          api: harness.api,
          cache: harness.cache,
          embed: (_) async {
            matchStarted.complete();
            return matching.future;
          },
          capture: (_, _, validate) async {
            expect(await validate(photo), isNull);
            return photo;
          },
        );
        final result = flow.verify(
          context: context,
          action: 'attendance_in',
          overlapLocationWithMatching: true,
          refreshLocation: () async {
            gpsStarted.complete();
            return gps.future;
          },
        );
        await matchStarted.future;
        await gpsStarted.future;
        expect(matching.isCompleted, isFalse);
        expect(gps.isCompleted, isFalse);
        expect(harness.posts, isEmpty);
        matching.complete(fixture.embedding());
        await Future<void>.delayed(Duration.zero);
        expect(harness.posts, isEmpty);
        gps.complete(location());
        final verified = await result;
        expect(verified!.recordId, 'RECEIPT-1');
        expect(harness.posts.length, 1);
        final body = jsonDecode(harness.posts.single.body) as Map;
        expect(body['latitude'], location().position.latitude);
        expect(body['longitude'], location().position.longitude);
        expect(body['reference_version'], 'reference-version-1');
        expect(await photo.exists(), isFalse);
      });
    },
  );

  testWidgets(
    'Head Office checks GPS after matching and blocks a moved-outside employee',
    (tester) async {
      await withPhoto(tester, (context, photo) async {
        final harness = FlowHarness();
        await harness.primeTemplate();
        final matching = Completer<List<double>>();
        final matchStarted = Completer<void>();
        var gpsCalls = 0;
        final flow = FaceAuthFlow(
          api: harness.api,
          cache: harness.cache,
          embed: (_) async {
            matchStarted.complete();
            return matching.future;
          },
          capture: (_, _, validate) async {
            expect(await validate(photo), isNull);
            return photo;
          },
        );
        final result = flow.verify(
          context: context,
          action: 'attendance_out',
          overlapLocationWithMatching: false,
          refreshLocation: () async {
            gpsCalls++;
            expect(matching.isCompleted, isTrue);
            throw StateError('You are outside the 100 m geofence!');
          },
        );
        await matchStarted.future;
        expect(gpsCalls, 0);
        final rejected = expectLater(
          result,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('100 m geofence'),
            ),
          ),
        );
        matching.complete(fixture.embedding());
        await rejected;
        expect(gpsCalls, 1);
        expect(harness.posts, isEmpty);
        expect(await photo.exists(), isFalse);
      });
    },
  );

  testWidgets('wrong face with a concurrent GPS error never uploads evidence', (
    tester,
  ) async {
    await withPhoto(tester, (context, photo) async {
      final harness = FlowHarness();
      await harness.primeTemplate();
      String? rejection;
      var gpsCalls = 0;
      final flow = FaceAuthFlow(
        api: harness.api,
        cache: harness.cache,
        embed: (_) async => fixture.embedding(axis: 1),
        capture: (_, _, validate) async {
          rejection = await validate(photo);
          return null;
        },
      );
      expect(
        await flow.verify(
          context: context,
          action: 'attendance_in',
          overlapLocationWithMatching: true,
          refreshLocation: () async {
            gpsCalls++;
            throw StateError('GPS unavailable');
          },
        ),
        isNull,
      );
      expect(rejection, contains('does not match'));
      expect(gpsCalls, 1);
      expect(harness.posts, isEmpty);
    });
  });

  testWidgets(
    'cancelled camera observes failed reference preparation without uploading',
    (tester) async {
      await withPhoto(tester, (context, photo) async {
        final harness = FlowHarness();
        final reference = Completer<http.Response>();
        harness.onReference = () => reference.future;
        final flow = FaceAuthFlow(
          api: harness.api,
          cache: harness.cache,
          embed: (_) async => fixture.embedding(),
          capture: (_, _, _) async => null,
        );
        expect(
          await flow.verify(
            context: context,
            action: 'attendance_in',
            overlapLocationWithMatching: true,
            refreshLocation: () async {
              fail('Cancelled capture cannot fetch GPS.');
            },
          ),
          isNull,
        );
        reference.complete(http.Response('Reference unavailable', 403));
        await Future<void>.delayed(Duration.zero);
        expect(harness.posts, isEmpty);
      });
    },
  );

  testWidgets(
    'retry uses the accepted photo location and observes abandoned GPS errors',
    (tester) async {
      await withPhoto(tester, (context, photo) async {
        final harness = FlowHarness();
        await harness.primeTemplate();
        final abandonedGps = Completer<FaceLocation>();
        var attempts = 0;
        var gpsCalls = 0;
        final flow = FaceAuthFlow(
          api: harness.api,
          cache: harness.cache,
          embed: (_) async => fixture.embedding(axis: ++attempts == 1 ? 1 : 0),
          capture: (_, _, validate) async {
            expect(await validate(photo), contains('does not match'));
            expect(await validate(photo), isNull);
            abandonedGps.completeError(StateError('Old attempt GPS failed'));
            return photo;
          },
        );
        final verified = await flow.verify(
          context: context,
          action: 'attendance_in',
          overlapLocationWithMatching: true,
          refreshLocation:
              () async => ++gpsCalls == 1 ? abandonedGps.future : location(),
        );
        expect(verified!.address, 'Fresh address');
        expect(gpsCalls, 2);
        expect(harness.posts.length, 1);
      });
    },
  );

  testWidgets(
    'preparation shares an in-flight reference with scanning and still checks live status',
    (tester) async {
      await withPhoto(tester, (context, photo) async {
        final harness = FlowHarness();
        final reference = Completer<http.Response>();
        final referenceRequested = Completer<void>();
        final cameraOpened = Completer<void>();
        harness.onReference = () {
          referenceRequested.complete();
          return reference.future;
        };
        var referenceEmbeddings = 0;
        final flow = FaceAuthFlow(
          api: harness.api,
          cache: harness.cache,
          embed: (file) async {
            if (file.path.endsWith('reference.jpg')) referenceEmbeddings++;
            return fixture.embedding();
          },
          capture: (_, _, validate) async {
            cameraOpened.complete();
            expect(await validate(photo), isNull);
            return null;
          },
        );
        final preparation = flow.prepare();
        await referenceRequested.future;
        final verified = flow.verify(
          context: context,
          action: 'attendance_in',
          refreshLocation: () async => location(),
        );
        await cameraOpened.future;
        reference.complete(http.Response.bytes(fixture.jpeg, 200));
        await preparation;
        expect(await verified, isNull);
        expect(referenceEmbeddings, 1);
        expect(
          harness.requests
              .where(
                (request) => request.url.path.startsWith('/private/files/'),
              )
              .length,
          1,
        );
        expect(
          harness.requests
              .where(
                (request) => request.url.queryParameters['action'] == 'status',
              )
              .length,
          2,
        );
        expect(harness.posts, isEmpty);
      });
    },
  );

  test(
    'fresh GPS enforces the configured 100 m radius before address lookup',
    () async {
      final previous = GeolocatorPlatform.instance;
      final gps = FakeFaceGps(position(0.0008, 0)); // about 89 m north
      GeolocatorPlatform.instance = gps;
      dotenv.testLoad(fileInput: 'GOOGLE_MAPS_API_KEY=test');
      var addressCalls = 0;
      try {
        await http.runWithClient(
          () async {
            bool withinRadius(Position current) =>
                Geolocator.distanceBetween(
                  0,
                  0,
                  current.latitude,
                  current.longitude,
                ) <=
                100;
            final allowed = await FaceAuthFlow.freshLocation(
              isAllowed: withinRadius,
            );
            expect(allowed.address, 'Inside office');
            gps.current = position(0.001, 0); // about 111 m north
            await expectLater(
              FaceAuthFlow.freshLocation(isAllowed: withinRadius),
              throwsStateError,
            );
            expect(gps.reads, 2);
            expect(addressCalls, 1);
          },
          () => MockClient((_) async {
            addressCalls++;
            return http.Response(
              jsonEncode({
                'status': 'OK',
                'results': [
                  {'formatted_address': 'Inside office'},
                ],
              }),
              200,
            );
          }),
        );
      } finally {
        GeolocatorPlatform.instance = previous;
      }
    },
  );

  Face face({
    double eyes = 0.65,
    double yaw = 0,
    double pitch = 0,
    double roll = 0,
    Rect bounds = const Rect.fromLTWH(100, 100, 250, 250),
  }) => Face(
    boundingBox: bounds,
    landmarks: {},
    contours: {},
    headEulerAngleX: pitch,
    headEulerAngleY: yaw,
    headEulerAngleZ: roll,
    leftEyeOpenProbability: eyes,
    rightEyeOpenProbability: eyes,
  );

  test(
    'shared final-photo checks retain the stricter capture eye threshold',
    () {
      expect(
        () => FaceEmbeddingService.validateFaceQuality(
          face(eyes: 0.64),
          600,
          600,
          validateCapture: true,
        ),
        throwsA(isA<FaceEmbeddingException>()),
      );
      FaceEmbeddingService.validateFaceQuality(
        face(eyes: 0.65),
        600,
        600,
        validateCapture: true,
      );
      FaceEmbeddingService.validateFaceQuality(
        face(eyes: 0.55),
        600,
        600,
        validateCapture: false,
      );
      expect(
        () => FaceEmbeddingService.validateFaceQuality(
          face(eyes: 0.54),
          600,
          600,
          validateCapture: false,
        ),
        throwsA(isA<FaceEmbeddingException>()),
      );
    },
  );

  test(
    'shared final-photo checks still reject pose, undersized and cropped faces',
    () {
      for (final invalid in [
        face(yaw: 21),
        face(pitch: -21),
        face(roll: 21),
        face(bounds: const Rect.fromLTWH(100, 100, 111, 111)),
        face(bounds: const Rect.fromLTWH(-1, 100, 250, 250)),
      ]) {
        expect(
          () => FaceEmbeddingService.validateFaceQuality(
            invalid,
            600,
            600,
            validateCapture: true,
          ),
          throwsA(isA<FaceEmbeddingException>()),
        );
      }
    },
  );

  test(
    'center brightness uses the same region and luminance as standalone captures',
    () {
      final pixels = image.Image(width: 160, height: 160);
      image.fill(pixels, color: image.ColorRgb8(255, 255, 255));
      for (var y = 40; y < 120; y++) {
        for (var x = 40; x < 120; x++) {
          pixels.setPixelRgb(x, y, 30, 30, 30);
        }
      }
      expect(faceCenterBrightness(pixels), closeTo(30, 0.001));
    },
  );
}
