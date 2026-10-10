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

  static checkin(id, lat, lng, String address, String type) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');

    try {
      var response = await http.get(
        Uri.parse(
          '$methodapiUrl.checkin?user=$id&lat=$lat&lng=$lng&address=${Uri.encodeComponent(address)}&office_type=$type',
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

  static checkout(
    id,
    lat,
    lng,
    String address,
    lastCheckoutAddress,
    distance,
    String type,
    List<Map<String, dynamic>> locationLogs,
  ) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      token = prefs.getString('token');
      final withEvent = prefs.getBool('with_event');
      final lastLatLng = prefs.getString('last_lat_lng');

      var response = await http.get(
        Uri.parse(
          '$methodapiUrl.checkout?user=$id&lat=$lat&lng=$lng&address=${Uri.encodeComponent(address)}&lastCheckoutAddress=$lastCheckoutAddress&distance=$distance&office_type=$type&"location_logs": locationLogs&with_event=$withEvent&last_lat_lng=$lastLatLng',
        ),
        headers: {"Authorization": token ?? ""},
      );

      final data = json.decode(response.body);
      String message = data['message'].toString();
      String status = "Success";

      if (response.statusCode == 403) {
        status = "Warning";
      } else if (response.statusCode == 400 || response.statusCode == 500) {
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
