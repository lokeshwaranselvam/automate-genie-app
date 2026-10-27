import 'dart:math' as math;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Select the clearly dominant selfie subject, never whichever face ML Kit
/// returns first. Similar-size or substantially overlapping faces remain
/// ambiguous and must not share a blink/identity challenge.
Face? selectPrimaryFace(List<Face> faces, double width, double height) {
  if (faces.isEmpty) return null;
  if (faces.length == 1) return faces.single;
  if (width <= 0 || height <= 0) return null;
  double area(Face face) => face.boundingBox.width * face.boundingBox.height;
  final ordered = List<Face>.of(faces)
    ..sort((a, b) => area(b).compareTo(area(a)));
  final primary = ordered.first;
  final bounds = primary.boundingBox;
  final primaryArea = area(primary);
  if (!primaryArea.isFinite ||
      primaryArea <= 0 ||
      math.max(
            (bounds.center.dx / width - .5).abs(),
            (bounds.center.dy / height - .5).abs(),
          ) >
          .28) {
    return null;
  }
  for (final other in ordered.skip(1)) {
    final otherArea = area(other);
    if (!otherArea.isFinite ||
        otherArea <= 0 ||
        otherArea > primaryArea * .65) {
      return null;
    }
    final intersection = bounds.intersect(other.boundingBox);
    if (!intersection.isEmpty &&
        intersection.width * intersection.height > otherArea * .35) {
      return null;
    }
  }
  return primary;
}
