import 'package:shared_preferences/shared_preferences.dart';
import 'session_auth.dart';

class LoginApi {
  static Future<Map<String, dynamic>> login(String usr, String pwd) async {
    try {
      // One guarded request creates both credentials; never call standard
      // /login first, which could invalidate the active phone's session.
      final user = await SessionAuthApi.login(usr, pwd);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('api_key');
      await prefs.remove('api_secret');
      await prefs.setString('email', user['username']!);
      await prefs.setString('name', user['full_name']!);
      return {
        'name': user['full_name'],
        'employee_id': user['employee_id'],
        'token': user['token'],
      };
    } catch (error) {
      // A rejected second phone must never log out the first phone or release
      // its binding. Same-installation retries recover a lost login response.
      return {
        'error': error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('Exception: ', ''),
      };
    }
  }
}
