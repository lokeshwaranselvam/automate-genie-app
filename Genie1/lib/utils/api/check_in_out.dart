import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'session_auth.dart';
import '../face/face_performance_trace.dart';

class Check {
  static Future<http.Response> _sendAttendance(
    Uri uri,
    Map<String, String> headers,
    String stage,
  ) async {
    final client = http.Client();
    try {
      return await FacePerformanceTrace.send(
        client,
        http.Request('GET', uri)..headers.addAll(headers),
        stage,
      );
    } finally {
      client.close();
    }
  }

  static pingpong() async {
    try {
      final baseUrl = dotenv.env['SITE_URL'];
      final uri = Uri.parse('$baseUrl/api/method/ping');
      // Browser cookies are automatic; a read-only ping must not need CSRF.
      final response = kIsWeb
          ? await http.get(uri, headers: {'Accept': 'application/json'})
          : await http.post(uri, headers: {'Accept': 'application/json'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data != null && data['message'] == 'pong') {
          return data;
        }
      }
      return false;
    } catch (e) {
      print("Error in pingpong: $e");
      return false;
    }
  }

  static Future<bool> sessionActive(String token, String email) async {
    return SessionAuthApi.isSessionActive(email);
  }

  static final methodapiUrl = dotenv.env['URL'];
  static String? token;

  static checkin(
    id,
    lat,
    lng,
    String address,
    String type, {
    String? photoUrl,
    String? faceVerification,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');

    try {
      var response = await _sendAttendance(
        Uri.parse(
          '$methodapiUrl.checkin?user=$id&lat=$lat&lng=$lng&address=${Uri.encodeComponent(address)}&office_type=$type'
          '${photoUrl == null ? '' : '&photo_url=${Uri.encodeComponent(photoUrl)}'}'
          '${faceVerification == null ? '' : '&face_verification=${Uri.encodeComponent(faceVerification)}'}'
          '${faceVerification != null && FacePerformanceTrace.enabled ? '&include_timings=1' : ''}',
        ),
        {"Authorization": token ?? ""},
        'check-in',
      );

      var data = json.decode(response.body);
      FacePerformanceTrace.logServerTimings(data);

      if (response.statusCode == 200) {
        return {
          "message": data['message'] ?? "No message",
          "status":
              data['message'] == "Check-In Created Successfully"
                  ? "Success"
                  : "Error",
        };
      } else {
        return {
          "message": "Server error: ${response.statusCode}",
          "status": "Error",
        };
      }
    } catch (e) {
      print('Check-in error: $e');
      return {
        "message": "An error occurred while checking in.",
        "status": "Error",
      };
    }
  }

  static Future<Map<String, dynamic>> getStatus(
    String email, {
    bool recordsFirst = false,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final auth = prefs.getString('token') ?? '';
    final employeeDetails = <String, dynamic>{};
    if (recordsFirst) {
      final records = await const FacePerformanceTrace().measure(
        'direct attendance records',
        () => _readAttendanceRecords(
          email,
          auth,
          employeeDetails: employeeDetails,
        ),
      );
      if (records != null) {
        return {
          ...records,
          ...employeeDetails,
          'attendance_records_verified': true,
          'attendance_status_source': 'employee_checkin_records',
        };
      }
      // Preserve the paired-status fallback for permission-limited accounts.
    }
    final results = await Future.wait<Object?>([
      http
          .post(
            Uri.parse(
              '$methodapiUrl.get_checkin_checkout_status',
            ).replace(queryParameters: {'user': email}),
            headers: {
              'Authorization': auth,
              'Cache-Control': 'no-cache, no-store',
            },
          )
          .timeout(const Duration(seconds: 15))
          .catchError((Object _) => http.Response('', 503)),
      recordsFirst
          ? Future<Map<String, dynamic>?>.value(null)
          : _readAttendanceRecords(
            email,
            auth,
            employeeDetails: employeeDetails,
          ),
    ]);
    final response = results[0] as http.Response;
    Map<String, dynamic> status = {};
    if (response.statusCode == 200) {
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['message'] is Map) {
          status = Map<String, dynamic>.from(body['message']);
        }
      } catch (_) {}
    }
    final records = results[1] as Map<String, dynamic>?;
    if (records != null) {
      // Read real rows: checkout_status is an action-availability flag on
      // some ERP versions, NOT proof that an OUT record exists.
      status.addAll(records);
      status['attendance_records_verified'] = true;
      status['attendance_status_source'] = 'employee_checkin_records';
    } else if (status['checked_in'] is bool && status['checked_out'] is bool) {
      // Permission-limited accounts can use the main endpoint's paired flags.
      // Never replace its checked_out with the unrelated checkout_status flag.
      final hasIn = status['checked_in'] == true;
      final hasOut = status['checked_out'] == true;
      status['completed_today'] = hasIn && hasOut;
      status['checked_in'] = hasIn && !hasOut;
      status['attendance_records_verified'] = true;
      status['attendance_status_source'] = 'paired_server_status';
    } else {
      status['attendance_records_verified'] = false;
    }
    return {...status, ...employeeDetails};
  }

  static Future<Map<String, dynamic>?> _readAttendanceRecords(
    String email,
    String authorization, {
    Map<String, dynamic>? employeeDetails,
  }) async {
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    if (site.isEmpty) return null;
    final base = Uri.parse(site.endsWith('/') ? site : '$site/');
    final headers = {
      'Authorization': authorization,
      'Cache-Control': 'no-cache, no-store',
    };
    Future<List<Map<String, dynamic>>> rows(
      String doctype,
      Map<String, String> query,
    ) async {
      var response = await http
          .get(
            base
                .resolve('api/resource/${Uri.encodeComponent(doctype)}')
                .replace(queryParameters: query),
            headers: headers,
          )
          .timeout(const Duration(seconds: 12));
      if (doctype == 'Employee' &&
          (response.statusCode == 403 || response.statusCode == 417)) {
        // Optional profile metadata must not break attendance record lookup.
        response = await http
            .get(
              base
                  .resolve('api/resource/Employee')
                  .replace(
                    queryParameters: {
                      ...query,
                      'fields': jsonEncode(['name']),
                    },
                  ),
              headers: headers,
            )
            .timeout(const Duration(seconds: 12));
      }
      if (response.statusCode != 200) {
        throw StateError('Attendance records unavailable.');
      }
      final body = jsonDecode(response.body);
      if (body is! Map || body['data'] is! List) {
        throw const FormatException('Invalid attendance records.');
      }
      return (body['data'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    }

    try {
      final employees = await rows('Employee', {
        'filters': jsonEncode({'user_id': email, 'status': 'Active'}),
        'fields': jsonEncode(['name', 'default_shift']),
        'limit_page_length': '2',
      });
      if (employees.length != 1 || employees.single['name'] is! String) {
        return null;
      }
      if (employees.single.containsKey('default_shift')) {
        employeeDetails?['default_shift'] = employees.single['default_shift'];
      }
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      String day(DateTime value) =>
          '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} 00:00:00';
      final common = {
        'fields': jsonEncode(['name', 'log_type', 'time']),
        'order_by': 'time desc, creation desc',
      };
      final results = await Future.wait([
        rows('Employee Checkin', {
          ...common,
          'filters': jsonEncode([
            ['employee', '=', employees.single['name']],
            ['time', '>=', day(today)],
            ['time', '<', day(tomorrow)],
          ]),
          'limit_page_length': '1000',
        }),
        rows('Employee Checkin', {
          ...common,
          'filters': jsonEncode([
            ['employee', '=', employees.single['name']],
            ['time', '<', day(today)],
          ]),
          'limit_page_length': '1',
        }),
      ]);
      final logs = results[0];
      if (logs.any(
        (row) => row['log_type'] != 'IN' && row['log_type'] != 'OUT',
      )) {
        return null;
      }
      final ins = logs.where((row) => row['log_type'] == 'IN');
      final outs = logs.where((row) => row['log_type'] == 'OUT');
      final hasIn = ins.isNotEmpty;
      final hasOut = outs.isNotEmpty;
      final active = hasIn && logs.first['log_type'] == 'IN';
      final completed = hasIn && hasOut && !active;
      final previousPending =
          logs.isEmpty &&
          results[1].isNotEmpty &&
          results[1].first['log_type'] == 'IN';
      return {
        'checked_in': active,
        'checked_out': completed,
        'completed_today': completed,
        'check_in_exists_today': hasIn,
        'check_out_exists_today': hasOut,
        'previous_checkout_pending': previousPending,
        if (previousPending) 'check_in_time': results[1].first['time'],
        if (hasIn) 'check_in_time': ins.first['time'],
        if (completed) 'check_out_time': outs.first['time'],
      };
    } catch (_) {
      return null;
    }
  }

  /// Returns why an event/visit check-in must be blocked, or null when the
  /// employee is checked in for today. Uses the server's attendance status,
  /// not a cached flag, so a stale local state cannot let it through.
  static Future<String?> eventCheckinBlockReason(String? email) async {
    if (email == null || email.trim().isEmpty) {
      return 'Your signed-in user is missing. Please sign in again.';
    }
    final Map<String, dynamic> status;
    try {
      final response = await getStatus(
        email.trim(),
      ).timeout(const Duration(seconds: 15));
      status = Map<String, dynamic>.from(response);
      if (status['attendance_records_verified'] != true) {
        return 'Could not verify your Employee Check-in for today. '
            'Check your connection and try again.';
      }
    } catch (e) {
      print('Attendance status check failed: $e');
      return 'Could not verify your Employee Check-in for today. '
          'Check your connection and try again.';
    }
    if (status['previous_checkout_pending'] == true) {
      return 'Your previous day Employee Check-in is still open. '
          'Check out of it and do today\'s Employee Check-in before checking in to this visit.';
    }
    if (status['checked_in'] != true) {
      return 'Please complete your Employee Check-in for today '
          'before checking in to this visit.';
    }
    return null;
  }

  static checkout(
    id,
    lat,
    lng,
    String address,
    lastCheckoutAddress,
    distance,
    String type,
    List<Map<String, dynamic>> locationLogs, {
    String? photoUrl,
    String? faceVerification,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      token = prefs.getString('token');
      final withEvent = prefs.getBool('with_event');
      final lastLatLng = prefs.getString('last_lat_lng');

      // Build the query with Uri so addresses containing '&', '#' or spaces
      // are encoded instead of breaking the request.
      final uri = Uri.parse('$methodapiUrl.checkout').replace(
        queryParameters: {
          'user': '$id',
          'lat': '$lat',
          'lng': '$lng',
          'address': address,
          'lastCheckoutAddress': '${lastCheckoutAddress ?? ''}',
          'distance': '$distance',
          'office_type': type,
          'with_event': '$withEvent',
          'last_lat_lng': '$lastLatLng',
          if (photoUrl != null) 'photo_url': photoUrl,
          if (faceVerification != null) 'face_verification': faceVerification,
          if (faceVerification != null && FacePerformanceTrace.enabled)
            'include_timings': '1',
        },
      );
      var response = await _sendAttendance(uri, {
        "Authorization": token ?? "",
      }, 'check-out');

      final data = json.decode(response.body);
      FacePerformanceTrace.logServerTimings(data);
      String message =
          (data is Map ? data['message'] : null)?.toString() ??
          'Checkout failed (${response.statusCode}).';
      String status = "Success";

      if ((response.statusCode == 200 || response.statusCode == 403) &&
          RegExp(
            r'^(?:employee\s+)?already\s+checked\s*out\b',
            caseSensitive: false,
          ).hasMatch(message.trim())) {
        // The desired OUT already exists. Reconcile the UI just like a
        // successful checkout, including the legacy endpoint's 403 warning.
        status = 'Success';
      } else if (response.statusCode == 403) {
        status = "Warning";
      } else if (response.statusCode != 200) {
        // Any other non-200 (401, 404, 417 validation, 5xx) is a failure;
        // treating it as Success stopped tracking while still checked in.
        status = "Error";
      } else if (message.contains("CheckIn Already Exists")) {
        status = "Warning";
      }

      return {"message": message, "status": status};
    } catch (e) {
      print(['error $e']);
      return {"message": "Something went wrong: $e", "status": "Error"};
    }
  }

  static Future<bool?> check_in_status(user) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      token = prefs.getString('token');
      var response = await http
          .get(
            Uri.parse(
              '$methodapiUrl.checkin_status',
            ).replace(queryParameters: {'user': '$user'}),
            headers: {
              'Authorization': token ?? '',
              'Cache-Control': 'no-cache, no-store',
            },
          )
          .timeout(const Duration(seconds: 15));
      var data = json.decode(response.body);

      if (response.statusCode == 200) {
        return data is Map && data['message'] is bool ? data['message'] : null;
      }
    } catch (e) {
      print(['error $e']);
    }
    return null;
  }

  static Future<bool?> check_out_status(user) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      token = prefs.getString('token');
      var response = await http
          .get(
            Uri.parse(
              '$methodapiUrl.checkout_status',
            ).replace(queryParameters: {'user': '$user'}),
            headers: {
              'Authorization': token ?? '',
              'Cache-Control': 'no-cache, no-store',
            },
          )
          .timeout(const Duration(seconds: 15));
      var data = json.decode(response.body);

      if (response.statusCode == 200) {
        return data is Map && data['message'] is bool ? data['message'] : null;
      }
    } catch (e) {
      print(['error $e']);
    }
    return null;
  }

  static Future<bool?> hasCompletedAttendanceToday(String user) async {
    try {
      final status = await getStatus(user);
      return status['attendance_records_verified'] == true
          ? status['completed_today'] == true
          : null;
    } catch (_) {
      return null;
    }
  }
}
