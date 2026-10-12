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
        // The 403 message may be a map ({message: ...}) or a plain string.
        final message = data is Map ? data['message'] : null;
        final detail =
            message is Map ? message['message']?.toString() : message?.toString();
        return {
          'error': (detail == null || detail.isEmpty) ? 'Access Denied' : detail,
        };
      }

      if (response.statusCode == 200 && data['message'] == "Logged In") {
        // Missing fields must not throw (setString rejects null), so fall back
        // to the verified Frappe session values or skip the key.
        Future<void> save(String key, dynamic value) async {
          final text = value?.toString();
          if (text != null && text.isNotEmpty) await prefs.setString(key, text);
        }

        // api_key/api_secret are not used by the app; don't keep them in
        // plain-text SharedPreferences, and remove copies saved by older builds.
        await prefs.remove('api_key');
        await prefs.remove('api_secret');
        await save('token', data['token']);
        // The standard Frappe session is authoritative for the signed-in user.
        await prefs.setString('email', sessionUser['username']!);
        await prefs.setString(
          'name',
          data['full_name']?.toString() ?? sessionUser['full_name']!,
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
