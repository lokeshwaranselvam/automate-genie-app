import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Normalized coordinates of the face to preserve, used only for rendering.
class PortraitFaceRegion {
  const PortraitFaceRegion(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
}

class PortraitMatteInput {
  const PortraitMatteInput(
    this.width,
    this.height,
    this.confidences,
    this.face, {
    this.backgroundFaces = const [],
  });
  final int width, height;
  final List<double> confidences;
  final PortraitFaceRegion face;
  final List<PortraitFaceRegion> backgroundFaces;
}

/// Subject masks are cropped; their origin is in the upright source image.
class PortraitSubjectMask {
  const PortraitSubjectMask(
    this.startX,
    this.startY,
    this.width,
    this.height,
    this.confidences,
  );
  final int startX, startY, width, height;
  final List<double> confidences;

  double confidenceAt(double x, double y) {
    final sx = x - startX, sy = y - startY;
    if (width <= 0 ||
        height <= 0 ||
        confidences.length != width * height ||
        sx < 0 ||
        sy < 0 ||
        sx >= width ||
        sy >= height) {
      return 0;
    }
    final x0 = sx.floor(), y0 = sy.floor();
    final x1 = math.min(x0 + 1, width - 1), y1 = math.min(y0 + 1, height - 1);
    final dx = sx - x0, dy = sy - y0;
    final value =
        confidences[y0 * width + x0] * (1 - dx) * (1 - dy) +
        confidences[y0 * width + x1] * dx * (1 - dy) +
        confidences[y1 * width + x0] * (1 - dx) * dy +
        confidences[y1 * width + x1] * dx * dy;
    return value.isFinite ? value.clamp(0.0, 1.0) : 0;
  }
}

class PortraitSubjectInput {
  const PortraitSubjectInput(
    this.width,
    this.height,
    this.subjects,
    this.face, {
    this.backgroundFaces = const [],
  });
  final int width, height;
  final List<PortraitSubjectMask> subjects;
  final PortraitFaceRegion face;
  final List<PortraitFaceRegion> backgroundFaces;
}

class PortraitMatte {
  const PortraitMatte(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
}

/// Choose by confidence inside the selected face, not subject size/list order.
/// Never substitute the combined foreground mask, which also preserves bystanders.
PortraitMatte? buildSubjectPortraitMatte(PortraitSubjectInput input) {
  if (input.width < 2 || input.height < 2 || input.subjects.isEmpty) {
    return null;
  }
  PortraitSubjectMask? selected;
  var best = 0.0, second = 0.0;
  for (final subject in input.subjects) {
    if (subject.width <= 0 ||
        subject.height <= 0 ||
        subject.confidences.length != subject.width * subject.height) {
      continue;
    }
    var score = 0.0;
    // Central face samples avoid hair/bounding-box corners at silhouette edges.
    for (var y = 0; y < 5; y++) {
      for (var x = 0; x < 5; x++) {
        score += subject.confidenceAt(
          (input.face.left +
                  (input.face.right - input.face.left) * (.25 + x * .125)) *
              input.width,
          (input.face.top +
                  (input.face.bottom - input.face.top) * (.25 + y * .125)) *
              input.height,
        );
      }
    }
    score /= 25;
    if (score > best) {
      second = best;
      best = score;
      selected = subject;
    } else if (score > second) {
      second = score;
    }
  }
  // No reliable subject, or competing masks over the same face: use the
  // established fallback rather than sharpening an unrelated person/object.
  if (selected == null || best < .7 || best - second < .15) return null;
  final scale = math.min(1.0, 640 / math.max(input.width, input.height));
  final width = math.max(2, (input.width * scale).round());
  final height = math.max(2, (input.height * scale).round());
  final confidence = List<double>.generate(
    width * height,
    (index) => selected!.confidenceAt(
      (index % width + .5) * input.width / width - .5,
      (index ~/ width + .5) * input.height / height - .5,
    ),
  );
  final matte = buildPortraitMatte(
    PortraitMatteInput(
      width,
      height,
      confidence,
      input.face,
      backgroundFaces: input.backgroundFaces,
    ),
  );
  return matte == null ? null : PortraitMatte(width, height, matte);
}

/// Keep the person's connected foreground mask, with the face fully opaque.
/// This mask is never used for face counting, blink detection or matching.
Uint8List? buildPortraitMatte(PortraitMatteInput input) {
  final w = input.width, h = input.height;
  if (w < 2 || h < 2 || input.confidences.length != w * h) return null;
  final face = input.face;
  final faceWidth = face.right - face.left, faceHeight = face.bottom - face.top;
  if (faceWidth <= 0 || faceHeight <= 0) return null;
  // The model labels all people as foreground. Remove background heads even
  // when their shoulders connect to the main person in that mask. Feather the
  // surrounding head/body territory, preserving the closer face and torso.
  double backgroundExclusion(double x, double y) {
    var exclusion = 0.0;
    for (final other in input.backgroundFaces) {
      final ow = other.right - other.left, oh = other.bottom - other.top;
      if (ow <= 0 || oh <= 0) continue;
      final ox = (other.left + other.right) / 2;
      final oy = (other.top + other.bottom) / 2 - oh * .12;
      final headDistance = math.sqrt(
        math.pow((x - ox) / (ow * .85), 2) + math.pow((y - oy) / (oh * .9), 2),
      );
      var remove = ((1.18 - headDistance) / .18).clamp(0.0, 1.0);
      if (y > other.bottom && y < face.bottom + faceHeight * .45) {
        final shoulder = ((y - other.bottom) / oh).clamp(0.0, 1.0);
        final halfWidth = ow * (.8 + .55 * shoulder);
        final bodyRemove = ((halfWidth - (x - ox).abs()) / (ow * .2)).clamp(
          0.0,
          1.0,
        );
        final mainHalfWidth =
            faceWidth * (.7 + ((y - face.bottom) / faceHeight).clamp(0.0, 1.0));
        final mainCenter = (face.left + face.right) / 2;
        final mainTorso =
            y >= face.bottom && (x - mainCenter).abs() < mainHalfWidth;
        if (!mainTorso) remove = math.max(remove, bodyRemove);
      }
      exclusion = math.max(exclusion, remove);
    }
    return exclusion;
  }

  final cx = ((face.left + face.right) * w / 2).clamp(0, w - 1);
  final cy = ((face.top + face.bottom) * h / 2).clamp(0, h - 1);
  var seed = -1;
  var nearest = double.infinity;
  for (
    var y = (face.top * h).floor().clamp(0, h - 1);
    y <= (face.bottom * h).ceil().clamp(0, h - 1);
    y++
  ) {
    for (
      var x = (face.left * w).floor().clamp(0, w - 1);
      x <= (face.right * w).ceil().clamp(0, w - 1);
      x++
    ) {
      final confidence = input.confidences[y * w + x];
      final distance = (x - cx) * (x - cx) + (y - cy) * (y - cy);
      if (confidence.isFinite && confidence >= 0.6 && distance < nearest) {
        seed = y * w + x;
        nearest = distance.toDouble();
      }
    }
  }
  // If segmentation cannot locate the face, retain the original photograph.
  if (seed < 0) return null;
  final visited = Uint8List(w * h);
  final queue = Int32List(w * h);
  var read = 0, written = 1;
  queue[0] = seed;
  visited[seed] = 1;
  while (read < written) {
    final index = queue[read++];
    final x = index % w, y = index ~/ w;
    for (final next in [
      if (x > 0) index - 1,
      if (x + 1 < w) index + 1,
      if (y > 0) index - w,
      if (y + 1 < h) index + w,
    ]) {
      final value = input.confidences[next];
      if (visited[next] == 0 && value.isFinite && value > 0.25) {
        visited[next] = 1;
        queue[written++] = next;
      }
    }
  }
  final rgba = Uint8List(w * h * 4);
  final padX = (face.right - face.left) * 0.12;
  final padY = (face.bottom - face.top) * 0.12;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final index = y * w + x;
      var alpha = 0.0;
      if (visited[index] != 0) {
        final t = ((input.confidences[index] - 0.25) / 0.6).clamp(0.0, 1.0);
        alpha = t * t * (3 - 2 * t);
      }
      if (x / w >= face.left - padX &&
          x / w <= face.right + padX &&
          y / h >= face.top - padY &&
          y / h <= face.bottom + padY) {
        alpha = 1;
      }
      rgba[index * 4] = 255;
      // Do this after the face padding, which can otherwise overlap a smaller
      // background head. The selected face's actual pixels stay unmodified.
      final nx = x / w, ny = y / h;
      if (!(nx >= face.left &&
          nx <= face.right &&
          ny >= face.top &&
          ny <= face.bottom)) {
        alpha *= 1 - backgroundExclusion(nx, ny);
      }
      rgba[index * 4 + 1] = 255;
      rgba[index * 4 + 2] = 255;
      rgba[index * 4 + 3] = (alpha * 255).round();
    }
  }
  return rgba;
}

/// Same orientation and size limit as enrollment; PNG avoids another lossy pass.
Uint8List preparePortraitImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Invalid portrait image.');
  var image = img.bakeOrientation(decoded);
  if (image.width > 1280 || image.height > 1280) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 1280 : null,
      height: image.height > image.width ? 1280 : null,
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}

class PortraitCompositeInput {
  const PortraitCompositeInput(
    this.png,
    this.mask,
    this.maskWidth,
    this.maskHeight,
  );
  final Uint8List png, mask;
  final int maskWidth, maskHeight;
}

/// Apply a strong blur only behind the matte; opaque foreground pixels survive.
Uint8List compositePortraitImage(PortraitCompositeInput input) {
  final original = img.decodePng(input.png);
  if (original == null ||
      input.mask.length != input.maskWidth * input.maskHeight * 4) {
    throw const FormatException('Invalid portrait mask.');
  }
  final matte = img.Image.fromBytes(
    width: input.maskWidth,
    height: input.maskHeight,
    bytes: input.mask.buffer,
    bytesOffset: input.mask.offsetInBytes,
    numChannels: 4,
  );
  final fullMask = img.copyResize(
    matte,
    width: original.width,
    height: original.height,
    interpolation: img.Interpolation.linear,
  );
  final scale = math.min(1.0, 400 / math.max(original.width, original.height));
  var blurred = img.copyResize(
    original,
    width: math.max(1, (original.width * scale).round()),
    height: math.max(1, (original.height * scale).round()),
    interpolation: img.Interpolation.average,
  );
  blurred = img.gaussianBlur(blurred, radius: 24);
  blurred = img.copyResize(
    blurred,
    width: original.width,
    height: original.height,
    interpolation: img.Interpolation.linear,
  );
  for (final pixel in original) {
    final keep = fullMask.getPixel(pixel.x, pixel.y).a / 255;
    if (keep >= 1) continue;
    final background = blurred.getPixel(pixel.x, pixel.y);
    pixel
      ..r = pixel.r * keep + background.r * (1 - keep)
      ..g = pixel.g * keep + background.g * (1 - keep)
      ..b = pixel.b * keep + background.b * (1 - keep);
  }
  return Uint8List.fromList(img.encodePng(original));
}
