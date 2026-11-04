import 'dart:convert';
import 'dart:js_interop';
import 'package:homegenie/utils/face/face_embedding_service_web.dart';
import 'package:homegenie/utils/platform/platform_file_web.dart';
import 'package:image/image.dart' as image;

@JS('runDartFaceProbe')
external set _probe(JSFunction callback);
void main() {
  _probe = ((JSString input) => _run(input.toDart).toJS).toJS;
}

Future<JSString> _run(String input) async {
  final source = File.fromBytes(base64Decode(input));
  File? variant;
  try {
    final service = FaceEmbeddingService.instance;
    final reference = await service.embeddingFromFile(source);
    final decoded = image.decodeImage(await source.readAsBytes())!;
    variant = File.fromBytes(image.encodeJpg(decoded, quality: 85));
    final candidate = await service.embeddingFromCapture(variant);
    final score = FaceEmbeddingService.cosineSimilarity(reference, candidate);
    if (score < .5) {
      throw StateError('Recompressed reference failed to match: $score');
    }
    return jsonEncode({
      'dimensions': reference.length,
      'score': score,
      'reference': reference,
    }).toJS;
  } finally {
    await source.delete();
    await variant?.delete();
  }
}
