import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;

import '../../Screen/face_capture_page.dart';
import '../api/face_auth_api.dart';
import '../api/location_api.dart';
import 'face_embedding_service.dart';
import 'face_template_cache.dart';
import 'face_performance_trace.dart';

typedef FaceCapture =
    Future<File?> Function(
      BuildContext context,
      String title,
      Future<String?> Function(File) validate,
    );

typedef FaceLocation = ({Position position, String address});
typedef _LocationOutcome =
    ({FaceLocation? location, Object? error, StackTrace? stackTrace});

class FaceVerifiedResult {
  const FaceVerifiedResult({
    required this.receipt,
    required this.currentUser,
    required this.position,
    required this.address,
  });

  final FaceVerificationReceipt receipt;
  final String currentUser;
  final Position position;
  final String address;
  String get recordId => receipt.recordId;
}

class FaceAuthFlow {
  FaceAuthFlow({
    FaceAuthApi? api,
    FaceTemplateCache? cache,
    Future<List<double>> Function(File)? embed,
    Future<List<double>> Function(File)? captureEmbed,
    Future<void> Function()? warmUp,
    FaceCapture? capture,
  }) : api = api ?? FaceAuthApi.instance,
       _cache = cache ?? FaceTemplateCache.instance,
       _embed = embed ?? FaceEmbeddingService.instance.embeddingFromFile,
       _captureEmbed =
           captureEmbed ??
           embed ??
           FaceEmbeddingService.instance.embeddingFromCapture,
       _warmUp =
           warmUp ??
           (embed == null ? FaceEmbeddingService.instance.warmUp : _noWarmUp),
       _capture = capture ?? _openCamera,
       _enrollmentCapture = capture ?? _openCamera;

  static final instance = FaceAuthFlow();
  final FaceAuthApi api;
  final FaceTemplateCache _cache;
  final Future<List<double>> Function(File) _embed;
  final Future<List<double>> Function(File) _captureEmbed;
  final Future<void> Function() _warmUp;
  final FaceCapture _capture;
  final FaceCapture _enrollmentCapture;
  final _templateLoads = <String, Future<List<double>>>{};
  static const _timing = FacePerformanceTrace();

  static Future<void> _noWarmUp() async {}

  static Future<File?> _openCamera(
    BuildContext context,
    String title,
    Future<String?> Function(File) validate,
  ) => Navigator.of(context, rootNavigator: true).push<File>(
    MaterialPageRoute(
      builder:
          (_) => FaceCapturePage(
            title: title,
            validateCapture: validate,
            validatePhotoInCallback: true,
            usePrimaryFaceSelection: true,
          ),
    ),
  );

  String _identity(FaceEnrollmentStatus status) => jsonEncode([
    api.site.toString(),
    status.currentUser,
    status.referenceName,
    status.referenceVersion,
    FaceAuthApi.modelVersion,
  ]);

  Future<List<double>> _template(FaceEnrollmentStatus status) async {
    final key = jsonEncode([_identity(status), _cache.generation]);
    final load = _templateLoads.putIfAbsent(key, () => _loadTemplate(status));
    try {
      final template = await load;
      await api.assertSessionUser(status.currentUser);
      return template;
    } finally {
      if (identical(_templateLoads[key], load)) _templateLoads.remove(key);
    }
  }

  Future<List<double>> _loadTemplate(FaceEnrollmentStatus status) async {
    final identity = _identity(status);
    final cached = await _cache.read(identity);
    await api.assertSessionUser(status.currentUser);
    if (cached != null) return cached;
    final generation = _cache.generation;
    final bytes = await api.downloadReference(status);
    final directory = await Directory.systemTemp.createTemp(
      'genie-face-reference-',
    );
    try {
      final photo = await File(
        '${directory.path}/reference.jpg',
      ).writeAsBytes(bytes, flush: true);
      final embedding = await _embed(photo);
      await api.assertSessionUser(status.currentUser);
      await _cache.write(identity, embedding, expectedGeneration: generation);
      return embedding;
    } finally {
      await directory.delete(recursive: true);
    }
  }

  /// Background preparation on opening Attendance. Verification still obtains
  /// fresh ERP status; only the version-bound template/model are reused.
  Future<void> prepare() async {
    await Future.wait<void>([
      _warmUp(),
      (() async {
        final status = await api.status();
        if (status.enrolled) await _template(status);
      })(),
    ]);
  }

  /// Called after login and on saved-session startup. Cancel leaves enrollment pending.
  Future<FaceEnrollmentStatus?> enroll(
    BuildContext context,
    FaceEnrollmentStatus status,
  ) async {
    if (status.enrolled) return status;
    _warmUp().ignore();
    final photo = await _enrollmentCapture(
      context,
      'Set up your attendance selfie',
      (photo) async {
        try {
          await _captureEmbed(photo);
          return null;
        } catch (error) {
          return error.toString();
        }
      },
    );
    if (photo == null) return null;
    try {
      if (!context.mounted) return null;
      await api.assertSessionUser(status.currentUser);
      final jpeg = await compute(_enrollmentJpeg, await photo.readAsBytes());
      final enrolled = await api.enroll(status, jpeg);
      if (!context.mounted) return null;
      await api.assertSessionUser(status.currentUser);
      if (!enrolled.enrolled) {
        throw StateError('ERP did not save your enrollment photo.');
      }
      // Derive from the saved reference on first verification, not a differently
      // compressed or older camera image. No self-reenrollment is allowed.
      await _cache.clear();
      return enrolled;
    } finally {
      await _delete(photo);
    }
  }

  Future<FaceVerifiedResult?> verify({
    required BuildContext context,
    required String action,
    required Future<FaceLocation> Function() refreshLocation,
    bool overlapLocationWithMatching = false,
  }) async {
    _warmUp().ignore();
    final status = await _timing.measure('ERP face status', api.status);
    if (!status.enrolled) {
      throw StateError(
        'Complete your first-login selfie setup before checking in or out.',
      );
    }
    if (status.receiptVersion != 2) {
      throw StateError(
        'Update the ERP face scripts to use attendance without saving selfies.',
      );
    }
    // Open the camera while a missing reference is being prepared. Its result
    // is still required before the candidate can be accepted.
    final templateFuture = _timing.measure(
      'reference template',
      () => _template(status),
    );
    templateFuture.ignore();
    if (!context.mounted) return null;
    double? similarity;
    DateTime? capturedOn;
    Future<_LocationOutcome>? pendingLocation;
    final label = switch (action) {
      'attendance_in' => 'Employee Check-in',
      'attendance_out' => 'Employee Check-out',
      _ => throw ArgumentError.value(action, 'action'),
    };
    final photo = await _capture(context, label, (photo) async {
      similarity = null;
      capturedOn = null;
      pendingLocation = null;
      try {
        await api.assertSessionUser(status.currentUser);
        if (overlapLocationWithMatching) {
          pendingLocation = _loadLocation(refreshLocation);
        }
        final template = await templateFuture;
        final embedding = await _timing.measure(
          'selfie verification',
          () => _captureEmbed(photo),
        );
        await api.assertSessionUser(status.currentUser);
        final score = FaceEmbeddingService.cosineSimilarity(
          template,
          embedding,
        );
        if (!score.isFinite || score < status.minimumSimilarity) {
          return 'This selfie does not match your enrolled face. Look straight at the camera and try again.';
        }
        similarity = score.clamp(-1.0, 1.0);
        capturedOn = DateTime.now();
        return null;
      } catch (error) {
        return error.toString();
      }
    });
    if (photo == null) return null;
    final postMatchClock = Stopwatch()..start();
    try {
      if (!context.mounted) return null;
      await api.assertSessionUser(status.currentUser);
      if (similarity == null || capturedOn == null) {
        throw StateError('The selfie was not face verified. Please retry.');
      }
      // Head Office retains its fresh geofence check after matching. Other
      // attendance paths may overlap GPS with matching after photo capture.
      // Errors are observed even for rejected/cancelled capture attempts.
      final outcome = await (pendingLocation ?? _loadLocation(refreshLocation));
      if (outcome.error != null) {
        Error.throwWithStackTrace(outcome.error!, outcome.stackTrace!);
      }
      final location = outcome.location!;
      if (!context.mounted) return null;
      await api.assertSessionUser(status.currentUser);
      final receipt = await _timing.measure(
        'verification receipt',
        () => api.recordVerification(
          status: status,
          action: action,
          similarity: similarity!,
          latitude: location.position.latitude,
          longitude: location.position.longitude,
          capturedOn: capturedOn!,
        ),
      );
      if (!context.mounted) return null;
      await api.assertSessionUser(status.currentUser);
      return FaceVerifiedResult(
        receipt: receipt,
        currentUser: status.currentUser,
        position: location.position,
        address: location.address,
      );
    } finally {
      FacePerformanceTrace.logDuration(
        'after face match to receipt',
        postMatchClock.elapsed,
      );
      await _delete(photo);
    }
  }

  Future<_LocationOutcome> _loadLocation(
    Future<FaceLocation> Function() refresh,
  ) async {
    try {
      final location = await _timing.measure('fresh GPS and address', refresh);
      return (location: location, error: null, stackTrace: null);
    } catch (error, stackTrace) {
      return (location: null, error: error, stackTrace: stackTrace);
    }
  }

  static Future<FaceLocation> freshLocation({
    bool Function(Position)? isAllowed,
    String restrictionMessage = 'You are outside the allowed location.',
  }) async {
    final position = await _timing.measure(
      'fresh GPS fix',
      () => Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      ),
    );
    if (isAllowed != null && !isAllowed(position)) {
      throw StateError(restrictionMessage);
    }
    // An address is descriptive; missing reverse geocoding must not replace
    // a valid GPS fix or delay the submission indefinitely.
    var address =
        '${position.latitude.toStringAsFixed(6)}, '
        '${position.longitude.toStringAsFixed(6)}';
    try {
      final resolved = await _timing.measure(
        'reverse geocoding',
        () => LocationHelper.getAddressFromCoordinates(
          position.latitude,
          position.longitude,
        ).timeout(const Duration(seconds: 4)),
      );
      if (resolved.trim().isNotEmpty) address = resolved;
    } catch (_) {}
    return (position: position, address: address);
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

Uint8List _enrollmentJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('The selfie is not a valid image.');
  var image = img.bakeOrientation(decoded);
  if (image.width > 1280 || image.height > 1280) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 1280 : null,
      height: image.height > image.width ? 1280 : null,
    );
  }
  final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 92));
  if (jpeg.length > 2 * 1024 * 1024) {
    throw StateError('The selfie is too large. Please capture it again.');
  }
  return jpeg;
}
