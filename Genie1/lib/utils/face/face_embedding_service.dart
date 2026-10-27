import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as image;

import 'face_alignment.dart';
import 'face_image_quality.dart';
import 'face_performance_trace.dart';
import 'primary_face.dart';

class FaceEmbeddingException implements Exception {
  final String message;

  const FaceEmbeddingException(this.message);

  @override
  String toString() => message;
}

/// Local 1:1 face embeddings; never uploads an image or biometric template.
/// Blink continuity must be verified separately by the live camera flow.
class FaceEmbeddingService {
  static final FaceEmbeddingService instance = FaceEmbeddingService();
  static const modelAsset = 'assets/face_recognition/sface_2021dec.onnx';
  static const modelVersion = 'opencv-sface-2021dec-int8bq-v1';
  static const embeddingDimensions = 128;
  // Pilot value only. Validate false accept/reject rates on the actual fleet.
  static const pilotCosineThreshold = 0.5;

  Future<OrtSession>? _sessionFuture;
  FaceDetector? _detector;
  static const _timing = FacePerformanceTrace();
  Future<void> _operations = Future<void>.value();
  bool _disposed = false;

  /// Returns a normalized embedding from a raw, unstamped selfie. Operations
  /// are serialized so model disposal cannot race native inference.
  Future<List<double>> embeddingFromFile(File file) =>
      _embedding(file, validateCapture: false);

  /// Includes the camera's final-photo checks in the same upright-image pass.
  Future<List<double>> embeddingFromCapture(File file) =>
      _embedding(file, validateCapture: true);

  /// Warm the cached model while the user is opening Attendance or blinking.
  Future<void> warmUp() => _serialized(() async {
    if (_disposed) {
      throw StateError('The face recognition service has been disposed.');
    }
    await _timing.measure('model preparation', _session);
  });

  FaceDetector _photoDetector() =>
      _detector ??= FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: true,
          performanceMode: FaceDetectorMode.accurate,
          minFaceSize: 0.15,
        ),
      );

  Future<List<double>> _embedding(
    File file, {
    required bool validateCapture,
  }) => _serialized(() async {
    if (_disposed) {
      throw StateError('The face recognition service has been disposed.');
    }
    // Model loading and image preparation are independent. Observe errors even
    // if photo validation fails before this operation reaches inference.
    final sessionFuture = _session();
    sessionFuture.ignore();
    final bytes = await file.readAsBytes();
    final prepared = await _timing.measure(
      'photo preparation',
      () => compute(_prepareUprightImage, bytes),
    );
    if (validateCapture && prepared.centerBrightness < 35) {
      throw const FaceEmbeddingException(
        'The selfie is too dark. Move to better lighting and try again.',
      );
    }
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'genie-face-',
    );
    final uprightFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}upright.jpg',
    );
    try {
      await uprightFile.writeAsBytes(prepared.bytes, flush: true);
      final faces = await _timing.measure(
        'final photo detection',
        () => _photoDetector().processImage(
          InputImage.fromFilePath(uprightFile.path),
        ),
      );
      final face = selectPrimaryFace(
        faces,
        prepared.width.toDouble(),
        prepared.height.toDouble(),
      );
      if (face == null) {
        throw FaceEmbeddingException(
          faces.isEmpty
              ? 'Keep your face clearly visible and try again.'
              : 'Keep your face closest to the camera. Move other people farther behind you.',
        );
      }
      validateFaceQuality(
        face,
        prepared.width,
        prepared.height,
        validateCapture: validateCapture,
      );
      final landmarks = _faceLandmarks(face);
      final tensorData = await _timing.measure(
        'alignment and quality',
        () =>
            compute(_alignedTensor, _AlignmentInput(prepared.bytes, landmarks)),
      );
      final session = await sessionFuture;
      OrtValue? input;
      Map<String, OrtValue> outputs = {};
      try {
        input = await OrtValue.fromList(tensorData, [1, 3, 112, 112]);
        // Android's plugin executes this call on a native background task
        // queue; expensive Dart decoding/alignment ran in compute above.
        outputs = await _timing.measure(
          'face model inference',
          () => session.run({'data': input!}),
        );
        final output = outputs['fc1'];
        if (output == null) {
          throw const FaceEmbeddingException(
            'The face recognition model returned no result.',
          );
        }
        final flattened = await output.asFlattenedList();
        final values =
            flattened.map((value) => (value as num).toDouble()).toList();
        if (values.length != embeddingDimensions) {
          throw const FaceEmbeddingException(
            'The face recognition model returned an unexpected result.',
          );
        }
        return FaceAlignment.normalizeEmbedding(values);
      } finally {
        try {
          if (input != null) await input.dispose();
        } finally {
          for (final output in outputs.values) {
            await output.dispose();
          }
        }
      }
    } finally {
      // The detector is reused within the serialized service, and closed by
      // clear/dispose. This directory belongs only to the current operation.
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  });

  static double cosineSimilarity(List<double> first, List<double> second) =>
      FaceAlignment.cosineSimilarity(first, second);

  /// Release the model after logout/backgrounding; the service remains usable.
  Future<void> clear() => _serialized(_closeSession);

  Future<void> dispose() => _serialized(() async {
    _disposed = true;
    await _closeSession();
  });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    // A failed capture must not poison subsequent attempts.
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<OrtSession> _session() async {
    final future =
        _sessionFuture ??= OnnxRuntime().createSessionFromAsset(
          modelAsset,
          options: OrtSessionOptions(
            intraOpNumThreads: 2,
            interOpNumThreads: 1,
          ),
        );
    try {
      final session = await future;
      if (!session.inputNames.contains('data') ||
          !session.outputNames.contains('fc1')) {
        await session.close();
        _sessionFuture = null;
        throw const FaceEmbeddingException(
          'The installed face recognition model is incompatible.',
        );
      }
      return session;
    } catch (_) {
      _sessionFuture = null;
      rethrow;
    }
  }

  Future<void> _closeSession() async {
    final future = _sessionFuture;
    _sessionFuture = null;
    try {
      if (future != null) {
        final session = await future;
        await session.close();
      }
    } finally {
      final detector = _detector;
      _detector = null;
      if (detector != null) await detector.close();
    }
  }

  @visibleForTesting
  static void validateFaceQuality(
    Face face,
    int width,
    int height, {
    required bool validateCapture,
  }) {
    final bounds = face.boundingBox;
    if (bounds.width < 112 ||
        bounds.height < 112 ||
        bounds.width < width * 0.15 ||
        bounds.height < height * 0.15) {
      throw const FaceEmbeddingException(
        'Move closer to the camera and try again.',
      );
    }
    if (bounds.left < 0 ||
        bounds.top < 0 ||
        bounds.right > width ||
        bounds.bottom > height) {
      throw const FaceEmbeddingException(
        'Keep your whole face inside the camera.',
      );
    }
    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX;
    final roll = face.headEulerAngleZ;
    if (yaw == null ||
        pitch == null ||
        roll == null ||
        yaw.abs() > 20 ||
        pitch.abs() > 20 ||
        roll.abs() > 20) {
      throw const FaceEmbeddingException(
        'Look straight at the camera and try again.',
      );
    }
    final left = face.leftEyeOpenProbability;
    final right = face.rightEyeOpenProbability;
    final minimumEyeOpen = validateCapture ? 0.65 : 0.55;
    if (left == null ||
        right == null ||
        left < minimumEyeOpen ||
        right < minimumEyeOpen) {
      throw const FaceEmbeddingException('Keep both eyes open after blinking.');
    }
  }

  static List<FacePoint> _faceLandmarks(Face face) {
    FacePoint point(FaceLandmarkType type) {
      final landmark = face.landmarks[type];
      if (landmark == null) {
        throw const FaceEmbeddingException(
          'Your eyes, nose, and mouth must be clearly visible.',
        );
      }
      return FacePoint(
        landmark.position.x.toDouble(),
        landmark.position.y.toDouble(),
      );
    }

    final eyes = [
      point(FaceLandmarkType.leftEye),
      point(FaceLandmarkType.rightEye),
    ]..sort((first, second) => first.x.compareTo(second.x));
    final mouth = [
      point(FaceLandmarkType.leftMouth),
      point(FaceLandmarkType.rightMouth),
    ]..sort((first, second) => first.x.compareTo(second.x));
    return [
      eyes[0],
      eyes[1],
      point(FaceLandmarkType.noseBase),
      mouth[0],
      mouth[1],
    ];
  }
}

class _PreparedImage {
  final Uint8List bytes;
  final int width;
  final int height;
  final double centerBrightness;

  const _PreparedImage(
    this.bytes,
    this.width,
    this.height,
    this.centerBrightness,
  );
}

_PreparedImage _prepareUprightImage(Uint8List bytes) {
  final decoded = image.decodeImage(bytes);
  if (decoded == null) {
    throw const FaceEmbeddingException(
      'The captured selfie could not be read.',
    );
  }
  var upright = image.bakeOrientation(decoded);
  final centerBrightness = faceCenterBrightness(upright);
  const maximumSide = 1600;
  final longSide = math.max(upright.width, upright.height);
  if (longSide > maximumSide) {
    final ratio = maximumSide / longSide;
    upright = image.copyResize(
      upright,
      width: (upright.width * ratio).round(),
      height: (upright.height * ratio).round(),
      interpolation: image.Interpolation.linear,
    );
  }
  // Encode upright with no original orientation metadata. Both ML Kit and
  // the alignment worker decode these same pixels, so their coordinates agree.
  upright.exif.clear();
  return _PreparedImage(
    Uint8List.fromList(image.encodeJpg(upright, quality: 95)),
    upright.width,
    upright.height,
    centerBrightness,
  );
}

class _AlignmentInput {
  final Uint8List bytes;
  final List<FacePoint> landmarks;

  const _AlignmentInput(this.bytes, this.landmarks);
}

Float32List _alignedTensor(_AlignmentInput input) {
  final decoded = image.decodeImage(input.bytes);
  if (decoded == null) {
    throw const FaceEmbeddingException(
      'The captured selfie could not be read.',
    );
  }
  final aligned = FaceAlignment.align(decoded, input.landmarks);
  _checkImageQuality(aligned);
  return FaceAlignment.rgbNchw(aligned);
}

void _checkImageQuality(image.Image aligned) {
  double luminance(int x, int y) {
    final pixel = aligned.getPixel(x, y);
    return pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
  }

  var brightness = 0.0;
  var laplacian = 0.0;
  var laplacianSquared = 0.0;
  var count = 0;
  // Exclude the outer alignment border so background does not dominate.
  for (var y = 12; y < 100; y++) {
    for (var x = 12; x < 100; x++) {
      final center = luminance(x, y);
      final lap =
          luminance(x - 1, y) +
          luminance(x + 1, y) +
          luminance(x, y - 1) +
          luminance(x, y + 1) -
          4 * center;
      brightness += center;
      laplacian += lap;
      laplacianSquared += lap * lap;
      count++;
    }
  }
  final averageBrightness = brightness / count;
  if (averageBrightness < 30 || averageBrightness > 230) {
    throw const FaceEmbeddingException('Move to even lighting and try again.');
  }
  final variance = laplacianSquared / count - math.pow(laplacian / count, 2);
  if (variance < 12) {
    throw const FaceEmbeddingException(
      'Hold the phone still for a clear selfie.',
    );
  }
}
