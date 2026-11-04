import 'dart:math' as math;
import 'package:image/image.dart' as image;
import '../platform/platform_file_web.dart';
import 'browser_face_runtime.dart';
import 'face_alignment.dart';
import 'face_image_quality.dart';

class FaceEmbeddingException implements Exception {
  const FaceEmbeddingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FaceEmbeddingService {
  static final instance = FaceEmbeddingService();
  static const modelAsset = 'assets/face_recognition/sface_2021dec.onnx';
  static const modelVersion = 'opencv-sface-2021dec-int8bq-v1';
  static const embeddingDimensions = 128;
  static const pilotCosineThreshold = 0.5;
  Future<void> _operations = Future.value();
  Future<void> warmUp() => BrowserFaceRuntime.warmUp();
  Future<List<double>> embeddingFromFile(File file) => _embed(file, false);
  Future<List<double>> embeddingFromCapture(File file) => _embed(file, true);
  Future<List<double>> _embed(File file, bool capture) {
    final operation = _operations.then((_) => _run(file, capture));
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<List<double>> _run(File file, bool capture) async {
    try {
      final decoded = image.decodeImage(await file.readAsBytes());
      if (decoded == null) {
        throw const FaceEmbeddingException(
          'The captured selfie could not be read.',
        );
      }
      var upright = image.bakeOrientation(decoded);
      if (capture && faceCenterBrightness(upright) < 35) {
        throw const FaceEmbeddingException(
          'Move to better lighting so your face is clear.',
        );
      }
      final longSide = math.max(upright.width, upright.height);
      if (longSide > 1600) {
        final ratio = 1600 / longSide;
        upright = image.copyResize(
          upright,
          width: (upright.width * ratio).round(),
          height: (upright.height * ratio).round(),
          interpolation: image.Interpolation.linear,
        );
      }
      upright.exif.clear();
      final bytes = image.encodeJpg(upright, quality: 95);
      await warmUp();
      final face = await BrowserFaceRuntime.detect(bytes);
      validateFace(face, upright.width, upright.height, capture: capture);
      final points =
          (face['landmarks'] as List)
              .map(
                (p) => FacePoint(
                  (p[0] as num).toDouble(),
                  (p[1] as num).toDouble(),
                ),
              )
              .toList();
      final aligned = FaceAlignment.align(image.decodeJpg(bytes)!, points);
      checkImageQuality(aligned);
      final values = await BrowserFaceRuntime.embed(
        FaceAlignment.rgbNchw(aligned),
      );
      if (values.length != embeddingDimensions) {
        throw const FaceEmbeddingException('Unexpected face model output.');
      }
      return FaceAlignment.normalizeEmbedding(values);
    } on FaceEmbeddingException {
      rethrow;
    } catch (error) {
      throw FaceEmbeddingException(
        'Face verification could not complete: $error',
      );
    }
  }

  static void validateFace(
    Map<String, dynamic> face,
    int width,
    int height, {
    required bool capture,
  }) {
    if (face['faceCount'] != 1) {
      throw FaceEmbeddingException(
        face['faceCount'] == 0
            ? 'Keep your face clearly visible and try again.'
            : 'Only one person can be visible in the selfie.',
      );
    }
    double value(String key) => (face[key] as num?)?.toDouble() ?? double.nan;
    final left = value('left'),
        right = value('right'),
        top = value('top'),
        bottom = value('bottom');
    if ([left, right, top, bottom].any((v) => !v.isFinite) ||
        right - left < 112 ||
        bottom - top < 112 ||
        right - left < width * .15 ||
        bottom - top < height * .15) {
      throw const FaceEmbeddingException(
        'Move closer to the camera and try again.',
      );
    }
    if (left < 0 || top < 0 || right > width || bottom > height) {
      throw const FaceEmbeddingException(
        'Keep your whole face inside the camera.',
      );
    }
    if ([
      'yaw',
      'pitch',
      'roll',
    ].any((key) => !value(key).isFinite || value(key).abs() > 20)) {
      throw const FaceEmbeddingException(
        'Look straight at the camera and try again.',
      );
    }
    if (['leftEyeOpen', 'rightEyeOpen'].any(
      (key) =>
          !value(key).isFinite ||
          value(key) > 1 ||
          value(key) < (capture ? .65 : .55),
    )) {
      throw const FaceEmbeddingException('Keep both eyes open after blinking.');
    }
  }

  // Identical aligned-image brightness and Laplacian limits to native SFace.
  static void checkImageQuality(image.Image aligned) {
    double luminance(int x, int y) {
      final p = aligned.getPixel(x, y);
      return p.r * .299 + p.g * .587 + p.b * .114;
    }

    var brightness = 0.0, laplacian = 0.0, squared = 0.0;
    var count = 0;
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
        squared += lap * lap;
        count++;
      }
    }
    if (brightness / count < 30 || brightness / count > 230) {
      throw const FaceEmbeddingException(
        'Move to even lighting and try again.',
      );
    }
    if (squared / count - math.pow(laplacian / count, 2) < 12) {
      throw const FaceEmbeddingException('Hold still for a clear selfie.');
    }
  }

  static double cosineSimilarity(List<double> a, List<double> b) =>
      FaceAlignment.cosineSimilarity(a, b);
  Future<void> clear() async {
    await _operations;
    BrowserFaceRuntime.clear();
  }

  Future<void> dispose() => clear();
}
