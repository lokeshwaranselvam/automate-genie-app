import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';
import '../face/face_performance_trace.dart';

class FaceEnrollmentStatus {
  const FaceEnrollmentStatus({
    required this.currentUser,
    required this.csrfToken,
    required this.minimumSimilarity,
    this.referenceName,
    this.referenceUrl,
    this.referenceVersion,
    this.receiptVersion = 2,
  });

  final String currentUser;
  final String csrfToken;
  final double minimumSimilarity;
  final String? referenceName;
  final String? referenceUrl;
  final String? referenceVersion;
  final int receiptVersion;
  bool get enrolled => referenceName != null;
}

class FaceVerificationReceipt {
  const FaceVerificationReceipt({required this.recordId});

  final String recordId;
}

/// Uses the verified Frappe session, never an employee/user supplied by a form.
class FaceAuthApi {
  FaceAuthApi({
    http.Client? client,
    Future<String?> Function()? sessionId,
    Future<String?> Function()? savedUser,
    Uri? site,
  }) : _client = client ?? http.Client(),
       _sessionId = sessionId ?? SessionAuthApi.getSessionId,
       _savedUser = savedUser ?? SessionAuthApi.getSavedSessionUser,
       _siteOverride = site;

  static final instance = FaceAuthApi();
  static const modelVersion = 'opencv-sface-2021dec-int8bq-v1';
  static const _timeout = Duration(seconds: 25);
  static const _imageUploadTimeout = Duration(seconds: 90);
  final http.Client _client;
  final Future<String?> Function() _sessionId;
  final Future<String?> Function() _savedUser;
  final Uri? _siteOverride;

  Uri get site {
    if (_siteOverride != null) return _siteOverride;
    final value = dotenv.env['SITE_URL']?.trim() ?? '';
    if (value.isEmpty) throw StateError('SITE_URL is not configured.');
    return Uri.parse(value.endsWith('/') ? value : '$value/');
  }

  Future<({String user, Map<String, String> headers})> _auth({
    String? expectedUser,
  }) async {
    final user = await _savedUser();
    final sid = await _sessionId();
    if (user == null || user.isEmpty || sid == null || sid.isEmpty) {
      throw StateError('Your ERP session expired. Please sign in again.');
    }
    if (expectedUser != null && user != expectedUser) {
      throw StateError('Your account changed. Please start the selfie again.');
    }
    return (
      user: user,
      headers: {
        'Accept': 'application/json',
        'Cookie': 'sid=$sid',
        'Cache-Control': 'no-cache, no-store',
      },
    );
  }

  /// Abort an in-flight scan if logout or account switching occurred.
  Future<void> assertSessionUser(String expectedUser) async {
    await _auth(expectedUser: expectedUser);
  }

  Map<String, dynamic> _message(http.Response response, String expectedUser) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw StateError('ERP returned an invalid face verification response.');
    }
    if (response.statusCode != 200) {
      var detail = 'Face verification request failed (${response.statusCode}).';
      if (decoded is Map) {
        try {
          final messages = jsonDecode(decoded['_server_messages'] ?? '[]');
          if (messages is List && messages.isNotEmpty) {
            final first = messages.first;
            final value = first is String ? jsonDecode(first) : first;
            if (value is Map && value['message'] is String) {
              detail = value['message'];
            }
          }
        } catch (_) {}
        if (decoded['message'] is String) detail = decoded['message'];
        final exceptionType = decoded['exc_type']?.toString() ?? '';
        if (exceptionType.isNotEmpty &&
            RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(exceptionType) &&
            (decoded['message'] == null ||
                decoded['message'] == 'Internal Server Error')) {
          var exceptionSummary = '';
          for (final line
              in (decoded['exception']?.toString() ?? '')
                  .split(RegExp(r'[\r\n]+'))
                  .reversed) {
            final cleaned = line.replaceAll(RegExp(r'<[^>]*>'), '').trim();
            if (cleaned.isNotEmpty) {
              exceptionSummary = cleaned;
              break;
            }
          }
          if (exceptionSummary.length > 240) {
            exceptionSummary = '${exceptionSummary.substring(0, 240)}...';
          }
          detail = 'ERP server error ($exceptionType)';
          if (exceptionSummary.isNotEmpty) {
            detail = '$detail: $exceptionSummary';
          }
          detail = '$detail. Check the Frappe server logs for this request.';
        }
      }
      throw StateError(detail.replaceAll(RegExp(r'<[^>]*>'), ''));
    }
    final message = decoded is Map ? decoded['message'] : null;
    if (message is! Map || message['current_user'] != expectedUser) {
      throw StateError(
        'ERP did not confirm the signed-in user. Sign in again.',
      );
    }
    return Map<String, dynamic>.from(message);
  }

  FaceEnrollmentStatus _status(Map<String, dynamic> message) {
    if (message['model_version'] != modelVersion) {
      throw StateError('The face model does not match ERP. Update the app.');
    }
    final threshold = double.tryParse('${message['minimum_similarity']}');
    if (threshold == null ||
        !threshold.isFinite ||
        threshold <= 0 ||
        threshold > 1) {
      throw StateError('ERP has an invalid face matching threshold.');
    }
    final csrf = message['csrf_token']?.toString() ?? '';
    if (csrf.isEmpty) {
      throw StateError('ERP did not return a session CSRF token.');
    }
    final reference = message['reference_file'];
    final enrolled = message['enrolled'] == true;
    if (enrolled &&
        (reference is! Map ||
            '${reference['name'] ?? ''}'.isEmpty ||
            '${reference['file_url'] ?? reference['url'] ?? ''}'.isEmpty ||
            '${reference['version'] ?? ''}'.isEmpty)) {
      throw StateError('Your enrolled face photo is incomplete in ERP.');
    }
    return FaceEnrollmentStatus(
      currentUser: message['current_user'],
      csrfToken: csrf,
      minimumSimilarity: threshold,
      referenceName: enrolled ? reference['name'].toString() : null,
      referenceUrl:
          enrolled
              ? (reference['file_url'] ?? reference['url']).toString()
              : null,
      referenceVersion: enrolled ? reference['version'].toString() : null,
      receiptVersion: message['verification_receipt_version'] == 2 ? 2 : 1,
    );
  }

  Future<FaceEnrollmentStatus> status() async {
    final auth = await _auth();
    final request = http.Request(
      'GET',
      site
          .resolve('api/method/mobile_face_auth')
          .replace(queryParameters: {
            'action': 'status',
            'model_version': modelVersion,
          }),
    )..headers.addAll(auth.headers);
    final response = await _send(request);
    await assertSessionUser(auth.user);
    final message = _message(response, auth.user);
    final responseToken = message['csrf_token']?.toString() ?? '';
    if (responseToken.isNotEmpty) return _status(message);

    final token = await const FacePerformanceTrace().measure(
      'face CSRF bootstrap',
      () => _loadDeskCsrfToken(auth),
    );
    await assertSessionUser(auth.user);
    return _status({...message, 'csrf_token': token});
  }

  Future<String> _loadDeskCsrfToken(
    ({String user, Map<String, String> headers}) auth,
  ) async {
    final response = await _getFollowingSameOriginRedirects(
      site.resolve('app'),
      auth.headers,
    );
    if (response.statusCode != 200) {
      throw StateError(
        'ERP could not initialize the face session token '
        '(${response.statusCode}). Sign in again and retry.',
      );
    }

    final match = RegExp(
      r'frappe\.csrf_token\s*=\s*"([^"]+)"',
    ).firstMatch(response.body);
    final token = match?.group(1);
    if (token == null || token.isEmpty) {
      throw StateError(
        'ERP Desk did not provide a CSRF token for this session. '
        'Confirm this ERP user can access Desk, then sign in again.',
      );
    }
    return token;
  }

  Future<http.Response> _getFollowingSameOriginRedirects(
    Uri uri,
    Map<String, String> headers,
  ) async {
    const redirectStatuses = {301, 302, 303, 307, 308};
    for (var redirects = 0; ; redirects++) {
      final response = await _send(
        http.Request('GET', uri)..headers.addAll(headers),
      );
      if (!redirectStatuses.contains(response.statusCode)) return response;
      if (redirects == 3) {
        throw StateError(
          'ERP Desk redirected too many times while initializing the '
          'face session. Check the ERP site URL and sign in again.',
        );
      }

      final location = response.headers['location'];
      if (location == null || location.isEmpty) return response;
      final redirectedUri = uri.resolve(location);
      if (redirectedUri.origin != site.origin ||
          redirectedUri.userInfo.isNotEmpty) {
        throw StateError(
          'ERP Desk redirected to a different site. Update SITE_URL to the '
          'canonical ERP URL, then sign in again.',
        );
      }
      uri = redirectedUri;
    }
  }

  Future<Map<String, dynamic>> _post(
    FaceEnrollmentStatus status,
    Map<String, dynamic> body,
  ) async {
    final auth = await _auth(expectedUser: status.currentUser);
    final request =
        http.Request('POST', site.resolve('api/method/mobile_face_auth'))
          ..headers.addAll({
            ...auth.headers,
            'Content-Type': 'application/json',
            'X-Frappe-CSRF-Token': status.csrfToken,
          })
          ..body = jsonEncode({
            ...body,
            'csrf_token': status.csrfToken,
            if (FacePerformanceTrace.enabled &&
                body['action'] == 'record_verification')
              'include_timings': true,
          });
    final response = await _send(
      request,
      timeout: _imageUploadTimeout,
      timingStage: 'face receipt',
    );
    await assertSessionUser(auth.user);
    final message = _message(response, auth.user);
    FacePerformanceTrace.logServerTimings(jsonDecode(response.body));
    return message;
  }

  Future<http.Response> _send(
    http.Request request, {
    Duration timeout = _timeout,
    String? timingStage,
  }) {
    // Explicit cookies must never follow a redirect to another origin.
    request.followRedirects = false;
    if (timingStage != null) {
      return FacePerformanceTrace.send(
        _client,
        request,
        timingStage,
      ).timeout(timeout);
    }
    return (() async {
      final response = await _client.send(request);
      return http.Response.fromStream(response);
    })().timeout(timeout);
  }

  Future<FaceEnrollmentStatus> enroll(
    FaceEnrollmentStatus status,
    Uint8List jpeg,
  ) async => _status(
    await _post(status, {
      'action': 'enroll',
      'image_base64': base64Encode(jpeg),
      'model_version': modelVersion,
      'blink_completed': true,
    }),
  );

  Future<Uint8List> downloadReference(FaceEnrollmentStatus status) async {
    if (!status.enrolled) {
      throw StateError('Take your first-login selfie first.');
    }
    final uri = site.resolve(status.referenceUrl!);
    if (uri.origin != site.origin || !uri.path.startsWith('/private/files/')) {
      throw StateError('ERP returned an invalid private face photo URL.');
    }
    final auth = await _auth(expectedUser: status.currentUser);
    final request =
        http.Request('GET', uri)
          ..headers.addAll(auth.headers)
          ..followRedirects = false;
    final response = await _send(request);
    final bytes = response.bodyBytes;
    if (response.statusCode != 200 ||
        bytes.length < 4 ||
        bytes.length > 2 * 1024 * 1024 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8) {
      throw StateError(
        'Your private enrollment photo could not be loaded. Please retry.',
      );
    }
    await assertSessionUser(status.currentUser);
    return bytes;
  }

  Future<FaceVerificationReceipt> recordVerification({
    required FaceEnrollmentStatus status,
    required String action,
    required double similarity,
    required double latitude,
    required double longitude,
    required DateTime capturedOn,
  }) async {
    if (action != 'attendance_in' && action != 'attendance_out') {
      throw ArgumentError.value(
        action,
        'action',
        'Face verification is only available for attendance.',
      );
    }
    if (status.receiptVersion != 2) {
      throw StateError(
        'Update the ERP face scripts to use attendance without saving selfies.',
      );
    }
    final message = await _post(status, {
      'action': 'record_verification',
      'verification_action': action,
      'reference_file': status.referenceName,
      'reference_version': status.referenceVersion,
      'model_version': modelVersion,
      'similarity': similarity,
      'blink_completed': true,
      'latitude': latitude,
      'longitude': longitude,
      'captured_on': capturedOn.toUtc().toIso8601String(),
    });
    if (message['receipt_version'] != 2) {
      throw StateError('ERP did not confirm the updated face receipt format.');
    }
    for (final key in ['record_id']) {
      if (message[key] is! String || (message[key] as String).isEmpty) {
        throw StateError('ERP did not create your face verification receipt.');
      }
    }
    return FaceVerificationReceipt(recordId: message['record_id']);
  }
}
