import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

// Opt-in, read-only verification against the debug phone's existing account.
// Credentials are provided in a temporary process environment, never a file.
void main() {
  final input = Platform.environment['GENIE_ATTENDANCE_READONLY_JSON'];
  // Create before the widget binding installs its no-network HTTP override.
  final connections =
      input == null ? <HttpClient>[] : List.generate(8, (_) => HttpClient());
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live checkout resolves from saved Employee Checkin rows',
    () async {
      final config = jsonDecode(input!) as Map;
      dotenv.testLoad(
        fileInput: 'URL=${config['URL']}\nSITE_URL=${config['SITE_URL']}',
      );
      SharedPreferences.setMockInitialValues({'token': config['token']});
      final status = await http.runWithClient(
        () => Check.getStatus(config['email']),
        () => IOClient(connections.removeLast()),
      );
      expect(status['attendance_status_source'], 'employee_checkin_records');
      expect(status['attendance_records_verified'], isTrue);
      expect(status['checked_in'], isFalse);
      expect(status['completed_today'], isTrue);
      for (final connection in connections) {
        connection.close(force: true);
      }
    },
    skip:
        input == null ? 'Requires an explicit read-only debug session.' : false,
  );
}
