import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Stage timings only; never logs images, coordinates, identities or scores.
class FacePerformanceTrace {
  const FacePerformanceTrace();

  static const enabled =
      !kReleaseMode || bool.fromEnvironment('ATTENDANCE_TIMINGS');

  /// Header wait includes connection, upload, server queue/work and commit.
  /// It must not be interpreted as upload time alone.
  static Future<http.Response> send(
    http.Client client,
    http.BaseRequest request,
    String stage,
  ) async {
    const timing = FacePerformanceTrace();
    final response = await timing.measure(
      '$stage response headers',
      () => client.send(request),
    );
    return timing.measure(
      '$stage response body',
      () => http.Response.fromStream(response),
    );
  }

  static void logServerTimings(dynamic body) {
    if (!enabled || body is! Map) return;
    final timings = body['attendance_timings_ms'];
    if (timings is! Map) return; // Compatible with older server scripts.
    // Only known duration fields may enter logs, never arbitrary server text.
    const stages = {
      'request_validation': 'request validation',
      'jpeg_validation': 'JPEG validation',
      'file_insert': 'private File insert',
      'receipt_insert': 'receipt insert',
      'receipt_secure': 'receipt ownership update',
      'verification_total': 'verification script total',
      'receipt_lock': 'receipt lock',
      'guard_total': 'before-insert guard total',
      'attachment_file_save': 'attachment File save',
      'attach_total': 'after-insert attachment total',
      'checkin_employee_lookup': 'checkin employee lookup',
      'checkin_existing_in': 'checkin existing IN lookup',
      'checkin_checkin_save': 'checkin Employee Checkin save',
      'checkin_visit_save': 'checkin Visit save',
      'checkin_commit': 'checkin transaction commit',
      'checkin_total': 'checkin endpoint total',
      'checkout_employee_lookup': 'checkout employee lookup',
      'checkout_active_visit': 'checkout active visit lookup',
      'checkout_latest_in': 'checkout latest IN lookup',
      'checkout_latest_out': 'checkout latest OUT lookup',
      'checkout_previous_visit': 'checkout previous visit lookup',
      'checkout_google_distance': 'checkout Google distance lookup',
      'checkout_checkin_save': 'checkout Employee Checkin save',
      'checkout_visit_save': 'checkout Visit save',
      'checkout_commit': 'checkout transaction commit',
      'checkout_total': 'checkout endpoint total',
    };
    for (final entry in stages.entries) {
      final value = timings[entry.key];
      if (value is num && value.isFinite && value >= 0 && value <= 3600000) {
        logDuration(
          'server ${entry.value}',
          Duration(microseconds: (value * 1000).round()),
        );
      }
    }
  }

  Future<T> measure<T>(String stage, Future<T> Function() operation) async {
    if (!enabled) return operation();
    final task = TimelineTask()..start('Attendance: $stage');
    final clock = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      task.finish();
      logDuration(stage, clock.elapsed);
    }
  }

  static void logDuration(String stage, Duration duration) {
    if (enabled) {
      debugPrint('[Attendance timing] $stage: ${duration.inMilliseconds} ms');
    }
  }
}
