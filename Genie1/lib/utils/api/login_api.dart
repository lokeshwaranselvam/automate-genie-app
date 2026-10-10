import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'session_auth.dart';

class LoginApi {
  static late SharedPreferences prefs;
  static final emploginapiURL = dotenv.env['URL'];

  static Future<Map<String, dynamic>> login(String usr, String pwd) async {
    final prefs = await SharedPreferences.getInstance();

    try {
      // Keep the Frappe session user in sync with the API credentials used by Genie1.
      final sessionUser = await SessionAuthApi.login(usr, pwd);
      var response = await http.post(
        Uri.parse('$emploginapiURL.login'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({"usr": usr, "pwd": pwd}),
      );

      var data = json.decode(response.body);

      if (response.statusCode == 401) {
        await SessionAuthApi.logout();
        return {'error': 'Incorrect Username or Password'};
      }

      if (response.statusCode == 403) {
        await SessionAuthApi.logout();
        return {'error': data['message']['message'] ?? 'Access Denied'};
      }

      if (response.statusCode == 200 && data['message'] == "Logged In") {
        await prefs.setString('name', data['full_name']);
        await prefs.setString('email', data['email']);
        await prefs.setString('api_key', data['api_key']);
        await prefs.setString('api_secret', data['api_secret']);
        await prefs.setString('token', data['token']);
        // The standard Frappe session is authoritative for the signed-in user.
        await prefs.setString('email', sessionUser['username']!);
        await prefs.setString(
          'name',
          data['full_name'] ?? sessionUser['full_name']!,
        );

        return {
          'name': data['full_name'] ?? sessionUser['full_name'],
          'employee_id': data['employee_id'],
          'token': data['token'],
        };
      } else {
        await SessionAuthApi.logout();
        return {'error': data['message'] ?? 'Login failed'};
      }
    } catch (e) {
      await SessionAuthApi.logout();
      return {'error': 'Exception: $e'};
    }
  }
}
