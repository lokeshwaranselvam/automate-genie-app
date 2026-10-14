import 'dart:math' as math;

import 'package:image/image.dart' as image;

/// The same center-region brightness check for standalone and shared capture.
double faceCenterBrightness(image.Image upright) {
  var total = 0.0;
  var count = 0;
  final step = math.max(1, math.min(upright.width, upright.height) ~/ 40);
  for (var y = upright.height ~/ 4; y < upright.height * 3 ~/ 4; y += step) {
    for (var x = upright.width ~/ 4; x < upright.width * 3 ~/ 4; x += step) {
      final pixel = upright.getPixel(x, y);
      total += pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
      count++;
    }
  }
  return count == 0 ? 0 : total / count;
}
