import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraService {
  static final ImagePicker _picker = ImagePicker();

  /// Opens the device camera and returns the captured image file.
  /// Returns null if the user cancels. [front] opens the selfie camera.
  static Future<File?> capturePhoto({bool front = false}) async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (status.isPermanentlyDenied) {
          await openAppSettings();
        }
        debugPrint('Camera permission denied: ${status.name}');
        return null;
      }

      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 55,
        maxWidth: 1600,
        maxHeight: 1600,
        preferredCameraDevice: front ? CameraDevice.front : CameraDevice.rear,
      );
      if (photo == null) return null;
      return File(photo.path);
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      return null;
    }
  }

  // Gallery access is intentionally disabled.
  // Users must capture photos using the device camera only.
}
