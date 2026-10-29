import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class ImageUploadApi {
  /// Uploads a single image file to the ERPNext Event doctype
  /// via Frappe's /api/method/upload_file endpoint.
  ///
  /// [filePath] - local path of the captured image
  /// [docname]  - ERPNext Event document name (e.g. "EV-00123")
  ///
  /// Returns the uploaded file URL on success, null on failure.
  static Future<String?> uploadImageToEvent({
    required String filePath,
    required String docname,
    BuildContext? context,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString('token');
      final String baseUrl = dotenv.env['SITE_URL'] ?? '';

      if (token == null || token.isEmpty) {
        debugPrint('❌ No auth token found.');
        return null;
      }

      if (baseUrl.isEmpty) {
        debugPrint('❌ SITE_URL not set in .env');
        return null;
      }

      final file = File(filePath);
      if (!file.existsSync()) {
        debugPrint('❌ Image file does not exist: $filePath');
        return null;
      }

      final fileName = p.basename(filePath);
      final uploadUrl = '$baseUrl/api/method/upload_file';

      var request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

      // Frappe upload_file fields
      request.fields['doctype'] = 'Event';
      request.fields['docname'] = docname;
      request.fields['fieldname'] = 'custom_event_images';
      // Visit photos are customer-site images; keep them private. Every
      // in-app viewer (site_visit_report_page, completed_visit_attachments)
      // already sends the Authorization token that private files require.
      request.fields['is_private'] = '1';

      request.headers['Authorization'] = token;

      request.files.add(
        await http.MultipartFile.fromPath('file', filePath, filename: fileName),
      );

      debugPrint('📤 Uploading image "$fileName" to Event: $docname ...');

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
      final responseBody = await streamedResponse.stream
          .bytesToString()
          .timeout(const Duration(seconds: 60));

      if (streamedResponse.statusCode == 200) {
        final jsonResponse = jsonDecode(responseBody);
        final message = jsonResponse is Map ? jsonResponse['message'] : null;
        final fileUrl = message is Map ? message['file_url'] : null;
        if (fileUrl is! String || fileUrl.isEmpty) {
          debugPrint('❌ Upload response had no file_url: $responseBody');
          return null;
        }
        debugPrint('✅ Image uploaded successfully: $fileUrl');
        return fileUrl;
      } else {
        debugPrint(
          '❌ Upload failed [${streamedResponse.statusCode}]: $responseBody',
        );
        return null;
      }
    } catch (e) {
      debugPrint('❌ Image upload exception: $e');
      return null;
    }
  }

  /// Uploads an attendance photo as a private File not yet linked to a
  /// document, before the check-in/check-out request. The returned file_url
  /// is sent with that request so the server can attach it to the new
  /// Employee Checkin. Returns null on failure.
  static Future<String?> uploadAttendancePhoto({
    required String filePath,
    required String fileName,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString('token');
      final String baseUrl = dotenv.env['SITE_URL'] ?? '';
      if (token == null || token.isEmpty || baseUrl.isEmpty) {
        debugPrint('[ImageUploadApi] Attendance photo: missing token/SITE_URL');
        return null;
      }
      if (!File(filePath).existsSync()) return null;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/method/upload_file'),
      );
      request.fields['is_private'] = '1';
      request.fields['folder'] = 'Home/Attachments';
      request.headers['Authorization'] = token;
      request.files.add(
        await http.MultipartFile.fromPath('file', filePath, filename: fileName),
      );

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
      final responseBody = await streamedResponse.stream
          .bytesToString()
          .timeout(const Duration(seconds: 60));
      if (streamedResponse.statusCode != 200) {
        debugPrint(
          '[ImageUploadApi] Attendance photo upload failed '
          '[${streamedResponse.statusCode}]: $responseBody',
        );
        return null;
      }
      final fileUrl = jsonDecode(responseBody)['message']?['file_url'];
      return fileUrl is String && fileUrl.isNotEmpty ? fileUrl : null;
    } catch (e) {
      debugPrint('[ImageUploadApi] Attendance photo upload exception: $e');
      return null;
    }
  }

  /// Uploads multiple images and returns a list of uploaded file URLs.
  static Future<List<String>> uploadMultipleImages({
    required List<String> filePaths,
    required String docname,
    BuildContext? context,
  }) async {
    final List<String> uploadedUrls = [];
    for (final path in filePaths) {
      final url = await uploadImageToEvent(
        filePath: path,
        docname: docname,
        context: context,
      );
      if (url != null) uploadedUrls.add(url);
    }
    debugPrint('✅ Uploaded ${uploadedUrls.length}/${filePaths.length} images.');
    return uploadedUrls;
  }

  static Future<String?> uploadImageToEventWithRetry({
    required String filePath,
    required String docname,
    BuildContext? context,
    int attempts = 2,
  }) async {
    final file = File(filePath);
    if (file.existsSync()) {
      final fileSizeKb = file.lengthSync() / 1024;
      debugPrint(
        '[ImageUploadApi] Starting upload for "$filePath" (${fileSizeKb.toStringAsFixed(1)} KB)',
      );
    }

    for (var attempt = 1; attempt <= attempts; attempt++) {
      final result = await uploadImageToEvent(
        filePath: filePath,
        docname: docname,
        context: context,
      );
      if (result != null) {
        return result;
      }

      if (attempt < attempts) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return null;
  }
}
