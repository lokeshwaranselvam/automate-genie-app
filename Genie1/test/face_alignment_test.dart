import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/face/face_alignment.dart';
import 'package:image/image.dart' as image;

void main() {
  test('five-point fit recovers rotation, scale and translation', () {
    final target = FaceAlignment.sfaceReferencePoints;
    const original = FaceSimilarityTransform(1.7, 0.35, 40, -20);
    final source = target.map(original.inverse).toList();
    final fitted = FaceSimilarityTransform.fit(source, target);
    expect(fitted.a, closeTo(original.a, 1e-10));
    expect(fitted.b, closeTo(original.b, 1e-10));
    expect(fitted.tx, closeTo(original.tx, 1e-10));
    expect(fitted.ty, closeTo(original.ty, 1e-10));
    for (var index = 0; index < target.length; index++) {
      final mapped = fitted.apply(source[index]);
      expect(mapped.x, closeTo(target[index].x, 1e-10));
      expect(mapped.y, closeTo(target[index].y, 1e-10));
    }
  });

  test('inverse transform maps aligned coordinates back to the photo', () {
    const transform = FaceSimilarityTransform(0.7, -0.3, 9, 4);
    const point = FacePoint(36, 58);
    final recovered = transform.inverse(transform.apply(point));
    expect(recovered.x, closeTo(point.x, 1e-10));
    expect(recovered.y, closeTo(point.y, 1e-10));
  });

  test('fit rejects mismatched, nonfinite and coincident landmarks', () {
    expect(
      () => FaceSimilarityTransform.fit([
        const FacePoint(1, 1),
      ], FaceAlignment.sfaceReferencePoints),
      throwsArgumentError,
    );
    expect(
      () => FaceSimilarityTransform.fit(
        List.filled(5, const FacePoint(1, 1)),
        FaceAlignment.sfaceReferencePoints,
      ),
      throwsArgumentError,
    );
    expect(
      () => FaceSimilarityTransform.fit(
        [const FacePoint(double.nan, 1), const FacePoint(2, 2)],
        [const FacePoint(1, 1), const FacePoint(2, 2)],
      ),
      throwsArgumentError,
    );
  });

  test(
    'alignment preserves an already aligned image without channel swaps',
    () {
      final source = image.Image(width: 112, height: 112);
      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          source.setPixelRgb(x, y, x, y, 75);
        }
      }
      final aligned = FaceAlignment.align(
        source,
        FaceAlignment.sfaceReferencePoints,
      );
      expect(aligned.width, 112);
      expect(aligned.height, 112);
      final pixel = aligned.getPixel(40, 60);
      expect(pixel.r, 40);
      expect(pixel.g, 60);
      expect(pixel.b, 75);
    },
  );

  test('inverse warp follows translated landmarks and uses black borders', () {
    final source = image.Image(width: 112, height: 112);
    source.setPixelRgb(50, 60, 200, 100, 50);
    final translatedLandmarks =
        FaceAlignment.sfaceReferencePoints
            .map((point) => FacePoint(point.x + 10, point.y))
            .toList();
    final aligned = FaceAlignment.align(source, translatedLandmarks);
    final mapped = aligned.getPixel(40, 60);
    expect(mapped.r, 200);
    expect(mapped.g, 100);
    expect(mapped.b, 50);
    expect(aligned.getPixel(111, 60).r, 0);
  });

  test('SFace input retains RGB 0 to 255 in channel-first float32 order', () {
    final source = image.Image(width: 112, height: 112);
    source.setPixelRgb(2, 3, 255, 128, 17);
    final data = FaceAlignment.rgbNchw(source);
    const plane = 112 * 112;
    const offset = 3 * 112 + 2;
    expect(data.length, 3 * plane);
    expect(data[offset], 255);
    expect(data[plane + offset], 128);
    expect(data[2 * plane + offset], 17);
    expect(
      () => FaceAlignment.rgbNchw(image.Image(width: 111, height: 112)),
      throwsArgumentError,
    );
  });

  test('cosine similarity handles unnormalized vectors and opposite faces', () {
    expect(FaceAlignment.cosineSimilarity([3, 4], [6, 8]), closeTo(1, 1e-12));
    expect(FaceAlignment.cosineSimilarity([1, 0], [0, 2]), closeTo(0, 1e-12));
    expect(FaceAlignment.cosineSimilarity([1, 0], [-5, 0]), closeTo(-1, 1e-12));
    final normalized = FaceAlignment.normalizeEmbedding([3, 4]);
    final magnitude = math.sqrt(
      normalized.fold<double>(0, (s, v) => s + v * v),
    );
    expect(magnitude, closeTo(1, 1e-12));
    expect(() => normalized[0] = 0, throwsUnsupportedError);
  });

  test('invalid embeddings fail instead of becoming a successful match', () {
    for (final values in <List<double>>[
      [],
      [0, 0],
      [double.infinity, 1],
      [double.nan, 1],
    ]) {
      expect(
        () => FaceAlignment.normalizeEmbedding(values),
        throwsArgumentError,
      );
    }
    expect(
      () => FaceAlignment.cosineSimilarity([1, 2], [1]),
      throwsArgumentError,
    );
  });
}
