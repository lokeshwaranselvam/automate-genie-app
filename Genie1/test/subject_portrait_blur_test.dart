import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:homegenie/utils/face/portrait_blur_image.dart';
import 'package:homegenie/utils/face/portrait_blur_service.dart';
import 'package:image/image.dart' as img;

import 'portrait_blur_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const face = PortraitFaceRegion(.4, .3, .6, .6);
  PortraitSubjectMask mainPerson() =>
      PortraitSubjectMask(35, 20, 40, 80, List.filled(3200, 1));
  PortraitSubjectMask background() =>
      PortraitSubjectMask(0, 0, 35, 100, List.filled(3500, 1));
  int alpha(PortraitMatte matte, int x, int y) =>
      matte.rgba[(y * matte.width + x) * 4 + 3];

  test('selects the main face mask instead of a larger background subject', () {
    for (final subjects in [
      [background(), mainPerson()],
      [mainPerson(), background()],
    ]) {
      final matte =
          buildSubjectPortraitMatte(
            PortraitSubjectInput(100, 100, subjects, face),
          )!;
      expect(alpha(matte, 50, 45), 255);
      expect(alpha(matte, 50, 90), 255);
      expect(alpha(matte, 10, 45), 0);
      expect(alpha(matte, 90, 90), 0);
    }
  });

  test('bounding rectangle alone cannot select an unrelated subject', () {
    final empty = PortraitSubjectMask(0, 0, 100, 100, List.filled(10000, 0));
    final matte =
        buildSubjectPortraitMatte(
          PortraitSubjectInput(100, 100, [empty, mainPerson()], face),
        )!;
    expect(alpha(matte, 50, 45), 255);
    expect(alpha(matte, 10, 45), 0);
  });

  test(
    'empty, malformed, low-confidence and competing face masks use fallback',
    () {
      for (final subjects in <List<PortraitSubjectMask>>[
        [],
        [const PortraitSubjectMask(0, 0, 10, 10, [])],
        [PortraitSubjectMask(0, 0, 100, 100, List.filled(10000, .3))],
        [mainPerson(), mainPerson()],
        [background()],
      ]) {
        expect(
          buildSubjectPortraitMatte(
            PortraitSubjectInput(100, 100, subjects, face),
          ),
          isNull,
        );
      }
    },
  );

  test('merged subject mask still excludes a detected background head', () {
    final merged = PortraitSubjectMask(0, 0, 100, 100, List.filled(10000, 1));
    final matte =
        buildSubjectPortraitMatte(
          PortraitSubjectInput(
            100,
            100,
            [merged],
            face,
            backgroundFaces: const [PortraitFaceRegion(.1, .3, .29, .6)],
          ),
        )!;
    expect(alpha(matte, 18, 40), 0);
    expect(alpha(matte, 50, 45), 255);
  });

  test('large cropped masks map into the full frame with bounded memory', () {
    final mask = PortraitSubjectMask(
      400,
      200,
      400,
      760,
      List.filled(304000, 1),
    );
    final matte =
        buildSubjectPortraitMatte(
          PortraitSubjectInput(1280, 960, [mask], face),
        )!;
    expect([matte.width, matte.height], [640, 480]);
    expect(alpha(matte, 320, 216), 255);
    expect(alpha(matte, 50, 216), 0);
    expect(alpha(matte, 320, 440), 255);
  });

  const faces = MethodChannel('google_mlkit_face_detector');
  const subjects = MethodChannel('google_mlkit_subject_segmentation');
  const selfies = MethodChannel('google_mlkit_selfie_segmenter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(
      faces,
      (call) async => call.method.contains('close') ? null : [fixture.faceJson],
    );
  });
  tearDown(() {
    for (final channel in [faces, subjects, selfies]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  Map<String, Object> nativeSubject() => {
    'subjects': [
      {
        'startX': 20,
        'startY': 20,
        'width': 40,
        'height': 60,
        'confidenceMask': Float32List.fromList(List.filled(2400, 1)),
      },
    ],
  };

  test(
    'Android photo uses per-subject masks without requesting combined foreground',
    () async {
      var starts = 0, closes = 0, selfieCalls = 0;
      messenger.setMockMethodCallHandler(subjects, (call) async {
        if (call.method.contains('close')) {
          closes++;
          return null;
        }
        starts++;
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['enableForegroundConfidenceMask'], isFalse);
        expect(options['enableForegroundBitmap'], isFalse);
        expect(
          (options['enableMultiSubjectBitmap'] as Map)['enableConfidenceMask'],
          isTrue,
        );
        return nativeSubject();
      });
      messenger.setMockMethodCallHandler(selfies, (_) async {
        selfieCalls++;
        return null;
      });
      await fixture.withPhoto((original) async {
        final service = PortraitBlurService(subjectSegmentationSupported: true);
        final detector = FaceDetector(options: FaceDetectorOptions());
        File? output;
        try {
          output = await service.blurAcceptedPhoto(original, detector);
          expect(output.path, isNot(original.path));
          expect(img.decodePng(await output.readAsBytes()), isNotNull);
          expect(starts, 1);
          expect(selfieCalls, 0);
        } finally {
          if (output != null && output.path != original.path) {
            await output.delete();
          }
          await service.close();
          await detector.close();
        }
        expect(closes, 1);
      });
    },
  );

  test(
    'model download failure preserves the existing local photo blur',
    () async {
      var selfieStarts = 0;
      messenger.setMockMethodCallHandler(subjects, (call) async {
        if (call.method.contains('close')) return null;
        throw PlatformException(code: 'model_downloading');
      });
      messenger.setMockMethodCallHandler(selfies, (call) async {
        if (call.method.contains('close')) return null;
        selfieStarts++;
        return {
          'width': 10,
          'height': 10,
          'confidences': List.filled(100, 1.0),
        };
      });
      await fixture.withPhoto((original) async {
        final service = PortraitBlurService(subjectSegmentationSupported: true);
        final detector = FaceDetector(options: FaceDetectorOptions());
        File? output;
        try {
          output = await service.blurAcceptedPhoto(original, detector);
          expect(output.path, isNot(original.path));
          expect(selfieStarts, 1);
        } finally {
          if (output != null && output.path != original.path) {
            await output.delete();
          }
          await service.close();
          await detector.close();
        }
      });
    },
  );

  test(
    'warm-up runs once and completes before the accepted photo is segmented',
    () async {
      final warmUp = Completer<Map<String, Object>>();
      var starts = 0, closes = 0;
      messenger.setMockMethodCallHandler(subjects, (call) async {
        if (call.method.contains('close')) {
          closes++;
          return null;
        }
        starts++;
        return starts == 1 ? warmUp.future : nativeSubject();
      });
      final service = PortraitBlurService(subjectSegmentationSupported: true);
      service.warmUpPhotoSegmentation(InputImage.fromFilePath('live-frame'));
      service.warmUpPhotoSegmentation(InputImage.fromFilePath('next-frame'));
      await fixture.withPhoto((original) async {
        final detector = FaceDetector(options: FaceDetectorOptions());
        File? output;
        try {
          final pending = service.blurAcceptedPhoto(original, detector);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(starts, 1);
          warmUp.complete(nativeSubject());
          output = await pending;
          expect(output.path, isNot(original.path));
          expect(starts, 2);
        } finally {
          if (!warmUp.isCompleted) warmUp.complete(nativeSubject());
          if (output != null && output.path != original.path) {
            await output.delete();
          }
          await service.close();
          await detector.close();
        }
        expect(closes, 1);
      });
    },
  );
}
