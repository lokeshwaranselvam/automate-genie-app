import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';

import 'portrait_blur_image.dart';
import 'primary_face.dart';

/// Cosmetic processing only. The original image remains the validation input.
class PortraitBlurService {
  PortraitBlurService({bool? subjectSegmentationSupported})
    : _useSubjectSegmentation =
          subjectSegmentationSupported ?? Platform.isAndroid;
  final bool _useSubjectSegmentation;
  final previewMask = ValueNotifier<ui.Image?>(null);
  final _clock = Stopwatch()..start();
  SelfieSegmenter? _previewSegmenter, _photoSegmenter;
  SubjectSegmenter? _subjectSegmenter;
  Future<void>? _subjectWarmUp;
  Future<void>? _previewWork;
  Duration _lastPreview = const Duration(seconds: -1);
  int _generation = 0, _failures = 0;
  bool _closed = false;

  SubjectSegmenter _subjects() =>
      _subjectSegmenter ??= SubjectSegmenter(
        options: SubjectSegmenterOptions(
          enableForegroundBitmap: false,
          enableForegroundConfidenceMask: false,
          enableMultipleSubjects: SubjectResultOptions(
            enableConfidenceMask: true,
            enableSubjectBitmap: false,
          ),
        ),
      );

  /// A single still frame starts the SDK's automatic model download early.
  /// This is cosmetic preparation only and never delays live blink checks.
  void warmUpPhotoSegmentation(InputImage image) {
    if (_closed || !_useSubjectSegmentation || _subjectWarmUp != null) return;
    _subjectWarmUp =
        (() async {
          try {
            await _subjects().processImage(image);
          } catch (_) {
            /* Google Play services may still be downloading the model. */
          }
        })();
  }

  Future<PortraitMatte?> _subjectMatte(
    InputImage image,
    int width,
    int height,
    PortraitFaceRegion face,
    List<PortraitFaceRegion> backgroundFaces,
  ) async {
    if (!_useSubjectSegmentation || _closed) return null;
    try {
      await _subjectWarmUp;
      if (_closed) return null;
      final result = await _subjects().processImage(image);
      if (_closed) return null;
      return await compute(
        buildSubjectPortraitMatte,
        PortraitSubjectInput(
          width,
          height,
          result.subjects
              .where((subject) => subject.confidenceMask != null)
              .map(
                (subject) => PortraitSubjectMask(
                  subject.startX,
                  subject.startY,
                  subject.width,
                  subject.height,
                  subject.confidenceMask!,
                ),
              )
              .toList(),
          face,
          backgroundFaces: backgroundFaces,
        ),
      );
    } catch (_) {
      // Missing model/Play services or unavailable subjects retain local blur.
      return null;
    }
  }

  void resetPreview() {
    _generation++;
    _failures = 0;
    _setMask(null);
  }

  void updatePreview(
    InputImage image,
    List<Face> faces,
    double width,
    double height,
  ) {
    if (_closed ||
        _previewWork != null ||
        _failures >= 3 ||
        _clock.elapsed - _lastPreview < const Duration(milliseconds: 250)) {
      return;
    }
    if (faces.isEmpty) {
      _setMask(null);
      return;
    }
    final face = selectPrimaryFace(faces, width, height);
    if (face == null) {
      _setMask(null);
      return;
    }
    final region = _region(face.boundingBox, width, height);
    final backgroundFaces =
        faces
            .where((other) => !identical(other, face))
            .map((other) => _region(other.boundingBox, width, height))
            .toList();
    final generation = _generation;
    _lastPreview = _clock.elapsed;
    _previewWork = _update(
      image,
      region,
      backgroundFaces,
      generation,
    ).whenComplete(() => _previewWork = null);
  }

  Future<void> _update(
    InputImage image,
    PortraitFaceRegion face,
    List<PortraitFaceRegion> backgroundFaces,
    int generation,
  ) async {
    try {
      final segmenter =
          _previewSegmenter ??= SelfieSegmenter(enableRawSizeMask: true);
      final result = await segmenter.processImage(image);
      if (_closed || generation != _generation) return;
      if (result == null) {
        _setMask(null);
        return;
      }
      final bytes = await compute(
        buildPortraitMatte,
        PortraitMatteInput(
          result.width,
          result.height,
          result.confidences,
          face,
          backgroundFaces: backgroundFaces,
        ),
      );
      if (_closed || generation != _generation || bytes == null) return;
      final completed = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes,
        result.width,
        result.height,
        ui.PixelFormat.rgba8888,
        completed.complete,
      );
      final mask = await completed.future;
      if (_closed || generation != _generation) {
        mask.dispose();
        return;
      }
      _failures = 0;
      _setMask(mask);
    } catch (_) {
      _failures++;
      if (!_closed && generation == _generation) _setMask(null);
    }
  }

  void _setMask(ui.Image? next) {
    if (_closed) {
      next?.dispose();
      return;
    }
    final previous = previewMask.value;
    if (identical(previous, next)) return;
    previewMask.value = next;
    if (previous != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  /// Called only after the existing raw-image callback accepted registration.
  /// On an unavailable cosmetic effect, the accepted original is retained.
  Future<File> blurAcceptedPhoto(File original, FaceDetector detector) async {
    Directory? directory;
    File? upright;
    File? output;
    var completed = false;
    try {
      final bytes = await compute(
        preparePortraitImage,
        await original.readAsBytes(),
      );
      if (_closed) return original;
      directory = await Directory.systemTemp.createTemp('genie-portrait-');
      upright = await File(
        '${directory.path}/upright.png',
      ).writeAsBytes(bytes, flush: true);
      final input = InputImage.fromFilePath(upright.path);
      final faces = await detector.processImage(input);
      if (_closed || faces.isEmpty) return original;
      final data = ByteData.sublistView(bytes);
      final width = data.getUint32(16).toDouble(),
          height = data.getUint32(20).toDouble();
      final face = selectPrimaryFace(faces, width, height);
      if (face == null) return original;
      final region = _region(face.boundingBox, width, height);
      final backgroundFaces =
          faces
              .where((other) => !identical(other, face))
              .map((other) => _region(other.boundingBox, width, height))
              .toList();
      var matte = await _subjectMatte(
        input,
        width.toInt(),
        height.toInt(),
        region,
        backgroundFaces,
      );
      if (_closed) return original;
      if (matte == null) {
        final segmenter =
            _photoSegmenter ??= SelfieSegmenter(
              mode: SegmenterMode.single,
              enableRawSizeMask: true,
            );
        final mask = await segmenter.processImage(input);
        if (_closed || mask == null) return original;
        final rgba = await compute(
          buildPortraitMatte,
          PortraitMatteInput(
            mask.width,
            mask.height,
            mask.confidences,
            region,
            backgroundFaces: backgroundFaces,
          ),
        );
        if (rgba != null) matte = PortraitMatte(mask.width, mask.height, rgba);
      }
      if (_closed || matte == null) return original;
      final result = await compute(
        compositePortraitImage,
        PortraitCompositeInput(bytes, matte.rgba, matte.width, matte.height),
      );
      if (_closed) return original;
      output = File(
        '${original.path}.portrait-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await output.writeAsBytes(result, flush: true);
      completed = true;
      return output;
    } catch (_) {
      return original;
    } finally {
      if (!completed && output != null) {
        try {
          if (await output.exists()) await output.delete();
        } on FileSystemException {
          /* Own incomplete output. */
        }
      }
      if (directory != null) {
        try {
          if (upright != null && await upright.exists()) await upright.delete();
          await directory.delete();
        } on FileSystemException {
          /* Temporary cosmetic output only. */
        }
      }
    }
  }

  PortraitFaceRegion _region(ui.Rect face, double width, double height) =>
      PortraitFaceRegion(
        face.left / width,
        face.top / height,
        face.right / width,
        face.bottom / height,
      );

  Future<void> close() async {
    _closed = true;
    _generation++;
    await _previewWork;
    await _subjectWarmUp;
    previewMask.value?.dispose();
    previewMask.dispose();
    for (final segmenter in [_previewSegmenter, _photoSegmenter]) {
      try {
        await segmenter?.close();
      } catch (_) {
        // An unavailable cosmetic plugin must not interrupt camera cleanup.
      }
    }
    try {
      await _subjectSegmenter?.close();
    } catch (_) {
      /* Cosmetic plugin cleanup must not interrupt camera cleanup. */
    }
  }
}
