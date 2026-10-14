import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/face/face_performance_trace.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('diagnostics log only known finite durations', () {
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    try {
      for (final value in [
        null,
        'invalid',
        {},
        {'attendance_timings_ms': []},
      ]) {
        FacePerformanceTrace.logServerTimings(value);
      }
      FacePerformanceTrace.logServerTimings({
        'attendance_timings_ms': {
          'file_insert': 123.5,
          'receipt_insert': 'private data',
          'receipt_secure': double.nan,
          'guard_total': -1,
          'attach_total': double.infinity,
          'verification_total': 1e50,
          'private_identity': 'staff@example.test',
        },
      });
      expect(lines, ['[Attendance timing] server private File insert: 123 ms']);
    } finally {
      debugPrint = original;
    }
  });

  test(
    'diagnostics include checkout endpoint stages',
    () {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
      try {
        FacePerformanceTrace.logServerTimings({
          'attendance_timings_ms': {
            'checkout_google_distance': 8000,
            'checkout_visit_save': 2000,
            'checkout_commit': 500,
            'checkout_total': 11000,
          },
        });
        expect(lines, [
          '[Attendance timing] server checkout Google distance lookup: 8000 ms',
          '[Attendance timing] server checkout Visit save: 2000 ms',
          '[Attendance timing] server checkout transaction commit: 500 ms',
          '[Attendance timing] server checkout endpoint total: 11000 ms',
        ]);
      } finally {
        debugPrint = original;
      }
    },
  );

  test(
    'timing waits for complete response body and sends exactly once',
    () async {
      final body = StreamController<List<int>>();
      final headersReturned = Completer<void>();
      var sends = 0;
      final client = MockClient.streaming((request, stream) async {
        sends++;
        await stream.drain<void>();
        headersReturned.complete();
        return http.StreamedResponse(body.stream, 200);
      });
      var completed = false;
      final result = FacePerformanceTrace.send(
        client,
        http.Request('GET', Uri.parse('https://erp.example.test/attendance')),
        'check-in',
      ).then((response) {
        completed = true;
        return response;
      });
      await headersReturned.future;
      expect(completed, isFalse);
      body.add(utf8.encode('{"message":"saved"}'));
      await body.close();
      expect((await result).body, '{"message":"saved"}');
      expect(sends, 1);
      client.close();
    },
  );
}
