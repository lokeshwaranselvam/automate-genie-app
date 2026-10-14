import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/face/face_blink_controller.dart';

FaceBlinkSample sample({
  int faces = 1,
  double? left = 0.95,
  double? right = 0.95,
  double? yaw = 0,
  double? pitch = 0,
  double size = 0.5,
  double center = 0,
  double light = 100,
  int? id = 1,
}) => FaceBlinkSample(
  faceCount: faces,
  leftEyeOpen: left,
  rightEyeOpen: right,
  yaw: yaw,
  pitch: pitch,
  faceFraction: size,
  centerOffset: center,
  brightness: light,
  trackingId: id,
);

void openEyes(FaceBlinkController controller, {int start = 0, int id = 1}) {
  for (final offset in [0, 100, 200]) {
    controller.observe(sample(id: id), Duration(milliseconds: start + offset));
  }
}

void main() {
  test(
    'captures exactly after stable open, closed, and stable reopened eyes',
    () {
      final controller = FaceBlinkController()..reset(Duration.zero);
      openEyes(controller);
      expect(controller.progress.stage, FaceBlinkStage.blink);
      expect(controller.progress.canCapture, isFalse);
      controller.observe(
        sample(left: 0.1, right: 0.1),
        const Duration(milliseconds: 300),
      );
      expect(controller.progress.stage, FaceBlinkStage.reopenEyes);
      controller.observe(sample(), const Duration(milliseconds: 450));
      expect(controller.progress.stage, FaceBlinkStage.holdStill);
      controller.observe(sample(), const Duration(milliseconds: 550));
      expect(controller.progress.canCapture, isTrue);
      expect(
        controller
            .observe(sample(faces: 0), const Duration(milliseconds: 650))
            .canCapture,
        isTrue,
      );
    },
  );

  test('starting with closed eyes or winking never completes a blink', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    controller.observe(sample(left: 0.1, right: 0.1), Duration.zero);
    expect(controller.progress.stage, FaceBlinkStage.openEyes);
    openEyes(controller, start: 100);
    for (final time in [400, 500, 600]) {
      controller.observe(
        sample(left: 0.1, right: 0.95),
        Duration(milliseconds: time),
      );
    }
    controller.observe(sample(), const Duration(milliseconds: 700));
    expect(controller.progress.canCapture, isFalse);
    expect(controller.progress.stage, FaceBlinkStage.blink);
  });

  test('unknown eye probabilities reset a partially completed blink', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    openEyes(controller);
    controller.observe(
      sample(left: 0.1, right: 0.1),
      const Duration(milliseconds: 300),
    );
    controller.observe(sample(left: null), const Duration(milliseconds: 400));
    expect(controller.progress.stage, FaceBlinkStage.positionFace);
    controller.observe(sample(), const Duration(milliseconds: 500));
    controller.observe(sample(), const Duration(milliseconds: 600));
    expect(controller.progress.canCapture, isFalse);
  });

  for (final faces in [0, 2, 3]) {
    test('$faces faces reset the challenge before capture', () {
      final controller = FaceBlinkController()..reset(Duration.zero);
      openEyes(controller);
      controller.observe(
        sample(left: 0.1, right: 0.1),
        const Duration(milliseconds: 300),
      );
      controller.observe(
        sample(faces: faces),
        const Duration(milliseconds: 400),
      );
      controller.observe(sample(), const Duration(milliseconds: 500));
      controller.observe(sample(), const Duration(milliseconds: 600));
      expect(controller.progress.canCapture, isFalse);
    });
  }

  test('a different tracked face cannot finish another face blink', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    openEyes(controller);
    controller.observe(
      sample(left: 0.1, right: 0.1),
      const Duration(milliseconds: 300),
    );
    controller.observe(sample(id: 2), const Duration(milliseconds: 450));
    expect(controller.progress.stage, FaceBlinkStage.positionFace);
    controller.observe(sample(id: 2), const Duration(milliseconds: 550));
    expect(controller.progress.canCapture, isFalse);
  });

  test('long or unrealistically short eye closure requires another blink', () {
    for (final reopenedAt in [320, 1250]) {
      final controller = FaceBlinkController()..reset(Duration.zero);
      openEyes(controller);
      controller.observe(
        sample(left: 0.1, right: 0.1),
        const Duration(milliseconds: 300),
      );
      controller.observe(sample(), Duration(milliseconds: reopenedAt));
      expect(controller.progress.canCapture, isFalse);
      expect(controller.progress.stage, isNot(FaceBlinkStage.holdStill));
    }
  });

  test('a missing frame interval cannot bridge closed and reopened eyes', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    openEyes(controller);
    controller.observe(
      sample(left: 0.1, right: 0.1),
      const Duration(milliseconds: 300),
    );
    controller.observe(sample(), const Duration(milliseconds: 1000));
    controller.observe(sample(), const Duration(milliseconds: 1100));
    expect(controller.progress.canCapture, isFalse);
  });

  test('non-monotonic timestamps reset the challenge', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    openEyes(controller);
    controller.observe(
      sample(left: 0.1, right: 0.1),
      const Duration(milliseconds: 300),
    );
    controller.observe(sample(), const Duration(milliseconds: 250));
    expect(controller.progress.stage, FaceBlinkStage.positionFace);
    expect(controller.progress.canCapture, isFalse);
  });

  final badQuality = <String, FaceBlinkSample>{
    'dark': sample(light: 20),
    'too small': sample(size: 0.1),
    'off center': sample(center: 0.4),
    'turned sideways': sample(yaw: 25),
    'tilted': sample(pitch: -25),
    'unknown pose': sample(yaw: null),
    'invalid probability': sample(left: double.nan),
    'missing tracking': sample(id: null),
  };
  for (final entry in badQuality.entries) {
    test('${entry.key} photo cannot finish a partial blink', () {
      final controller = FaceBlinkController()..reset(Duration.zero);
      openEyes(controller);
      controller.observe(
        sample(left: 0.1, right: 0.1),
        const Duration(milliseconds: 300),
      );
      controller.observe(entry.value, const Duration(milliseconds: 450));
      expect(controller.progress.stage, FaceBlinkStage.positionFace);
      expect(controller.progress.canCapture, isFalse);
    });
  }

  test('timeout stays blocked until explicit retry resets the session', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    openEyes(controller);
    expect(controller.tick(const Duration(seconds: 35)).needsRetry, isTrue);
    expect(
      controller.observe(sample(), const Duration(seconds: 36)).needsRetry,
      isTrue,
    );
    controller.reset(const Duration(seconds: 36));
    openEyes(controller, start: 36000);
    controller.observe(
      sample(left: 0.1, right: 0.1),
      const Duration(milliseconds: 36300),
    );
    controller.observe(sample(), const Duration(milliseconds: 36450));
    expect(
      controller
          .observe(sample(), const Duration(milliseconds: 36550))
          .canCapture,
      isTrue,
    );
  });

  test('reset after backgrounding requires a completely new blink', () {
    final controller = FaceBlinkController()..reset(Duration.zero);
    openEyes(controller);
    controller.observe(
      sample(left: 0.1, right: 0.1),
      const Duration(milliseconds: 300),
    );
    controller.reset(const Duration(seconds: 1));
    controller.observe(sample(), const Duration(milliseconds: 1100));
    controller.observe(sample(), const Duration(milliseconds: 1200));
    expect(controller.progress.canCapture, isFalse);
  });
}
