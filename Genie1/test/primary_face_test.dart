import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:homegenie/utils/face/face_blink_controller.dart';
import 'package:homegenie/utils/face/face_embedding_service.dart';
import 'package:homegenie/utils/face/primary_face.dart';

Face person(Rect bounds, {int id = 1, double eyes = 1}) => Face(
  boundingBox: bounds,
  landmarks: {},
  contours: {},
  trackingId: id,
  leftEyeOpenProbability: eyes,
  rightEyeOpenProbability: eyes,
  headEulerAngleX: 0,
  headEulerAngleY: 0,
  headEulerAngleZ: 0,
);

void main() {
  final primary = person(const Rect.fromLTWH(280, 250, 400, 440));
  final background = person(const Rect.fromLTWH(60, 300, 180, 220), id: 2);

  test(
    'selects the dominant main person regardless of detector return order',
    () {
      for (final faces in [
        [primary, background],
        [background, primary],
      ]) {
        expect(selectPrimaryFace(faces, 1000, 1000), same(primary));
      }
    },
  );

  test('single-face captures retain their existing positioning validation', () {
    final offCenter = person(const Rect.fromLTWH(0, 0, 150, 150));
    expect(selectPrimaryFace([offCenter], 1000, 1000), same(offCenter));
    expect(selectPrimaryFace([], 1000, 1000), isNull);
  });

  test('two similarly close people remain ambiguous', () {
    final peer = person(const Rect.fromLTWH(680, 250, 300, 400), id: 2);
    expect(selectPrimaryFace([primary, peer], 1000, 1000), isNull);
  });

  test('a competing face over the main face cannot be selected away', () {
    final overlap = person(const Rect.fromLTWH(300, 300, 180, 200), id: 2);
    expect(selectPrimaryFace([primary, overlap], 1000, 1000), isNull);
  });

  test(
    'a large face away from the guide cannot become the subject in a crowd',
    () {
      final side = person(const Rect.fromLTWH(0, 100, 400, 440));
      expect(selectPrimaryFace([side, background], 1000, 1000), isNull);
    },
  );

  test(
    'background eye motion cannot complete the main person blink challenge',
    () {
      final blink = FaceBlinkController();
      void sample(int time, double mainEyes, double otherEyes) {
        final faces = [
          person(background.boundingBox, id: 2, eyes: otherEyes),
          person(primary.boundingBox, eyes: mainEyes),
        ];
        final selected = selectPrimaryFace(faces, 1000, 1000)!;
        blink.observe(
          FaceBlinkSample(
            faceCount: 1,
            trackingId: selected.trackingId,
            leftEyeOpen: selected.leftEyeOpenProbability,
            rightEyeOpen: selected.rightEyeOpenProbability,
            yaw: selected.headEulerAngleY,
            pitch: selected.headEulerAngleX,
            faceFraction: .4,
            centerOffset: .05,
            brightness: 100,
          ),
          Duration(milliseconds: time),
        );
      }

      sample(0, 1, 1);
      sample(100, 1, 1);
      sample(200, 1, 1);
      sample(300, 1, 0);
      sample(400, 1, 1);
      sample(500, 1, 1);
      expect(blink.progress.canCapture, isFalse);
      sample(600, 0, 1);
      sample(700, 1, 1);
      sample(800, 1, 1);
      expect(blink.progress.canCapture, isTrue);
    },
  );

  test('main subject still has to pass final-photo eye and pose checks', () {
    final selected =
        selectPrimaryFace(
          [background, person(primary.boundingBox, eyes: .5)],
          1000,
          1000,
        )!;
    expect(
      () => FaceEmbeddingService.validateFaceQuality(
        selected,
        1000,
        1000,
        validateCapture: true,
      ),
      throwsA(isA<FaceEmbeddingException>()),
    );
  });
}
