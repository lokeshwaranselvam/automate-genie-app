import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../utils/face/face_blink_controller.dart';
import '../utils/face/face_image_quality.dart';
import '../utils/face/face_performance_trace.dart';
import '../utils/face/portrait_blur_preview.dart';
import '../utils/face/portrait_blur_service.dart';
import '../utils/face/primary_face.dart';

/// Validates a raw JPEG after one continuous blink and a clear eyes-open photo.
/// [validateCapture] returns null to accept, or guidance to retry. Enrollment
/// can apply a cosmetic portrait effect only after validation has accepted it.
class FaceCapturePage extends StatefulWidget {
  const FaceCapturePage({
    super.key,
    required this.title,
    this.validateCapture,
    this.validatePhotoInCallback = false,
    this.portraitBackgroundBlur = false,
    this.blurCapturedPhoto = false,
  }) : assert(!validatePhotoInCallback || validateCapture != null),
       assert(!blurCapturedPhoto || portraitBackgroundBlur);

  final String title;
  final Future<String?> Function(File rawPhoto)? validateCapture;

  /// The attendance callback performs all final-photo quality checks and
  /// matching on one upright image. Standalone captures retain local checks.
  final bool validatePhotoInCallback;

  /// Cosmetic preview effect. Face checks always receive original frames.
  final bool portraitBackgroundBlur;

  /// Enrollment can also blur its accepted photo; attendance keeps the raw file.
  final bool blurCapturedPhoto;

  @override
  State<FaceCapturePage> createState() => _FaceCapturePageState();
}

class _FaceCapturePageState extends State<FaceCapturePage>
    with WidgetsBindingObserver {
  static const _blue = BrandColors.ink;
  final _blink = FaceBlinkController();
  final _clock = Stopwatch()..start();
  static const _timing = FacePerformanceTrace();
  late final _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: true,
      performanceMode: FaceDetectorMode.fast,
      // Find smaller background faces for the cosmetic exclusion mask. Main
      // face size, blink, pose and final-photo quality thresholds stay intact.
      minFaceSize: widget.portraitBackgroundBlur ? 0.05 : 0.15,
    ),
  );
  CameraController? _camera;
  PortraitBlurService? _portrait;
  Future<void> _cameraOperations = Future<void>.value();
  Future<void>? _frameWork;
  Timer? _timer;
  bool _active = true;
  bool _alive = true;
  bool _processing = false;
  bool _capturing = false;
  bool _starting = true;
  bool _needsSettings = false;
  bool _completed = false;
  int _session = 0;
  int _unsupportedFrames = 0;
  int _detectorFailures = 0;
  String? _error;
  String? _retryMessage;

  @override
  void initState() {
    super.initState();
    if (widget.portraitBackgroundBlur) _portrait = PortraitBlurService();
    WidgetsBinding.instance.addObserver(this);
    _queueStart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _active = true;
      if (!_completed) _queueStart();
    } else {
      _active = false;
      _session++;
      _timer?.cancel();
      _queueStop();
    }
  }

  @override
  void dispose() {
    _alive = false;
    _active = false;
    _session++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _queueStop();
    unawaited(
      _cameraOperations.then((_) async {
        await _portrait?.close();
        await _detector.close();
      }),
    );
    super.dispose();
  }

  void _queueStart() {
    if (!_alive || !_active || _completed) return;
    final session = ++_session;
    _cameraOperations = _cameraOperations
        .then((_) async {
          await _releaseCamera();
          if (!_validSession(session)) return;
          _portrait?.resetPreview();
          await _initializeCamera(session);
        })
        .catchError((Object error) {
          if (_validSession(session)) {
            _showError('Could not open the selfie camera. Please try again.');
          }
        });
  }

  void _queueStop() {
    _cameraOperations = _cameraOperations
        .then((_) => _releaseCamera())
        .catchError((Object error) {});
  }

  bool _validSession(int session) =>
      _alive && mounted && _active && !_completed && session == _session;

  Future<void> _releaseCamera() async {
    final pending = _frameWork;
    if (pending != null) await pending;
    final camera = _camera;
    _camera = null;
    if (camera == null) return;
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } on CameraException {
      // The OS may already have released the camera on backgrounding.
    }
    await camera.dispose();
  }

  Future<void> _initializeCamera(int session) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _showError('Face verification requires an Android or iOS phone.');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
      _retryMessage = null;
      _needsSettings = false;
    });
    final permission = await Permission.camera.request();
    if (!_validSession(session)) return;
    if (!permission.isGranted) {
      _needsSettings =
          permission.isPermanentlyDenied || permission.isRestricted;
      _showError('Allow camera access to capture your live selfie.');
      return;
    }
    final cameras = await availableCameras();
    if (!_validSession(session)) return;
    CameraDescription? front;
    for (final camera in cameras) {
      if (camera.lensDirection == CameraLensDirection.front) {
        front = camera;
        break;
      }
    }
    if (front == null) {
      _showError('A front camera is required for face verification.');
      return;
    }
    final camera = CameraController(
      front,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
    );
    _camera = camera;
    try {
      await _timing.measure('camera initialization', camera.initialize);
      if (!_validSession(session)) return;
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (!_validSession(session)) return;
      _unsupportedFrames = 0;
      _detectorFailures = 0;
      _blink.reset(_clock.elapsed);
      await camera.startImageStream((frame) => _onFrame(frame, session));
      if (!_validSession(session)) return;
      setState(() => _starting = false);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!_validSession(session) || _capturing || _retryMessage != null) {
          return;
        }
        final before = _blink.progress.stage;
        _blink.tick(_clock.elapsed);
        if (_blink.progress.stage != before) setState(() {});
      });
    } on CameraException catch (error) {
      if (!_validSession(session)) return;
      _needsSettings =
          error.code == 'CameraAccessDeniedWithoutPrompt' ||
          error.code == 'CameraAccessRestricted';
      _showError(
        'Could not open the selfie camera. Check camera access and try again.',
      );
    }
  }

  void _onFrame(CameraImage frame, int session) {
    if (!_validSession(session) ||
        _processing ||
        _capturing ||
        _error != null ||
        _retryMessage != null ||
        _blink.progress.needsRetry) {
      return;
    }
    _processing = true;
    _frameWork = _processFrame(frame, session).whenComplete(() {
      _processing = false;
      _frameWork = null;
    });
  }

  Future<void> _processFrame(CameraImage frame, int session) async {
    try {
      final input = _inputImage(frame);
      if (input == null) {
        if (++_unsupportedFrames >= 10 && _validSession(session)) {
          _showError(
            'This camera is not providing a supported image stream. '
            'Please contact support with your phone model.',
          );
        }
        return;
      }
      final faces = await _detector.processImage(input);
      if (!_validSession(session)) return;
      _detectorFailures = 0;
      final rotation = input.metadata!.rotation;
      final rotated =
          rotation == InputImageRotation.rotation90deg ||
          rotation == InputImageRotation.rotation270deg;
      final width = (rotated ? frame.height : frame.width).toDouble();
      final height = (rotated ? frame.width : frame.height).toDouble();
      final face =
          widget.portraitBackgroundBlur
              ? selectPrimaryFace(faces, width, height)
              : (faces.length == 1 ? faces.single : null);
      _portrait?.updatePreview(input, faces, width, height);
      if (widget.blurCapturedPhoto) _portrait?.warmUpPhotoSegmentation(input);
      final rect = face?.boundingBox;
      final previousProgress = _blink.progress;
      final progress = _blink.observe(
        FaceBlinkSample(
          faceCount: face == null ? faces.length : 1,
          leftEyeOpen: face?.leftEyeOpenProbability,
          rightEyeOpen: face?.rightEyeOpenProbability,
          yaw: face?.headEulerAngleY,
          pitch: face?.headEulerAngleX,
          faceFraction:
              rect == null
                  ? 0
                  : math.min(rect.width, rect.height) / math.min(width, height),
          centerOffset:
              rect == null
                  ? 1
                  : math.max(
                    (rect.center.dx / width - 0.5).abs(),
                    (rect.center.dy / height - 0.5).abs(),
                  ),
          brightness: _streamBrightness(frame),
          trackingId: face?.trackingId,
        ),
        _clock.elapsed,
      );
      // Stable camera frames still feed every blink sample, but do not need
      // to rebuild the page when its guidance and capture state are unchanged.
      if (previousProgress.stage != progress.stage ||
          previousProgress.instruction != progress.instruction) {
        setState(() {});
      }
      if (progress.canCapture) await _captureSelfie(session);
    } catch (_) {
      if (_validSession(session) && ++_detectorFailures >= 3) {
        _showError('The face scan could not run. Please try again.');
      }
    }
  }

  InputImage? _inputImage(CameraImage image) {
    final camera = _camera;
    if (camera == null || image.planes.length != 1) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if ((Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    final sensor = camera.description.sensorOrientation;
    int degrees = sensor;
    if (Platform.isAndroid) {
      const orientations = {
        DeviceOrientation.portraitUp: 0,
        DeviceOrientation.landscapeLeft: 90,
        DeviceOrientation.portraitDown: 180,
        DeviceOrientation.landscapeRight: 270,
      };
      final compensation = orientations[camera.value.deviceOrientation];
      if (compensation == null) return null;
      degrees =
          camera.description.lensDirection == CameraLensDirection.front
              ? (sensor + compensation) % 360
              : (sensor - compensation + 360) % 360;
    }
    final rotation = InputImageRotationValue.fromRawValue(degrees);
    if (rotation == null || format == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  double _streamBrightness(CameraImage frame) {
    final plane = frame.planes.first;
    double total = 0;
    int count = 0;
    // Sample the center region; do not decode or allocate a full RGB frame.
    for (int y = frame.height ~/ 4; y < frame.height * 3 ~/ 4; y += 16) {
      for (int x = frame.width ~/ 4; x < frame.width * 3 ~/ 4; x += 16) {
        final index = y * plane.bytesPerRow + (Platform.isIOS ? x * 4 : x);
        if (index < 0 || index >= plane.bytes.length) continue;
        if (Platform.isIOS) {
          if (index + 2 >= plane.bytes.length) continue;
          total +=
              plane.bytes[index] * 0.114 +
              plane.bytes[index + 1] * 0.587 +
              plane.bytes[index + 2] * 0.299;
        } else {
          total += plane.bytes[index];
        }
        count++;
      }
    }
    return count == 0 ? 0 : total / count;
  }

  Future<void> _captureSelfie(int session) async {
    final camera = _camera;
    if (camera == null || _capturing || !_validSession(session)) return;
    setState(() => _capturing = true);
    File? photo;
    File? portrait;
    bool accepted = false;
    try {
      _timer?.cancel();
      await camera.stopImageStream();
      if (!_validSession(session)) return;
      photo = File((await camera.takePicture()).path);
      if (!_validSession(session)) return;
      String? error;
      if (!widget.validatePhotoInCallback || widget.validateCapture == null) {
        final faces = await _detector.processImage(
          InputImage.fromFilePath(photo.path),
        );
        if (!_validSession(session)) return;
        final information = await compute(
          _jpegInformation,
          await photo.readAsBytes(),
        );
        if (!_validSession(session)) return;
        final face =
            widget.portraitBackgroundBlur && information != null
                ? selectPrimaryFace(
                  faces,
                  information['width']!,
                  information['height']!,
                )
                : (faces.length == 1 ? faces.single : null);
        if (face == null) {
          error = 'Keep only your face in the camera and try again.';
        } else {
          final yaw = face.headEulerAngleY;
          final pitch = face.headEulerAngleX;
          if (information == null || information['brightness']! < 35) {
            error =
                'The selfie is too dark. Move to better lighting and try again.';
          } else if (yaw == null ||
              pitch == null ||
              yaw.abs() > 20 ||
              pitch.abs() > 20) {
            error = 'Look straight at the camera and try again.';
          } else if ((face.leftEyeOpenProbability ?? 0) < 0.65 ||
              (face.rightEyeOpenProbability ?? 0) < 0.65) {
            error = 'Keep both eyes open after your blink and try again.';
          } else if (math.min(face.boundingBox.width, face.boundingBox.height) <
              100) {
            error = 'Move closer so your face is clear and try again.';
          }
        }
      }
      if (error == null && widget.validateCapture != null) {
        error = await widget.validateCapture!(photo);
        if (!_validSession(session)) return;
      }
      if (error != null) {
        setState(() => _retryMessage = error);
      } else {
        // Keep the original photo as the input to every existing face check.
        // Only an accepted enrollment photograph receives the cosmetic effect.
        if (widget.blurCapturedPhoto) {
          portrait = await _portrait?.blurAcceptedPhoto(photo, _detector);
        }
        if (!mounted || !_validSession(session)) return;
        accepted = true;
        _completed = true;
        Navigator.of(context).pop<File>(portrait ?? photo);
      }
    } catch (_) {
      if (_validSession(session)) {
        setState(
          () =>
              _retryMessage = 'Could not verify this selfie. Please try again.',
        );
      }
    } finally {
      if (portrait != null && portrait.path != photo?.path && !accepted) {
        try {
          if (await portrait.exists()) await portrait.delete();
        } on FileSystemException {
          // Remove only this capture's cancelled cosmetic output.
        }
      }
      if (photo != null &&
          (!accepted || (portrait != null && portrait.path != photo.path))) {
        try {
          if (await photo.exists()) await photo.delete();
        } on FileSystemException {
          // Only this screen's rejected temporary selfie is removed.
        }
      }
      _capturing = false;
      if (_alive && mounted) setState(() {});
    }
  }

  void _showError(String error) {
    _timer?.cancel();
    if (!_alive || !mounted) return;
    setState(() {
      _starting = false;
      _error = error;
    });
  }

  Future<void> _retry() async {
    if (_needsSettings) {
      await openAppSettings();
      return;
    }
    _queueStart();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final previewReady = camera != null && camera.value.isInitialized;
    final message =
        _error ??
        _retryMessage ??
        (_capturing ? 'Checking your selfie…' : _blink.progress.instruction);
    final needsRetry =
        _error != null || _retryMessage != null || _blink.progress.needsRetry;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FC),
      appBar: brandAppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (previewReady)
                          Center(
                            child:
                                _portrait == null
                                    ? CameraPreview(camera)
                                    : AspectRatio(
                                      aspectRatio: 1 / camera.value.aspectRatio,
                                      child: PortraitBlurPreview(
                                        mask: _portrait!.previewMask,
                                        child: CameraPreview(camera),
                                      ),
                                    ),
                          ),
                        if (previewReady)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _FaceGuidePainter(
                                color:
                                    _blink.progress.canCapture
                                        ? Colors.green
                                        : Colors.white,
                              ),
                            ),
                          ),
                        if (_starting || _capturing)
                          const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                        if (!previewReady && !_starting)
                          const Center(
                            child: Icon(
                              Icons.face,
                              color: Colors.white70,
                              size: 80,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                children: [
                  Icon(
                    needsRetry ? Icons.info_outline : Icons.face,
                    color: _blue,
                    size: 30,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The camera takes your selfie automatically after you blink.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF667085), height: 1.4),
                  ),
                  if (needsRetry && !_capturing) ...[
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _retry,
                        style: FilledButton.styleFrom(
                          backgroundColor: _blue,
                        ).copyWith(
                          backgroundBuilder: BrandColors.buttonBackground,
                        ),
                        icon: Icon(
                          _needsSettings
                              ? Icons.settings
                              : Icons.camera_alt_outlined,
                        ),
                        label: Text(
                          _needsSettings ? 'Open settings' : 'Try again',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Map<String, double>? _jpegInformation(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final image = img.bakeOrientation(decoded);
  return {
    'brightness': faceCenterBrightness(image),
    'width': image.width.toDouble(),
    'height': image.height.toDouble(),
  };
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final width = math.min(size.width * 0.76, size.height * 0.56);
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: width * 1.28,
    );
    final shade =
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addOval(rect);
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_FaceGuidePainter oldDelegate) =>
      oldDelegate.color != color;
}
