import 'package:flutter/material.dart';
import '../utils/platform/platform_file_web.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/face/face_embedding_service_web.dart';

class FaceCapturePage extends StatelessWidget {
  const FaceCapturePage({
    super.key,
    required this.title,
    this.validateCapture,
    this.validatePhotoInCallback = false,
  });
  final String title;
  final Future<String?> Function(File)? validateCapture;
  final bool validatePhotoInCallback;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: brandAppBar(title: Text(title)),
    body: const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          FaceEmbeddingService.unavailable,
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}
