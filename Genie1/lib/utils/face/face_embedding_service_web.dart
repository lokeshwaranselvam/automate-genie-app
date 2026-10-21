import 'face_platform_capability.dart';
import '../platform/platform_file.dart';
import 'face_alignment.dart';

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
  static const unavailable = webFaceUnavailable;
  Future<void> warmUp() async {}
  Future<List<double>> embeddingFromFile(File file) async =>
      throw const FaceEmbeddingException(unavailable);
  Future<List<double>> embeddingFromCapture(File file) =>
      embeddingFromFile(file);
  static double cosineSimilarity(List<double> a, List<double> b) =>
      FaceAlignment.cosineSimilarity(a, b);
  Future<void> clear() async {}
  Future<void> dispose() async {}
}
