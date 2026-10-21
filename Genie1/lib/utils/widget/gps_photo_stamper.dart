import 'package:homegenie/utils/platform/platform_file.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../api/location_api.dart';

/// Draws the GPS stamp (time, coordinates, address, map thumbnail) onto a
/// captured photo and saves it as a compressed JPEG, so uploads are a few
/// hundred KB instead of multi-MB PNGs while the stamp stays readable.
class GpsPhotoStamper {
  GpsPhotoStamper._();

  static const double _maxOutputDimension = 960;
  static const int _targetBytes = 200 * 1024;
  static const List<int> _jpegQualities = [75, 62, 50, 40];

  /// Returns a new stamped JPEG file. Falls back to a compressed copy of the
  /// original photo if stamping fails, and to [file] itself as a last resort.
  static Future<File> stamp({
    required File file,
    required double lat,
    required double lng,
    required String address,
    String? title,
    bool includeMapThumbnail = true,
  }) async {
    try {
      return await _stamp(
        file: file,
        lat: lat,
        lng: lng,
        address: address,
        title: title,
        includeMapThumbnail: includeMapThumbnail,
      );
    } catch (error) {
      debugPrint('[GpsPhotoStamper] Stamping failed, compressing only: $error');
      try {
        return await _compressOnly(file);
      } catch (compressError) {
        debugPrint('[GpsPhotoStamper] Compression failed: $compressError');
        return file;
      }
    }
  }

  static String formatCapturedOn(DateTime dateTime) {
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$day-$month-$year $hour:$minute';
  }

  static String buildStampText({
    required DateTime capturedOn,
    required double lat,
    required double lng,
    required String address,
    String? title,
  }) {
    final normalizedAddress = address.replaceAll(RegExp(r'\s+'), ' ').trim();
    final heading =
        (title == null || title.trim().isEmpty) ? '' : '${title.trim()}\n';
    return '$heading'
        'Captured on: ${formatCapturedOn(capturedOn)}\n'
        'Latitude: ${lat.toStringAsFixed(6)}\n'
        'Longitude: ${lng.toStringAsFixed(6)}\n'
        'Address: $normalizedAddress';
  }

  static TextPainter _buildTextPainter({
    required String text,
    required double maxWidth,
    required double maxHeight,
  }) {
    for (double fontSize = 18; fontSize >= 10; fontSize -= 1) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.12,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 7,
        ellipsis: '...',
      )..layout(maxWidth: maxWidth);

      if (painter.height <= maxHeight) {
        return painter;
      }
    }

    return TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.12,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 7,
      ellipsis: '...',
    )..layout(maxWidth: maxWidth);
  }

  static Future<File> _stamp({
    required File file,
    required double lat,
    required double lng,
    required String address,
    String? title,
    required bool includeMapThumbnail,
  }) async {
    final bytes = await file.readAsBytes();
    final ui.Image originalImage = await decodeImageFromList(bytes);
    final capturedOn = await file.lastModified();
    final Uint8List? mapBytes =
        includeMapThumbnail
            ? await LocationHelper.getStaticMapImageBytes(lat, lng)
            : null;
    ui.Image? mapImage;
    if (mapBytes != null) {
      mapImage = await decodeImageFromList(mapBytes);
    }

    final longestSide = math.max(originalImage.width, originalImage.height);
    final scale =
        longestSide > _maxOutputDimension
            ? _maxOutputDimension / longestSide
            : 1.0;
    final int targetWidth =
        math.max(1, (originalImage.width * scale).round()).toInt();
    final int targetHeight =
        math.max(1, (originalImage.height * scale).round()).toInt();

    final stampText = buildStampText(
      capturedOn: capturedOn,
      lat: lat,
      lng: lng,
      address: address,
      title: title,
    );

    final footerHeight = math.max(120.0, targetHeight * 0.28);
    final footerTop = targetHeight.toDouble() - footerHeight;
    final horizontalPadding = targetWidth * 0.02;
    final verticalPadding = footerHeight * 0.08;
    final mapSize =
        mapImage == null
            ? 0.0
            : math.min(
              footerHeight - (verticalPadding * 2),
              targetWidth * 0.26,
            );
    final textStartX =
        mapImage == null
            ? horizontalPadding
            : horizontalPadding + mapSize + horizontalPadding;
    final textWidth = math.max(
      1.0,
      targetWidth.toDouble() - textStartX - horizontalPadding,
    );
    final textHeight = math.max(1.0, footerHeight - (verticalPadding * 2));
    final textPainter = _buildTextPainter(
      text: stampText,
      maxWidth: textWidth,
      maxHeight: textHeight,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawImageRect(
      originalImage,
      Rect.fromLTWH(
        0,
        0,
        originalImage.width.toDouble(),
        originalImage.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, footerTop, targetWidth.toDouble(), footerHeight),
      Paint()..color = Colors.black.withValues(alpha: 0.70),
    );

    if (mapImage != null) {
      final mapRect = Rect.fromLTWH(
        horizontalPadding,
        footerTop + verticalPadding,
        mapSize,
        mapSize,
      );
      canvas.drawRect(
        mapRect.inflate(2),
        Paint()..color = Colors.white.withValues(alpha: 0.95),
      );
      paintImage(
        canvas: canvas,
        rect: mapRect,
        image: mapImage,
        fit: BoxFit.cover,
      );
    }

    final safeTextTop = math.max(
      footerTop + verticalPadding,
      footerTop + ((footerHeight - textPainter.height) / 2),
    );

    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(textStartX, footerTop, textWidth, footerHeight),
    );
    textPainter.paint(canvas, Offset(textStartX, safeTextTop));
    canvas.restore();

    final stampedImage = await recorder.endRecording().toImage(
      targetWidth,
      targetHeight,
    );
    final byteData = await stampedImage.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (byteData == null) {
      throw StateError('Could not read the stamped image pixels.');
    }

    final jpegBytes = await compute(
      _encodeRgbaToJpeg,
      _RgbaFrame(
        width: targetWidth,
        height: targetHeight,
        rgba: byteData.buffer.asUint8List(),
      ),
    );
    return _writeJpeg(file, jpegBytes, '_gps.jpg');
  }

  static Future<File> _compressOnly(File file) async {
    final bytes = await file.readAsBytes();
    final jpegBytes = await compute(_resizeAndEncodeJpeg, bytes);
    return _writeJpeg(file, jpegBytes, '_small.jpg');
  }

  static Future<File> _writeJpeg(File source, Uint8List bytes, String suffix) {
    final outputPath = source.path.replaceFirst(RegExp(r'(\.[^.]*)?$'), suffix);
    debugPrint(
      '[GpsPhotoStamper] Saved ${(bytes.length / 1024).toStringAsFixed(0)} KB '
      'to $outputPath',
    );
    return File(outputPath).writeAsBytes(bytes, flush: true);
  }
}

class _RgbaFrame {
  const _RgbaFrame({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

/// Lowers JPEG quality step by step until the file is under the target size.
Uint8List _encodeJpegWithinTarget(img.Image image) {
  Uint8List encoded = Uint8List(0);
  for (final quality in GpsPhotoStamper._jpegQualities) {
    encoded = img.encodeJpg(image, quality: quality);
    if (encoded.length <= GpsPhotoStamper._targetBytes) break;
  }
  return encoded;
}

Uint8List _encodeRgbaToJpeg(_RgbaFrame frame) {
  final image = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.rgba.buffer,
    numChannels: 4,
  );
  return _encodeJpegWithinTarget(image);
}

Uint8List _resizeAndEncodeJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unsupported image format.');
  }
  final oriented = img.bakeOrientation(decoded);
  final longestSide = math.max(oriented.width, oriented.height);
  final resized =
      longestSide > GpsPhotoStamper._maxOutputDimension
          ? img.copyResize(
            oriented,
            width:
                oriented.width >= oriented.height
                    ? GpsPhotoStamper._maxOutputDimension.round()
                    : null,
            height:
                oriented.height > oriented.width
                    ? GpsPhotoStamper._maxOutputDimension.round()
                    : null,
          )
          : oriented;
  return _encodeJpegWithinTarget(resized);
}
