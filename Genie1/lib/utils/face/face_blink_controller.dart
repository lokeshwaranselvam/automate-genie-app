/// A blink challenge checks live eye motion, not biometric identity or replay
/// resistance. Recognition of the captured photo is a separate required step.
enum FaceBlinkStage {
  positionFace,
  openEyes,
  blink,
  reopenEyes,
  holdStill,
  ready,
  timedOut,
}

class FaceBlinkConfig {
  const FaceBlinkConfig({
    this.openProbability = 0.75,
    this.closedProbability = 0.30,
    this.openFrames = 3,
    this.reopenedFrames = 2,
    this.minimumBlink = const Duration(milliseconds: 80),
    this.maximumBlink = const Duration(milliseconds: 900),
    this.maximumFrameGap = const Duration(milliseconds: 650),
    this.timeout = const Duration(seconds: 35),
    this.maximumHeadAngle = 15,
    this.minimumFaceFraction = 0.25,
    this.maximumCenterOffset = 0.28,
    this.minimumBrightness = 35,
  });

  final double openProbability;
  final double closedProbability;
  final int openFrames;
  final int reopenedFrames;
  final Duration minimumBlink;
  final Duration maximumBlink;
  final Duration maximumFrameGap;
  final Duration timeout;
  final double maximumHeadAngle;
  final double minimumFaceFraction;
  final double maximumCenterOffset;
  final double minimumBrightness;
}

/// Coordinates and brightness are normalized by the camera adapter. Timestamps
/// come from a monotonic clock, never the device's wall clock.
class FaceBlinkSample {
  const FaceBlinkSample({
    required this.faceCount,
    this.leftEyeOpen,
    this.rightEyeOpen,
    this.yaw,
    this.pitch,
    this.faceFraction = 0,
    this.centerOffset = 1,
    this.brightness = 0,
    this.trackingId,
  });

  final int faceCount;
  final double? leftEyeOpen;
  final double? rightEyeOpen;
  final double? yaw;
  final double? pitch;
  final double faceFraction;
  final double centerOffset;
  final double brightness;
  final int? trackingId;
}

class FaceBlinkProgress {
  const FaceBlinkProgress(this.stage, this.instruction);

  final FaceBlinkStage stage;
  final String instruction;
  bool get canCapture => stage == FaceBlinkStage.ready;
  bool get needsRetry => stage == FaceBlinkStage.timedOut;
}

class FaceBlinkController {
  FaceBlinkController({this.config = const FaceBlinkConfig()});

  final FaceBlinkConfig config;
  FaceBlinkProgress _progress = const FaceBlinkProgress(
    FaceBlinkStage.positionFace,
    'Place your face inside the guide.',
  );
  Duration? _started;
  Duration? _lastFrame;
  Duration? _closedAt;
  int? _trackingId;
  int _openCount = 0;
  int _reopenedCount = 0;

  FaceBlinkProgress get progress => _progress;

  void reset(Duration timestamp) {
    _started = timestamp;
    _lastFrame = null;
    _clearBlink();
    _progress = const FaceBlinkProgress(
      FaceBlinkStage.positionFace,
      'Place your face inside the guide.',
    );
  }

  FaceBlinkProgress tick(Duration timestamp) {
    _started ??= timestamp;
    if (!_progress.canCapture && timestamp - _started! >= config.timeout) {
      _clearBlink();
      _progress = const FaceBlinkProgress(
        FaceBlinkStage.timedOut,
        'Scan timed out. Face the camera in good light, then try again.',
      );
    }
    return _progress;
  }

  FaceBlinkProgress observe(FaceBlinkSample sample, Duration timestamp) {
    tick(timestamp);
    if (_progress.canCapture || _progress.needsRetry) return _progress;

    final lastFrame = _lastFrame;
    _lastFrame = timestamp;
    if (lastFrame != null && timestamp <= lastFrame) {
      return _reject('Hold still and start the blink again.');
    }
    if (lastFrame != null && timestamp - lastFrame > config.maximumFrameGap) {
      _clearBlink();
      _progress = const FaceBlinkProgress(
        FaceBlinkStage.openEyes,
        'Keep your eyes open and look straight.',
      );
    }

    final qualityError = _qualityError(sample);
    if (qualityError != null) return _reject(qualityError);
    if (_trackingId != null && sample.trackingId != _trackingId) {
      return _reject('Keep the same face inside the guide and start again.');
    }
    _trackingId = sample.trackingId;
    final left = sample.leftEyeOpen!;
    final right = sample.rightEyeOpen!;
    final open =
        left >= config.openProbability && right >= config.openProbability;
    final closed =
        left <= config.closedProbability && right <= config.closedProbability;

    if (_closedAt != null) {
      final closedDuration = timestamp - _closedAt!;
      if (closedDuration > config.maximumBlink) {
        return _reject('Open your eyes, then blink normally once.');
      }
      if (open) {
        if (closedDuration < config.minimumBlink) {
          return _reject('Blink normally once with both eyes.');
        }
        _reopenedCount++;
        if (_reopenedCount >= config.reopenedFrames) {
          _progress = const FaceBlinkProgress(
            FaceBlinkStage.ready,
            'Blink detected. Capturing your selfie…',
          );
        } else {
          _progress = const FaceBlinkProgress(
            FaceBlinkStage.holdStill,
            'Keep your eyes open and hold still.',
          );
        }
      } else {
        _reopenedCount = 0;
        _progress = const FaceBlinkProgress(
          FaceBlinkStage.reopenEyes,
          'Open both eyes and hold still.',
        );
      }
      return _progress;
    }

    if (_openCount >= config.openFrames && closed) {
      _closedAt = timestamp;
      _progress = const FaceBlinkProgress(
        FaceBlinkStage.reopenEyes,
        'Open both eyes and hold still.',
      );
    } else if (open) {
      _openCount++;
      _progress =
          _openCount >= config.openFrames
              ? const FaceBlinkProgress(
                FaceBlinkStage.blink,
                'Blink both eyes once.',
              )
              : const FaceBlinkProgress(
                FaceBlinkStage.openEyes,
                'Keep your eyes open and look straight.',
              );
    } else if (_openCount < config.openFrames) {
      _openCount = 0;
      _progress = const FaceBlinkProgress(
        FaceBlinkStage.openEyes,
        'Keep both eyes open and look straight.',
      );
    }
    return _progress;
  }

  String? _qualityError(FaceBlinkSample sample) {
    if (sample.faceCount == 0) return 'Place your face inside the guide.';
    if (sample.faceCount != 1) {
      return 'Only one person should be in the camera.';
    }
    if (sample.trackingId == null) {
      return 'Hold still while the camera locks onto your face.';
    }
    if (!sample.brightness.isFinite ||
        sample.brightness < config.minimumBrightness) {
      return 'Move to better lighting so your face is clear.';
    }
    if (!sample.faceFraction.isFinite ||
        sample.faceFraction < config.minimumFaceFraction) {
      return 'Move a little closer to the camera.';
    }
    if (!sample.centerOffset.isFinite ||
        sample.centerOffset > config.maximumCenterOffset) {
      return 'Center your face inside the guide.';
    }
    if (sample.yaw == null ||
        sample.pitch == null ||
        !sample.yaw!.isFinite ||
        !sample.pitch!.isFinite ||
        sample.yaw!.abs() > config.maximumHeadAngle ||
        sample.pitch!.abs() > config.maximumHeadAngle) {
      return 'Look straight at the camera.';
    }
    if (sample.leftEyeOpen == null ||
        sample.rightEyeOpen == null ||
        !sample.leftEyeOpen!.isFinite ||
        !sample.rightEyeOpen!.isFinite ||
        sample.leftEyeOpen! < 0 ||
        sample.leftEyeOpen! > 1 ||
        sample.rightEyeOpen! < 0 ||
        sample.rightEyeOpen! > 1) {
      return 'Make sure both eyes are clearly visible.';
    }
    return null;
  }

  FaceBlinkProgress _reject(String instruction) {
    _clearBlink();
    _progress = FaceBlinkProgress(FaceBlinkStage.positionFace, instruction);
    return _progress;
  }

  void _clearBlink() {
    _trackingId = null;
    _closedAt = null;
    _openCount = 0;
    _reopenedCount = 0;
  }
}
