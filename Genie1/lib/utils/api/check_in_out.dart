import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'session_auth.dart';

class Check {
  static pingpong() async {
    try {
      final baseUrl = dotenv.env['SITE_URL'];
      final uri = Uri.parse('$baseUrl/api/method/ping');
      final response = await http.post(
        uri,
        headers: {'Accept': 'application/json'},
      );
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
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');

    try {
      var response = await http.get(
        Uri.parse(
          '$methodapiUrl.checkin?user=$id&lat=$lat&lng=$lng&address=${Uri.encodeComponent(address)}&office_type=$type'
          '${photoUrl == null ? '' : '&photo_url=${Uri.encodeComponent(photoUrl)}'}',
        ),
        headers: {"Authorization": token ?? ""},
      );

      var data = json.decode(response.body);

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

  static Future<Map<String, dynamic>> getStatus(String email) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    token = prefs.getString('token');

    final response = await http.post(
      Uri.parse("$methodapiUrl.get_checkin_checkout_status?user=$email"),
      headers: {"Authorization": token ?? ""},
    );

    final body = jsonDecode(response.body);
    return body["message"];
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
        },
      );
      var response = await http.get(
        uri,
        headers: {"Authorization": token ?? ""},
      );

      final data = json.decode(response.body);
      String message =
          (data is Map ? data['message'] : null)?.toString() ??
          'Checkout failed (${response.statusCode}).';
      String status = "Success";

      if (response.statusCode == 403) {
        status = "Warning";
      } else if (response.statusCode != 200) {
        // Any other non-200 (401, 404, 417 validation, 5xx) is a failure;
        // treating it as Success stopped tracking while still checked in.
        status = "Error";
      } else if (message.contains("Already checked out")) {
        status = "Warning";
      } else if (message.contains("CheckIn Already Exists")) {
        status = "Warning";
      }

      return {"message": message, "status": status};
    } catch (e) {
      print(['error $e']);
      return {"message": "Something went wrong: $e", "status": "Error"};
    }
  }

  static check_in_status(user) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      token = prefs.getString('token');
      var response = await http.get(
        Uri.parse('$methodapiUrl.checkin_status?user=$user'),
        headers: {"Authorization": token ?? ""},
      );
      var data = json.decode(response.body);

      if (response.statusCode == 200) {
        if (data['message'] == true) {
          return true;
        } else {
          return false;
        }
      }
    } catch (e) {
      print(['error $e']);
    }
  }

  static check_out_status(user) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      token = prefs.getString('token');
      var response = await http.get(
        Uri.parse('$methodapiUrl.checkout_status?user=$user'),
        headers: {"Authorization": token ?? ""},
      );
      var data = json.decode(response.body);

      if (response.statusCode == 200) {
        if (data['message'] == true) {
          return true;
        } else {
          return false;
        }
      }
    } catch (e) {
      print(['error $e']);
    }
  }
}
